import Foundation
import CAblLink

/// Ableton Link + Link Audio のラッパー。
/// - Link タイムライン (tempo / beat / isPlaying)
/// - Link Audio チャンネルの発見と購読 (受信した int16 PCM をモノラル化してリングバッファへ)
///
/// 受信コールバックは Link 管理スレッドで呼ばれるため、リングバッファはロックで保護する。
final class LinkEngine {

    struct Channel {
        let id: abl_link_audio_channel_id
        let name: String
        let peerName: String
        var key: String // "ピア名 | チャンネル名"。同名は " (2)" などを付けて一意化
    }

    private let link: abl_link
    private let sessionState: abl_link_session_state

    // ring buffer (stereo float)
    private let ringSize = 16384 // 2^14
    private var ringL: [Float]
    private var ringR: [Float]
    private var writeIndex = 0
    private let lock = NSLock()
    private(set) var sampleRate: Double = 0
    private var framesReceived: UInt64 = 0
    private var monitorOut: MonitorOutput?

    // channels
    private var channelsDirtyFlag = ManagedAtomic(true)
    private(set) var channels: [Channel] = []
    private var source: abl_link_audio_source?
    private var sourceKey: String?

    init() {
        link = abl_link_create(120.0)
        sessionState = abl_link_create_session_state()
        ringL = [Float](repeating: 0, count: ringSize)
        ringR = [Float](repeating: 0, count: ringSize)

        abl_link_audio_set_peer_name(link, "LinkOSC")
        abl_link_enable_start_stop_sync(link, true)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        abl_link_audio_set_channels_changed_callback(link, { ctx in
            guard let ctx else { return }
            Unmanaged<LinkEngine>.fromOpaque(ctx).takeUnretainedValue()
                .channelsDirtyFlag.set(true)
        }, ctx)
    }

    deinit {
        removeSource()
        abl_link_destroy_session_state(sessionState)
        abl_link_destroy(link)
    }

    // MARK: - Link enable / timeline

    func setEnabled(_ on: Bool) {
        if on {
            // Link セッション参加後に Link Audio を入れ直すことで
            // チャンネル告知/購読のネゴシエーションを確実に開始させる
            abl_link_enable(link, true)
            abl_link_audio_enable_link_audio(link, false)
            abl_link_audio_enable_link_audio(link, true)
            channelsDirtyFlag.set(true)
        } else {
            abl_link_audio_enable_link_audio(link, false)
            abl_link_enable(link, false)
        }
    }

    struct Timeline {
        var beat: Double
        var phase: Double
        var tempo: Double
        var isPlaying: Bool
        var peers: Int
    }

    func timeline(quantum: Double = 4.0) -> Timeline {
        abl_link_capture_app_session_state(link, sessionState)
        let now = abl_link_clock_micros(link)
        return Timeline(
            beat: abl_link_beat_at_time(sessionState, now, quantum),
            phase: abl_link_phase_at_time(sessionState, now, quantum),
            tempo: abl_link_tempo(sessionState),
            isPlaying: abl_link_is_playing(sessionState),
            peers: Int(abl_link_num_peers(link))
        )
    }

    // MARK: - Channels

    private var lastChannelRefresh = Date.distantPast

    /// Link Audio の探索を再起動する (Refresh ボタン用)。
    /// コールバック取りこぼしや参加タイミングの問題への保険。
    func restartAudioDiscovery() {
        removeSource()
        abl_link_audio_enable_link_audio(link, false)
        abl_link_audio_enable_link_audio(link, true)
        channelsDirtyFlag.set(true)
    }

    /// チャンネル一覧が変化していれば再取得して true を返す。
    /// コールバック由来の dirty フラグに加え、2秒ごとのポーリングでも再取得する
    /// (発見タイミング・コールバック取りこぼし対策)。
    @discardableResult
    func refreshChannelsIfNeeded() -> Bool {
        let dirty = channelsDirtyFlag.getAndSet(false)
        let polled = Date().timeIntervalSince(lastChannelRefresh) > 2.0
        guard dirty || polled else { return false }
        lastChannelRefresh = Date()
        let oldKeys = channels.map { $0.key }
        let list = abl_link_audio_get_channels(link)
        var result: [Channel] = []
        if let items = list.channels {
            for i in 0..<list.count {
                let c = items[i]
                result.append(Channel(
                    id: c.id,
                    name: c.name.map { String(cString: $0) } ?? "?",
                    peerName: c.peer_name.map { String(cString: $0) } ?? "?",
                    key: ""
                ))
            }
        }
        abl_link_audio_free_channel_list(list)

        // 表示順とキーの一意化を安定させる (同名トラック対策)
        result.sort { lhs, rhs in
            if lhs.peerName != rhs.peerName { return lhs.peerName < rhs.peerName }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return withUnsafeBytes(of: lhs.id.bytes) { a in
                withUnsafeBytes(of: rhs.id.bytes) { b in
                    a.lexicographicallyPrecedes(b)
                }
            }
        }
        var seen: [String: Int] = [:]
        channels = result.map { c in
            let base = "\(c.peerName) | \(c.name)"
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            var out = c
            out.key = n > 1 ? "\(base) (\(n))" : base
            return out
        }
        return channels.map { $0.key } != oldKeys
    }

