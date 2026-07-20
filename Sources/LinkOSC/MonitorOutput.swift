import Foundation
import AVFoundation

/// Link Audio 受信音のモニター再生。
/// 受信スレッド (Link thread) から FIFO に積み、AVAudioSourceNode の
/// render callback が払い出してスピーカーへ流す。解析・OSC 送信とは独立。
///
/// 送信側クロックとローカル出力クロックの差は、FIFO あふれ時に古いサンプルを
/// 捨てる / アンダーラン時に再プライム (約50ms 溜まるまで無音) することで吸収する。
/// モニター用途なので数十 ms のジャンプは許容する設計。
final class MonitorOutput {
    private let lock = NSLock()
    private let capacity = 32768 // ~0.68s @48kHz
    private var bufL: [Float]
    private var bufR: [Float]
    private var readIdx = 0
    private var writeIdx = 0
    private var stored = 0
    private var primed = false
    private var rate: Double = 0

    private var engine: AVAudioEngine?
    private var volumeValue: Float = 0.8
    private let engineQueue = DispatchQueue(label: "linkosc.monitor")

    init() {
        bufL = [Float](repeating: 0, count: capacity)
        bufR = [Float](repeating: 0, count: capacity)
    }

    /// 実効音量 (mute 時は 0 を渡す)。いつでも呼べる。
    func setVolume(_ v: Float) {
        lock.lock()
        volumeValue = v
        let e = engine
        lock.unlock()
        e?.mainMixerNode.outputVolume = v
    }

    func stop() {
        lock.lock()
        let e = engine
        engine = nil
        stored = 0
        readIdx = 0
        writeIdx = 0
        primed = false
        rate = 0
        lock.unlock()
        e?.stop()
    }

    /// 受信サンプルを積む (Link thread から呼ばれる)。初回/レート変更時にエンジンを起動。
    func append(interleavedInt16 samples: UnsafePointer<Int16>, frames: Int,
                channels: Int, sampleRate: Double) {
        var needStart = false
        lock.lock()
        if rate != sampleRate, sampleRate > 0 {
            rate = sampleRate
            needStart = true
            stored = 0
            readIdx = 0
            writeIdx = 0
            primed = false
        }
        // 通常は数百〜数千frame。異常に大きいbufferでもFIFO容量を越えず、
        // 時系列上もっとも新しい部分だけを採用する。
        let n = min(max(0, frames), capacity)
        let sourceStart = max(0, frames - n)
        if stored + n > capacity {
            // あふれ: 古いサンプルを捨てて追いつく (クロック差の吸収)
            let drop = stored + n - capacity
            readIdx = (readIdx + drop) % capacity
            stored -= drop
        }
        for i in 0..<n {
            let sourceFrame = sourceStart + i
            let l = Float(samples[sourceFrame * channels]) / 32768.0
            let r = channels > 1
                ? Float(samples[sourceFrame * channels + 1]) / 32768.0 : l
            bufL[writeIdx] = l
            bufR[writeIdx] = r
            writeIdx = (writeIdx + 1) % capacity
        }
        stored += n
        lock.unlock()

        if needStart {
            engineQueue.async { [self] in restart(sampleRate) }
        }
    }

    private func restart(_ sr: Double) {
        lock.lock()
        let old = engine
        engine = nil
        lock.unlock()
        old?.stop()

        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else {
            return
        }
        let e = AVAudioEngine()
        let node = AVAudioSourceNode(format: fmt) { [weak self] _, _, frameCount, ablPtr in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            guard abl.count >= 2,
                  let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let frames = Int(frameCount)
            lock.lock()
            if !primed {
                primed = stored >= 2400 // ~50ms 溜まってから再生開始
            }
            var produced = 0
            if primed {
                produced = min(stored, frames)
                for i in 0..<produced {
                    outL[i] = bufL[readIdx]
                    outR[i] = bufR[readIdx]
                    readIdx = (readIdx + 1) % capacity
                }
                stored -= produced
                if stored == 0 { primed = false } // アンダーラン → 再プライム
            }
            lock.unlock()
            if produced < frames {
                for i in produced..<frames {
                    outL[i] = 0
                    outR[i] = 0
                }
            }
            return noErr
        }
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: fmt)
        lock.lock()
        let v = volumeValue
        lock.unlock()
        e.mainMixerNode.outputVolume = v
        e.prepare()
        do {
            try e.start()
        } catch {
            return
        }
        lock.lock()
        engine = e
        lock.unlock()
    }
}
