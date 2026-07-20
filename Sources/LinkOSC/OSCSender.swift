import Foundation
import Network

/// OSC メッセージのエンコード (最小実装)
enum OSC {
    private static func padded(_ s: String) -> Data {
        var d = Data(s.utf8)
        d.append(0)
        while d.count % 4 != 0 { d.append(0) }
        return d
    }

    private static func appendBE(_ v: UInt32, to d: inout Data) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
    }

    static func message(_ address: String, floats: [Float]) -> Data {
        var d = padded(address)
        d.append(padded("," + String(repeating: "f", count: floats.count)))
        for f in floats { appendBE(f.bitPattern, to: &d) }
        return d
    }

    static func message(_ address: String, float: Float) -> Data {
        message(address, floats: [float])
    }

    static func message(_ address: String, int: Int32) -> Data {
        message(address, ints: [int])
    }

    static func message(_ address: String, ints: [Int32]) -> Data {
        var d = padded(address)
        d.append(padded("," + String(repeating: "i", count: ints.count)))
        for i in ints { appendBE(UInt32(bitPattern: i), to: &d) }
        return d
    }
}

/// 送信メッセージのアドレス識別 (宛先フィルタ用)
enum OSCAddr {
    case fft, vol, pfft, pvol, hfft, hvol, hpss, novelty, chroma
    case beat, note, attack, pattack, section, ping
}

/// アドレスタグ付きメッセージ (エンコードは1回、フィルタは宛先ごと)
struct TaggedMsg {
    let addr: OSCAddr
    let data: Data
}

/// ④ 宛先ごとのアドレスフィルタ (プリセット)。/ping は常に通す (生死判定)。
enum DestFilter: String, CaseIterable, Codable, Identifiable {
    case all, streams, events, percussive
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .streams: return "Streams"
        case .events: return "Events"
        case .percussive: return "Perc"
        }
    }

    func allows(_ a: OSCAddr) -> Bool {
        if a == .ping { return true }
        switch self {
        case .all:
            return true
        case .streams:
            switch a {
            case .fft, .vol, .pfft, .pvol, .hfft, .hvol, .hpss, .novelty, .chroma:
                return true
            default:
                return false
            }
        case .events:
            switch a {
            case .beat, .note, .attack, .pattack, .section:
                return true
            default:
                return false
            }
        case .percussive:
            switch a {
            case .pfft, .pvol, .pattack, .hpss, .beat:
                return true
            default:
                return false
            }
        }
    }
}

extension OSC {
    /// ⑥ OSC バンドル: "#bundle" + timetag(immediate=1) + (size + message)...
    static func bundle(_ msgs: [Data]) -> Data {
        var d = Data("#bundle".utf8)
        d.append(0) // "#bundle\0" = 8 bytes
        d.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1]) // timetag: immediate
        for m in msgs {
            var be = UInt32(m.count).bigEndian
            withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
            d.append(m)
        }
        return d
    }

    /// IP フラグメンテーション回避のため maxBytes 以下にチャンクした複数バンドルを返す
    static func bundles(_ msgs: [Data], maxBytes: Int = 1400) -> [Data] {
        var out: [Data] = []
        var current: [Data] = []
        var size = 16 // ヘッダぶん
        for m in msgs {
            let add = 4 + m.count
            if !current.isEmpty, size + add > maxBytes {
                out.append(bundle(current))
                current = []
                size = 16
            }
            current.append(m)
            size += add
        }
        if !current.isEmpty { out.append(bundle(current)) }
        return out
    }

    /// ⑤ マルチキャストアドレス判定 (224.0.0.0 – 239.255.255.255)
    static func isMulticastHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4, let first = Int(parts[0]) else { return false }
        return (224...239).contains(first)
    }
}

/// UDP 送信先 1つぶん。
///
/// 重要: NWConnection は ready でない間や送信が滞っている間、send を無制限に
/// キューイングする。60fps 送信では数分で数万件の nw_write_request が連結され、
/// cancel 時にそのチェーンの再帰 dealloc がスタックオーバーフローでクラッシュする
/// (実クラッシュレポートで確認済み)。そのため ready 時のみ・in-flight 上限付きで
/// 送信し、あふれたパケットはドロップする (OSC は損失前提のプロトコル)。
final class OSCDestination {
    let host: String
    let port: UInt16
    let filter: DestFilter
    let bundled: Bool
    let isMulticast: Bool
    private let connection: NWConnection
    private let lock = NSLock()
    private var isReady = false
    private var inFlight = 0
    private var dropped: UInt64 = 0
    private let maxInFlight = 128

