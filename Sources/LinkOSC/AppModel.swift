import Foundation
import SwiftUI
import Accelerate
import Network

struct DestConfig: Codable, Equatable {
    var enabled: Bool = false
    var host: String = "127.0.0.1"
    var port: String = "9001"
    /// ④ アドレスフィルタ (DestFilter の rawValue、nil = all)
    var filter: String?
    /// ⑥ OSC バンドルで送る (受信側の対応が必要)
    var bundled: Bool?
}

/// 高頻度 (10Hz) で更新される表示用の値。
/// AppModel から分離することで、更新時に再評価される SwiftUI ビューを
/// これを観測する小さな末端ビューだけに限定する (全体再評価を防ぐ)。
final class LiveStats {
    struct Values: Equatable {
        var peers = 0
        var tempo: Double = 0
        var isPlaying = false
        var beat = -1
        var vol: Float = 0
        var receivingRate: Double = 0
        var audioFlowing = false
        var noveltyValue: Float = 0
        var attackCount = 0
        var pattackCount = 0
        var sectionCount = 0
        var lastNote = "—"
        /// 宛先ごとの送信状態: 0=disabled 1=connecting 2=sending 3=dropping
        var destStates: [Int] = [0, 0, 0, 0]
        /// 宛先ごとの実送出経路 ("en0 · 192.168.1.23" 等)
        var destVia: [String] = ["", "", "", ""]
    }

    final class Transport: ObservableObject {
        struct Snapshot: Equatable {
            var peers = 0
            var tempo: Double = 0
            var isPlaying = false
            var beat = -1
            var receivingRate: Double = 0
            var audioFlowing = false
        }
        @Published private(set) var snapshot = Snapshot()
        var peers: Int { snapshot.peers }
        var tempo: Double { snapshot.tempo }
        var isPlaying: Bool { snapshot.isPlaying }
        var beat: Int { snapshot.beat }
        var receivingRate: Double { snapshot.receivingRate }
        var audioFlowing: Bool { snapshot.audioFlowing }
        func update(_ next: Snapshot) {
            if snapshot != next { snapshot = next }
        }
    }

    final class Signal: ObservableObject {
        struct Snapshot: Equatable {
            var vol: Float = 0
            var noveltyValue: Float = 0
        }
        @Published private(set) var snapshot = Snapshot()
        var vol: Float { snapshot.vol }
        var noveltyValue: Float { snapshot.noveltyValue }
        func update(_ next: Snapshot) {
            if snapshot != next { snapshot = next }
        }
    }

    final class Events: ObservableObject {
        struct Snapshot: Equatable {
            var attackCount = 0
            var pattackCount = 0
            var sectionCount = 0
            var lastNote = "—"
        }
        @Published private(set) var snapshot = Snapshot()
        var attackCount: Int { snapshot.attackCount }
        var pattackCount: Int { snapshot.pattackCount }
        var sectionCount: Int { snapshot.sectionCount }
        var lastNote: String { snapshot.lastNote }
        func update(_ next: Snapshot) {
            if snapshot != next { snapshot = next }
        }
    }

    final class Destinations: ObservableObject {
        struct Snapshot: Equatable {
            var states: [Int] = [0, 0, 0, 0]
            var via: [String] = ["", "", "", ""]
        }
        @Published private(set) var snapshot = Snapshot()
        var states: [Int] { snapshot.states }
        var via: [String] { snapshot.via }
        func update(_ next: Snapshot) {
            if snapshot != next { snapshot = next }
        }
    }

    final class AutoBPM: ObservableObject {
        struct Snapshot: Equatable {
            var active = false
            var elapsed = 0.0
            var bpm: Double?
            var confidence: Float = 0
            var stable = false
        }
        @Published private(set) var snapshot = Snapshot()
        func update(_ next: Snapshot) {
            if snapshot != next { snapshot = next }
        }
    }

    let transport = Transport()
    let signal = Signal()
    let events = Events()
    let destinations = Destinations()
    let autoBPM = AutoBPM()
    var lastNote: String { events.lastNote }

    func update(_ next: Values) {
        transport.update(Transport.Snapshot(
            peers: next.peers, tempo: next.tempo, isPlaying: next.isPlaying,
            beat: next.beat, receivingRate: next.receivingRate,
            audioFlowing: next.audioFlowing))
        signal.update(Signal.Snapshot(vol: next.vol, noveltyValue: next.noveltyValue))
        events.update(Events.Snapshot(
            attackCount: next.attackCount, pattackCount: next.pattackCount,
            sectionCount: next.sectionCount, lastNote: next.lastNote))
        destinations.update(Destinations.Snapshot(
            states: next.destStates, via: next.destVia))
    }
}

/// アプリ全体の状態。60fps の送信ループを持つ。
final class AppModel: ObservableObject {

    // MARK: 設定 (UserDefaults に保存)
    @Published var dests: [DestConfig] {
        didSet { saveSettings(destsChanged: true) }
    }
    @Published var selectedChannelKey: String {
        didSet { saveSettings() }
    }
    /// 連続操作は ContentView 全体を invalidate しない。FaderControls が
    /// ローカル @State を持ち、ここには解析用の値だけを反映する。
    private(set) var gain: Double
    @Published var beatOnlyWhenPlaying: Bool {
        didSet { saveSettings() }
    }
    @Published var linkEnabled: Bool {
        didSet {
            saveSettings(updateSnapshot: false)
            if !devMode {
                let on = linkEnabled
                loopQueue.async { [engine] in engine.setEnabled(on) }
            }
        }
    }

