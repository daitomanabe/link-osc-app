// vjbake (github.com/daitomanabe/vjbake) と共有している解析ソース。
// アルゴリズム・校正を両ツールで一致させるため、変更時は両方に反映すること。
import Foundation
import Accelerate

// MARK: - Response curves (/fft /vol)

enum ResponseCurve: String, CaseIterable, Codable, Identifiable {
    case linear, sqrt, log, pow2, pow3
    var id: String { rawValue }

    var label: String {
        switch self {
        case .linear: return "Linear"
        case .sqrt: return "Sqrt"
        case .log: return "Log"
        case .pow2: return "Pow²"
        case .pow3: return "Pow³"
        }
    }

    func apply(_ x: Float) -> Float {
        let c = min(max(x, 0), 1)
        switch self {
        case .linear: return c
        case .sqrt: return sqrtf(c)
        case .log: return log1pf(9 * c) / log1pf(9) // lifts low levels
        case .pow2: return c * c
        case .pow3: return c * c * c
        }
    }

    func apply(_ v: [Float]) -> [Float] {
        v.map { apply($0) }
    }
}

// MARK: - Golden presets

/// Onset detection (spectral flux, lightweight port of flucoma OnsetSlice for 60fps)
struct AttackPreset: Identifiable {
    let name: String
    let smooth: Int        // moving average frames for flux
    let ratio: Float       // adaptive threshold = ratio × running median
    let minGapFrames: Int  // retrigger blackout (60fps frames)
    let minAbs: Float      // absolute flux floor
    var id: String { name }

    static let presets: [AttackPreset] = [
        // Tight: catches fast repeats (hi-hats etc.)
        AttackPreset(name: "Tight", smooth: 1, ratio: 1.6, minGapFrames: 4, minAbs: 0.008),
        // Standard: general drums
        AttackPreset(name: "Standard", smooth: 3, ratio: 2.0, minGapFrames: 8, minAbs: 0.012),
        // Smooth: strong hits only (kick / snare class)
        AttackPreset(name: "Smooth", smooth: 5, ratio: 2.8, minGapFrames: 15, minAbs: 0.02),
    ]

    static func named(_ name: String) -> AttackPreset {
        presets.first { $0.name == name } ?? presets[1]
    }
}

/// HPSS (median filtering) presets. Kernels are odd.
struct HPSSPreset: Identifiable {
    let name: String
    let timeK: Int  // temporal median (frames @60fps)
    let freqK: Int  // spectral median (bins)
    var id: String { name }

    static let presets: [HPSSPreset] = [
        // Fast: low latency, reactive
        HPSSPreset(name: "Fast", timeK: 7, freqK: 17),
        // Standard: balanced (≈ flucoma defaults)
        HPSSPreset(name: "Standard", timeK: 17, freqK: 31),
        // Deep: strongest separation, slower
        HPSSPreset(name: "Deep", timeK: 31, freqK: 63),
    ]

    static func named(_ name: String) -> HPSSPreset {
        presets.first { $0.name == name } ?? presets[1]
    }
}

/// Judgement window at bar heads: how much of the bar is accumulated before
/// judging. Longer = later reaction but far less likely to miss a change.
enum SectionWindow: String, CaseIterable, Codable, Identifiable {
    case twoHundredFiftySixthBeat
    case oneHundredTwentyEighthBeat
    case sixtyFourthBeat
    case thirtySecondBeat
    case sixteenthBeat
    case eighthBeat
    case quarterBeat
    case halfBeat
    case oneBeat
    case twoBeats
    var id: String { rawValue }

    var label: String {
        switch self {
        case .twoHundredFiftySixthBeat: return "1/256 beat"
        case .oneHundredTwentyEighthBeat: return "1/128 beat"
        case .sixtyFourthBeat: return "1/64 beat"
        case .thirtySecondBeat: return "1/32 beat"
        case .sixteenthBeat: return "1/16 beat"
        case .eighthBeat: return "1/8 beat"
        case .quarterBeat: return "¼ beat"
        case .halfBeat: return "½ beat"
        case .oneBeat: return "1 beat"
        case .twoBeats: return "2 beats"
        }
    }

