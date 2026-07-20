import Foundation
import AVFoundation

/// 開発モード: WAV ファイルをループ再生し、解析用リングバッファに供給する。
/// /beat はループ再生位置 × BPM から算出するため、ループ素材の頭が1拍目なら音と同期する。
final class DevLooper {

    private var avEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    private let ringSize = 16384
    private var ringL: [Float]
    private var ringR: [Float]
    private var writeIndex = 0
    // Audio tap must never wait for MIDI parsing/note-window work.
    private let audioLock = NSLock()
    private let midiLock = NSLock()

    private var sampleRateValue: Double = 0
    private var framesPlayed: UInt64 = 0
    private var fileFrames: UInt64 = 0
    private var runningValue = false

    var sampleRate: Double {
        audioLock.lock()
        defer { audioLock.unlock() }
        return sampleRateValue
    }

    var bpm: Double = 140.0
    private var monitorVolume: Float = 0.8

    // MIDI ループ (/note 用)
    private var midi: MidiLoop?
    private var lastEmitBeat: Double = -0.0001

    init() {
        ringL = [Float](repeating: 0, count: ringSize)
        ringR = [Float](repeating: 0, count: ringSize)
    }

    /// MIDI ファイルを読み込む。空パスで解除。
    func loadMidi(path: String) throws {
        // ファイルI/Oとパースはロック外。音声tapを止めない。
        let loaded = path.isEmpty ? nil : try MidiLoop.load(path: path)
        midiLock.lock()
        midi = loaded
        lastEmitBeat = -0.0001
        midiLock.unlock()
    }

    var midiInfo: String? {
        audioLock.lock()
        let sr = sampleRateValue
        let frames = fileFrames
        audioLock.unlock()
        midiLock.lock()
        defer { midiLock.unlock() }
        guard let m = midi else { return nil }
        let beats = effectiveMidiLoopBeats(m, sampleRate: sr, fileFrames: frames, bpm: bpm)
        return "\(m.notes.count) notes / \(Int(beats.rounded())) beats"
    }

    /// WAVの長さとSMFの拍数が両方ある場合の強いテンポhint。
    /// half/double tempo は 90...180 BPM に正規化する。
    func tempoHintBPM() -> Double? {
        audioLock.lock()
        let sr = sampleRateValue
        let frames = fileFrames
        audioLock.unlock()
        midiLock.lock()
        let beats = midi?.loopBeats
        midiLock.unlock()
        guard let beats, sr > 0, frames > 0 else { return nil }
        var bpm = beats * 60.0 / (Double(frames) / sr)
        while bpm < AutoBPMDetector.minimumBPM { bpm *= 2 }
        while bpm > AutoBPMDetector.maximumBPM { bpm *= 0.5 }
        guard bpm >= AutoBPMDetector.minimumBPM,
              bpm <= AutoBPMDetector.maximumBPM else { return nil }
        return bpm
    }

    func loopDurationSeconds() -> Double? {
        audioLock.lock()
        defer { audioLock.unlock() }
        guard sampleRateValue > 0, fileFrames > 0 else { return nil }
        return Double(fileFrames) / sampleRateValue
    }

    /// MIDI は WAV と同じタイミングで周回させる。SMF の EOT が最後の
    /// ノート直後にあっても、WAV 末尾の余白を含めたループ長を保つ。
    private func effectiveMidiLoopBeats(_ midi: MidiLoop, sampleRate: Double,
                                        fileFrames: UInt64, bpm: Double) -> Double {
        guard sampleRate > 0, fileFrames > 0 else { return midi.loopBeats }
        return Double(fileFrames) / sampleRate * bpm / 60.0
    }

    /// 前回呼び出しから現在までの再生位置窓に入った note-on を返す (ループ考慮)
    func consumeNotes() -> [(note: UInt8, velocity: UInt8)] {
        audioLock.lock()
        let played = framesPlayed
        let sr = sampleRateValue
        let fileLength = fileFrames
        audioLock.unlock()

        let bpmNow = bpm
        midiLock.lock()
        defer { midiLock.unlock() }
        guard let m = midi, sr > 0, !m.notes.isEmpty else { return [] }
        let loop = effectiveMidiLoopBeats(
            m, sampleRate: sr, fileFrames: fileLength, bpm: bpmNow)
        let last = lastEmitBeat

        let now = Double(played) / sr * bpmNow / 60.0
        guard now > last else { return [] }

        let posA = last.truncatingRemainder(dividingBy: loop)
        let posB = now.truncatingRemainder(dividingBy: loop)
        var out: [(UInt8, UInt8)] = []

        if now - last >= loop {
            // 窓がループ1周以上 (通常起こらない): 全ノートを1回ずつ
            out = m.notes.map { ($0.note, $0.velocity) }
        } else if posA <= posB {
            for n in m.notes where n.beat > posA && n.beat <= posB {
                out.append((n.note, n.velocity))
            }
        } else { // ループ境界をまたいだ
            for n in m.notes where n.beat > posA || n.beat <= posB {
                out.append((n.note, n.velocity))
            }
        }

        lastEmitBeat = now
        return out
    }

