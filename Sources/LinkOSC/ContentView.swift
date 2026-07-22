import SwiftUI

/// 2カラムレイアウト (最大 1280×720):
/// 左 = 設定 (Dev / Link / Channel / Analysis / Destinations)
/// 右 = モニター (ビジュアライザ群 + vol/gain)。Lite mode で描画を停止できる。
///
/// パフォーマンス設計: 高頻度 (10Hz) で変わる値は `LiveStats` を観測する
/// 小さな末端ビュー (下部の *Live* 系 struct) だけに閉じ込め、
/// ContentView 本体は設定変更時にしか再評価されないようにしている。
struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    devSection
                    Divider()
                    linkSection
                    Divider()
                    inputSection
                    Divider()
                    analysisSection
                    Divider()
                    destsSection
                    Text("LinkOSC \(AppInfo.display) · GPL-2.0-or-later")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding(.bottom, 8)
            }
            .frame(width: 470)

            monitorColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        // 高さは開発モード (WAV/MIDI 行あり) でも左カラムがスクロール無しで
        // 全部見える値。小さい画面用に minHeight まで縮められる (左カラムは
        // ScrollView なので縮めても操作は失われない)
        .frame(minWidth: 1020, idealWidth: 1280, maxWidth: 1280,
               minHeight: 620, idealHeight: 900, maxHeight: 900)
    }

    // MARK: - Left column

    private var devSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Dev Mode (WAV loop / Link OFF)", isOn: $model.devMode)
                    .toggleStyle(.switch)
                Spacer()
                if model.devMode {
                    Text("BPM").font(.caption).foregroundStyle(.secondary)
                    TextField("BPM", value: $model.devBPM, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Button {
                        model.toggleAutoBPM()
                    } label: {
                        Label(model.autoBPMEnabled ? "Stop" : "Auto BPM",
                              systemImage: model.autoBPMEnabled ? "stop.fill" : "metronome")
                    }
                    .controlSize(.small)
                    .help("Count tempo automatically (90–180 BPM)")
                }
            }
            if model.devMode {
                if model.autoBPMEnabled {
                    HStack {
                        Spacer()
                        AutoBPMStatus(stats: model.stats.autoBPM)
                    }
                }
                HStack(spacing: 8) {
                    Text("WAV").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    TextField("WAV file path", text: $model.devFilePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Menu("Bundled") {
                        Button("Dry loop") {
                            model.devBPM = 140
                            model.devFilePath = AppModel.defaultDevFile
                        }
                        Button("Effects loop") {
                            model.devBPM = 140
                            model.devFilePath = AppModel.defaultDevEffectsFile
                        }
                    }
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.audio]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url {
                            model.devFilePath = url.path
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("MIDI").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    TextField("MIDI file path (empty = /note off)", text: $model.devMidiPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.midi]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url {
                            model.devMidiPath = url.path
                        }
                    }
                }
                if let err = model.devError {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Text("Loops WAV + MIDI, sends /fft /vol /beat /note")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if let info = model.devMidiInfo {
                            Text(info).font(.caption2).foregroundStyle(.secondary)
                        }
                        LiveNoteLabel(stats: model.stats.events)
                    }
                }
            }
        }
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Ableton Link", isOn: $model.linkEnabled)
                    .toggleStyle(.switch)
                Spacer()
                LiveLinkInfo(stats: model.stats.transport)
            }
            HStack(spacing: 10) {
                Text("/beat").font(.caption).foregroundStyle(.secondary)
                LiveBeatLights(stats: model.stats.transport)
                Spacer()
                Toggle("send /beat only while playing", isOn: $model.beatOnlyWhenPlaying)
                    .font(.caption)
            }
        }
        .disabled(model.devMode)
        .opacity(model.devMode ? 0.45 : 1)
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audio Input").font(.headline)
                Button {
                    model.refreshInputs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Re-scan macOS input devices and Link Audio channels")
                Spacer()
            }
            Picker("Source", selection: $model.selectedInputKey) {
                Text("Ableton Link Audio").tag(AppModel.linkInputKey)
                Divider()
                ForEach(model.audioInputDevices) { device in
                    Text(device.displayName).tag(device.key)
                }
            }
            .pickerStyle(.menu)

            if model.isLinkAudioSelected {
                Picker("Channel", selection: $model.selectedChannelKey) {
                    Text("(none)").tag("")
                    ForEach(model.channelKeys, id: \.self) { key in
                        Text(key).tag(key)
                    }
                    if !model.selectedChannelKey.isEmpty,
                       !model.channelKeys.contains(model.selectedChannelKey) {
                        Text("\(model.selectedChannelKey) (waiting…)")
                            .tag(model.selectedChannelKey)
                    }
                }
                .pickerStyle(.menu)

                if model.channelKeys.isEmpty {
                    Text("If no channels appear: in the sending Live, check BOTH ① Settings → Link → Link Audio \"On\" and ② the main LINK toggle in Live's top bar. Also allow LinkOSC under macOS System Settings → Privacy & Security → Local Network.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Picker("Channel", selection: $model.selectedInputChannelKey) {
                    ForEach(model.selectedInputChannelOptions) { channel in
                        Text(channel.label).tag(channel.key)
                    }
                }
                .pickerStyle(.menu)
                Text("The selected macOS device is analyzed directly. Monitor playback is disabled to prevent feedback; Ableton Link still supplies /beat timing when enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.audioInputError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(model.devMode)
        .opacity(model.devMode ? 0.45 : 1)
    }

    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Analysis").font(.headline)
                Text("(checked = always computed & sent)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("/fft curve").font(.caption)
                    Picker("", selection: $model.fftCurve) {
                        ForEach(ResponseCurve.allCases) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .labelsHidden().frame(width: 90)
                }
                HStack(spacing: 6) {
                    Text("/vol curve").font(.caption)
                    Picker("", selection: $model.volCurve) {
                        ForEach(ResponseCurve.allCases) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .labelsHidden().frame(width: 90)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                Toggle("/attack", isOn: $model.sendAttack).toggleStyle(.checkbox)
                Picker("", selection: $model.attackPresetName) {
                    ForEach(AttackPreset.presets) { p in
                        Text(p.name).tag(p.name)
                    }
                }
                .labelsHidden().frame(width: 105)
                .disabled(!model.sendAttack)
                LiveCounter(stats: model.stats.events, kind: .attack)
                Spacer()
                Toggle("/novelty", isOn: $model.sendNovelty).toggleStyle(.checkbox)
                LiveNovelty(stats: model.stats.signal)
            }
            HStack(spacing: 12) {
                Toggle("/pattack", isOn: $model.sendPAttack).toggleStyle(.checkbox)
                Picker("", selection: $model.pattackPresetName) {
                    ForEach(AttackPreset.presets) { p in
                        Text(p.name).tag(p.name)
                    }
                }
                .labelsHidden().frame(width: 105)
                .disabled(!model.sendPAttack)
                LiveCounter(stats: model.stats.events, kind: .pattack)
                Text("HPSS percussive onsets").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Toggle("/chroma", isOn: $model.sendChroma).toggleStyle(.checkbox)
            }
            HStack(spacing: 12) {
                Toggle("/hpss", isOn: $model.sendHpss).toggleStyle(.checkbox)
                Picker("", selection: $model.hpssPresetName) {
                    ForEach(HPSSPreset.presets) { p in
                        Text(p.name).tag(p.name)
                    }
                }
                .labelsHidden().frame(width: 105)
                .disabled(!model.sendHpss)
                Toggle("/pfft + /pvol", isOn: $model.sendPFFT).toggleStyle(.checkbox)
                    .help("Percussive-only spectrum & volume (orange overlay)")
                Toggle("/hfft + /hvol", isOn: $model.sendHFFT).toggleStyle(.checkbox)
                    .help("Harmonic-only spectrum & volume (cyan overlay)")
                Spacer()
            }
            HStack(spacing: 12) {
                Toggle("/section", isOn: $model.sendSection)
                    .toggleStyle(.checkbox)
                    .help("Arrangement-change detection at bar heads")
                Picker("", selection: $model.sectionSensitivity) {
                    ForEach(SectionSensitivity.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .labelsHidden().frame(width: 92)
                .disabled(!model.sendSection)
                .help("Sensitivity (threshold)")
                Picker("", selection: $model.sectionWindow) {
                    ForEach(SectionWindow.allCases) { w in
                        Text(w.label).tag(w)
                    }
                }
                .labelsHidden().frame(width: 105)
                .disabled(!model.sendSection)
                .help("Judge window after the bar head — minimum latency is one 60 fps analysis frame")
                LiveCounter(stats: model.stats.events, kind: .section)
                Spacer()
            }
            Text("section = sensitivity + judge window (sub-frame windows: judge on next analysis frame)")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var destsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OSC Destinations").font(.headline)
            Text("/fft /vol (+HPSS variants) /novelty /chroma /hpss @60fps · /beat /note /attack /pattack /section on events · /ping 1 every 500 ms")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(0..<4, id: \.self) { i in
                HStack(spacing: 6) {
                    Toggle("", isOn: $model.dests[i].enabled)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    Text("\(i + 1)").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 12)
                    TextField("host", text: $model.dests[i].host)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 130)
                    Text(":").foregroundStyle(.secondary)
                    TextField("port", text: $model.dests[i].port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 58)
                    Picker("", selection: Binding(
                        get: { DestFilter(rawValue: model.dests[i].filter ?? "") ?? .all },
                        set: { model.dests[i].filter = $0.rawValue }
                    )) {
                        ForEach(DestFilter.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .labelsHidden().frame(width: 82)
                    .help("Address filter: All / Streams only / Events only / Percussive set. /ping is always sent.")
                    Toggle("Bdl", isOn: Binding(
                        get: { model.dests[i].bundled ?? false },
                        set: { model.dests[i].bundled = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Send as OSC #bundle packets (fewer datagrams; receiver must support bundles). Chunked to ≤1400 B — no IP fragmentation.")
                    LiveDestDot(stats: model.stats.destinations, index: i)
                }
            }
            HStack(spacing: 6) {
                Text("Interface").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $model.ifaceName) {
                    Text("Auto (OS routing)").tag("")
                    ForEach(model.ifaceChoices) { c in
                        Text(c.label).tag(c.name)
                    }
                    if !model.ifaceName.isEmpty,
                       !model.ifaceChoices.contains(where: { $0.name == model.ifaceName }) {
                        Text("\(model.ifaceName) (not present)").tag(model.ifaceName)
                    }
                }
                .labelsHidden().frame(width: 190)
                .help("Which NIC OSC leaves from. Auto = OS routing (correct for most unicast). Pin an interface when a multicast group must leave a specific port, or when Wi-Fi and Ethernet share the same subnet. Hover a destination dot to see the actual egress path.")
                Spacer()
            }
            if model.ifaceMissing {
                Text("Selected interface is not present — sending via Auto until it returns.")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.dests.contains(where: { $0.enabled && OSC.isMulticastHost($0.host) }) {
                Text("Multicast destination (224–239.x.x.x): use a wired LAN — Wi-Fi multicast is slow and lossy. Receivers must join the group; TTL is 1 (same segment only).")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Idle suppression (skip unchanged frames, refresh at 2 Hz)",
                   isOn: $model.idleSuppression)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("When values haven't changed (silence / freeze), stream messages are skipped and re-sent at least every 500 ms. Latest-value-store receivers are unaffected. Events and /ping always go out.")
            Text("All settings are saved automatically")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Right column (monitor)

    private var monitorColumn: some View {
        let displayState = model.visualizationLevelMode == .raw
            ? model.rawVizState : model.vizState
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Monitor").font(.headline)
                Spacer()
                LiveReceiving(stats: model.stats.transport)
                Picker("Graph level", selection: $model.visualizationLevelMode) {
                    ForEach(VisualizationLevelMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
                .help("Adjusted shows Auto/Manual gain; Raw shows the input before analysis gain. OSC output is unchanged.")
                Toggle("Lite mode", isOn: $model.liteMode)
                    .toggleStyle(.switch)
                    .help("Pauses visualization rendering and slows UI updates to 1 Hz — analysis & OSC output are unaffected")
            }

            if model.liteMode {
                LiteBox(transport: model.stats.transport,
                        signal: model.stats.signal,
                        events: model.stats.events)
            } else {
                MetalVisualizer(state: displayState)
                    .id("main-\(model.visualizationLevelMode.rawValue)")
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Text("spectrum (dim) + harmonic/percussive overlays + correlation")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("L R H P").font(.caption2.monospaced()).foregroundStyle(.secondary)
                }

                MetalChromaView(state: displayState)
                    .id("chroma-\(model.visualizationLevelMode.rawValue)")
                    .frame(height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(model.sendChroma ? 1 : 0.35)
                ChromaLabels()

                MetalHistoryView(state: displayState)
                    .id("history-\(model.visualizationLevelMode.rawValue)")
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HistoryLegend()
            }

            LiveVolMeter(stats: model.stats.signal)
            FaderControls(model: model)
        }
    }
}

/// 連続的に変化するフェーダー値を ContentView/AppModel の全体再評価から分離する。
/// ドラッグ中に再評価されるのはこの小さな View だけ。
private struct FaderControls: View {
    let model: AppModel
    @State private var monitorMuted: Bool
    @State private var monitorVolume: Double
    @State private var gain: Double
    @State private var gainMode: InputGainMode

    init(model: AppModel) {
        self.model = model
        _monitorMuted = State(initialValue: model.monitorMuted)
        _monitorVolume = State(initialValue: model.monitorVolume)
        _gain = State(initialValue: model.gain)
        _gainMode = State(initialValue: model.gainMode)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("monitor").font(.caption).foregroundStyle(.secondary)
                Button {
                    monitorMuted.toggle()
                    model.setMonitorMuted(monitorMuted)
                } label: {
                    Image(systemName: monitorMuted
                          ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 20)
                        .foregroundStyle(monitorMuted ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help("Mute monitor output — analysis & OSC are unaffected")
                Slider(value: $monitorVolume, in: 0...1)
                    .disabled(monitorMuted)
                    .onChange(of: monitorVolume) { model.setMonitorVolume($0) }
                Text(monitorMuted ? "muted" : String(format: "%3d%%", Int(monitorVolume * 100)))
                    .font(.caption).monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            HStack {
                Text("gain").font(.caption).foregroundStyle(.secondary)
                Picker("Gain mode", selection: $gainMode) {
                    ForEach(InputGainMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 126)
                .onChange(of: gainMode) { model.gainMode = $0 }

                if gainMode == .automatic {
                    AutoGainFader(stats: model.stats.gainControl)
                } else {
                    Slider(value: $gain, in: 0.1...8.0)
                        .onChange(of: gain) { model.setGain($0) }
                        .help("Manual analysis gain")
                    Text(String(format: "×%.1f", gain))
                        .font(.caption).monospacedDigit()
                        .frame(width: 54, alignment: .trailing)
                }
            }
        }
    }
}

private struct AutoGainFader: View {
    @ObservedObject var stats: LiveStats.GainControl

    var body: some View {
        Slider(
            value: .constant(Double(stats.snapshot.effectiveGain)),
            in: Double(AutoGainController.minimumGain)...Double(AutoGainController.maximumGain))
            .disabled(true)
            .help("Auto gain: hold for 4 seconds and normalize peaks near 0.95 (up to 1.05 before clamping)")
        Text(String(format: "×%.1f", stats.snapshot.effectiveGain))
            .font(.caption).monospacedDigit()
            .frame(width: 54, alignment: .trailing)
    }
}

// MARK: - 静的な補助ビュー

private struct ChromaLabels: View {
    private static let noteNames = ["C", "C#", "D", "D#", "E", "F",
                                    "F#", "G", "G#", "A", "A#", "B"]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<12, id: \.self) { i in
                Text(Self.noteNames[i])
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct HistoryLegend: View {
    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            legend("vol", .green)
            legend("novelty", .yellow)
            legend("harmonic", .cyan)
            legend("percussive", .orange)
            Spacer()
            legend("attack ▎", .orange)
            legend("pattack ▎", Color(red: 1.0, green: 0.3, blue: 0.55))
            legend("section │", Color(red: 0.95, green: 0.3, blue: 0.35))
        }
    }
}

// MARK: - LiveStats を観測する末端ビュー (10Hz 更新はここだけ再評価される)

private struct LiveLinkInfo: View {
    @ObservedObject var stats: LiveStats.Transport
    var body: some View {
        HStack {
            Text("peers: \(stats.peers)")
                .foregroundStyle(stats.peers > 0 ? .primary : .secondary)
                .frame(width: 70, alignment: .trailing)
            Text(String(format: "%.1f BPM", stats.tempo))
                .monospacedDigit()
                .frame(width: 85, alignment: .trailing)
            Text(stats.isPlaying ? "▶︎ playing" : "■ stopped")
                .foregroundStyle(stats.isPlaying ? .green : .secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }
}

private struct AutoBPMStatus: View {
    @ObservedObject var stats: LiveStats.AutoBPM
    var body: some View {
        let snapshot = stats.snapshot
        Group {
            if let bpm = snapshot.bpm {
                Text(String(format: "%@ %.1f BPM · %d%%",
                            snapshot.stable ? "locked" : "counting",
                            bpm, Int(snapshot.confidence * 100)))
                    .foregroundStyle(snapshot.stable ? .green : .orange)
            } else {
                Text(String(format: "counting… %.1fs", snapshot.elapsed))
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption.monospacedDigit())
        .frame(width: 190, alignment: .trailing)
    }
}

private struct LiveBeatLights: View {
    @ObservedObject var stats: LiveStats.Transport
    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(stats.beat == i ? Color.accentColor : Color.gray.opacity(0.25))
                    .frame(width: 16, height: 16)
                    .overlay(Text("\(i)").font(.system(size: 9)).foregroundStyle(.secondary))
            }
        }
    }
}

private struct LiveNoteLabel: View {
    @ObservedObject var stats: LiveStats.Events
    var body: some View {
        Text(stats.lastNote)
            .font(.caption2.monospaced())
            .foregroundStyle(.cyan)
            .frame(width: 110, alignment: .trailing)
    }
}

private struct LiveReceiving: View {
    @ObservedObject var stats: LiveStats.Transport
    var body: some View {
        Group {
            if stats.audioFlowing {
                Text(String(format: "receiving %.0f Hz", stats.receivingRate))
                    .foregroundStyle(.green)
            } else {
                Text("no audio").foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospacedDigit())
        .frame(width: 130, alignment: .trailing)
    }
}

private struct LiveNovelty: View {
    @ObservedObject var stats: LiveStats.Signal
    var body: some View {
        Text(String(format: "%.2f", stats.noveltyValue))
            .font(.caption.monospaced()).foregroundStyle(.secondary)
            .frame(width: 40, alignment: .trailing)
    }
}

private struct LiveCounter: View {
    enum Kind { case attack, pattack, section }
    @ObservedObject var stats: LiveStats.Events
    let kind: Kind

    var body: some View {
        let (count, color): (Int, Color) = {
            switch kind {
            case .attack: return (stats.attackCount, .orange)
            case .pattack: return (stats.pattackCount, Color(red: 1.0, green: 0.3, blue: 0.55))
            case .section: return (stats.sectionCount, .cyan)
            }
        }()
        Text("×\(count)")
            .font(.caption.monospaced()).foregroundStyle(color)
            .frame(width: 56, alignment: .leading)
    }
}

private struct LiveVolMeter: View {
    @ObservedObject var stats: LiveStats.Signal
    var body: some View {
        HStack {
            Text("/vol OSC").font(.caption).foregroundStyle(.secondary)
                .help("Actual outgoing /vol value; the Adjusted / Raw selector changes only the graphs above")
            // scaleEffect はレイアウトを再計算させない (GeometryReader だと毎更新で
            // ウィンドウ全体の AutoLayout パスが走る)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.green)
                    .scaleEffect(x: CGFloat(min(max(stats.vol, 0), 1)), y: 1,
                                 anchor: .leading)
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(String(format: "%.3f", stats.vol))
                .font(.caption).monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// 宛先の送信状態ドット: 灰=無効 / 橙=接続中 / 緑=送信中 / 赤=ドロップ発生
private struct LiveDestDot: View {
    @ObservedObject var stats: LiveStats.Destinations
    let index: Int

    var body: some View {
        let s = index < stats.states.count ? stats.states[index] : 0
        let via = index < stats.via.count ? stats.via[index] : ""
        let (color, label): (Color, String) = {
            switch s {
            case 1: return (.orange, "connecting…")
            case 2: return (.green, "sending")
            case 3: return (.red, "dropping — receiver unreachable or slow")
            default: return (Color.gray.opacity(0.35), "disabled")
            }
        }()
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(via.isEmpty ? label : "\(label) — via \(via)")
    }
}

private struct LiteBox: View {
    @ObservedObject var transport: LiveStats.Transport
    @ObservedObject var signal: LiveStats.Signal
    @ObservedObject var events: LiveStats.Events
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.gray.opacity(0.08))
            .overlay(
                VStack(spacing: 10) {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Rendering paused")
                        .font(.headline)
                    Text("Analysis and OSC output continue at 60 fps.\nUI refreshes once per second.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Text(String(format: "vol %.3f", signal.vol))
                        Text("beat \(max(transport.beat, 0))")
                        Text(String(format: "novelty %.2f", signal.noveltyValue))
                        Text("attacks ×\(events.attackCount)")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
            )
            .frame(maxHeight: .infinity)
    }
}