    var beats: Double {
        switch self {
        case .twoHundredFiftySixthBeat: return 1.0 / 256.0
        case .oneHundredTwentyEighthBeat: return 1.0 / 128.0
        case .sixtyFourthBeat: return 1.0 / 64.0
        case .thirtySecondBeat: return 1.0 / 32.0
        case .sixteenthBeat: return 1.0 / 16.0
        case .eighthBeat: return 1.0 / 8.0
        case .quarterBeat: return 0.25
        case .halfBeat: return 0.5
        case .oneBeat: return 1.0
        case .twoBeats: return 2.0
        }
    }

    /// 60fps フレーム数に変換 (テンポ依存)。1フレーム未満の設定は
    /// 次の解析フレームで即判定するため、最低1フレームに丸める。
    func frames(tempo: Double) -> Int {
        let bpm = tempo > 20 ? tempo : 120
        let f = Int((beats * 60.0 / bpm * 60.0).rounded())
        return min(max(f, 1), 240)
    }
}

/// Section-change sensitivity (relative-change threshold at bar heads)
enum SectionSensitivity: String, CaseIterable, Codable, Identifiable {
    case high, medium, low
    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    /// Lower threshold = more sensitive
    var threshold: Float {
        switch self {
        case .high: return 0.25
        case .medium: return 0.4
        case .low: return 0.6
        }
    }
}

// MARK: - DSP helpers

enum DSP {
    /// In-place quickselect median of a[0..<n]
    static func median(_ a: inout [Float], _ n: Int) -> Float {
        guard n > 0 else { return 0 }
        var lo = 0, hi = n - 1
        let k = n / 2
        while lo < hi {
            let pivot = a[(lo + hi) / 2]
            var i = lo, j = hi
            while i <= j {
                while a[i] < pivot { i += 1 }
                while a[j] > pivot { j -= 1 }
                if i <= j {
                    a.swapAt(i, j)
                    i += 1; j -= 1
                }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { break }
        }
        return a[k]
    }
}

// MARK: - Onset detector (one instance per signal)

/// Spectral-flux onset detector with adaptive (running-median) threshold.
final class OnsetDetector {
    private let nBins: Int
    private var prevMags: [Float]
    private var fluxHistory = [Float](repeating: 0, count: 43) // ~0.7s
    private var fluxIndex = 0
    private var fluxFilled = 0
    private var smoothBuf = [Float](repeating: 0, count: 8)
    private var smoothIndex = 0
    private var framesSinceAttack = 1000
    private var histScratch = [Float](repeating: 0, count: 43)

    init(bins: Int) {
        nBins = bins
        prevMags = [Float](repeating: 0, count: bins)
    }

    /// Returns (raw flux, attack strength if fired)
    func process(_ mags: [Float], preset: AttackPreset) -> (flux: Float, attack: Float?) {
        var flux: Float = 0
        for i in 0..<nBins {
            let d = mags[i] - prevMags[i]
            if d > 0 { flux += d }
        }
        flux /= 32
        for i in 0..<nBins { prevMags[i] = mags[i] }

        let sN = min(max(1, preset.smooth), smoothBuf.count)
        smoothBuf[smoothIndex % sN] = flux
        smoothIndex += 1
        var sFlux: Float = 0
        for i in 0..<sN { sFlux += smoothBuf[i] }
        sFlux /= Float(sN)

        fluxHistory[fluxIndex] = flux
        fluxIndex = (fluxIndex + 1) % fluxHistory.count
        fluxFilled = min(fluxFilled + 1, fluxHistory.count)

        var attack: Float?
        framesSinceAttack += 1
        if fluxFilled >= 8 {
            for i in 0..<fluxFilled { histScratch[i] = fluxHistory[i] }
            let med = DSP.median(&histScratch, fluxFilled)
            let threshold = max(preset.minAbs, preset.ratio * med)
            if sFlux > threshold, framesSinceAttack >= preset.minGapFrames {
                framesSinceAttack = 0
                attack = min(sFlux / max(threshold, 1e-6), 8.0)
            }
        }
        return (flux, attack)
    }
}

// MARK: - Analysis engine

/// Realtime analysis at 60fps: attack / percussive attack / novelty / chroma / HPSS.
/// Each stage runs only when its `Needs` flag is set (checked in UI = computed & used).
final class AnalysisKit {
    static let maxTimeK = 31
    private let nBins = SpectrumAnalyzer.fftSize / 2 // 1024
    private let bands = SpectrumAnalyzer.bands       // 128