    // MARK: 開発モード (WAV ループ)
    @Published var devMode: Bool {
        didSet {
            if !devMode, autoBPMEnabled { setAutoBPMEnabled(false) }
            saveSettings()
            applyDevMode()
        }
    }
    @Published var devFilePath: String {
        didSet {
            saveSettings(updateSnapshot: false)
            if devMode { applyDevMode() }
        }
    }
    @Published var devMidiPath: String {
        didSet {
            saveSettings(updateSnapshot: false)
            if devMode { applyDevMidi() }
        }
    }
    @Published var devBPM: Double {
        didSet {
            let valid = Self.clampedBPM(devBPM)
            if valid != devBPM {
                devBPM = valid
                return
            }
            saveSettings()
        }
    }
    @Published private(set) var autoBPMEnabled = false
    @Published var devError: String?
    @Published var devMidiInfo: String?

    // MARK: 解析設定
    @Published var fftCurve: ResponseCurve { didSet { saveSettings() } }
    @Published var volCurve: ResponseCurve { didSet { saveSettings() } }
    @Published var sendAttack: Bool { didSet { saveSettings() } }
    @Published var attackPresetName: String { didSet { saveSettings() } }
    @Published var sendPAttack: Bool { didSet { saveSettings() } }
    @Published var pattackPresetName: String { didSet { saveSettings() } }
    @Published var sendNovelty: Bool { didSet { saveSettings() } }
    @Published var sendChroma: Bool { didSet { saveSettings() } }
    @Published var sendHpss: Bool { didSet { saveSettings() } }
    @Published var hpssPresetName: String { didSet { saveSettings() } }
    @Published var sendPFFT: Bool { didSet { saveSettings() } }
    @Published var sendHFFT: Bool { didSet { saveSettings() } }
    @Published var sendSection: Bool { didSet { saveSettings() } }
    @Published var sectionSensitivity: SectionSensitivity { didSet { saveSettings() } }
    @Published var sectionWindow: SectionWindow { didSet { saveSettings() } }
    /// Lite mode: 可視化の描画と UI 更新だけを止める。解析・OSC 送信には影響しない。
    @Published var liteMode: Bool { didSet { saveSettings() } }
    /// アイドル抑制: 値が変化しない stream 送信をスキップ (最低 2Hz でリフレッシュ)
    @Published var idleSuppression: Bool { didSet { saveSettings() } }
    /// モニター出力も連続操作用の局所 state から更新する。
    /// 解析・OSC には影響しない。
    private(set) var monitorMuted: Bool
    private(set) var monitorVolume: Double
    /// 送信インターフェース ("" = Auto: OS ルーティング任せ)。マルチキャストの
    /// 送出 NIC 固定や、二重ホームで同一サブネットのときに指定する
    @Published var ifaceName: String { didSet { saveSettings(destsChanged: true) } }
    /// Picker の選択肢 (実在する物理 NIC のみ、NetMonitor が更新)
    @Published var ifaceChoices: [IfaceChoice] = []
    /// 選択中の NIC が現在存在しない → Auto にフォールバック中 (警告表示用)
    @Published var ifaceMissing = false

    let vizState = VizState()
    let stats = LiveStats()
    private let linkMonitor = MonitorOutput()

    // 低頻度の UI 表示用
    @Published var channelKeys: [String] = []

    private let engine = LinkEngine()
    private let looper = DevLooper()
    private let analyzer = SpectrumAnalyzer()
    private let kit = AnalysisKit()
    private let sectionDetector = SectionDetector()
    private let autoBPMDetector = AutoBPMDetector()
    private var bufL = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var bufR = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var lastBar = Int.min
    private var attackTotal = 0
    private var pattackTotal = 0
    private var sectionTotal = 0
    // loopQueue 専有。UIの @Published 値とは直接共有しない。
    private var autoBPMActive = false
    private var lastAutoAppliedBPM: Double?
    private let loopQueue = DispatchQueue(label: "linkosc.loop", qos: .userInteractive)
    /// AVAudioEngine start/stop is isolated from the 60fps Link/OSC loop.
    /// CoreAudio teardown must never be able to block OSC transmission.
    private let devAudioQueue = DispatchQueue(label: "linkosc.dev-audio-control", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let heartbeatLock = NSLock()
    private var lastHeartbeatNS = DispatchTime.now().uptimeNanoseconds
    private let watchdogQueue = DispatchQueue(label: "linkosc.watchdog", qos: .utility)
    private var watchdogTimer: DispatchSourceTimer?
    private var devTransitionGeneration: UInt64 = 0
    private let devTransitionLock = NSLock()

    private var senders: [OSCDestination?] = [nil, nil, nil, nil]
    private var sendRotation = 0
    private var pendingNote: String?
    private var lastBeatSent = Int.min
    private var lastFrames: UInt64 = 0
    private var lastDropped: [UInt64] = [0, 0, 0, 0]
    private var frameCount = 0
    private let netMonitor = NetMonitor()
    private var wasIfaceMissing = false
    private var lastLoggedDestStates: [Int] = [-1, -1, -1, -1]

    // ③ アイドル抑制ゲート (stream アドレスごと)
    private var gateFFT = StreamGate()
    private var gatePFFT = StreamGate()
    private var gateHFFT = StreamGate()
    private var gateVol = StreamGate()
    private var gatePVol = StreamGate()
    private var gateHVol = StreamGate()
    private var gateNovelty = StreamGate()
    private var gateHpss = StreamGate()
    private var gateChroma = StreamGate()
    private var samples = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)

