// vjbake (github.com/daitomanabe/vjbake) と共有している解析ソース。
// アルゴリズム・校正を両ツールで一致させるため、変更時は両方に反映すること。
import Foundation
import Accelerate

/// 2048点 FFT (Hann窓) → 128バンド (隣接8bin平均, 0..Nyquist を線形カバー) + RMS
final class SpectrumAnalyzer {
    static let fftSize = 2048
    static let bands = 128

    private let n = SpectrumAnalyzer.fftSize
    private let log2n = vDSP_Length(11)
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var mags: [Float]

    init() {
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed")
        }
        fftSetup = setup
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        windowed = [Float](repeating: 0, count: n)
        realp = [Float](repeating: 0, count: n / 2)
        imagp = [Float](repeating: 0, count: n / 2)
        mags = [Float](repeating: 0, count: n / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    struct Frame {
        var bands: [Float]      // 128バンド (グループ内最大値, 0..1)
        var mags: [Float]       // 1024bin 振幅 (スケール済み)
        var rms: Float
    }

    /// input は fftSize サンプル。gain 適用済みの解析フレームを返す
    func analyzeFrame(_ input: [Float], gain: Float) -> Frame {
        let (bands, rms) = analyze(input, gain: gain)
        return Frame(bands: bands, mags: mags, rms: rms)
    }

    /// input は fftSize サンプル。戻り値: (128バンドスペクトラム, RMS) いずれも gain 適用・0..1 クランプ済み
    func analyze(_ input: [Float], gain: Float) -> (spectrum: [Float], rms: Float) {
        precondition(input.count == n)

        var rms: Float = 0
        vDSP_rmsqv(input, 1, &rms, vDSP_Length(n))

        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(n))

        let half = n / 2
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { buf in
                    buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        // フルスケール正弦波 ≈ 1.0 になる正規化:
        // zrip の係数2 × Hann コヒーレントゲイン 0.5 × N/2 → スケール = 2/N
        var scale = gain * 2.0 / Float(n)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(half))

        // 各バンドはグループ内の最大値 (平均だと単一トーンが 1/8 に希釈される)
        let group = half / SpectrumAnalyzer.bands // 8
        var out = [Float](repeating: 0, count: SpectrumAnalyzer.bands)
        for b in 0..<SpectrumAnalyzer.bands {
            var m: Float = 0
            for k in 0..<group {
                m = max(m, mags[b * group + k])
            }
            out[b] = min(m, 1.0)
        }
        return (out, min(rms * gain, 1.0))
    }
}