    struct Needs {
        var attack = true
        var pattack = true
        var novelty = true
        var chroma = true
        var hpss = true // also forced on by pattack / section (percussive profile)
        var hfft = true // /hfft /hvol (harmonic-only spectrum & volume)
        var pfft = true // /pfft /pvol (percussive-only spectrum & volume)
    }

    struct Result {
        var chroma: [Float]      // 12 (0..1, max-normalized)
        var novelty: Float       // 0..1
        var flux: Float
        var attack: Float?       // fullband onset strength when fired
        var pattack: Float?      // HPSS-percussive onset strength when fired
        var harmonic: Float      // 0..1
        var percussive: Float    // 0..1
        var hBands: [Float]      // 128 harmonic-only bands
        var pBands: [Float]      // 128 percussive-only bands
        var hVol: Float          // harmonic-only RMS-equivalent (Parseval)
        var pVol: Float          // percussive-only RMS-equivalent
    }

    private let fullbandOnset = OnsetDetector(bins: SpectrumAnalyzer.fftSize / 2)
    private let percussiveOnset = OnsetDetector(bins: SpectrumAnalyzer.fftSize / 2)

    // novelty (cosine distance between last 8 frames and the 8 before)
    private let novW = 8
    private var bandHistory: [[Float]] = []

    // chroma
    private var pcMap = [Int8](repeating: -1, count: 1024)
    private var pcMapRate: Double = 0

    // HPSS
    private var magRing = [Float](repeating: 0, count: 31 * 1024)
    private var magRingIndex = 0
    private var magRingFilled = 0
    private var scratch = [Float](repeating: 0, count: 64)
    private var pMags = [Float](repeating: 0, count: 1024)
    private var hMags = [Float](repeating: 0, count: 1024)