    // メインスレッドの設定値をループスレッドへ渡すスナップショット
    private struct Snapshot {
        var dests: [DestConfig] = []
        var desired = ""
        var gain: Float = 1
        var beatGate = false
        var destsDirty = true
        var devMode = false
        var devBPM = 140.0
        var fftCurve = ResponseCurve.linear
        var volCurve = ResponseCurve.linear
        var sendAttack = true
        var attackPreset = AttackPreset.presets[1]
        var sendPAttack = true
        var pattackPreset = AttackPreset.presets[1]
        var sendNovelty = true
        var sendChroma = true
        var sendHpss = true
        var hpssPreset = HPSSPreset.presets[1]
        var sendSection = true
        var sectionSensitivity = SectionSensitivity.medium
        var sectionWindow = SectionWindow.oneBeat
        var sendPFFT = true
        var sendHFFT = false
        var liteMode = false
        var idleSuppression = true
        var ifaceName = ""
    }
    private let settingsLock = NSLock()
    private var snapshot = Snapshot()
    /// スライダーの高頻度変更で UserDefaults へ毎回書き込まないための世代番号。
    private var settingsWriteGeneration = 0

    /// App Nap によるタイマー間引きを防ぐ (ウィンドウが完全に隠れていても
    /// 解析と OSC 送信を 60fps で維持する)。システムのアイドルスリープは妨げない。
    private var activityToken: NSObjectProtocol?

    private static let defaultsKey = "com.fil.linkosc.settings"

    struct Settings: Codable {
        var dests: [DestConfig]
        var channel: String
        var gain: Double
        var beatOnlyWhenPlaying: Bool
        var linkEnabled: Bool
        // 後から追加した項目 (古い保存データに無くても読めるよう optional)
        var devMode: Bool?
        var devFilePath: String?
        var devBPM: Double?
        var devMidiPath: String?
        var fftCurve: String?
        var volCurve: String?
        var sendAttack: Bool?
        var attackPreset: String?
        var sendPAttack: Bool?
        var pattackPreset: String?
        var sendNovelty: Bool?
        var sendChroma: Bool?
        var sendHpss: Bool?
        var hpssPreset: String?
        var sendSection: Bool?
        var sectionSensitivity: String?
        var sectionWindow: String?
        var sendPFFT: Bool?
        var sendHFFT: Bool?
        var liteMode: Bool?
        var idleSuppression: Bool?
        var monitorMuted: Bool?
        var monitorVolume: Double?
        var ifaceName: String?
    }

    /// アプリに同梱したテストデータのパスを解決する。
    /// .app では Contents/Resources 直下、swift build 実行時は SPM リソースバンドルから。
    private static func bundledResource(_ name: String, _ ext: String) -> String {
        if let p = Bundle.main.path(forResource: name, ofType: ext) {
            return p
        }
        return Bundle.module.path(forResource: name, ofType: ext) ?? ""
    }

    static let defaultDevFile = bundledResource("loop-test", "wav")
    static let defaultDevEffectsFile = bundledResource("loop-test-effects", "wav")
    static let defaultDevMidi = bundledResource("loop-test", "mid")

    init() {
        RuntimeLog.shared.event("app_start", [
            "version": AppInfo.display,
            "pid": String(ProcessInfo.processInfo.processIdentifier)
        ])
        var s = Settings(dests: (0..<4).map { i in
            DestConfig(enabled: false, host: "127.0.0.1", port: String(9001 + i))
        }, channel: "", gain: 1.0, beatOnlyWhenPlaying: false, linkEnabled: true)
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let loaded = try? JSONDecoder().decode(Settings.self, from: data) {
            s = loaded
        }
        dests = s.dests
        selectedChannelKey = s.channel
        gain = s.gain
        beatOnlyWhenPlaying = s.beatOnlyWhenPlaying
        linkEnabled = s.linkEnabled
        devMode = s.devMode ?? false
        // 保存されたパスのファイルが無ければ同梱データにフォールバック
        // (アプリを別の場所/別の Mac に移しても必ずデフォルトが使える)
        let savedWav = s.devFilePath ?? ""
        let savedWavExists = FileManager.default.fileExists(atPath: savedWav)
        devFilePath = savedWavExists ? savedWav : Self.defaultDevFile
        if let savedMidi = s.devMidiPath {
            // 空文字は「/note 無効」の意図的な設定なので維持する
            devMidiPath = savedMidi.isEmpty || FileManager.default.fileExists(atPath: savedMidi)
                ? savedMidi : Self.defaultDevMidi
        } else {
            devMidiPath = Self.defaultDevMidi
        }
        // 旧同梱ループからのアップデート時は、新素材に合わせて 140 BPM へ移行。
        // 実在するカスタム WAV の保存 BPM は維持する。
        devBPM = Self.clampedBPM(savedWavExists ? (s.devBPM ?? 140.0) : 140.0)
        fftCurve = ResponseCurve(rawValue: s.fftCurve ?? "") ?? .linear
        volCurve = ResponseCurve(rawValue: s.volCurve ?? "") ?? .linear
        sendAttack = s.sendAttack ?? true
        attackPresetName = s.attackPreset ?? "Standard"
        sendPAttack = s.sendPAttack ?? true
        pattackPresetName = s.pattackPreset ?? "Standard"
        sendNovelty = s.sendNovelty ?? true
        sendChroma = s.sendChroma ?? true
        sendHpss = s.sendHpss ?? true
        hpssPresetName = s.hpssPreset ?? "Standard"
        sendSection = s.sendSection ?? true
        sectionSensitivity = SectionSensitivity(rawValue: s.sectionSensitivity ?? "") ?? .medium
        sectionWindow = SectionWindow(rawValue: s.sectionWindow ?? "") ?? .oneBeat
        sendPFFT = s.sendPFFT ?? true
        sendHFFT = s.sendHFFT ?? false
        liteMode = s.liteMode ?? false
        idleSuppression = s.idleSuppression ?? true
        monitorMuted = s.monitorMuted ?? false
        monitorVolume = s.monitorVolume ?? 0.8
        ifaceName = s.ifaceName ?? ""

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Realtime audio analysis and OSC output")

        engine.setEnabled(s.linkEnabled && !devMode)
        engine.setMonitor(linkMonitor)
        applyMonitorVolume()
        // ネットワーク構成の監視: 変化 (ケーブル挿抜 / Wi-Fi 切替) で全宛先を
        // 張り直し、Picker の NIC 一覧を更新する
        netMonitor.onChange = { [weak self] in self?.networkChanged() }
        netMonitor.start(queue: loopQueue)
        publishSnapshot(destsChanged: true)
        if devMode { applyDevMode() }
        startLoop()
        startWatchdog()
    }

