import Foundation

/// `LinkOSC --selftest [port]` : GUI なしの動作検査
/// 1. Link タイムラインが進行するか (beat/tempo)
/// 2. SpectrumAnalyzer の校正 (フルスケール正弦波 → バンド値 ≈ 1, RMS ≈ 0.707)
/// 3. OSC 送信 (/fft /vol /beat を指定ポートへ 60fps で 3 秒間)
enum SelfTest {
    static func run() {
        let port = UInt16(CommandLine.arguments.dropFirst(2).first ?? "") ?? 9099
        print("[selftest] start (osc -> 127.0.0.1:\(port))")

        // --- 2. analyzer 校正 ---
        let analyzer = SpectrumAnalyzer()
        let n = SpectrumAnalyzer.fftSize
        let sr = 48000.0
        let freq = sr / Double(n) * 512.0 // bin 512 ちょうど → バンド 64
        var sine = [Float](repeating: 0, count: n)
        for i in 0..<n {
            sine[i] = Float(sin(2.0 * .pi * freq * Double(i) / sr))
        }
        let (spec, rms) = analyzer.analyze(sine, gain: 1.0)
        let peakBand = spec.firstIndex(of: spec.max() ?? 0) ?? -1
        print(String(format: "[selftest] fft: peakBand=%d (expect 64) value=%.3f rms=%.3f (expect ~0.707)",
                     peakBand, spec[max(peakBand, 0)], rms))

        // --- 1. Link タイムライン ---
        let engine = LinkEngine()
        engine.setEnabled(true)
        Thread.sleep(forTimeInterval: 0.5)
        let t0 = engine.timeline()
        Thread.sleep(forTimeInterval: 1.0)
        let t1 = engine.timeline()
        print(String(format: "[selftest] link: tempo=%.1f beat %.2f -> %.2f (advanced %.2f, expect ~2.0) peers=%d",
                     t1.tempo, t0.beat, t1.beat, t1.beat - t0.beat, t1.peers))

        // --- 3. OSC 送信 ---
        let queue = DispatchQueue(label: "selftest.osc")
        guard let dest = OSCDestination(host: "127.0.0.1", port: port, queue: queue) else {
            print("[selftest] FAILED to create OSC destination")
            exit(1)
        }
        var lastBeat = -1
        for _ in 0..<180 { // 3秒 @60fps
            let tl = engine.timeline()
            let beatIdx = ((Int(floor(tl.beat)) % 4) + 4) % 4
            dest.send(OSC.message("/fft", floats: spec))
            dest.send(OSC.message("/vol", float: rms))
            if beatIdx != lastBeat {
                lastBeat = beatIdx
                dest.send(OSC.message("/beat", int: Int32(beatIdx)))
            }
            Thread.sleep(forTimeInterval: 1.0 / 60.0)
        }
        print("[selftest] sent 3s of /fft /vol /beat")
        Thread.sleep(forTimeInterval: 0.2)
        print("[selftest] done")
        exit(0)
    }
}
