import AudioToolbox
import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let sampleRate: Double
    let channels: Int
    let isDefault: Bool
}

/// CoreAudio HAL layer used by the direct AUHAL output engine. Besides enumeration, it owns
/// device buffer-size and latency queries so the transport can report real I/O timing.
enum AudioDevices {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputID() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func defaultInputID() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = Self.address(selector)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    static func inputID(uid: String) -> AudioDeviceID? {
        inputs().first { $0.uid == uid }?.id
    }

    static func inputs() -> [AudioDeviceInfo] {
        let defaultID = defaultInputID()
        return devices(channels: inputChannels, defaultID: defaultID)
    }

    static func outputs() -> [AudioDeviceInfo] {
        devices(channels: outputChannels, defaultID: defaultOutputID())
    }

    private static func devices(channels: (AudioDeviceID) -> Int,
                                defaultID: AudioDeviceID?) -> [AudioDeviceInfo] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        let status = ids.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                              &address, 0, nil, &size, base)
        }
        guard status == noErr else { return [] }

        return ids.compactMap { id in
            let channels = channels(id)
            guard channels > 0 else { return nil }
            let name = stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
                ?? "Audio Device \(id)"
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "\(id)"
            return AudioDeviceInfo(id: id, uid: uid, name: name,
                                   sampleRate: sampleRate(id), channels: channels,
                                   isDefault: id == defaultID)
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func outputChannels(_ id: AudioDeviceID) -> Int {
        channels(id, scope: kAudioDevicePropertyScopeOutput)
    }

    static func inputChannels(_ id: AudioDeviceID) -> Int {
        channels(id, scope: kAudioDevicePropertyScopeInput)
    }

    private static func channels(_ id: AudioDeviceID,
                                 scope: AudioObjectPropertyScope) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func sampleRate(_ id: AudioDeviceID) -> Double {
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else {
            return 0
        }
        return rate
    }

    static func bufferFrameSize(_ id: AudioDeviceID) -> Int {
        var address = Self.address(kAudioDevicePropertyBufferFrameSize)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &frames) == noErr else {
            return 0
        }
        return Int(frames)
    }

    static func bufferFrameSizeRange(_ id: AudioDeviceID) -> ClosedRange<Int>? {
        var address = Self.address(kAudioDevicePropertyBufferFrameSizeRange)
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &range) == noErr,
              range.mMinimum > 0, range.mMaximum >= range.mMinimum else { return nil }
        return Int(range.mMinimum)...Int(range.mMaximum)
    }

    static func setBufferFrameSize(_ id: AudioDeviceID, frames: Int) -> OSStatus {
        guard let range = bufferFrameSizeRange(id) else { return kAudioHardwareIllegalOperationError }
        var value = UInt32(min(max(frames, range.lowerBound), range.upperBound))
        var address = Self.address(kAudioDevicePropertyBufferFrameSize)
        return AudioObjectSetPropertyData(id, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func latencyFrames(_ id: AudioDeviceID) -> Int {
        latencyFrames(id, scope: kAudioDevicePropertyScopeOutput)
    }

    static func inputLatencyFrames(_ id: AudioDeviceID) -> Int {
        latencyFrames(id, scope: kAudioDevicePropertyScopeInput)
    }

    private static func latencyFrames(_ id: AudioDeviceID,
                                      scope: AudioObjectPropertyScope) -> Int {
        var address = Self.address(kAudioDevicePropertyLatency, scope: scope)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &frames) == noErr else {
            return 0
        }
        return Int(frames)
    }

    static func safetyOffset(_ id: AudioDeviceID) -> Int {
        var address = Self.address(kAudioDevicePropertySafetyOffset,
                                   scope: kAudioDevicePropertyScopeOutput)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &frames) == noErr else {
            return 0
        }
        return Int(frames)
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        let text = value as String
        return text.isEmpty ? nil : text
    }
}