    /// モニター実効音量を両経路 (dev WAV / Link Audio) に反映
    private func applyMonitorVolume() {
        let v: Float = monitorMuted ? 0 : Float(monitorVolume)
        devAudioQueue.async { [looper] in looper.setMonitorVolume(v) }
        linkMonitor.setVolume(v)
    }

    func toggleAutoBPM() {
        setAutoBPMEnabled(!autoBPMEnabled)
    }

    private func setAutoBPMEnabled(_ enabled: Bool) {
        guard autoBPMEnabled != enabled else { return }
        autoBPMEnabled = enabled
        loopQueue.async { [self] in
            autoBPMActive = enabled
            lastAutoAppliedBPM = nil
            autoBPMDetector.reset(
                tempoHint: enabled ? looper.tempoHintBPM() : nil,
                loopDuration: enabled ? looper.loopDurationSeconds() : nil)
            DispatchQueue.main.async { [self] in
                stats.autoBPM.update(LiveStats.AutoBPM.Snapshot(active: enabled))
            }
        }
    }

    /// gain は解析ループへ即時反映し、永続化だけを debounce する。
    func setGain(_ value: Double) {
        gain = min(max(value, 0.1), 8.0)
        saveContinuousSetting(updateSnapshot: true)
    }

    func setMonitorMuted(_ muted: Bool) {
        monitorMuted = muted
        applyMonitorVolume()
        saveSettings(updateSnapshot: false)
    }

    /// モニター音量はオーディオへ即時反映し、永続化だけを debounce する。
    func setMonitorVolume(_ value: Double) {
        monitorVolume = min(max(value, 0), 1)
        applyMonitorVolume()
        saveContinuousSetting(updateSnapshot: false)
    }

    /// Link Audio チャンネルの再探索 (Refresh ボタン)
    func refreshChannels() {
        loopQueue.async { [self] in
            engine.restartAudioDiscovery()
        }
    }

    /// ネットワーク構成の変化 (loopQueue 上で呼ばれる):
    /// 全宛先の張り直しを予約し、Picker の NIC 一覧を更新する
    private func networkChanged() {
        settingsLock.lock()
        snapshot.destsDirty = true
        settingsLock.unlock()
        let list = netMonitor.choices()
        DispatchQueue.main.async { [self] in
            if ifaceChoices != list { ifaceChoices = list }
        }
    }

    /// 開発モードの ON/OFF・ファイル変更を反映する
    private func applyDevMode() {
        let on = devMode
        let path = devFilePath
        let midiPath = devMidiPath
        let linkOn = linkEnabled
        let generation = nextDevTransitionGeneration()
        RuntimeLog.shared.event("dev_mode_requested", [
            "enabled": String(on),
            "generation": String(generation),
            "wav": URL(fileURLWithPath: path).lastPathComponent,
            "midi": URL(fileURLWithPath: midiPath).lastPathComponent
        ])

        // Link control is quick and stays on the realtime loop queue. Audio
        // teardown happens independently below and cannot stall this queue.
        loopQueue.async { [self] in
            if on {
                engine.setEnabled(false)   // Link / Link Audio を OFF
                engine.removeSource()
                linkMonitor.stop()
            } else {
                engine.setEnabled(linkOn)
            }
        }

        devAudioQueue.async { [self] in
            guard isCurrentDevTransition(generation) else {
                RuntimeLog.shared.event("dev_mode_skipped_stale", [
                    "generation": String(generation)
                ])
                return
            }
            let started = DispatchTime.now().uptimeNanoseconds
            RuntimeLog.shared.event("dev_audio_control_begin", [
                "enabled": String(on),
                "generation": String(generation)
            ])
            if on {
                do {
                    try looper.start(path: path)
                    do {
                        try looper.loadMidi(path: midiPath)
                        let info = looper.midiInfo
                        scheduleAutoBPMReset(
                            tempoHint: looper.tempoHintBPM(),
                            loopDuration: looper.loopDurationSeconds())
                        DispatchQueue.main.async {
                            guard self.isCurrentDevTransition(generation) else { return }
                            self.devError = nil
                            self.devMidiInfo = info
                        }
                    } catch {
                        try? looper.loadMidi(path: "")
                        scheduleAutoBPMReset(
                            tempoHint: nil, loopDuration: looper.loopDurationSeconds())
                        DispatchQueue.main.async {
                            guard self.isCurrentDevTransition(generation) else { return }
                            self.devError = "MIDI load failed: \(error.localizedDescription)"
                            self.devMidiInfo = nil
                        }
                    }
                } catch {
                    looper.stop()
                    scheduleAutoBPMReset(tempoHint: nil, loopDuration: nil)
                    DispatchQueue.main.async {
                        guard self.isCurrentDevTransition(generation) else { return }
                        self.devError = "WAV load failed: \(error.localizedDescription)"
                        self.devMidiInfo = nil
                    }
                }
            } else {
                looper.stop()
                DispatchQueue.main.async {
                    guard self.isCurrentDevTransition(generation) else { return }
                    self.devError = nil
                    self.devMidiInfo = nil
                }
            }
            let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            RuntimeLog.shared.event("dev_mode_completed", [
                "enabled": String(on),
                "generation": String(generation),
                "duration_ms": String(format: "%.1f", elapsedMS),
                "running": String(looper.isRunning)
            ])
        }
    }

