import Foundation
import AVFoundation
import Network
import CAblLink

/// `LinkOSC --publish` : Link Audio チャンネル "SineTest" を公開し 440Hz サイン波を送り続ける
/// (受信側の検証用。Live の代わりになる送信ピア)
enum PublishTest {
    static func run() {
        let link = abl_link_create(120.0)
        abl_link_audio_set_peer_name(link, "LinkOSC-Pub")
        abl_link_enable(link, true)
        abl_link_audio_enable_link_audio(link, true)

        let sink = abl_link_audio_sink_create(link, "SineTest", 4096)
        let state = abl_link_create_session_state()
        let sr = 48000.0
        let frames = 480 // 10ms
        var phase = 0.0
        var committed: UInt64 = 0
        var lastLog = Date()

        print("[publish] channel 'LinkOSC-Pub | SineTest' publishing 440Hz @48kHz...")
        while true {
            abl_link_capture_app_session_state(link, state)
            let now = abl_link_clock_micros(link)
            let beats = abl_link_beat_at_time(state, now, 4.0)

            var handle = abl_link_audio_sink_retain_buffer(sink)
            if abl_link_audio_sink_buffer_is_valid(&handle) {
                if let samples = handle.samples {
                    for i in 0..<frames {
                        samples[i] = Int16(sin(phase) * 32000.0)
                        phase += 2.0 * .pi * 440.0 / sr
                        if phase > 2.0 * .pi { phase -= 2.0 * .pi }
                    }
                }
                if abl_link_audio_sink_buffer_commit(&handle, state, beats, 4.0,
                                                     frames, 1, UInt32(sr)) {
                    committed &+= 1
                }
            }
            if Date().timeIntervalSince(lastLog) >= 1.0 {
                lastLog = Date()
                print("[publish] peers=\(abl_link_num_peers(link)) buffersCommitted=\(committed)")
            }
            Thread.sleep(forTimeInterval: Double(frames) / sr)
        }
    }
}

/// `LinkOSC --oscstress` : 送信バックログ起因のクラッシュ (nw_write_request の再帰 dealloc)
/// の回帰テスト。到達不能ホストへ 60fps 相当 ×30秒ぶんのメッセージを一気に投げてから
/// cancel しても落ちないことを確認する。
enum OSCStressTest {
    static func run() {
        let queue = DispatchQueue(label: "oscstress")
        // TEST-NET-1: ルーティング不能 → ready にならない/詰まる状況を再現
        guard let dest = OSCDestination(host: "192.0.2.55", port: 9999, queue: queue) else {
            print("[oscstress] FAIL: could not create destination")
            exit(1)
        }
        let payload = OSC.message("/fft", floats: [Float](repeating: 0.5, count: 128))
        print("[oscstress] sending 18000 messages to unreachable host...")
        for i in 0..<18000 {
            dest.send(payload)
            if i % 6000 == 0 { Thread.sleep(forTimeInterval: 0.05) }
        }
        print("[oscstress] cancelling connection (previously crashed here)...")
        dest.cancel()
        Thread.sleep(forTimeInterval: 1.0)
        // ローカルへも同じ量を流して正常経路の送信が生きていることを確認
        guard let local = OSCDestination(host: "127.0.0.1", port: 9999, queue: queue) else {
            print("[oscstress] FAIL: could not create local destination")
            exit(1)
        }
        Thread.sleep(forTimeInterval: 0.3)
        for _ in 0..<18000 { local.send(payload) }
        local.cancel()
        Thread.sleep(forTimeInterval: 0.5)
        print("[oscstress] PASS (no crash)")
        exit(0)
    }
}

/// `LinkOSC --pacetest [port]` : バースト平滑化 (OSCPacing) の実測。
/// 60fps × 3秒、/vol を即時・/fft /pfft /hfft を 1/2/3ms スロットで送る。
/// 受信側で /vol からの到着オフセットを測れば ~1/2/3ms になるはず。
enum PaceTest {
    static func run() {
        let port = UInt16(CommandLine.arguments.dropFirst(2).first ?? "") ?? 9099
        let queue = DispatchQueue(label: "pacetest", qos: .userInteractive)
        guard let dest = OSCDestination(host: "127.0.0.1", port: port, queue: queue) else {
            print("[pacetest] FAIL: could not create destination")
            exit(1)
        }
        Thread.sleep(forTimeInterval: 0.3) // ready 待ち

        let vol = TaggedMsg(addr: .vol, data: OSC.message("/vol", float: 0.5))
        let fft = TaggedMsg(addr: .fft,
                            data: OSC.message("/fft", floats: [Float](repeating: 0.5, count: 128)))
        let pfft = TaggedMsg(addr: .pfft,
                             data: OSC.message("/pfft", floats: [Float](repeating: 0.4, count: 128)))
        let hfft = TaggedMsg(addr: .hfft,
                             data: OSC.message("/hfft", floats: [Float](repeating: 0.3, count: 128)))

        print("[pacetest] 180 frames @60fps -> 127.0.0.1:\(port)")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var frames = 0
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667),
                       leeway: .microseconds(100))
        timer.setEventHandler {
            OSCPacing.send(immediate: [vol], paced: [[fft], [pfft], [hfft]],
                           to: [dest], on: queue)
            frames += 1
            if frames >= 180 {
                timer.cancel()
                print("[pacetest] done")
                exit(0)
            }
        }
        timer.resume()
        dispatchMain()
    }
}

