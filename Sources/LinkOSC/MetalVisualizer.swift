import SwiftUI
import MetalKit

/// ウィンドウが完全に隠れている間は描画を自動停止する MTKView。
/// 背面運用 (他アプリの裏に置きっぱなし) で描画コストをゼロにする。
/// 解析・OSC 送信ループとは無関係 (あちらは動き続ける)。
final class OcclusionPausingMTKView: MTKView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let w = window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(occlusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: w)
            occlusionChanged()
        }
    }

    @objc private func occlusionChanged() {
        isPaused = !(window?.occlusionState.contains(.visible) ?? false)
    }
}

/// 解析スレッド → Metal 描画スレッドへの受け渡し
final class VizState {
    struct Data: Equatable {
        var spectrum = [Float](repeating: 0, count: SpectrumAnalyzer.bands)
        var rmsL: Float = 0
        var rmsR: Float = 0
        var corr: Float = 1     // -1..1 (stereo phase correlation)
        var harmonic: Float = 0
        var percussive: Float = 0
        var chroma = [Float](repeating: 0, count: 12)
        var hSpectrum = [Float](repeating: 0, count: SpectrumAnalyzer.bands)
        var pSpectrum = [Float](repeating: 0, count: SpectrumAnalyzer.bands)

        init() {}

        init(spectrum: [Float], rmsL: Float, rmsR: Float, corr: Float,
             harmonic: Float, percussive: Float, chroma: [Float],
             hSpectrum: [Float], pSpectrum: [Float]) {
            self.spectrum = spectrum
            self.rmsL = rmsL
            self.rmsR = rmsR
            self.corr = corr
            self.harmonic = harmonic
            self.percussive = percussive
            self.chroma = chroma
            self.hSpectrum = hSpectrum
            self.pSpectrum = pSpectrum
        }
    }

    private let dataLock = NSLock()
    private let historyLock = NSLock()
    private var data = Data()
    private var dataGeneration: UInt64 = 0

    func set(_ d: Data) {
        dataLock.lock()
        if data != d {
            data = d
            dataGeneration &+= 1
        }
        dataLock.unlock()
    }

    func snapshot() -> (data: Data, generation: UInt64) {
        dataLock.lock()
        defer { dataLock.unlock() }
        return (data, dataGeneration)
    }

    // MARK: 解析値ヒストリー (8秒 @60fps)

    struct HistoryPoint {
        var vol: Float = 0
        var novelty: Float = 0
        var harmonic: Float = 0
        var percussive: Float = 0
        var attack = false
        var pattack = false
        var section = false
    }

    static let historyLength = 480
    private var history = [HistoryPoint](repeating: HistoryPoint(), count: VizState.historyLength)
    private var histIndex = 0

    func pushHistory(_ p: HistoryPoint) {
        historyLock.lock()
        history[histIndex] = p
        histIndex = (histIndex + 1) % Self.historyLength
        historyLock.unlock()
    }

    /// 古い→新しい順に整列したコピーを返す
    func historySnapshot(into out: inout [HistoryPoint]) {
        historyLock.lock()
        let n = Self.historyLength
        for i in 0..<n {
            out[i] = history[(histIndex + i) % n]
        }
        historyLock.unlock()
    }
}

