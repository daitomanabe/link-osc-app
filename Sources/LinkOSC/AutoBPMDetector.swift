import Foundation

/// 60fps のスペクトル変化からテンポを推定する軽量 detector。
/// 候補は 90...180 BPM に限定し、110...140 BPM は同点に近い候補の
/// tie-break にだけ使う。解析ループ専有で、process 中のヒープ確保を避ける。
final class AutoBPMDetector {
    struct Estimate {
        let bpm: Double?
        let confidence: Float
        let stable: Bool
        let elapsed: Double
    }

    static let frameRate = 60.0
    static let minimumBPM = 90.0
    static let maximumBPM = 180.0

    private static let capacity = 720       // 最新12秒
    private static let warmupFrames = 240   // 最初の推定まで4秒
    private static let estimateEvery = 30   // 2Hz
    private static let step = 0.25
    private static let candidateCount =
        Int((maximumBPM - minimumBPM) / step) + 1

    private var previousBands = [Float](repeating: 0, count: SpectrumAnalyzer.bands)
    private var hasPreviousBands = false
    private var history = [Float](repeating: 0, count: capacity)
    private var chronological = [Float](repeating: 0, count: capacity)
    private var centered = [Float](repeating: 0, count: capacity)
    private var scores = [Float](repeating: 0, count: candidateCount)
    private var writeIndex = 0
    private var filled = 0
    private var totalFrames = 0
    private var recentBPM = [Double](repeating: 0, count: 7)
    private var recentScratch = [Double](repeating: 0, count: 7)
    private var recentCount = 0
    private var recentIndex = 0
    private var lockedBPM: Double?
    private var tempoHint: Double?
    private var loopDuration: Double?

    func reset(tempoHint: Double? = nil, loopDuration: Double? = nil) {
        previousBands = [Float](repeating: 0, count: previousBands.count)
        hasPreviousBands = false
        history = [Float](repeating: 0, count: history.count)
        writeIndex = 0
        filled = 0
        totalFrames = 0
        recentCount = 0
        recentIndex = 0
        lockedBPM = nil
        self.tempoHint = tempoHint.map {
            min(max($0, Self.minimumBPM), Self.maximumBPM)
        }
        self.loopDuration = loopDuration.flatMap { $0 > 0 ? $0 : nil }
    }

    /// FFT bands から正の spectral flux を作る。低域を少し重くしつつ全帯域を使い、
    /// キックの少ない曲でもスネア/ハイハット/和音のアタックを拾う。
    func process(bands: [Float]) -> Estimate? {
        let count = min(bands.count, previousBands.count)
        var flux: Float = 0
        var weightSum: Float = 0
        for i in 0..<count {
            let value = sqrtf(max(bands[i], 0))
            if hasPreviousBands {
                let weight: Float = i < 16 ? 1.25 : (i < 72 ? 1.0 : 0.6)
                flux += max(value - previousBands[i], 0) * weight
                weightSum += weight
            }
            previousBands[i] = value
        }
        hasPreviousBands = true
        return process(onset: weightSum > 0 ? flux / weightSum : 0)
    }

    /// 合成試験にも使える onset-envelope 入力。
    func process(onset: Float) -> Estimate? {
        // 大きい一発だけが相関を支配しないよう振幅を圧縮する。
        history[writeIndex] = sqrtf(max(onset, 0))
        writeIndex = (writeIndex + 1) % Self.capacity
        filled = min(filled + 1, Self.capacity)
        totalFrames += 1

        let elapsed = Double(totalFrames) / Self.frameRate
        guard totalFrames.isMultiple(of: Self.estimateEvery) else { return nil }
        guard filled >= Self.warmupFrames else {
            return Estimate(bpm: nil, confidence: 0, stable: false, elapsed: elapsed)
        }
        return estimate(elapsed: elapsed)
    }