    init?(host: String, port: UInt16, queue: DispatchQueue,
          filter: DestFilter = .all, bundled: Bool = false,
          interface: NWInterface? = nil) {
        guard !host.isEmpty, port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            return nil
        }
        self.host = host
        self.port = port
        self.filter = filter
        self.bundled = bundled
        // ⑤ マルチキャスト宛先: 単に宛先 IP として送れる (join は受信側のみ必要)。
        //    TTL はデフォルト 1 = 同一セグメント内。有線 LAN 推奨 (Wi-Fi は低速/損失大)。
        self.isMulticast = OSC.isMulticastHost(host)
        // ② QoS: interactiveVideo で DSCP マーキング → Wi-Fi (WMM) のビデオ優先
        //    キューに乗り、混雑時のレイテンシ/ロスが改善する。内容は不変。
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        // 送信インターフェースの固定 (nil = Auto: OS のルーティングに任せる)。
        // マルチキャスト宛はどのサブネットにも一致しないため OS はプライマリ IF
        // から送出する — 二重ホーム環境で映像ネットワークが非プライマリ側の
        // ときは、ここで固定しないと届かない。
        if let interface { params.requiredInterface = interface }
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            lock.lock()
            switch state {
            case .ready:
                isReady = true
            default:
                isReady = false
            }
            lock.unlock()
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data) {
        lock.lock()
        guard isReady, inFlight < maxInFlight else {
            dropped &+= 1
            lock.unlock()
            return
        }
        inFlight += 1
        lock.unlock()

        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            lock.lock()
            inFlight -= 1
            lock.unlock()
        })
    }

    /// ① 複数メッセージを NWConnection.batch でまとめて送る。
    /// システムコール/ロックのオーバーヘッドが下がる (実測 5.8 → 3.7µs/msg)。
    func sendBatch(_ msgs: [Data]) {
        guard msgs.count > 1 else {
            if let m = msgs.first { send(m) }
            return
        }
        connection.batch {
            for m in msgs { send(m) }
        }
    }

    /// UI 表示用の状態 (ready か / 累計ドロップ数)
    func status() -> (ready: Bool, dropped: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (isReady, dropped)
    }

    /// 実際の送出経路 (ツールチップ用): "en0 · 192.168.1.23" など。未確定なら nil。
    /// 「違う NIC を掴んでいる」を沈黙の失敗ではなく目に見えるようにする。
    func viaInfo() -> String? {
        guard let path = connection.currentPath else { return nil }
        var parts: [String] = []
        if let name = path.availableInterfaces.first?.name { parts.append(name) }
        if case .hostPort(let h, _)? = path.localEndpoint { parts.append("\(h)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func cancel() {
        lock.lock()
        isReady = false
        lock.unlock()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

/// ③ アイドル抑制: stream メッセージの値が前回送信からほぼ変化していなければ
/// 送信をスキップし、最低 2Hz (30フレームごと) でリフレッシュ送信する。
/// latest-value store 型の受信側 (OSC-SPEC 推奨実装) には影響しない。
/// 無音・静止時のパケット数を ~96% 削減する。
struct StreamGate {
    static let epsilon: Float = 0.002
    static let refreshFrames = 30 // 60fps で 500ms = 最低 2Hz

    private var last: [Float] = []
    private var framesSinceSend = 1_000_000

    /// この値を今フレーム送るべきか。送ると判断したら内部状態を更新する。
    mutating func shouldSend(_ values: [Float]) -> Bool {
        framesSinceSend += 1
        if last.count != values.count || framesSinceSend >= Self.refreshFrames {
            last = values
            framesSinceSend = 0
            return true
        }
        var maxDelta: Float = 0
        for i in 0..<values.count {
            let d = abs(values[i] - last[i])
            if d > maxDelta { maxDelta = d }
        }
        if maxDelta > Self.epsilon {
            last = values
            framesSinceSend = 0
            return true
        }
        return false
    }
}

/// バースト平滑化: 同一フレームのメッセージを一斉に送らず、
/// 大きいメッセージ群を 1ms 間隔の後続スロットへずらして送る。
/// 受信側 (Max/TouchDesigner 等のシングルスレッド受信) の UDP バッファあふれと
/// Wi-Fi のバースト損失を避ける。スロット遅延は最大でも数 ms で、60fps の
/// 映像用途では知覚されない。
enum OSCPacing {
    static let slotMicroseconds = 1000

    /// `immediate` は即時、`paced[i]` は (i+1)×1ms 後に送る。
    /// - ④ 各宛先のフィルタを送信時に適用 (エンコードは共有)
    /// - ⑥ bundled 宛先はフレーム全体を #bundle にまとめて即時送信
    ///   (≤1400B にチャンクするので IP フラグメンテーションは起きない)
    /// - 非バンドル宛先は従来どおり batch + 1ms スロットのペーシング
    static func send(immediate: [TaggedMsg], paced: [[TaggedMsg]],
                     to dests: [OSCDestination], on queue: DispatchQueue) {
        var plain: [OSCDestination] = []
        for s in dests {
            if s.bundled {
                let all = (immediate + paced.flatMap { $0 })
                    .filter { s.filter.allows($0.addr) }
                    .map(\.data)
                if !all.isEmpty {
                    s.sendBatch(OSC.bundles(all))
                }
            } else {
                plain.append(s)
            }
        }
        guard !plain.isEmpty else { return }
        for s in plain {
            s.sendBatch(immediate.filter { s.filter.allows($0.addr) }.map(\.data))
        }
        for (i, group) in paced.enumerated() {
            queue.asyncAfter(deadline: .now() + .microseconds((i + 1) * slotMicroseconds)) {
                for s in plain {
                    s.sendBatch(group.filter { s.filter.allows($0.addr) }.map(\.data))
                }
            }
        }
    }
}