/// `LinkOSC --desttest [basePort]` : 宛先フィルタ / バンドル / マルチキャストの E2E 検証。
/// base+0: All + bundled / base+1: Events / base+2: Percussive / 239.77.7.7:base+3: multicast All
enum DestTest {
    static func run() {
        let base = UInt16(CommandLine.arguments.dropFirst(2).first ?? "") ?? 9070
        let q = DispatchQueue(label: "desttest", qos: .userInteractive)
        guard let dAll = OSCDestination(host: "127.0.0.1", port: base, queue: q,
                                        filter: .all, bundled: true),
              let dEvents = OSCDestination(host: "127.0.0.1", port: base + 1, queue: q,
                                           filter: .events, bundled: false),
              let dPerc = OSCDestination(host: "127.0.0.1", port: base + 2, queue: q,
                                         filter: .percussive, bundled: false),
              let dMcast = OSCDestination(host: "239.77.7.7", port: base + 3, queue: q,
                                          filter: .all, bundled: false) else {
            print("[desttest] FAIL: destination creation")
            exit(1)
        }
        Thread.sleep(forTimeInterval: 0.5)
        print("[desttest] multicast dest ready=\(dMcast.status().ready) isMulticast=\(dMcast.isMulticast)")

        let imm: [TaggedMsg] = [
            TaggedMsg(addr: .beat, data: OSC.message("/beat", int: 2)),
            TaggedMsg(addr: .vol, data: OSC.message("/vol", float: 0.5)),
            TaggedMsg(addr: .hpss, data: OSC.message("/hpss", floats: [0.2, 0.7])),
            TaggedMsg(addr: .chroma,
                      data: OSC.message("/chroma", floats: [Float](repeating: 0.3, count: 12))),
        ]
        let paced: [[TaggedMsg]] = [
            [TaggedMsg(addr: .fft,
                       data: OSC.message("/fft", floats: [Float](repeating: 0.5, count: 128)))],
            [TaggedMsg(addr: .pfft,
                       data: OSC.message("/pfft", floats: [Float](repeating: 0.4, count: 128)))],
        ]
        for _ in 0..<120 { // 2秒 @60fps
            OSCPacing.send(immediate: imm, paced: paced,
                           to: [dAll, dEvents, dPerc, dMcast], on: q)
            Thread.sleep(forTimeInterval: 1.0 / 60.0)
        }
        Thread.sleep(forTimeInterval: 0.3)
        print("[desttest] done (expected: p0 bundles w/ all addrs, p1 beat only, p2 beat/hpss/pfft, p3 multicast all)")
        exit(0)
    }
}

/// `LinkOSC --ifacetest [basePort]` : 送信インターフェース選択の E2E 検証。
/// 1) NWPathMonitor 経由で物理 NIC を列挙 (NWInterface は Path からしか得られない)
/// 2) Auto で 127.0.0.1 へ送信 → 受信できる (基準)
/// 3) 物理 NIC を requiredInterface に固定して 127.0.0.1 へ → ready にならず 0 受信
///    (loopback 宛は lo0 以外を通れない = 制約が経路選択に実際に効いている証明)
/// 4) NIC の IPv4 で join したマルチキャスト受信者へ、その NIC 固定で送信 → 届く
enum IfaceTest {
    static func run() {
        let base = UInt16(CommandLine.arguments.dropFirst(2).first ?? "") ?? 9080
        let q = DispatchQueue(label: "ifacetest", qos: .userInteractive)

        let mon = NetMonitor()
        mon.start(queue: q)
        var waited = 0
        while !mon.isPrimed(), waited < 20 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
        }
        let choices = mon.choices()
        print("[ifacetest] interfaces: "
              + (choices.isEmpty ? "(none)" : choices.map(\.label).joined(separator: ", ")))
        if mon.resolve("en99") != nil {
            print("[ifacetest] FAIL: resolve(en99) should be nil (Auto fallback)")
            exit(1)
        }