    var isRunning: Bool {
        audioLock.lock()
        defer { audioLock.unlock() }
        return runningValue
    }

    func start(path: String) throws {
        stop()
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "DevLooper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Empty file or failed to allocate buffer"])
        }
        try file.read(into: buf)

        audioLock.lock()
        sampleRateValue = format.sampleRate
        fileFrames = UInt64(buf.frameLength)
        framesPlayed = 0
        writeIndex = 0
        ringL = [Float](repeating: 0, count: ringSize)
        ringR = [Float](repeating: 0, count: ringSize)
        audioLock.unlock()
        midiLock.lock()
        lastEmitBeat = -0.0001
        midiLock.unlock()

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        node.scheduleBuffer(buf, at: nil, options: .loops)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] b, _ in
            self?.push(b)
        }
        engine.mainMixerNode.outputVolume = monitorVolume
        engine.prepare()
        try engine.start()
        node.play()
        avEngine = engine
        player = node
        audioLock.lock()
        runningValue = true
        audioLock.unlock()
    }

    /// モニター音量 (mute 時は 0)。解析用リングには影響しない (tap は mixer より上流)。
    func setMonitorVolume(_ v: Float) {
        monitorVolume = v
        avEngine?.mainMixerNode.outputVolume = v
    }

    func stop() {
        // AVAudioPlayerNode.stop() may wait forever in AudioUnitReset while its
        // engine render graph is active. Detach state first, stop the engine,
        // then tear down the node. AppModel runs this on the dedicated audio
        // control queue so even a CoreAudio fault cannot stop Link/OSC ticks.
        let engine = avEngine
        let node = player
        avEngine = nil
        player = nil
        audioLock.lock()
        runningValue = false
        audioLock.unlock()
        engine?.stop()
        node?.removeTap(onBus: 0)
        node?.stop()
    }

    private func push(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let nch = Int(buffer.format.channelCount)
        let mask = ringSize - 1

        audioLock.lock()
        var w = writeIndex
        for f in 0..<frames {
            let l = ch[0][f]
            let r = nch > 1 ? ch[1][f] : l
            ringL[w] = l
            ringR[w] = r
            w = (w + 1) & mask
        }
        writeIndex = w
        framesPlayed &+= UInt64(frames)
        audioLock.unlock()
    }

    func latestSamples(_ count: Int, into out: inout [Float]) {
        precondition(out.count == count && count <= ringSize)
        let mask = ringSize - 1
        audioLock.lock()
        var r = (writeIndex - count) & mask
        for i in 0..<count {
            out[i] = (ringL[r] + ringR[r]) * 0.5
            r = (r + 1) & mask
        }
        audioLock.unlock()
    }

    func latestStereo(_ count: Int, intoL: inout [Float], intoR: inout [Float]) {
        precondition(intoL.count == count && intoR.count == count && count <= ringSize)
        let mask = ringSize - 1
        audioLock.lock()
        var r = (writeIndex - count) & mask
        for i in 0..<count {
            intoL[i] = ringL[r]
            intoR[i] = ringR[r]
            r = (r + 1) & mask
        }
        audioLock.unlock()
    }

    struct AnalysisSnapshot {
        let frames: UInt64
        let sampleRate: Double
        let totalBeats: Double
        let beatIndex: Int
    }

    /// 解析に必要な最新L/Rと再生位置を1回のロックで取得する。
    func analysisSnapshot(_ count: Int, intoL: inout [Float], intoR: inout [Float])
        -> AnalysisSnapshot {
        precondition(intoL.count == count && intoR.count == count && count <= ringSize)
        let mask = ringSize - 1
        audioLock.lock()
        var r = (writeIndex - count) & mask
        for i in 0..<count {
            intoL[i] = ringL[r]
            intoR[i] = ringR[r]
            r = (r + 1) & mask
        }
        let frames = framesPlayed
        let sr = sampleRateValue
        audioLock.unlock()

        let beats = sr > 0 ? Double(frames) / sr * bpm / 60.0 : 0
        return AnalysisSnapshot(
            frames: frames,
            sampleRate: sr,
            totalBeats: beats,
            beatIndex: ((Int(floor(beats)) % 4) + 4) % 4)
    }

    /// 総再生 beat 数 (小節頭検出用)
    func totalBeats() -> Double {
        audioLock.lock()
        let played = framesPlayed
        let sr = sampleRateValue
        audioLock.unlock()
        guard sr > 0 else { return 0 }
        return Double(played) / sr * bpm / 60.0
    }

    /// 総再生時間 × BPM から 0..3 のビート番号を返す (等間隔のフリーランクロック)
    /// ループ長が拍数で割り切れないファイルでも /beat の周期は常に正確に保つ
    func beatIndex() -> Int {
        audioLock.lock()
        let played = framesPlayed
        let sr = sampleRateValue
        audioLock.unlock()
        guard sr > 0 else { return 0 }
        let beats = Double(played) / sr * bpm / 60.0
        return ((Int(floor(beats)) % 4) + 4) % 4
    }

    func stats() -> (frames: UInt64, sampleRate: Double) {
        audioLock.lock()
        defer { audioLock.unlock() }
        return (framesPlayed, sampleRateValue)
    }
}