/// 共有 Metal パイプライン (単色頂点シェーダ)
enum VizMetal {
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VIn { packed_float2 pos; packed_float4 color; };
    struct VOut { float4 pos [[position]]; float4 color; };
    vertex VOut viz_vertex(const device VIn *verts [[buffer(0)]], uint vid [[vertex_id]]) {
        VOut o;
        o.pos = float4(verts[vid].pos, 0.0, 1.0);
        o.color = float4(verts[vid].color);
        return o;
    }
    fragment float4 viz_fragment(VOut in [[stage_in]]) {
        return in.color;
    }
    """

    static func makePipeline(_ view: MTKView) -> MTLRenderPipelineState? {
        guard let device = view.device else { return nil }
        do {
            let lib = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "viz_vertex")
            desc.fragmentFunction = lib.makeFunction(name: "viz_fragment")
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            return try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            return nil
        }
    }
}

/// 軽量 Metal ビジュアライザ:
/// スペクトラム128バー + L/R レベル + H(armonic)/P(ercussive) バー + ステレオ相関マーカー
struct MetalVisualizer: NSViewRepresentable {
    let state: VizState

    func makeCoordinator() -> VizRenderer {
        VizRenderer(state: state)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = OcclusionPausingMTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.preferredFramesPerSecond = 30 // モニター用途は 30fps で十分 (CPU 節約)
        view.clearColor = MTLClearColor(red: 0.04, green: 0.045, blue: 0.06, alpha: 1)
        view.delegate = context.coordinator
        context.coordinator.setup(view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}

/// Chroma (12 pitch classes) bar display
struct MetalChromaView: NSViewRepresentable {
    let state: VizState

    func makeCoordinator() -> ChromaRenderer {
        ChromaRenderer(state: state)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = OcclusionPausingMTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.preferredFramesPerSecond = 15
        view.clearColor = MTLClearColor(red: 0.04, green: 0.045, blue: 0.06, alpha: 1)
        view.delegate = context.coordinator
        context.coordinator.setup(view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}

final class ChromaRenderer: NSObject, MTKViewDelegate {
    private struct Vertex {
        var x: Float, y: Float
        var r: Float, g: Float, b: Float, a: Float
    }

    private let state: VizState
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var vertexBuffer: MTLBuffer?
    private var vertices: [Vertex] = []
    private var lastGeneration: UInt64?

    // one hue per pitch class (C .. B)
    private static let colors: [(Float, Float, Float)] = (0..<12).map { i in
        let h = Float(i) / 12.0
        // simple HSV→RGB (s=0.65, v=0.95)
        let s: Float = 0.65, v: Float = 0.95
        let k = h * 6
        let f = k - floor(k)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch Int(k) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    init(state: VizState) {
        self.state = state
        super.init()
    }

    func setup(_ view: MTKView) {
        guard let device = view.device else { return }
        queue = device.makeCommandQueue()
        vertexBuffer = device.makeBuffer(length: 32 * 6 * MemoryLayout<Vertex>.stride,
                                         options: .storageModeShared)
        pipeline = VizMetal.makePipeline(view)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lastGeneration = nil
    }

    private func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float,
                      _ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        vertices.append(Vertex(x: x0, y: y0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x1, y: y0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x0, y: y1, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x1, y: y0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x1, y: y1, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x0, y: y1, r: r, g: g, b: b, a: a))
    }

    func draw(in view: MTKView) {
        let snapshot = state.snapshot()
        guard snapshot.generation != lastGeneration else { return }
        guard let pipeline,
              let queue,
              let vertexBuffer,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        lastGeneration = snapshot.generation

        let chroma = snapshot.data.chroma
        vertices.removeAll(keepingCapacity: true)

        let x0: Float = -0.99, x1: Float = 0.99
        let y0: Float = -0.9, y1: Float = 0.9
        let bw = (x1 - x0) / 12
        for i in 0..<12 {
            let bx0 = x0 + Float(i) * bw + bw * 0.06
            let bx1 = x0 + Float(i + 1) * bw - bw * 0.06
            let c = Self.colors[i]
            // background slot
            quad(bx0, y0, bx1, y1, 0.11, 0.12, 0.15)
            let v = min(max(chroma[i], 0), 1)
            quad(bx0, y0, bx1, y0 + (y1 - y0) * v, c.0, c.1, c.2)
        }

        let count = vertices.count
        vertices.withUnsafeBytes { src in
            vertexBuffer.contents().copyMemory(from: src.baseAddress!,
                                               byteCount: count * MemoryLayout<Vertex>.stride)
        }
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

/// 解析値のヒストリーグラフ (8秒スクロール):
/// vol(緑) / novelty(黄) / harmonic(シアン) / percussive(オレンジ) の折れ線 +
/// attack(上部ティック) / section(縦ライン) イベントマーカー
struct MetalHistoryView: NSViewRepresentable {
    let state: VizState

    func makeCoordinator() -> HistoryRenderer {
        HistoryRenderer(state: state)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = OcclusionPausingMTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.preferredFramesPerSecond = 10 // 8秒窓の推移確認には10fpsで十分
        view.clearColor = MTLClearColor(red: 0.04, green: 0.045, blue: 0.06, alpha: 1)
        view.delegate = context.coordinator
        context.coordinator.setup(view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}

final class HistoryRenderer: NSObject, MTKViewDelegate {
    private struct Vertex {
        var x: Float, y: Float
        var r: Float, g: Float, b: Float, a: Float
    }

    private let state: VizState
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var vertexBuffer: MTLBuffer?
    private var vertices: [Vertex] = []
    private var snapshot = [VizState.HistoryPoint](repeating: VizState.HistoryPoint(),
                                                   count: VizState.historyLength)
    // 4曲線 + グリッド/マーカー分の余裕
    private var capacity: Int { VizState.historyLength * 4 + 1024 }

    init(state: VizState) {
        self.state = state
        super.init()
    }

    func setup(_ view: MTKView) {
        guard let device = view.device else { return }
        queue = device.makeCommandQueue()
        vertexBuffer = device.makeBuffer(length: capacity * MemoryLayout<Vertex>.stride,
                                         options: .storageModeShared)
        pipeline = VizMetal.makePipeline(view)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float,
                      _ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        vertices.append(Vertex(x: x0, y: y0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x1, y: y0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x0, y: y1, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x1, y: y0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x1, y: y1, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x0, y: y1, r: r, g: g, b: b, a: a))
    }

    func draw(in view: MTKView) {
        guard let pipeline,
              let queue,
              let vertexBuffer,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }

        state.historySnapshot(into: &snapshot)
        vertices.removeAll(keepingCapacity: true)

        let n = VizState.historyLength
        let x0: Float = -0.99, x1: Float = 0.99
        let y0: Float = -0.92, y1: Float = 0.92
        func xAt(_ i: Int) -> Float { x0 + (x1 - x0) * Float(i) / Float(n - 1) }
        func yAt(_ v: Float) -> Float { y0 + (y1 - y0) * min(max(v, 0), 1) }

        // グリッド (25/50/75%) とイベントマーカー (三角形なので先に)
        for g in [0.25, 0.5, 0.75] {
            let y = yAt(Float(g))
            quad(x0, y - 0.004, x1, y + 0.004, 0.14, 0.15, 0.19)
        }
        for i in 0..<n {
            if snapshot[i].section {
                quad(xAt(i) - 0.003, y0, xAt(i) + 0.003, y1, 0.95, 0.3, 0.35, 0.9)
            }
            if snapshot[i].attack {
                quad(xAt(i) - 0.002, y1 - 0.12, xAt(i) + 0.002, y1, 1.0, 0.62, 0.2, 0.9)
            }
            if snapshot[i].pattack {
                quad(xAt(i) - 0.002, y1 - 0.26, xAt(i) + 0.002, y1 - 0.14, 1.0, 0.3, 0.55, 0.9)
            }
        }
        let quadCount = vertices.count

        // 折れ線 4本 (lineStrip)
        var lineRanges: [(start: Int, count: Int)] = []
        func strip(_ value: (VizState.HistoryPoint) -> Float,
                   _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
            let start = vertices.count
            for i in 0..<n {
                vertices.append(Vertex(x: xAt(i), y: yAt(value(snapshot[i])),
                                       r: r, g: g, b: b, a: a))
            }
            lineRanges.append((start, n))
        }
        strip({ $0.harmonic }, 0.25, 0.75, 1.0, 0.9)     // シアン
        strip({ $0.percussive }, 1.0, 0.6, 0.2, 0.9)     // オレンジ
        strip({ $0.novelty }, 0.95, 0.9, 0.35, 0.9)      // 黄
        strip({ $0.vol }, 0.3, 0.95, 0.4, 1.0)           // 緑 (最前面)

        let total = min(vertices.count, capacity)
        vertices.withUnsafeBytes { src in
            vertexBuffer.contents().copyMemory(from: src.baseAddress!,
                                               byteCount: total * MemoryLayout<Vertex>.stride)
        }

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        if quadCount > 0 {
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: quadCount)
        }
        for r in lineRanges {
            enc.drawPrimitives(type: .lineStrip, vertexStart: r.start, vertexCount: r.count)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

final class VizRenderer: NSObject, MTKViewDelegate {
    // packed_float2 + packed_float4 = 24 bytes
    private struct Vertex {
        var x: Float, y: Float
        var r: Float, g: Float, b: Float, a: Float
    }

    private let state: VizState
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var vertexBuffer: MTLBuffer?
    private var vertices: [Vertex] = []
    private let maxQuads = SpectrumAnalyzer.bands * 3 + 16
    private var lastGeneration: UInt64?

    init(state: VizState) {
        self.state = state
        super.init()
    }

    func setup(_ view: MTKView) {
        guard let device = view.device else { return }
        queue = device.makeCommandQueue()
        vertexBuffer = device.makeBuffer(length: maxQuads * 6 * MemoryLayout<Vertex>.stride,
                                         options: .storageModeShared)
        pipeline = VizMetal.makePipeline(view)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lastGeneration = nil
    }

    private func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float,
                      _ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        vertices.append(Vertex(x: x0, y: y0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x1, y: y0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x0, y: y1, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x1, y: y0, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x1, y: y1, r: r, g: g, b: b, a: a))
        vertices.append(Vertex(x: x0, y: y1, r: r, g: g, b: b, a: a))
    }

    func draw(in view: MTKView) {
        let snapshot = state.snapshot()
        guard snapshot.generation != lastGeneration else { return }
        guard let pipeline,
              let queue,
              let vertexBuffer,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        lastGeneration = snapshot.generation

        let d = snapshot.data
        vertices.removeAll(keepingCapacity: true)

        // --- スペクトラム 128 バー (x: -0.98..0.58) ---
        let specX0: Float = -0.98
        let specX1: Float = 0.58
        let bottom: Float = -0.78
        let top: Float = 0.95
        let n = d.spectrum.count
        let bw = (specX1 - specX0) / Float(n)
        for i in 0..<n {
            let v = min(max(d.spectrum[i], 0), 1)
            let h = bottom + (top - bottom) * v
            let t = Float(i) / Float(n)
            // full spectrum: green -> cyan (dimmed so the HPSS overlays read)
            quad(specX0 + Float(i) * bw, bottom,
                 specX0 + Float(i + 1) * bw - bw * 0.15, h,
                 (0.1 + 0.2 * t) * 0.55, (0.9 - 0.25 * t) * 0.55, (0.35 + 0.6 * t) * 0.55)
        }
        // HPSS overlays: harmonic (cyan, left half) / percussive (orange, right half)
        for i in 0..<n {
            let x = specX0 + Float(i) * bw
            let hv = min(max(d.hSpectrum[i], 0), 1)
            if hv > 0.003 {
                quad(x, bottom, x + bw * 0.42, bottom + (top - bottom) * hv,
                     0.25, 0.75, 1.0, 0.9)
            }
            let pv = min(max(d.pSpectrum[i], 0), 1)
            if pv > 0.003 {
                quad(x + bw * 0.43, bottom, x + bw * 0.85, bottom + (top - bottom) * pv,
                     1.0, 0.6, 0.2, 0.9)
            }
        }

        // --- 右側メーター: L R H P (x: 0.62..0.98) ---
        let labels: [(Float, Float, Float, Float)] = [
            (d.rmsL, 0.3, 0.95, 0.4),   // L 緑
            (d.rmsR, 0.3, 0.95, 0.4),   // R 緑
            (d.harmonic, 0.25, 0.75, 1.0),   // H シアン
            (d.percussive, 1.0, 0.6, 0.2),   // P オレンジ
        ]
        for (i, m) in labels.enumerated() {
            let x0 = 0.62 + Float(i) * 0.095
            let v = min(max(m.0, 0), 1)
            let h = bottom + (top - bottom) * v
            // 背景
            quad(x0, bottom, x0 + 0.07, top, 0.12, 0.13, 0.16)
            quad(x0, bottom, x0 + 0.07, h, m.1, m.2, m.3)
            // クリップ警告
            if v > 0.98 {
                quad(x0, top - 0.04, x0 + 0.07, top, 1, 0.2, 0.2)
            }
        }

        // --- ステレオ相関バー (下部, -1..+1 → x -0.98..0.58) ---
        let cy0: Float = -0.97
        let cy1: Float = -0.86
        quad(specX0, cy0, specX1, cy1, 0.12, 0.13, 0.16)
        let mid = (specX0 + specX1) / 2
        quad(mid - 0.002, cy0, mid + 0.002, cy1, 0.35, 0.37, 0.42) // センター線
        let corr = min(max(d.corr, -1), 1)
        let cx = mid + corr * (specX1 - specX0) / 2
        // corr < 0 (位相問題) は赤、>= 0 は白
        let bad = corr < 0
        quad(cx - 0.012, cy0, cx + 0.012, cy1,
             bad ? 1 : 0.9, bad ? 0.25 : 0.9, bad ? 0.25 : 0.9)

        let count = min(vertices.count, maxQuads * 6)
        vertices.withUnsafeBytes { src in
            vertexBuffer.contents().copyMemory(from: src.baseAddress!,
                                               byteCount: count * MemoryLayout<Vertex>.stride)
        }

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
