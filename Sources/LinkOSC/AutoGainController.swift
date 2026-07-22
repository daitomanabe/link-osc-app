import Foundation

enum InputGainMode: String, CaseIterable, Identifiable {
    case automatic = "Auto"
    case manual = "Manual"

    var id: String { rawValue }
}

enum VisualizationLevelMode: String, CaseIterable, Identifiable {
    case adjusted = "Adjusted"
    case raw = "Raw"

    var id: String { rawValue }
}

/// Block-based analysis gain. Four seconds of input are summarized, then one
/// gain value is held for the complete following block. The fixed histogram
/// avoids sorting samples or allocating memory in the 60 fps analysis loop.
struct AutoGainController {
    struct BlockAnalysis: Equatable {
        let minimumRMS: Float
        let maximumRMS: Float
        let medianRMS: Float
        let averageRMS: Float
        let maximumPeak: Float
        let activeFrameCount: Int
        let totalFrameCount: Int

        var activeRatio: Float {
            totalFrameCount > 0
                ? Float(activeFrameCount) / Float(totalFrameCount)
                : 0
        }
    }

    static let targetRMS: Float = 0.18
    /// Keep the measured block peak near full scale. A small overshoot is
    /// allowed before downstream analysis clamps public values to 0...1.
    static let targetPeak: Float = 0.95
    static let minimumGain: Float = 0.1
    static let maximumGain: Float = 64
    static let silenceRMS: Float = 0.0005
    static let peakCeiling: Float = 1.05
    static let framesPerSecond = 60
    static let analysisSeconds = 4
    static let blockFrameCount = framesPerSecond * analysisSeconds

    private static let minimumActiveFrames = 12
    private static let histogramBinCount = 64
    private static let histogramFloorDB: Float = -66
    private static let gainDeadbandDB: Float = 1.5

    private(set) var gain: Float = 1
    private(set) var completedBlockCount = 0
    private(set) var lastAnalysis: BlockAnalysis?

    private var frameCount = 0
    private var activeFrameCount = 0
    private var minimumRMS = Float.greatestFiniteMagnitude
    private var maximumRMS: Float = 0
    private var rmsSum: Float = 0
    private var maximumPeak: Float = 0
    private var histogram = [UInt16](repeating: 0, count: histogramBinCount)

    mutating func reset(to value: Float = 1) {
        gain = min(max(value, Self.minimumGain), Self.maximumGain)
        completedBlockCount = 0
        lastAnalysis = nil
        clearAccumulator()
    }

    /// Returns the currently held gain. A new value is chosen only after a
    /// complete analysis block, never in response to an individual frame.
    mutating func process(rms: Float, peak: Float) -> Float {
        let heldGain = gain
        let safeRMS = max(0, rms)
        let safePeak = max(0, peak)
        frameCount += 1

        if safeRMS >= Self.silenceRMS || safePeak >= Self.silenceRMS * 3 {
            let measuredRMS = max(safeRMS, Self.silenceRMS)
            activeFrameCount += 1
            minimumRMS = min(minimumRMS, measuredRMS)
            maximumRMS = max(maximumRMS, measuredRMS)
            rmsSum += measuredRMS
            maximumPeak = max(maximumPeak, safePeak)
            histogram[histogramIndex(for: measuredRMS)] += 1
        }

        guard frameCount >= Self.blockFrameCount else { return heldGain }
        finishBlock()
        // The boundary frame belongs to the block that was just analyzed, so
        // its old gain is returned. The newly computed value starts next frame.
        return heldGain
    }

    private mutating func finishBlock() {
        let analysis: BlockAnalysis
        if activeFrameCount > 0 {
            analysis = BlockAnalysis(
                minimumRMS: minimumRMS,
                maximumRMS: maximumRMS,
                medianRMS: histogramMedian(),
                averageRMS: rmsSum / Float(activeFrameCount),
                maximumPeak: maximumPeak,
                activeFrameCount: activeFrameCount,
                totalFrameCount: frameCount)
        } else {
            analysis = BlockAnalysis(
                minimumRMS: 0, maximumRMS: 0, medianRMS: 0, averageRMS: 0,
                maximumPeak: 0, activeFrameCount: 0, totalFrameCount: frameCount)
        }

        lastAnalysis = analysis
        completedBlockCount += 1
        apply(analysis)
        clearAccumulator()
    }

    private mutating func apply(_ analysis: BlockAnalysis) {
        // A few isolated noise frames are not enough evidence to amplify the
        // source. Return to unity only at a block boundary when input is silent.
        guard analysis.activeFrameCount >= Self.minimumActiveFrames else {
            gain = 1
            return
        }

        // Median supplies stability, average follows sustained level, max RMS
        // and min RMS retain the block's dynamic-range information. Peak is an
        // independent hard ceiling over every active frame in the block.
        let robustMinimum = min(analysis.maximumRMS,
                                max(analysis.minimumRMS, analysis.medianRMS * 0.25))
        let representative = analysis.medianRMS * 0.50
            + analysis.averageRMS * 0.30
            + analysis.maximumRMS * 0.15
            + robustMinimum * 0.05
        let levelGain = Self.targetRMS / max(representative, 1e-9)
        let targetPeakGain = analysis.maximumPeak > 1e-9
            ? Self.targetPeak / analysis.maximumPeak
            : Self.maximumGain
        let clippedPeakGain = analysis.maximumPeak > 1e-9
            ? Self.peakCeiling / analysis.maximumPeak
            : Self.maximumGain
        // Prefer a near-full-scale peak even when the RMS target alone would
        // turn an already loud source down too far. Statistics may ask for more
        // gain, but at most 5% measured-block clipping is allowed.
        let normalizedGain = min(max(levelGain, targetPeakGain), clippedPeakGain)
        let desired = min(max(normalizedGain, Self.minimumGain), Self.maximumGain)

        // Ignore small block-to-block changes; this removes visible fader
        // chatter and avoids modulating otherwise stable analysis values.
        let differenceDB = abs(20 * log10f(desired / max(gain, 1e-9)))
        if differenceDB >= Self.gainDeadbandDB {
            gain = desired
        }
    }