    private func estimate(elapsed: Double) -> Estimate {
        let n = filled
        let start = (writeIndex - n + Self.capacity) % Self.capacity
        var mean: Float = 0
        for i in 0..<n {
            let value = history[(start + i) % Self.capacity]
            chronological[i] = value
            mean += value
        }
        mean /= Float(n)

        var energy: Float = 0
        for i in 0..<n {
            let value = chronological[i] - mean
            centered[i] = value
            energy += value * value
        }
        guard energy / Float(n) > 1e-7 else {
            recentCount = 0
            recentIndex = 0
            lockedBPM = nil
            return Estimate(bpm: nil, confidence: 0, stable: false, elapsed: elapsed)
        }

        var bestIndex = 0
        var bestScore = -Float.greatestFiniteMagnitude
        for i in 0..<Self.candidateCount {
            let bpm = Self.minimumBPM + Double(i) * Self.step
            let period = Self.frameRate * 60.0 / bpm
            let direct = correlation(lag: period, count: n)
            let twoBeat = correlation(lag: period * 2.0, count: n)
            let subdivision = correlation(lag: period * 0.5, count: n)

            // 2拍周期を加点し、半周期を少し減点して half/double ambiguity を抑える。
            var score = direct + 0.45 * twoBeat - 0.15 * subdivision

            // 多い範囲は最大 +0.025 の弱い prior。明確な相関を覆さない。
            if bpm >= 110, bpm <= 140 {
                let centerDistance = abs(bpm - 125.0) / 15.0
                score += Float(0.025 * (1.0 - 0.45 * centerDistance))
            }
            if let lockedBPM {
                score += Float(0.04 * exp(-abs(bpm - lockedBPM) / 4.0))
            }
            if let tempoHint {
                let distance = (bpm - tempoHint) / 1.5
                score += Float(0.8 * exp(-0.5 * distance * distance))
            }
            if let loopDuration {
                let beats = loopDuration * bpm / 60.0
                let barDistance = abs(beats / 4.0 - (beats / 4.0).rounded()) * 4.0
                let beatDistance = abs(beats - beats.rounded())
                score += Float(0.18 * exp(-0.5 * pow(barDistance / 0.12, 2)))
                score += Float(0.03 * exp(-0.5 * pow(beatDistance / 0.10, 2)))
            }
            scores[i] = score
            if score > bestScore {
                bestScore = score
                bestIndex = i
            }
        }

        let rawBPM = Self.minimumBPM + Double(bestIndex) * Self.step
        var secondScore = -Float.greatestFiniteMagnitude
        for i in 0..<Self.candidateCount {
            let bpm = Self.minimumBPM + Double(i) * Self.step
            if abs(bpm - rawBPM) >= 2.0 {
                secondScore = max(secondScore, scores[i])
            }
        }
        let separation = max(bestScore - secondScore, 0)
        let confidence = min(max(separation * 3.0 + max(bestScore, 0) * 0.12, 0), 1)

        recentBPM[recentIndex] = rawBPM
        recentIndex = (recentIndex + 1) % recentBPM.count
        recentCount = min(recentCount + 1, recentBPM.count)
        for i in 0..<recentCount { recentScratch[i] = recentBPM[i] }
        if recentCount > 1 {
            for i in 1..<recentCount {
                let value = recentScratch[i]
                var j = i
                while j > 0, recentScratch[j - 1] > value {
                    recentScratch[j] = recentScratch[j - 1]
                    j -= 1
                }
                recentScratch[j] = value
            }
        }
        let smoothed = recentScratch[recentCount / 2]
        let spread = recentScratch[recentCount - 1] - recentScratch[0]
        let stable = recentCount >= 4 && spread <= 2.5 && confidence >= 0.08
        if stable { lockedBPM = smoothed }

        return Estimate(bpm: smoothed, confidence: confidence,
                        stable: stable, elapsed: elapsed)
    }

    /// Fractional-lag normalized autocorrelation (linear interpolation)。
    private func correlation(lag: Double, count: Int) -> Float {
        let first = Int(ceil(lag))
        guard first < count - 8 else { return 0 }
        var dot: Float = 0
        var e1: Float = 0
        var e2: Float = 0
        for i in first..<count {
            let delayed = Double(i) - lag
            let j = Int(delayed)
            let fraction = Float(delayed - Double(j))
            let b = centered[j] + (centered[min(j + 1, count - 1)] - centered[j]) * fraction
            let a = centered[i]
            dot += a * b
            e1 += a * a
            e2 += b * b
        }
        let denom = sqrtf(e1 * e2)
        return denom > 1e-9 ? dot / denom : 0
    }
}
