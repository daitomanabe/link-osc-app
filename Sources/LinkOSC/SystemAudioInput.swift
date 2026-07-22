import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// A selectable Core Audio input. The UID is persisted because AudioDeviceID is
/// only valid for the current boot/session.
struct AudioInputDevice: Identifiable, Equatable {
    let uid: String
    let name: String
    let deviceID: AudioDeviceID
    let channelCount: Int
    let isDefault: Bool

    var id: String { uid }
    var key: String { "device:\(uid)" }
    var displayName: String { isDefault ? "\(name) (Default)" : name }
}

/// A mono channel or a non-overlapping stereo pair. Indices are zero-based
/// internally and shown as one-based channel numbers in the UI.
struct AudioInputChannelSelection: Identifiable, Equatable {
    let key: String
    let label: String
    let leftIndex: Int
    let rightIndex: Int

    var id: String { key }

    static func options(channelCount: Int) -> [AudioInputChannelSelection] {
        guard channelCount > 0 else { return [] }
        var result: [AudioInputChannelSelection] = []
        if channelCount >= 2 {
            for left in stride(from: 0, to: channelCount - 1, by: 2) {
                result.append(AudioInputChannelSelection(
                    key: "stereo:\(left):\(left + 1)",
                    label: "Stereo \(left + 1)–\(left + 2)",
                    leftIndex: left,
                    rightIndex: left + 1))
            }
        }
        for channel in 0..<channelCount {
            result.append(AudioInputChannelSelection(
                key: "mono:\(channel)",
                label: "Mono \(channel + 1)",
                leftIndex: channel,
                rightIndex: channel))
        }
        return result
    }

}

enum SystemAudioInputError: LocalizedError {
    case audioUnitUnavailable
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .audioUnitUnavailable:
            return "The selected input device has no usable audio unit."
        case .invalidFormat(let detail):
            return "The selected input device has no usable audio channels (\(detail))."
        }
    }
}

/// Captures a macOS audio input into a fixed-size stereo ring buffer.
/// All start/stop operations are performed by AppModel's audio-control queue;
/// the tap callback only copies samples and never allocates.
final class SystemAudioInput {
    private let lock = NSLock()
    private let ringSize = 16_384
    private var ringL = [Float](repeating: 0, count: 16_384)
    private var ringR = [Float](repeating: 0, count: 16_384)
    private var writeIndex = 0
    private var framesReceived: UInt64 = 0
    private var sampleRateValue: Double = 0
    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    static func devices() -> [AudioInputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }

        var defaultID = AudioDeviceID(kAudioObjectUnknown)
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(
            system, &defaultAddress, 0, nil, &defaultSize, &defaultID)