    /// MIDI changes do not require AVAudioEngine teardown. Keeping them separate
    /// removes an unnecessary restart path and avoids audible gaps.
    private func applyDevMidi() {
        let path = devMidiPath
        devAudioQueue.async { [self] in
            do {
                try looper.loadMidi(path: path)
                let info = looper.midiInfo
                RuntimeLog.shared.event("dev_midi_loaded", [
                    "midi": URL(fileURLWithPath: path).lastPathComponent
                ])
                scheduleAutoBPMReset(
                    tempoHint: looper.tempoHintBPM(),
                    loopDuration: looper.loopDurationSeconds())
                DispatchQueue.main.async { [self] in
                    devError = nil
                    devMidiInfo = info
                }
            } catch {
                try? looper.loadMidi(path: "")
                RuntimeLog.shared.event("dev_midi_failed", ["error": error.localizedDescription])
                DispatchQueue.main.async { [self] in
                    devError = "MIDI load failed: \(error.localizedDescription)"
                    devMidiInfo = nil
                }
            }
        }
    }

    private func scheduleAutoBPMReset(tempoHint: Double?, loopDuration: Double?) {
        loopQueue.async { [self] in
            guard autoBPMActive else { return }
            autoBPMDetector.reset(tempoHint: tempoHint, loopDuration: loopDuration)
            lastAutoAppliedBPM = nil
        }
    }

    private func nextDevTransitionGeneration() -> UInt64 {
        devTransitionLock.lock()
        devTransitionGeneration &+= 1
        let value = devTransitionGeneration
        devTransitionLock.unlock()
        return value
    }

    private func isCurrentDevTransition(_ generation: UInt64) -> Bool {
        devTransitionLock.lock()
        defer { devTransitionLock.unlock() }
        return generation == devTransitionGeneration
    }

    /// トグルや Picker などの離散的な変更を保存する。
    /// OSC 送信先の再構築は宛先設定/NIC が変わったときだけ行う。
    private func saveSettings(updateSnapshot: Bool = true, destsChanged: Bool = false) {
        settingsWriteGeneration &+= 1 // 保留中の debounce 書き込みを無効化
        persistSettings()
        if updateSnapshot {
            publishSnapshot(destsChanged: destsChanged)
        }
    }