    private func histogramIndex(for rms: Float) -> Int {
        let db = 20 * log10f(max(rms, Self.silenceRMS))
        let normalized = (db - Self.histogramFloorDB) / -Self.histogramFloorDB
        return min(max(Int(normalized * Float(Self.histogramBinCount)), 0),
                   Self.histogramBinCount - 1)
    }

    private func histogramMedian() -> Float {
        let target = (activeFrameCount + 1) / 2
        var cumulative = 0
        for index in 0..<Self.histogramBinCount {
            cumulative += Int(histogram[index])
            if cumulative >= target {
                let binCenter = (Float(index) + 0.5) / Float(Self.histogramBinCount)
                let db = Self.histogramFloorDB
                    + binCenter * -Self.histogramFloorDB
                return powf(10, db / 20)
            }
        }
        return maximumRMS
    }

    private mutating func clearAccumulator() {
        frameCount = 0
        activeFrameCount = 0
        minimumRMS = Float.greatestFiniteMagnitude
        maximumRMS = 0
        rmsSum = 0
        maximumPeak = 0
        for index in histogram.indices { histogram[index] = 0 }
    }
}

/// `LinkOSC --autogaintest`: deterministic block hold, statistics, silence,
/// quiet-input normalization, deadband, and peak-ceiling tests.
enum AutoGainTest {
    static func run() {
        var controller = AutoGainController()
        let block = AutoGainController.blockFrameCount

        for _ in 0..<(block - 1) { _ = controller.process(rms: 0.008, peak: 0.02) }
        let initialHoldOK = abs(controller.gain - 1) < 0.0001
            && controller.completedBlockCount == 0
        let quietBoundaryGain = controller.process(rms: 0.008, peak: 0.02)
        let quietGain = controller.gain
        let quietStats = controller.lastAnalysis
        let quietPeak = quietGain * 0.02
        let quietOK = abs(quietBoundaryGain - 1) < 0.0001
            && quietPeak >= AutoGainController.targetPeak - 0.001
            && quietPeak <= AutoGainController.peakCeiling + 0.001
        let statsOK = quietStats?.activeFrameCount == block
            && abs((quietStats?.minimumRMS ?? 0) - 0.008) < 0.0001
            && abs((quietStats?.maximumRMS ?? 0) - 0.008) < 0.0001
            && abs((quietStats?.averageRMS ?? 0) - 0.008) < 0.0001
            && abs((quietStats?.medianRMS ?? 0) - 0.008) < 0.001

        let quietAppliedGain = controller.process(rms: 0.5, peak: 0.98)
        for _ in 0..<(block - 2) { _ = controller.process(rms: 0.5, peak: 0.98) }
        let loudHoldOK = abs(controller.gain - quietGain) < 0.0001
            && abs(quietAppliedGain - quietGain) < 0.0001
        let loudBoundaryGain = controller.process(rms: 0.5, peak: 0.98)
        let loudGain = controller.gain
        let loudPeak = loudGain * 0.98
        let peakOK = loudPeak >= AutoGainController.targetPeak - 0.001
            && loudPeak <= AutoGainController.peakCeiling + 0.001
            && abs(loudBoundaryGain - quietGain) < 0.0001

        let beforeDeadband = controller.gain
        for _ in 0..<block { _ = controller.process(rms: 0.52, peak: 0.90) }
        let deadbandOK = abs(controller.gain - beforeDeadband) < 0.0001

        for _ in 0..<block { _ = controller.process(rms: 0, peak: 0) }
        let silenceOK = abs(controller.gain - 1) < 0.0001
            && controller.lastAnalysis?.activeFrameCount == 0

        let passed = initialHoldOK && quietOK && statsOK && loudHoldOK
            && peakOK && deadbandOK && silenceOK
        print(String(format:
            "[autogaintest] initialHold=%@ quietGain=%.2f quietPeak=%.2f stats=%@ loudHold=%@ loudGain=%.2f loudPeak=%.2f deadband=%@ silence=%@ %@",
            initialHoldOK ? "PASS" : "FAIL", quietGain, quietPeak,
            statsOK ? "PASS" : "FAIL", loudHoldOK ? "PASS" : "FAIL", loudGain,
            loudPeak, deadbandOK ? "PASS" : "FAIL", silenceOK ? "PASS" : "FAIL",
            passed ? "PASS" : "FAIL"))
        if !passed { exit(1) }
    }
}