        return ids.compactMap { id -> AudioInputDevice? in
            let channelCount = inputChannelCount(id)
            guard channelCount > 0,
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName) else {
                return nil
            }
            return AudioInputDevice(
                uid: uid, name: name, deviceID: id,
                channelCount: channelCount, isDefault: id == defaultID)
        }.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func start(deviceID: AudioDeviceID, channel: AudioInputChannelSelection) throws {
        stop()

        let nextEngine = AVAudioEngine()
        let input = nextEngine.inputNode
        guard input.audioUnit != nil else {
            throw SystemAudioInputError.audioUnitUnavailable
        }
        // AUAudioUnit's device API also refreshes AVAudioEngine's bus format.
        // Setting kAudioOutputUnitProperty_CurrentDevice directly can leave the
        // outputFormat cached at the previous device's channel count.
        try input.auAudioUnit.setDeviceID(deviceID)
        input.reset()

        // After switching devices, inputFormat reflects the hardware input
        // channel layout; outputFormat can remain cached at the old default.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              channel.leftIndex < Int(format.channelCount),
              channel.rightIndex < Int(format.channelCount),
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else {
            throw SystemAudioInputError.invalidFormat(
                "device=\(input.auAudioUnit.deviceID)/\(deviceID) rate=\(Int(format.sampleRate)) channels=\(format.channelCount) requested=\(channel.key)")
        }

        lock.lock()
        for index in 0..<ringSize {
            ringL[index] = 0
            ringR[index] = 0
        }
        writeIndex = 0
        framesReceived = 0
        sampleRateValue = format.sampleRate
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.push(buffer, leftIndex: channel.leftIndex, rightIndex: channel.rightIndex)
        }
        nextEngine.prepare()
        do {
            try nextEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        engine = nextEngine
        inputNode = input
    }

    func stop() {
        let oldEngine = engine
        let oldInput = inputNode
        engine = nil
        inputNode = nil
        oldInput?.removeTap(onBus: 0)
        oldEngine?.stop()
        lock.lock()
        for index in 0..<ringSize {
            ringL[index] = 0
            ringR[index] = 0
        }
        writeIndex = 0
        sampleRateValue = 0
        lock.unlock()
    }

    func latestStereo(_ count: Int, intoL: inout [Float], intoR: inout [Float]) {
        precondition(count <= ringSize && intoL.count == count && intoR.count == count)
        let mask = ringSize - 1
        lock.lock()
        var read = (writeIndex - count) & mask
        for index in 0..<count {
            intoL[index] = ringL[read]
            intoR[index] = ringR[read]
            read = (read + 1) & mask
        }
        lock.unlock()
    }

    func stats() -> (frames: UInt64, sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (framesReceived, sampleRateValue)
    }

    private func push(_ buffer: AVAudioPCMBuffer, leftIndex: Int, rightIndex: Int) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0,
              leftIndex < channelCount, rightIndex < channelCount else { return }
        let left = channels[leftIndex]
        let right = channels[rightIndex]
        let mask = ringSize - 1

        lock.lock()
        var write = writeIndex
        let start = max(0, frameCount - ringSize)
        for frame in start..<frameCount {
            ringL[write] = left[frame]
            ringR[write] = right[frame]
            write = (write + 1) & mask
        }
        writeIndex = write
        framesReceived &+= UInt64(frameCount - start)
        sampleRateValue = buffer.format.sampleRate
        lock.unlock()
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeUnretainedValue() as String?
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// `LinkOSC --inputtest`: enumerate inputs without opening a device or asking
/// for microphone permission.
enum InputDeviceTest {
    static func run() {
        let devices = SystemAudioInput.devices()
        let uniqueUIDs = Set(devices.map(\.uid)).count == devices.count
        let defaultCount = devices.filter(\.isDefault).count
        let maximumChannels = devices.map(\.channelCount).max() ?? 0
        let channelOptionsValid = devices.allSatisfy { device in
            let options = AudioInputChannelSelection.options(channelCount: device.channelCount)
            return !options.isEmpty && options.allSatisfy {
                $0.leftIndex >= 0 && $0.rightIndex >= 0
                    && $0.leftIndex < device.channelCount && $0.rightIndex < device.channelCount
            }
        }
        var valid = uniqueUIDs && defaultCount <= 1 && channelOptionsValid
            && devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty }
        print("[inputtest] devices=\(devices.count) defaults=\(defaultCount) maxChannels=\(maximumChannels) uniqueUIDs=\(uniqueUIDs) channelOptions=\(channelOptionsValid)")
        if CommandLine.arguments.contains("--capture") {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                print("[inputtest] capture SKIP: microphone access is not already authorized")
                print(valid ? "[inputtest] PASS" : "[inputtest] FAIL")
                if !valid { exit(1) }
                return
            }
            guard let defaultDevice = devices.first(where: \.isDefault) ?? devices.first else {
                print("[inputtest] capture FAIL: no input device")
                exit(1)
            }
            let input = SystemAudioInput()
            do {
                var captureDevices = [defaultDevice]
                if let multi = devices.first(where: { $0.channelCount == maximumChannels }),
                   multi.uid != defaultDevice.uid {
                    captureDevices.append(multi)
                }
                for device in captureDevices {
                    let options = AudioInputChannelSelection.options(channelCount: device.channelCount)
                    guard let first = options.first else {
                        print("[inputtest] capture FAIL: no channel selection")
                        exit(1)
                    }
                    var selections = [first]
                    if let last = options.last, last.key != first.key { selections.append(last) }
                    for channel in selections {
                        try input.start(deviceID: device.deviceID, channel: channel)
                        Thread.sleep(forTimeInterval: 0.4)
                        let stats = input.stats()
                        input.stop()
                        let captured = stats.frames > 0 && stats.sampleRate > 0
                        valid = valid && captured
                        print("[inputtest] capture channels=\(device.channelCount) \(channel.key) frames=\(stats.frames) rate=\(Int(stats.sampleRate)) \(captured ? "PASS" : "FAIL")")
                    }
                }
            } catch {
                valid = false
                print("[inputtest] capture FAIL: \(error.localizedDescription)")
            }
        }
        print(valid ? "[inputtest] PASS" : "[inputtest] FAIL")
        if !valid { exit(1) }
    }
}