        // 受信カウンタ (BSD ソケット。multicast は指定 IF の IPv4 で join)
        final class Counter {
            private var n = 0
            private let lock = NSLock()
            func bump() { lock.lock(); n += 1; lock.unlock() }
            func value() -> Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        func receiver(port: UInt16, joinGroup: String? = nil, onIP: String? = nil) -> Counter {
            let c = Counter()
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(4))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if let g = joinGroup {
                var mreq = ip_mreq()
                mreq.imr_multiaddr.s_addr = inet_addr(g)
                mreq.imr_interface.s_addr = inet_addr(onIP ?? "0.0.0.0")
                setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq,
                           socklen_t(MemoryLayout<ip_mreq>.size))
            }
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 2048)
                while recv(fd, &buf, 2048, 0) > 0 { c.bump() }
            }
            return c
        }
        func ipv4(of name: String) -> String? {
            var ptr: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&ptr) == 0 else { return nil }
            defer { freeifaddrs(ptr) }
            var cur = ptr
            while let p = cur {
                let ifa = p.pointee
                if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                   String(cString: ifa.ifa_name) == name {
                    let sin = UnsafeRawPointer(sa)
                        .assumingMemoryBound(to: sockaddr_in.self).pointee
                    return String(cString: inet_ntoa(sin.sin_addr))
                }
                cur = ifa.ifa_next
            }
            return nil
        }

        // (2) Auto → loopback: 基準
        let cAuto = receiver(port: base)
        guard let dAuto = OSCDestination(host: "127.0.0.1", port: base, queue: q) else {
            print("[ifacetest] FAIL: destination creation")
            exit(1)
        }
        Thread.sleep(forTimeInterval: 0.3)
        for _ in 0..<30 {
            dAuto.send(OSC.message("/ping", int: 1))
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.3)
        let autoN = cAuto.value()
        print("[ifacetest] auto -> 127.0.0.1: via=\(dAuto.viaInfo() ?? "?") received \(autoN)/30 (expect ~30)")
        var ok = autoN >= 25
        dAuto.cancel()

        if let first = choices.first, let nic = mon.resolve(first.name) {
            // (3) 物理 NIC 固定 → loopback 宛: 経路が成立しないはず
            let cPin = receiver(port: base + 1)
            if let dPin = OSCDestination(host: "127.0.0.1", port: base + 1, queue: q,
                                         interface: nic) {
                Thread.sleep(forTimeInterval: 0.5)
                for _ in 0..<30 { dPin.send(OSC.message("/ping", int: 1)) }
                Thread.sleep(forTimeInterval: 0.5)
                let ready = dPin.status().ready
                let n = cPin.value()
                print("[ifacetest] \(first.name)-pinned -> 127.0.0.1: ready=\(ready) received=\(n) (expect ready=false, 0 — proves requiredInterface constrains routing)")
                ok = ok && !ready && n == 0
                dPin.cancel()
            }

            // (4) 物理 NIC 固定 → その NIC の IPv4 で join したマルチキャスト受信者
            if let ip = ipv4(of: first.name) {
                let group = "239.77.7.9"
                let cMc = receiver(port: base + 2, joinGroup: group, onIP: ip)
                if let dMc = OSCDestination(host: group, port: base + 2, queue: q,
                                            interface: nic) {
                    Thread.sleep(forTimeInterval: 0.5)
                    for _ in 0..<30 {
                        dMc.send(OSC.message("/ping", int: 1))
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                    let n = cMc.value()
                    print("[ifacetest] \(first.name)-pinned -> \(group) (joined on \(ip)): via=\(dMc.viaInfo() ?? "?") received \(n)/30 (expect >0)")
                    ok = ok && n > 0
                    dMc.cancel()
                }
            } else {
                print("[ifacetest] SKIP multicast: \(first.name) has no IPv4")
            }
        } else {
            print("[ifacetest] SKIP pinned tests: no physical interface available")
        }
        print(ok ? "[ifacetest] PASS" : "[ifacetest] FAIL")
        exit(ok ? 0 : 1)
    }
}