    func process(mags: [Float], bandsIn: [Float], sampleRate: Double,
                 attackPreset: AttackPreset, pattackPreset: AttackPreset,
                 hpssPreset: HPSSPreset, needs: Needs) -> Result {
        var result = Result(chroma: [Float](repeating: 0, count: 12),
                            novelty: 0, flux: 0, attack: nil, pattack: nil,
                            harmonic: 0, percussive: 0,
                            hBands: [Float](repeating: 0, count: bands),
                            pBands: [Float](repeating: 0, count: bands),
                            hVol: 0, pVol: 0)

        // ---- fullband spectral flux → /attack ----
        if needs.attack {
            let (flux, attack) = fullbandOnset.process(mags, preset: attackPreset)
            result.flux = flux
            result.attack = attack
        }

        // ---- novelty ----
        if needs.novelty {
            var norm = bandsIn
            var l2: Float = 0
            vDSP_svesq(norm, 1, &l2, vDSP_Length(norm.count))
            if l2 > 1e-9 {
                var s = 1.0 / sqrtf(l2)
                vDSP_vsmul(norm, 1, &s, &norm, 1, vDSP_Length(norm.count))
            }
            bandHistory.append(norm)
            if bandHistory.count > novW * 2 { bandHistory.removeFirst() }
            if bandHistory.count == novW * 2 {
                var recent = [Float](repeating: 0, count: bands)
                var older = [Float](repeating: 0, count: bands)
                for t in 0..<novW {
                    vDSP_vadd(older, 1, bandHistory[t], 1, &older, 1, vDSP_Length(bands))
                    vDSP_vadd(recent, 1, bandHistory[t + novW], 1, &recent, 1, vDSP_Length(bands))
                }
                var dot: Float = 0, e1: Float = 0, e2: Float = 0
                vDSP_dotpr(recent, 1, older, 1, &dot, vDSP_Length(bands))
                vDSP_svesq(recent, 1, &e1, vDSP_Length(bands))
                vDSP_svesq(older, 1, &e2, vDSP_Length(bands))
                let denom = sqrtf(e1 * e2)
                result.novelty = denom > 1e-9 ? min(max(1 - dot / denom, 0), 1) : 0
            }
        } else {
            bandHistory.removeAll(keepingCapacity: true)
        }

        // ---- chroma ----
        if needs.chroma {
            if pcMapRate != sampleRate {
                rebuildPcMap(sampleRate)
            }
            var chroma = [Float](repeating: 0, count: 12)
            for i in 2..<nBins {
                let pc = pcMap[i]
                if pc >= 0 { chroma[Int(pc)] += mags[i] }
            }
            let cmax = chroma.max() ?? 0
            if cmax > 1e-6 {
                for i in 0..<12 { chroma[i] = chroma[i] / cmax }
            }
            result.chroma = chroma
        }

        // ---- HPSS (also required by /pattack, /hfft, /pfft) ----
        if needs.hpss || needs.pattack || needs.hfft || needs.pfft {
            let base = magRingIndex * nBins
            for i in 0..<nBins { magRing[base + i] = mags[i] }
            magRingIndex = (magRingIndex + 1) % Self.maxTimeK
            magRingFilled = min(magRingFilled + 1, Self.maxTimeK)

            let tK = min(hpssPreset.timeK, magRingFilled)
            let fK = hpssPreset.freqK
            let hw = fK / 2
            var hSum: Float = 0
            var pSum: Float = 0
            if magRingFilled >= 3 {
                for f in 0..<nBins {
                    // temporal median (causal, last tK frames)
                    var n = 0
                    for t in 0..<tK {
                        let idx = (magRingIndex - 1 - t + Self.maxTimeK) % Self.maxTimeK
                        scratch[n] = magRing[idx * nBins + f]
                        n += 1
                    }
                    var h = DSP.median(&scratch, n)

                    // spectral median (current frame)
                    let lo = max(0, f - hw), hi = min(nBins - 1, f + hw)
                    n = 0
                    for b in lo...hi {
                        scratch[n] = mags[b]
                        n += 1
                    }
                    var p = DSP.median(&scratch, n)

                    // Wiener soft mask
                    h *= h; p *= p
                    let denom = h + p
                    if denom > 1e-12 {
                        let m = mags[f]
                        let pm = m * (p / denom)
                        let hm = m * (h / denom)
                        hSum += hm
                        pSum += pm
                        pMags[f] = pm
                        hMags[f] = hm
                    } else {
                        pMags[f] = 0
                        hMags[f] = 0
                    }
                }
            }
            // sqrt companding into a usable 0..1 range
            result.harmonic = min(sqrtf(max(hSum / Float(nBins), 0) * 40), 1)
            result.percussive = min(sqrtf(max(pSum / Float(nBins), 0) * 40), 1)

            // ---- onset on the percussive component → /pattack ----
            if needs.pattack, magRingFilled >= 3 {
                let (_, attack) = percussiveOnset.process(pMags, preset: pattackPreset)
                result.pattack = attack
            }

            // ---- HPSS spectrum + volume → /hfft /hvol /pfft /pvol ----
            if needs.hfft {
                result.hBands = Self.reduceBands(hMags)
                result.hVol = Self.spectralRMS(hMags)
            }
            if needs.pfft {
                result.pBands = Self.reduceBands(pMags)
                result.pVol = Self.spectralRMS(pMags)
            }
        }

        return result
    }

    /// 1024bin → 128 bands (max in each group of 8, same as the main /fft)
    private static func reduceBands(_ mags: [Float]) -> [Float] {
        let bands = SpectrumAnalyzer.bands
        let group = mags.count / bands
        var out = [Float](repeating: 0, count: bands)
        for b in 0..<bands {
            var m: Float = 0
            for k in 0..<group {
                m = max(m, mags[b * group + k])
            }
            out[b] = min(m, 1.0)
        }
        return out
    }