    /// フェーダーはリアルタイム処理に即時反映しつつ、UserDefaults は
    /// 最後の操作から 250ms 後に1回だけ書き込む。
    private func saveContinuousSetting(updateSnapshot: Bool) {
        if updateSnapshot {
            publishSnapshot(destsChanged: false)
        }
        settingsWriteGeneration &+= 1
        let generation = settingsWriteGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard let self, self.settingsWriteGeneration == generation else { return }
            self.persistSettings()
        }
    }

    private func persistSettings() {
        let s = Settings(dests: dests, channel: selectedChannelKey, gain: gain,
                         beatOnlyWhenPlaying: beatOnlyWhenPlaying, linkEnabled: linkEnabled,
                         devMode: devMode, devFilePath: devFilePath, devBPM: devBPM,
                         devMidiPath: devMidiPath,
                         fftCurve: fftCurve.rawValue, volCurve: volCurve.rawValue,
                         sendAttack: sendAttack, attackPreset: attackPresetName,
                         sendPAttack: sendPAttack, pattackPreset: pattackPresetName,
                         sendNovelty: sendNovelty, sendChroma: sendChroma,
                         sendHpss: sendHpss, hpssPreset: hpssPresetName,
                         sendSection: sendSection,
                         sectionSensitivity: sectionSensitivity.rawValue,
                         sectionWindow: sectionWindow.rawValue,
                         sendPFFT: sendPFFT, sendHFFT: sendHFFT,
                         liteMode: liteMode, idleSuppression: idleSuppression,
                         monitorMuted: monitorMuted, monitorVolume: monitorVolume,
                         ifaceName: ifaceName.isEmpty ? nil : ifaceName)
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func publishSnapshot(destsChanged: Bool) {
        settingsLock.lock()
        snapshot.dests = dests
        snapshot.desired = selectedChannelKey
        snapshot.gain = Float(gain)
        snapshot.beatGate = beatOnlyWhenPlaying
        snapshot.devMode = devMode
        snapshot.devBPM = devBPM
        snapshot.fftCurve = fftCurve
        snapshot.volCurve = volCurve
        snapshot.sendAttack = sendAttack
        snapshot.attackPreset = AttackPreset.named(attackPresetName)
        snapshot.sendPAttack = sendPAttack
        snapshot.pattackPreset = AttackPreset.named(pattackPresetName)
        snapshot.sendNovelty = sendNovelty
        snapshot.sendChroma = sendChroma
        snapshot.sendHpss = sendHpss
        snapshot.hpssPreset = HPSSPreset.named(hpssPresetName)
        snapshot.sendSection = sendSection
        snapshot.sectionSensitivity = sectionSensitivity
        snapshot.sectionWindow = sectionWindow
        snapshot.sendPFFT = sendPFFT
        snapshot.sendHFFT = sendHFFT
        snapshot.liteMode = liteMode
        snapshot.idleSuppression = idleSuppression
        snapshot.ifaceName = ifaceName
        if destsChanged { snapshot.destsDirty = true }
        settingsLock.unlock()
    }

    // MARK: - 60fps ループ

    private func startLoop() {
        let t = DispatchSource.makeTimerSource(queue: loopQueue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Runs independently of linkosc.loop, so it can record that queue being
    /// blocked. Only state transitions are logged (no per-frame disk writes).
    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: watchdogQueue)
        var wasStalled = false
        t.schedule(deadline: .now() + 2, repeating: .seconds(1), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.heartbeatLock.lock()
            let heartbeat = self.lastHeartbeatNS
            self.heartbeatLock.unlock()
            let now = DispatchTime.now().uptimeNanoseconds
            let age = Double(now &- heartbeat) / 1_000_000_000
            let stalled = age >= 2.0
            if stalled != wasStalled {
                wasStalled = stalled
                RuntimeLog.shared.event(stalled ? "loop_stalled" : "loop_resumed", [
                    "heartbeat_age_s": String(format: "%.2f", age)
                ])
            }
        }
        t.resume()
        watchdogTimer = t
    }

    private func tick() {
        heartbeatLock.lock()
        lastHeartbeatNS = DispatchTime.now().uptimeNanoseconds
        heartbeatLock.unlock()
        settingsLock.lock()
        let snap = snapshot
        snapshot.destsDirty = false
        settingsLock.unlock()

        // 送信先の再構築 (設定変更・ネットワーク構成変化時のみ)
        if snap.destsDirty {
            // 選択インターフェースの解決。実在しなければ Auto にフォールバックして
            // 警告を出す (NIC が戻れば NetMonitor の通知 → 再構築で自動復帰)
            let iface = snap.ifaceName.isEmpty ? nil : netMonitor.resolve(snap.ifaceName)
            let missing = !snap.ifaceName.isEmpty && iface == nil && netMonitor.isPrimed()
            if missing != wasIfaceMissing {
                wasIfaceMissing = missing
                DispatchQueue.main.async { self.ifaceMissing = missing }
            }
            for s in senders { s?.cancel() }
            senders = snap.dests.map { d in
                d.enabled ? OSCDestination(host: d.host.trimmingCharacters(in: .whitespaces),
                                           port: UInt16(d.port.trimmingCharacters(in: .whitespaces)) ?? 0,
                                           queue: loopQueue,
                                           filter: DestFilter(rawValue: d.filter ?? "") ?? .all,
                                           bundled: d.bundled ?? false,
                                           interface: iface) : nil
            }
        }
        let desired = snap.desired
        let gainNow = snap.gain
        let beatGate = snap.beatGate

        var channelsChanged = false
        let beatIdx: Int
        var totalBeats = 0.0
        var tlPeers = 0
        var tlTempo = 0.0
        var tlPlaying = false
        var srNow = 0.0
        var devFramesNow: UInt64 = 0

        var midiNotes: [(note: UInt8, velocity: UInt8)] = []
        if snap.devMode {
            // 開発モード: WAV ループを解析、ビートは再生時間×BPM、MIDI から /note
            looper.bpm = snap.devBPM
            let dev = looper.analysisSnapshot(
                SpectrumAnalyzer.fftSize, intoL: &bufL, intoR: &bufR)
            beatIdx = dev.beatIndex
            totalBeats = dev.totalBeats
            devFramesNow = dev.frames
            midiNotes = looper.consumeNotes()
            tlTempo = snap.devBPM
            tlPlaying = looper.isRunning
            srNow = dev.sampleRate
        } else {
            // チャンネル一覧の更新と購読の同期
            channelsChanged = engine.refreshChannelsIfNeeded()
            engine.syncSource(desiredKey: desired)
            engine.latestStereo(SpectrumAnalyzer.fftSize, intoL: &bufL, intoR: &bufR)

            let tl = engine.timeline()
            beatIdx = ((Int(floor(tl.beat)) % 4) + 4) % 4
            totalBeats = tl.beat
            tlPeers = tl.peers
            tlTempo = tl.tempo
            tlPlaying = tl.isPlaying
            srNow = engine.sampleRate
        }

        // モノラルミックス → FFT フレーム
        let nSamp = SpectrumAnalyzer.fftSize
        vDSP_vadd(bufL, 1, bufR, 1, &samples, 1, vDSP_Length(nSamp))
        var half: Float = 0.5
        vDSP_vsmul(samples, 1, &half, &samples, 1, vDSP_Length(nSamp))
        let frame = analyzer.analyzeFrame(samples, gain: gainNow)

        // attack / pattack / novelty / chroma / HPSS
        // チェックが付いている解析だけを計算して使用する
        // (section は percussive プロファイルを使うため HPSS を要求する)
        let needs = AnalysisKit.Needs(
            attack: snap.sendAttack,
            pattack: snap.sendPAttack,
            novelty: snap.sendNovelty,
            chroma: snap.sendChroma,
            hpss: snap.sendHpss || snap.sendSection,
            hfft: snap.sendHFFT,
            pfft: snap.sendPFFT)
        let res = kit.process(mags: frame.mags, bandsIn: frame.bands,
                              sampleRate: srNow > 0 ? srNow : 48000,
                              attackPreset: snap.attackPreset,
                              pattackPreset: snap.pattackPreset,
                              hpssPreset: snap.hpssPreset,
                              needs: needs)

        if snap.devMode, autoBPMActive,
           let estimate = autoBPMDetector.process(bands: frame.bands) {
            var applyBPM: Double?
            if estimate.stable, let bpm = estimate.bpm,
               lastAutoAppliedBPM.map({ abs($0 - bpm) >= 0.25 }) ?? true {
                let rounded = (bpm * 10).rounded() / 10
                lastAutoAppliedBPM = rounded
                applyBPM = rounded
            }
            DispatchQueue.main.async { [self] in
                stats.autoBPM.update(LiveStats.AutoBPM.Snapshot(
                    active: true, elapsed: estimate.elapsed, bpm: estimate.bpm,
                    confidence: estimate.confidence, stable: estimate.stable))
                if let applyBPM { devBPM = applyBPM }
            }
        }
        if res.attack != nil { attackTotal += 1 }
        if res.pattack != nil { pattackTotal += 1 }

        // 応答カーブ
        let spec = snap.fftCurve == .linear ? frame.bands : snap.fftCurve.apply(frame.bands)
        let rms = snap.volCurve.apply(frame.rms)
        let pSpec = snap.sendPFFT
            ? (snap.fftCurve == .linear ? res.pBands : snap.fftCurve.apply(res.pBands))
            : [Float](repeating: 0, count: SpectrumAnalyzer.bands)
        let hSpec = snap.sendHFFT
            ? (snap.fftCurve == .linear ? res.hBands : snap.fftCurve.apply(res.hBands))
            : [Float](repeating: 0, count: SpectrumAnalyzer.bands)

        // 小節頭の検出 → セクション (展開) 判定
        var sectionChange: SectionDetector.Change?
        if snap.sendSection {
            let bar = Int(floor(totalBeats / 4.0))
            if bar != lastBar {
                if lastBar != Int.min, bar > lastBar {
                    sectionDetector.barHead(
                        collectFrames: snap.sectionWindow.frames(tempo: tlTempo))
                }
                lastBar = bar
            }
            sectionChange = sectionDetector.tick(
                profile: Self.bandProfile(frame.bands, percussive: res.percussive),
                threshold: snap.sectionSensitivity.threshold)
            if sectionChange != nil { sectionTotal += 1 }
        }

        // ビジュアライザへ (Lite mode 中は描画用データの生成もスキップ)。
        // 主表示は30fpsなので、追加のRMS/相関計算とVizState更新も30fpsに揃える。
        if !snap.liteMode {
            if frameCount.isMultiple(of: 2) {
                var rl: Float = 0, rr: Float = 0
                vDSP_rmsqv(bufL, 1, &rl, vDSP_Length(nSamp))
                vDSP_rmsqv(bufR, 1, &rr, vDSP_Length(nSamp))
                var dot: Float = 0, el: Float = 0, er: Float = 0
                vDSP_dotpr(bufL, 1, bufR, 1, &dot, vDSP_Length(nSamp))
                vDSP_svesq(bufL, 1, &el, vDSP_Length(nSamp))
                vDSP_svesq(bufR, 1, &er, vDSP_Length(nSamp))
                let cDenom = sqrtf(el * er)
                vizState.set(VizState.Data(
                    spectrum: spec,
                    rmsL: min(rl * gainNow * 1.4, 1),
                    rmsR: min(rr * gainNow * 1.4, 1),
                    corr: cDenom > 1e-9 ? max(-1, min(1, dot / cDenom)) : 1,
                    harmonic: res.harmonic,
                    percussive: res.percussive,
                    chroma: res.chroma,
                    hSpectrum: hSpec,
                    pSpectrum: pSpec))
            }
            vizState.pushHistory(VizState.HistoryPoint(
                vol: rms, novelty: res.novelty,
                harmonic: res.harmonic, percussive: res.percussive,
                attack: res.attack != nil, pattack: res.pattack != nil,
                section: sectionChange != nil))
        }

        // OSC 送信 — バースト平滑化:
        // イベントと小さいメッセージ (~110B 以下) は即時、
        // 大きいスペクトラム系 (~670B) は 1ms 刻みの後続スロットへずらす。
        let active = senders.compactMap { $0 }
        if !active.isEmpty {
            var immediate: [TaggedMsg] = []
            // イベント系は遅延ゼロで先頭に
            if beatIdx != lastBeatSent, !beatGate || tlPlaying {
                lastBeatSent = beatIdx
                immediate.append(TaggedMsg(addr: .beat,
                    data: OSC.message("/beat", int: Int32(beatIdx))))
            }
            for n in midiNotes {
                immediate.append(TaggedMsg(addr: .note,
                    data: OSC.message("/note", ints: [Int32(n.note), Int32(n.velocity)])))
            }
            if snap.sendAttack, let a = res.attack {
                immediate.append(TaggedMsg(addr: .attack, data: OSC.message("/attack", float: a)))
            }
            if snap.sendPAttack, let a = res.pattack {
                immediate.append(TaggedMsg(addr: .pattack, data: OSC.message("/pattack", float: a)))
            }
            if snap.sendSection, let c = sectionChange {
                immediate.append(TaggedMsg(addr: .section,
                    data: OSC.message("/section", floats: [c.magnitude] + c.deltas)))
            }
            if frameCount % 30 == 0 {
                immediate.append(TaggedMsg(addr: .ping, data: OSC.message("/ping", int: 1)))
            }
            // ③ アイドル抑制: 変化がなければ送らない (最低 2Hz でリフレッシュ)
            let sup = snap.idleSuppression
            let pVolCurved = snap.volCurve.apply(res.pVol)
            let hVolCurved = snap.volCurve.apply(res.hVol)
            if !sup || gateVol.shouldSend([rms]) {
                immediate.append(TaggedMsg(addr: .vol, data: OSC.message("/vol", float: rms)))
            }
            if snap.sendPFFT, !sup || gatePVol.shouldSend([pVolCurved]) {
                immediate.append(TaggedMsg(addr: .pvol, data: OSC.message("/pvol", float: pVolCurved)))
            }
            if snap.sendHFFT, !sup || gateHVol.shouldSend([hVolCurved]) {
                immediate.append(TaggedMsg(addr: .hvol, data: OSC.message("/hvol", float: hVolCurved)))
            }
            if snap.sendNovelty, !sup || gateNovelty.shouldSend([res.novelty]) {
                immediate.append(TaggedMsg(addr: .novelty,
                    data: OSC.message("/novelty", float: res.novelty)))
            }
            if snap.sendHpss, !sup || gateHpss.shouldSend([res.harmonic, res.percussive]) {
                immediate.append(TaggedMsg(addr: .hpss,
                    data: OSC.message("/hpss", floats: [res.harmonic, res.percussive])))
            }
            if snap.sendChroma, !sup || gateChroma.shouldSend(res.chroma) {
                immediate.append(TaggedMsg(addr: .chroma,
                    data: OSC.message("/chroma", floats: res.chroma)))
            }

            // 大きいメッセージ: /fft +1ms, /pfft +2ms, /hfft +3ms
            var paced: [[TaggedMsg]] = []
            if !sup || gateFFT.shouldSend(spec) {
                paced.append([TaggedMsg(addr: .fft, data: OSC.message("/fft", floats: spec))])
            }
            if snap.sendPFFT, !sup || gatePFFT.shouldSend(pSpec) {
                paced.append([TaggedMsg(addr: .pfft, data: OSC.message("/pfft", floats: pSpec))])
            }
            if snap.sendHFFT, !sup || gateHFFT.shouldSend(hSpec) {
                paced.append([TaggedMsg(addr: .hfft, data: OSC.message("/hfft", floats: hSpec))])
            }

            // 宛先の送信順を毎フレーム回して末尾偏りをなくす
            sendRotation &+= 1
            let order = Self.rotated(active, by: sendRotation)
            OSCPacing.send(immediate: immediate, paced: paced, to: order, on: loopQueue)
        }
        if let last = midiNotes.last {
            pendingNote = "note \(last.note) vel \(last.velocity)"
        }

        // UI 更新 (通常 10Hz / Lite mode では 1Hz)
        // 毎フレーム publish すると AppKit レイアウトが表示サイクルごとに走るため間引く
        frameCount += 1
        let uiEvery = snap.liteMode ? 60 : 6
        if frameCount % uiEvery == 0 || channelsChanged {
            let keys = engine.channels.map { $0.key }
            let (frames, rate) = snap.devMode
                ? (devFramesNow, srNow) : engine.stats()
            let flowing = frames != lastFrames
            lastFrames = frames
            // 宛先状態 (ドット表示用): ready でなければ connecting、
            // ready かつ直近 UI 周期でドロップが増えていれば dropping
            var dstates = [Int](repeating: 0, count: 4)
            var via = [String](repeating: "", count: 4)
            for i in 0..<4 {
                if let s = senders[i] {
                    let st = s.status()
                    let delta = st.dropped &- lastDropped[i]
                    lastDropped[i] = st.dropped
                    dstates[i] = !st.ready ? 1 : (delta > 0 ? 3 : 2)
                    via[i] = s.viaInfo() ?? ""
                } else {
                    dstates[i] = 0
                    lastDropped[i] = 0
                }
            }
            if dstates != lastLoggedDestStates {
                lastLoggedDestStates = dstates
                RuntimeLog.shared.event("osc_destination_states", [
                    "states": dstates.map(String.init).joined(separator: ",")
                ])
            }
            let noteText = pendingNote
            pendingNote = nil
            let nov = res.novelty
            let atk = attackTotal
            let patk = pattackTotal
            let sec = sectionTotal
            DispatchQueue.main.async { [self] in
                if channelKeys != keys { channelKeys = keys }
                stats.update(LiveStats.Values(
                    peers: tlPeers,
                    tempo: tlTempo,
                    isPlaying: tlPlaying,
                    beat: beatIdx,
                    vol: rms,
                    receivingRate: rate,
                    audioFlowing: flowing,
                    noveltyValue: nov,
                    attackCount: atk,
                    pattackCount: patk,
                    sectionCount: sec,
                    lastNote: noteText ?? stats.lastNote,
                    destStates: dstates,
                    destVia: via))
            }
        }
    }

    private static func rotated(_ a: [OSCDestination], by n: Int) -> [OSCDestination] {
        guard a.count > 1 else { return a }
        let k = ((n % a.count) + a.count) % a.count
        guard k > 0 else { return a }
        return Array(a[k...]) + Array(a[..<k])
    }

    private static func clampedBPM(_ value: Double) -> Double {
        guard value.isFinite else { return 120 }
        return min(max(value, AutoBPMDetector.minimumBPM), AutoBPMDetector.maximumBPM)
    }

    /// セクション判定用の帯域プロファイル [sub, low, mid, high, percussive]
    private static func bandProfile(_ b: [Float], percussive: Float) -> [Float] {
        func mean(_ r: Range<Int>) -> Float {
            var s: Float = 0
            for i in r { s += b[i] }
            return s / Float(r.count)
        }
        return [mean(0..<3), mean(3..<9), mean(9..<43), mean(43..<128), percussive]
    }
}