/// `LinkOSC --bench` : 解析パイプラインのステージ別コスト計測 (release ビルドで実行)
enum BenchTest {
    static func run() {
        // 同梱 WAV を直接読み、実データの 2048 サンプル窓を 60fps 相当でステップ
        guard let file = try? AVAudioFile(forReading:
            URL(fileURLWithPath: AppModel.defaultDevFile)),
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                       frameCapacity: AVAudioFrameCount(file.length)),
            (try? file.read(into: buf)) != nil,
            let ch = buf.floatChannelData else {
            print("[bench] FAIL: could not load test wav")
            exit(1)
        }
        let total = Int(buf.frameLength)
        let n = SpectrumAnalyzer.fftSize
        var mono = [Float](repeating: 0, count: total)
        let nch = Int(buf.format.channelCount)
        for i in 0..<total {
            mono[i] = nch > 1 ? (ch[0][i] + ch[1][i]) * 0.5 : ch[0][i]
        }

        let analyzer = SpectrumAnalyzer()
        var window = [Float](repeating: 0, count: n)
        var frames: [SpectrumAnalyzer.Frame] = []
        var pos = 0
        for _ in 0..<240 { // 4秒ぶんのフレームを事前生成
            for i in 0..<n { window[i] = mono[(pos + i) % total] }
            pos = (pos + 800) % total
            frames.append(analyzer.analyzeFrame(window, gain: 1.0))
        }