    /// Parseval: RMS-equivalent of the signal reconstructed from magnitudes.
    /// Full-scale sine (one bin at 1.0) → 0.707, matching the time-domain /vol.
    private static func spectralRMS(_ mags: [Float]) -> Float {
        var sq: Float = 0
        vDSP_svesq(mags, 1, &sq, vDSP_Length(mags.count))
        return min(sqrtf(sq / 2), 1)
    }

    private func rebuildPcMap(_ sr: Double) {
        pcMapRate = sr
        for i in 0..<nBins {
            let f = Double(i) * sr / Double(SpectrumAnalyzer.fftSize)
            if f >= 55, f <= 8000 {
                let midi = 69.0 + 12.0 * log2(f / 440.0)
                let pc = Int(midi.rounded()) % 12
                pcMap[i] = Int8((pc + 12) % 12)
            } else {
                pcMap[i] = -1
            }
        }
    }
}

// MARK: - Section (arrangement change) detector

/// Compares the band profile at each bar head against recent bar heads and
/// reports only large changes — e.g. the kick disappearing at a bar head
/// shows up as strongly negative sub/percussive deltas.
final class SectionDetector {
    /// Profile: [sub, low, mid, high, percussive]
    static let dims = 5
    private var snapshots: [[Float]] = []   // recent bar-head profiles (max 4)
    private var accum = [Float](repeating: 0, count: dims)
    private var accumCount = 0
    private var collecting = false
    private var collectTarget = 6           // set per bar from the window setting

    struct Change {
        var magnitude: Float
        var deltas: [Float] // dims
    }

    /// 小節頭で呼ぶ。collectFrames = 判定窓 (このフレーム数を集計してから判定)
    func barHead(collectFrames: Int) {
        collecting = true
        collectTarget = max(1, collectFrames)
        accum = [Float](repeating: 0, count: Self.dims)
        accumCount = 0
    }

    /// Call every frame. Returns a change on the collection-complete frame.
    /// 発火条件 (どちらか):
    ///  1. 全体変化量 magnitude > threshold
    ///  2. 単一帯域の相対変化 > threshold × 1.75
    ///     — 他が鳴り続ける中で1要素だけ消えた/入ったケースを見逃さないため
    ///     (例: パッドが大音量のままキックだけ消えると、総和では埋もれる)
    func tick(profile: [Float], threshold: Float) -> Change? {
        guard collecting else { return nil }
        for i in 0..<Self.dims { accum[i] += profile[i] }
        accumCount += 1
        guard accumCount >= collectTarget else { return nil }
        collecting = false

        let snap = accum.map { $0 / Float(accumCount) }
        defer {
            snapshots.append(snap)
            if snapshots.count > 4 { snapshots.removeFirst() }
        }
        guard snapshots.count >= 2 else { return nil }

        var baseline = [Float](repeating: 0, count: Self.dims)
        for s in snapshots {
            for i in 0..<Self.dims { baseline[i] += s[i] }
        }
        for i in 0..<Self.dims { baseline[i] /= Float(snapshots.count) }

        var deltas = [Float](repeating: 0, count: Self.dims)
        var absSum: Float = 0
        var baseSum: Float = 0
        var maxRel: Float = 0
        for i in 0..<Self.dims {
            deltas[i] = snap[i] - baseline[i]
            absSum += abs(deltas[i])
            baseSum += baseline[i]
            // 帯域単体の相対変化 (無音帯域のノイズは除外)
            if max(baseline[i], snap[i]) > 0.015 {
                maxRel = max(maxRel, abs(deltas[i]) / (baseline[i] + 0.02))
            }
        }
        let magnitude = absSum / (baseSum + 0.05)
        let fired = magnitude > threshold || maxRel > threshold * 1.75
        guard fired else { return nil }
        // 強度は「全体」と「最大単一帯域」の大きい方を報告
        return Change(magnitude: min(max(magnitude, maxRel), 4), deltas: deltas)
    }
}