    /// 希望チャンネル (key 文字列) に合わせて source を張り替える
    func syncSource(desiredKey: String) {
        if desiredKey.isEmpty {
            removeSource()
            return
        }
        guard let target = channels.first(where: { $0.key == desiredKey }) else {
            // 目的のチャンネルが消えたら購読解除して再出現を待つ
            removeSource()
            return
        }
        if sourceKey == target.key, source != nil { return }
        removeSource()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        source = abl_link_audio_source_create(link, target.id, { buffer, ctx in
            guard let buffer, let ctx else { return }
            Unmanaged<LinkEngine>.fromOpaque(ctx).takeUnretainedValue().push(buffer)
        }, ctx)
        sourceKey = target.key
    }

    func removeSource() {
        if let s = source {
            abl_link_audio_source_destroy(s)
            source = nil
            sourceKey = nil
        }
    }

    var isReceiving: Bool { source != nil }

    /// 受信音のモニター出力先を設定 (nil で解除)
    func setMonitor(_ m: MonitorOutput?) {
        lock.lock()
        monitorOut = m
        lock.unlock()
    }

    // MARK: - Audio ring buffer

    private func push(_ buffer: UnsafePointer<abl_link_audio_source_buffer>) {
        let info = buffer.pointee.info
        guard let samples = buffer.pointee.samples else { return }
        let frames = Int(info.num_frames)
        let ch = max(1, Int(info.num_channels))
        let mask = ringSize - 1

        lock.lock()
        sampleRate = Double(info.sample_rate)
        var w = writeIndex
        for f in 0..<frames {
            let l = Float(samples[f * ch]) / 32768.0
            let r = ch > 1 ? Float(samples[f * ch + 1]) / 32768.0 : l
            ringL[w] = l
            ringR[w] = r
            w = (w + 1) & mask
        }
        writeIndex = w
        framesReceived &+= UInt64(frames)
        let monitor = monitorOut
        let sr = sampleRate
        lock.unlock()

        // Link のリアルタイムコールバックではヒープ確保しない。
        // 元の interleaved Int16 を同期的に FIFO へ変換し、一時 L/R 配列を避ける。
        monitor?.append(interleavedInt16: samples, frames: frames,
                        channels: ch, sampleRate: sr)
    }

    /// 最新 count サンプル (モノラルミックス) を時系列順にコピーして返す
    func latestSamples(_ count: Int, into out: inout [Float]) {
        precondition(out.count == count && count <= ringSize)
        let mask = ringSize - 1
        lock.lock()
        var r = (writeIndex - count) & mask
        for i in 0..<count {
            out[i] = (ringL[r] + ringR[r]) * 0.5
            r = (r + 1) & mask
        }
        lock.unlock()
    }

    /// 最新 count サンプルを L/R 別々にコピーして返す
    func latestStereo(_ count: Int, intoL: inout [Float], intoR: inout [Float]) {
        precondition(intoL.count == count && intoR.count == count && count <= ringSize)
        let mask = ringSize - 1
        lock.lock()
        var r = (writeIndex - count) & mask
        for i in 0..<count {
            intoL[i] = ringL[r]
            intoR[i] = ringR[r]
            r = (r + 1) & mask
        }
        lock.unlock()
    }

    /// 受信統計 (累計フレーム数, サンプルレート)
    func stats() -> (frames: UInt64, sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (framesReceived, sampleRate)
    }
}

/// 最小限のアトミック Bool (コールバックスレッド → ループスレッド間のフラグ用)
final class ManagedAtomic {
    private var value: Bool
    private let lock = NSLock()
    init(_ v: Bool) { value = v }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func getAndSet(_ v: Bool) -> Bool {
        lock.lock()
        defer { value = v; lock.unlock() }
        return value
    }
}