        func measure(_ label: String, needs: AnalysisKit.Needs,
                     preset: HPSSPreset = HPSSPreset.named("Standard")) {
            let kit = AnalysisKit()
            let t0 = DispatchTime.now().uptimeNanoseconds
            for f in frames {
                _ = kit.process(mags: f.mags, bandsIn: f.bands, sampleRate: 48000,
                                attackPreset: AttackPreset.presets[1],
                                pattackPreset: AttackPreset.presets[1],
                                hpssPreset: preset, needs: needs)
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                / Double(frames.count)
            let pad = label.padding(toLength: 28, withPad: " ", startingAt: 0)
            print("[bench] " + pad + String(format: "%6.3f ms/frame", ms))
        }

        // FFT 自体
        do {
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<240 {
                for i in 0..<n { window[i] = mono[(pos + i) % total] }
                pos = (pos + 800) % total
                _ = analyzer.analyzeFrame(window, gain: 1.0)
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / 240
            print("[bench] " + "fft+bands+rms".padding(toLength: 28, withPad: " ", startingAt: 0)
                + String(format: "%6.3f ms/frame", ms))
        }

        var off = AnalysisKit.Needs(attack: false, pattack: false, novelty: false,
                                    chroma: false, hpss: false, hfft: false, pfft: false)
        measure("baseline (all off)", needs: off)
        off.attack = true
        measure("+attack", needs: off)
        off.attack = false; off.novelty = true
        measure("+novelty", needs: off)
        off.novelty = false; off.chroma = true
        measure("+chroma", needs: off)
        off.chroma = false; off.hpss = true
        measure("+hpss Fast", needs: off, preset: HPSSPreset.named("Fast"))
        measure("+hpss Standard", needs: off, preset: HPSSPreset.named("Standard"))
        measure("+hpss Deep", needs: off, preset: HPSSPreset.named("Deep"))
        off.pattack = true; off.pfft = true; off.hfft = true
        measure("+hpss Std +pattack +p/hfft", needs: off, preset: HPSSPreset.named("Standard"))
        measure("ALL ON (Standard)", needs: AnalysisKit.Needs())

        // Auto BPM (2Hzで相関を更新、毎フレームは低域fluxのみ)
        do {
            let detector = AutoBPMDetector()
            let t0 = DispatchTime.now().uptimeNanoseconds
            for i in 0..<720 {
                _ = detector.process(bands: frames[i % frames.count].bands)
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / 720
            print("[bench] " + "auto bpm".padding(toLength: 28, withPad: " ", startingAt: 0)
                + String(format: "%6.3f ms/frame", ms))
        }

        // OSC エンコード
        do {
            let spec = frames[0].bands
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<240 {
                _ = OSC.message("/fft", floats: spec)
                _ = OSC.message("/pfft", floats: spec)
                _ = OSC.message("/hfft", floats: spec)
                _ = OSC.message("/chroma", floats: [Float](repeating: 0.5, count: 12))
                _ = OSC.message("/vol", float: 0.5)
                _ = OSC.message("/hpss", floats: [0.2, 0.3])
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / 240
            print("[bench] " + "osc encode (6 msgs)".padding(toLength: 28, withPad: " ", startingAt: 0)
                + String(format: "%6.3f ms/frame", ms))
        }
        exit(0)
    }
}

/// `LinkOSC --bpmtest` : Auto BPM の範囲・倍テンポ耐性と同梱WAVを検証。
enum AutoBPMTest {
    static func run() {
        var ok = true
        for target in [90.0, 110.0, 128.0, 140.0, 180.0] {
            let detector = AutoBPMDetector()
            let period = AutoBPMDetector.frameRate * 60.0 / target
            var last: AutoBPMDetector.Estimate?
            for frame in 0..<720 {
                let phase = Double(frame).truncatingRemainder(dividingBy: period)
                let beatDistance = min(phase, period - phase)
                let halfPeriod = period * 0.5
                let halfPhase = Double(frame).truncatingRemainder(dividingBy: halfPeriod)
                let halfDistance = min(halfPhase, halfPeriod - halfPhase)
                let beat = exp(-(beatDistance * beatDistance) / 1.3)
                let subdivisionAmount = (target > 95 && target < 175) ? 0.18 : 0
                let subdivision = subdivisionAmount
                    * exp(-(halfDistance * halfDistance) / 1.3)
                let accent = (target > 95 && target < 175
                              && Int(Double(frame) / period) % 4 == 0) ? 0.22 : 0
                let noise = Double((frame * 17) % 29) / 29.0 * 0.004
                if let e = detector.process(onset: Float(beat + subdivision + accent + noise)) {
                    last = e
                }
            }
            let estimated = last?.bpm ?? 0
            let pass = last?.stable == true && abs(estimated - target) <= 2.0
            ok = ok && pass
            print(String(format: "[bpmtest] synthetic %5.1f -> %5.1f BPM conf=%.2f %@",
                         target, estimated, last?.confidence ?? 0, pass ? "PASS" : "FAIL"))
        }

        guard let file = try? AVAudioFile(forReading:
            URL(fileURLWithPath: AppModel.defaultDevFile)),
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                          frameCapacity: AVAudioFrameCount(file.length)),
            (try? file.read(into: buffer)) != nil,
            let channels = buffer.floatChannelData else {
            print("[bpmtest] bundled WAV FAIL: could not load")
            exit(1)
        }
        let total = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: total)
        for i in 0..<total {
            mono[i] = channelCount > 1
                ? (channels[0][i] + channels[1][i]) * 0.5 : channels[0][i]
        }
        let analyzer = SpectrumAnalyzer()
        let detector = AutoBPMDetector()
        detector.reset(loopDuration: Double(total) / buffer.format.sampleRate)
        let n = SpectrumAnalyzer.fftSize
        let hop = max(1, Int((buffer.format.sampleRate / AutoBPMDetector.frameRate).rounded()))
        var window = [Float](repeating: 0, count: n)
        var position = 0
        var last: AutoBPMDetector.Estimate?
        for _ in 0..<720 {
            for i in 0..<n { window[i] = mono[(position + i) % total] }
            position = (position + hop) % total
            let frame = analyzer.analyzeFrame(window, gain: 1)
            if let e = detector.process(bands: frame.bands) { last = e }
        }
        let estimated = last?.bpm ?? 0
        let wavPass = last?.stable == true && abs(estimated - 140.0) <= 3.0
        ok = ok && wavPass
        print(String(format: "[bpmtest] bundled WAV 140.0 -> %5.1f BPM conf=%.2f %@",
                     estimated, last?.confidence ?? 0, wavPass ? "PASS" : "FAIL"))
        print(ok ? "[bpmtest] PASS" : "[bpmtest] FAIL")
        exit(ok ? 0 : 1)
    }
}

/// `LinkOSC --probe` : Link ピアと Link Audio チャンネルの見え方を10秒間表示する診断モード
enum ProbeTest {
    static func run() {
        let engine = LinkEngine()
        engine.setEnabled(true)
        print("[probe] Link + Link Audio を有効化して観測中 (10秒)...")
        for i in 1...10 {
            Thread.sleep(forTimeInterval: 1.0)
            engine.refreshChannelsIfNeeded()
            let tl = engine.timeline()
            let chans = engine.channels.map { $0.key }
            print(String(format: "[probe] %2ds peers=%d tempo=%.1f playing=%@ channels=%@",
                         i, tl.peers, tl.tempo, tl.isPlaying ? "yes" : "no",
                         chans.isEmpty ? "（なし）" : chans.joined(separator: ", ")))
        }
        print("""
        [probe] 判定:
          peers=0           → Link 自体が見えていない (Live起動? 同一ネットワーク? ローカルネットワーク権限?)
          peers>0 かつ channels なし → Link は接続済みだが Live 側の Link Audio が OFF
          channels あり      → 受信可能。アプリのピッカーでそのチャンネルを選択
        """)
        exit(0)
    }
}

/// `LinkOSC --devtest [oscport] [wavpath] [bpm]` : 開発モード (WAVループ) の検査
/// ループ再生 → 解析 → OSC送信 → /beat の周期を確認する。音が実際に鳴る。
enum DevTest {
    static func run() {
        let args = Array(CommandLine.arguments.dropFirst(2))
        let port = UInt16(args.first ?? "") ?? 9099
        let path = args.count > 1 ? args[1] : AppModel.defaultDevFile
        let bpm = Double(args.count > 2 ? args[2] : "") ?? 140.0

        let midiPath = args.count > 3 ? args[3] : AppModel.defaultDevMidi

        let looper = DevLooper()
        looper.bpm = bpm
        do {
            try looper.start(path: path)
            try looper.loadMidi(path: midiPath)
        } catch {
            print("[devtest] FAIL: \(error.localizedDescription)")
            exit(1)
        }
        // Regression test for the CoreAudio teardown deadlock that previously
        // blocked linkosc.loop and stopped all OSC output.
        do {
            for _ in 0..<5 {
                looper.stop()
                try looper.start(path: path)
            }
            print("[devtest] audio start/stop cycles: PASS (5)")
        } catch {
            print("[devtest] audio start/stop cycles: FAIL: \(error.localizedDescription)")
            exit(1)
        }
        print("[devtest] looping '\(path)' + midi '\(midiPath)' (\(looper.midiInfo ?? "-")) bpm=\(bpm) -> osc 127.0.0.1:\(port)")

        // --- SectionDetector の合成データ検証 ---
        let fineWindowFramesOK = SectionWindow.twoHundredFiftySixthBeat.frames(tempo: 120) == 1
            && SectionWindow.oneHundredTwentyEighthBeat.frames(tempo: 120) == 1
            && SectionWindow.sixtyFourthBeat.frames(tempo: 120) == 1
            && SectionWindow.sixteenthBeat.frames(tempo: 120) == 2
        print("[devtest] section fine windows: \(fineWindowFramesOK ? "PASS" : "FAIL") "
              + "(1/256=\(SectionWindow.twoHundredFiftySixthBeat.frames(tempo: 120))f, "
              + "1/128=\(SectionWindow.oneHundredTwentyEighthBeat.frames(tempo: 120))f, "
              + "1/64=\(SectionWindow.sixtyFourthBeat.frames(tempo: 120))f @120BPM)")

        var oneFrameSectionOK = false
        do {
            let det = SectionDetector()
            let before: [Float] = [0.8, 0.4, 0.3, 0.2, 0.7]
            let after: [Float] = [0.05, 0.35, 0.3, 0.2, 0.15]
            for barIdx in 0..<4 {
                det.barHead(collectFrames: 1)
                let profile = barIdx < 3 ? before : after
                if det.tick(profile: profile, threshold: 0.4) != nil {
                    oneFrameSectionOK = true
                }
            }
            print("[devtest] section one-frame judgement: \(oneFrameSectionOK ? "PASS" : "FAIL")")
        }

        // Case 1: 3小節同じ→4小節目でキック消失 (全体変化で発火)
        do {
            let det = SectionDetector()
            let withKick: [Float] = [0.8, 0.4, 0.3, 0.2, 0.7]
            let noKick: [Float] = [0.05, 0.35, 0.3, 0.2, 0.15]
            var fired: Float = -1
            for barIdx in 0..<4 {
                det.barHead(collectFrames: 20)
                let p = barIdx < 3 ? withKick : noKick
                for _ in 0..<20 {
                    if let c = det.tick(profile: p, threshold: 0.4) { fired = c.magnitude }
                }
            }
            print(String(format: "[devtest] section case1 (kick drop): %@ (mag=%.2f)",
                         fired > 0 ? "FIRED" : "MISSED", fired))
        }
        // Case 2: 他パートが大音量のままキックだけ消える
        // (総和では threshold 未満 → 単一帯域の相対変化で発火するべき)
        do {
            let det = SectionDetector()
            let full: [Float] = [0.6, 0.5, 0.5, 0.5, 0.5]
            let noSub: [Float] = [0.05, 0.5, 0.5, 0.5, 0.45]
            var fired: Float = -1
            for barIdx in 0..<4 {
                det.barHead(collectFrames: 20)
                let p = barIdx < 3 ? full : noSub
                for _ in 0..<20 {
                    if let c = det.tick(profile: p, threshold: 0.4) { fired = c.magnitude }
                }
            }
            print(String(format: "[devtest] section case2 (kick drop, loud mix): %@ (mag=%.2f, old logic missed this)",
                         fired > 0 ? "FIRED" : "MISSED", fired))
        }

        // --- StreamGate の合成検証: 無変化なら 2Hz、変化すれば毎フレーム ---
        do {
            var g = StreamGate()
            let constant = [Float](repeating: 0.5, count: 128)
            var sentConst = 0
            for _ in 0..<180 where g.shouldSend(constant) { sentConst += 1 }
            var g2 = StreamGate()
            var sentVary = 0
            for i in 0..<180 {
                var v = constant
                v[0] = Float(i) * 0.01
                if g2.shouldSend(v) { sentVary += 1 }
            }
            print("[devtest] idle suppression: constant 180f -> \(sentConst) sends (expect ~6 = 2Hz), varying -> \(sentVary) (expect 180)")
        }

        let analyzer = SpectrumAnalyzer()
        let kit = AnalysisKit()
        let sectionDet = SectionDetector()
        let queue = DispatchQueue(label: "devtest.osc")
        let dest = OSCDestination(host: "127.0.0.1", port: port, queue: queue)
        var samples = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
        var lastBeat = -1
        var lastBar = Int.min
        var beatTimes: [Double] = []
        let start = Date()
        var maxRms: Float = 0
        var noteCount = 0
        var noteHist: [UInt8: Int] = [:]
        var attackCount = 0
        var pattackCount = 0
        var sectionCount = 0
        var maxNovelty: Float = 0
        var hSum: Float = 0, pSum: Float = 0
        var chromaAccum = [Float](repeating: 0, count: 12)

        for frame in 0..<300 { // 5秒 @60fps
            if frame % 30 == 0 { dest?.send(OSC.message("/ping", int: 1)) }
            looper.latestSamples(SpectrumAnalyzer.fftSize, into: &samples)
            let frame = analyzer.analyzeFrame(samples, gain: 1.0)
            let res = kit.process(mags: frame.mags, bandsIn: frame.bands,
                                  sampleRate: 48000,
                                  attackPreset: AttackPreset.presets[1],
                                  pattackPreset: AttackPreset.presets[1],
                                  hpssPreset: HPSSPreset.presets[1],
                                  needs: AnalysisKit.Needs())
            maxRms = max(maxRms, frame.rms)
            maxNovelty = max(maxNovelty, res.novelty)
            hSum += res.harmonic
            pSum += res.percussive
            for i in 0..<12 { chromaAccum[i] += res.chroma[i] }
            if let a = res.attack {
                attackCount += 1
                dest?.send(OSC.message("/attack", float: a))
            }
            if let a = res.pattack {
                pattackCount += 1
                dest?.send(OSC.message("/pattack", float: a))
            }
            dest?.send(OSC.message("/fft", floats: frame.bands))
            dest?.send(OSC.message("/vol", float: frame.rms))
            dest?.send(OSC.message("/novelty", float: res.novelty))
            dest?.send(OSC.message("/chroma", floats: res.chroma))
            dest?.send(OSC.message("/hpss", floats: [res.harmonic, res.percussive]))
            dest?.send(OSC.message("/pfft", floats: res.pBands))
            dest?.send(OSC.message("/pvol", float: res.pVol))
            dest?.send(OSC.message("/hfft", floats: res.hBands))
            dest?.send(OSC.message("/hvol", float: res.hVol))

            let beats = looper.totalBeats()
            let bar = Int(floor(beats / 4.0))
            if bar != lastBar {
                if lastBar != Int.min { sectionDet.barHead(collectFrames: 26) } // ≈1 beat @140BPM
                lastBar = bar
            }
            func bmean(_ r: Range<Int>) -> Float {
                var s: Float = 0
                for i in r { s += frame.bands[i] }
                return s / Float(r.count)
            }
            let profile = [bmean(0..<3), bmean(3..<9), bmean(9..<43), bmean(43..<128),
                           res.percussive]
            if let c = sectionDet.tick(profile: profile, threshold: 0.4) {
                sectionCount += 1
                dest?.send(OSC.message("/section", floats: [c.magnitude] + c.deltas))
            }

            let b = looper.beatIndex()
            if b != lastBeat {
                lastBeat = b
                beatTimes.append(Date().timeIntervalSince(start))
                dest?.send(OSC.message("/beat", int: Int32(b)))
            }
            for n in looper.consumeNotes() {
                noteCount += 1
                noteHist[n.note, default: 0] += 1
                dest?.send(OSC.message("/note", ints: [Int32(n.note), Int32(n.velocity)]))
            }
            Thread.sleep(forTimeInterval: 1.0 / 60.0)
        }
        looper.stop()

        let topChroma = chromaAccum.enumerated().max { $0.element < $1.element }?.offset ?? -1
        print(String(format: "[devtest] analysis: attacks=%d pattacks=%d novelty(max)=%.2f hpss(avg H=%.3f P=%.3f) chroma(top=%d) sections=%d",
                     attackCount, pattackCount, maxNovelty, hSum / 300, pSum / 300, topChroma, sectionCount))

        let intervals = zip(beatTimes.dropFirst(), beatTimes).map { $0 - $1 }
        let avg = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
        let (frames, rate) = looper.stats()
        let hist = noteHist.sorted { $0.key < $1.key }
            .map { "\($0.key)x\($0.value)" }.joined(separator: " ")
        print(String(format: "[devtest] frames=%llu rate=%.0f maxRms=%.3f beats=%d avgInterval=%.3fs (expect %.3fs @%.0fBPM)",
                     frames, rate, maxRms, beatTimes.count, avg, 60.0 / bpm, bpm))
        print("[devtest] notes sent=\(noteCount) hist=[\(hist)]")
        // 5秒 = 11.7拍。32拍の MIDI から十分な note-on が取れることを確認。
        let ok = fineWindowFramesOK && oneFrameSectionOK
            && frames > 0 && maxRms > 0.01
            && abs(avg - 60.0 / bpm) < 0.05 && noteCount > 10
        print(ok ? "[devtest] PASS" : "[devtest] FAIL")
        exit(ok ? 0 : 1)
    }
}

/// `LinkOSC --rxtest [oscport]` : GUI なしで受信経路を検査
/// チャンネル発見 → 購読 → PCM受信 → FFT/RMS → OSC送信 まで通す
enum RxTest {
    static func run() {
        let port = UInt16(CommandLine.arguments.dropFirst(2).first ?? "") ?? 9099
        let engine = LinkEngine()
        engine.setEnabled(true)

        // 第3引数: チャンネル名フィルタ (部分一致)。省略時は最初に見つかったチャンネル
        let filter = CommandLine.arguments.dropFirst(3).first ?? ""

        // チャンネル発見を最大15秒待つ
        var key = ""
        for i in 0..<150 {
            engine.refreshChannelsIfNeeded()
            let match = engine.channels.first { filter.isEmpty || $0.key.contains(filter) }
            if let c = match {
                key = c.key
                print("[rxtest] discovered after \(Double(i) * 0.1)s: \(engine.channels.count) channels, using '\(key)'")
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard !key.isEmpty else {
            print("[rxtest] FAIL: no Link Audio channels matching '\(filter)' found in 15s")
            exit(1)
        }

        engine.syncSource(desiredKey: key)
        let mon = MonitorOutput()
        mon.setVolume(0.3)
        engine.setMonitor(mon)
        print("[rxtest] subscribed to '\(key)', receiving (monitor audible at 30%)...")

        let analyzer = SpectrumAnalyzer()
        let queue = DispatchQueue(label: "rxtest.osc")
        let dest = OSCDestination(host: "127.0.0.1", port: port, queue: queue)
        var samples = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
        var lastSpec = [Float](repeating: 0, count: SpectrumAnalyzer.bands)
        var lastRms: Float = 0

        var lastFrames: UInt64 = 0
        for sec in 1...6 {
            for _ in 0..<60 {
                engine.refreshChannelsIfNeeded()
                engine.syncSource(desiredKey: key)
                engine.latestSamples(SpectrumAnalyzer.fftSize, into: &samples)
                (lastSpec, lastRms) = analyzer.analyze(samples, gain: 1.0)
                dest?.send(OSC.message("/fft", floats: lastSpec))
                dest?.send(OSC.message("/vol", float: lastRms))
                Thread.sleep(forTimeInterval: 1.0 / 60.0)
            }
            let (frames, rate) = engine.stats()
            let peakBand = lastSpec.firstIndex(of: lastSpec.max() ?? 0) ?? -1
            print(String(format: "[rxtest] %ds frames=%llu (+%llu/s) rate=%.0f peakBand=%d value=%.3f rms=%.4f",
                         sec, frames, frames - lastFrames, rate, peakBand,
                         lastSpec[max(peakBand, 0)], lastRms))
            lastFrames = frames
        }

        let (frames, _) = engine.stats()
        let ok = frames > 0
        print(ok ? "[rxtest] PASS (audio flowed)" : "[rxtest] FAIL (no audio frames received)")
        exit(ok ? 0 : 1)
    }
}
