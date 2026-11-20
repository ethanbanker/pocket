import AppKit
import AudioToolbox
import AVFoundation
import CoreAudioKit

/// Hosts an Audio Unit instrument (AUv2 or AUv3).
///
/// AUv2 generators (Serum 2, Kontakt, DLS, most commercial synths) use the classic
/// `AudioComponentInstance` + `MusicDeviceMIDIEvent` + `AudioUnitRender` path. That is the path
/// Apple's own AVAudioEngine uses, and it is the one those plugins were tested against; driving
/// the same units through `AUAudioUnit.renderBlock` made Serum render silence.
///
/// AUv3-only generators fall back to `AUAudioUnit`, still rendered inside our callback so the
/// editor edits the exact instance that is sounding.
///
/// Realtime rules: render never allocates or locks; MIDI and audio use preallocated buffers.
final class InstrumentSlot: @unchecked Sendable {
    static let maxFrames = 512

    let name: String
    let type: OSType
    let subtype: OSType
    let manufacturer: OSType

    private enum Backend {
        case v2(AudioComponentInstance)
        case v3(AUAudioUnit)
    }

    private struct ScheduledEvent {
        var status: UInt8 = 0
        var note: UInt8 = 0
        var value: UInt8 = 0
        var offset: Int32 = 0
    }

    private static let maxScheduledEvents = 512
    private var backend: Backend?
    private let outL: UnsafeMutablePointer<Float>
    private let outR: UnsafeMutablePointer<Float>
    private let outABL: UnsafeMutablePointer<AudioBufferList>
    private let midiBytes: UnsafeMutablePointer<UInt8>
    private let scheduled: UnsafeMutableBufferPointer<ScheduledEvent>
    private var scheduledCount = 0
    private var time: Double = 0
    private(set) var ready = false
    private var cachedEditor: NSViewController?

    var isReady: Bool { ready }
    var canScheduleMIDI: Bool {
        switch backend {
        case .v2: return true
        case .v3(let unit): return unit.scheduleMIDIEventBlock != nil
        case nil: return false
        }
    }

    init?(component: AudioComponent, sampleRate: Double) {
        var desc = AudioComponentDescription()
        AudioComponentGetDescription(component, &desc)
        type = desc.componentType
        subtype = desc.componentSubType
        manufacturer = desc.componentManufacturer

        var cfName: Unmanaged<CFString>?
        if AudioComponentCopyName(component, &cfName) == noErr, let cf = cfName?.takeRetainedValue() {
            name = cf as String
        } else {
            name = "Audio Unit"
        }

        let capacity = InstrumentSlot.maxFrames
        outL = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        outR = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        outL.initialize(repeating: 0, count: capacity)
        outR.initialize(repeating: 0, count: capacity)
        outABL = AudioBufferList.allocate(maximumBuffers: 2).unsafeMutablePointer
        outABL.pointee.mNumberBuffers = 2
        midiBytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 3)
        midiBytes.initialize(repeating: 0, count: 3)
        scheduled = Shared.alloc(InstrumentSlot.maxScheduledEvents, ScheduledEvent())

        // kAudioComponentFlag_IsV3AudioUnit (AudioComponent.h).
        let isV3 = (desc.componentFlags & 4) != 0
        if !isV3, let unit = InstrumentSlot.makeV2(component: component, sampleRate: sampleRate) {
            backend = .v2(unit)
            ready = true
            return
        }

        guard let audioUnit = try? AUAudioUnit(componentDescription: desc) else { return nil }
        audioUnit.maximumFramesToRender = AUAudioFrameCount(InstrumentSlot.maxFrames)
        if let format = AVAudioFormat(standardFormatWithSampleRate: max(sampleRate, 8_000), channels: 2) {
            let bus = audioUnit.outputBusses[0]
            // Some generators publish their main output disabled; leave it off and they render
            // pure silence.
            bus.isEnabled = true
            try? bus.setFormat(format)
        }
        do {
            try audioUnit.allocateRenderResources()
        } catch {
            return nil
        }
        backend = .v3(audioUnit)
        ready = true
    }

    private static func makeV2(component: AudioComponent,
                               sampleRate: Double) -> AudioComponentInstance? {
        var instance: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let instance else {
            return nil
        }
        var format = AudioStreamBasicDescription(
            mSampleRate: max(sampleRate, 8_000),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let formatStatus = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat,
                                                kAudioUnitScope_Output, 0, &format,
                                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var slice = UInt32(InstrumentSlot.maxFrames)
        AudioUnitSetProperty(instance, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &slice, 4)
        guard formatStatus == noErr, AudioUnitInitialize(instance) == noErr else {
            AudioComponentInstanceDispose(instance)
            return nil
        }
        return instance
    }

    deinit {
        switch backend {
        case .v2(let instance):
            AudioUnitUninitialize(instance)
            AudioComponentInstanceDispose(instance)
        case .v3(let unit):
            if ready { unit.deallocateRenderResources() }
        case nil:
            break
        }
        outL.deallocate()
        outR.deallocate()
        midiBytes.deallocate()
        scheduled.deallocate()
        free(outABL)
    }

    // MARK: - Render thread

    /// Renders in 512-frame quanta: every supported plugin is guaranteed to handle that block,
    /// whatever buffer size the audio device hands us.
    @discardableResult
    func render(frames: Int, left: UnsafeMutablePointer<Float>,
                right: UnsafeMutablePointer<Float>) -> Float {
        guard ready, frames > 0 else { return 0 }
        var done = 0
        var peak: Float = 0
        while done < frames {
            let n = min(frames - done, InstrumentSlot.maxFrames)
            let end = done + n
            // Timeline events were queued during the renderer's per-sample loop. Deliver each
            // one at its exact offset inside the 512-frame AU slice instead of snapping every
            // note to the start of the host block.
            while scheduledCount > 0 {
                let event = scheduled[0]
                if Int(event.offset) >= end { break }
                emit(status: event.status, note: Int(event.note), value: Int(event.value),
                     sampleOffset: max(0, Int(event.offset) - done))
                for i in 1..<scheduledCount { scheduled[i - 1] = scheduled[i] }
                scheduledCount -= 1
            }
            peak = max(peak, renderChunk(n, left: left.advanced(by: done),
                                        right: right.advanced(by: done)))
            done += n
        }
        return peak
    }

    private func renderChunk(_ n: Int, left: UnsafeMutablePointer<Float>,
                             right: UnsafeMutablePointer<Float>) -> Float {
        guard ready, n > 0 else { return 0 }
        let bytes = n * MemoryLayout<Float>.size
        memset(outL, 0, bytes)
        memset(outR, 0, bytes)

        let list = UnsafeMutableAudioBufferListPointer(outABL)
        list[0].mNumberChannels = 1
        list[0].mDataByteSize = UInt32(bytes)
        list[0].mData = UnsafeMutableRawPointer(outL)
        if list.count > 1 {
            list[1].mNumberChannels = 1
            list[1].mDataByteSize = UInt32(bytes)
            list[1].mData = UnsafeMutableRawPointer(outR)
        }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = time
        timestamp.mHostTime = mach_absolute_time()
        timestamp.mFlags = [.sampleTimeValid, .hostTimeValid]
        time += Double(n)

        let status: OSStatus
        switch backend {
        case .v2(let instance):
            status = AudioUnitRender(instance, &flags, &timestamp, 0,
                                     UInt32(n), outABL)
        case .v3(let unit):
            status = unit.renderBlock(&flags, &timestamp, AUAudioFrameCount(n), 0,
                                      outABL, nil)
        case nil:
            return 0
        }
        guard status == noErr else { return 0 }

        var peak: Float = 0
        for i in 0..<n {
            left[i] += outL[i]
            right[i] += outR[i]
            peak = max(peak, max(abs(outL[i]), abs(outR[i])))
        }
        return peak
    }

    // MARK: - MIDI (called from the render thread)

    func noteOn(_ note: Int, velocity: Int, channel: Int = 0) {
        emit(status: 0x90 | UInt8(min(max(channel, 0), 15)), note: note,
             value: min(max(velocity, 1), 127))
    }

    func noteOff(_ note: Int, channel: Int = 0) {
        emit(status: 0x80 | UInt8(min(max(channel, 0), 15)), note: note, value: 0)
    }

    /// Per-note bend is forwarded to the AU on the note's own channel, which is how MPE
    /// instruments expect to receive it.
    func pitchBend(channel: Int, value: Int) {
        let clamped = min(max(value, 0), 16_383)
        emit(status: 0xE0 | UInt8(min(max(channel, 0), 15)), note: clamped & 0x7F,
             value: (clamped >> 7) & 0x7F)
    }

    /// Sequenced note-on. Queued events are drained with sample offsets inside `render`.
    func scheduleNoteOn(_ note: Int, velocity: Int, channel: Int = 0, sampleOffset: Int) {
        enqueue(status: 0x90 | UInt8(min(max(channel, 0), 15)), note: note,
                value: min(max(velocity, 1), 127), offset: sampleOffset)
    }

    func scheduleNoteOff(_ note: Int, channel: Int = 0, sampleOffset: Int) {
        enqueue(status: 0x80 | UInt8(min(max(channel, 0), 15)), note: note,
                value: 0, offset: sampleOffset)
    }

    /// 14-bit pitch bend. Sent on the note's own channel, so MPE bends one note at a time.
    func schedulePitchBend(channel: Int, value: Int, sampleOffset: Int = 0) {
        let clamped = min(max(value, 0), 16_383)
        enqueue(status: 0xE0 | UInt8(min(max(channel, 0), 15)), note: clamped & 0x7F,
                value: (clamped >> 7) & 0x7F, offset: sampleOffset)
    }

    func allNotesOff() {
        scheduledCount = 0
        emit(status: 0xB0, note: 123, value: 0)
        emit(status: 0xB0, note: 120, value: 0)
    }

    /// Full AU state for project recall. AUv3 exposes `fullState`; AUv2 uses ClassInfo.
    func fullState() -> Data? {
        guard ready else { return nil }
        switch backend {
        case .v2(let instance):
            var classInfo: Unmanaged<CFPropertyList>?
            var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
            guard AudioUnitGetProperty(instance, kAudioUnitProperty_ClassInfo,
                                       kAudioUnitScope_Global, 0, &classInfo, &size) == noErr,
                  let value = classInfo?.takeRetainedValue() else { return nil }
            return try? PropertyListSerialization.data(fromPropertyList: value,
                                                        format: .binary, options: 0)
        case .v3(let unit):
            guard let state = unit.fullState else { return nil }
            return try? PropertyListSerialization.data(fromPropertyList: state,
                                                        format: .binary, options: 0)
        case nil:
            return nil
        }
    }

    @discardableResult
    func restoreState(_ data: Data) -> Bool {
        guard ready,
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) else { return false }
        switch backend {
        case .v2(let instance):
            var value = plist as CFPropertyList
            return AudioUnitSetProperty(instance, kAudioUnitProperty_ClassInfo,
                                        kAudioUnitScope_Global, 0, &value,
                                        UInt32(MemoryLayout<CFPropertyList>.size)) == noErr
        case .v3(let unit):
            guard let dictionary = plist as? [String: Any] else { return false }
            unit.fullState = dictionary
            return true
        case nil:
            return false
        }
    }

    func latencyFrames(at sampleRate: Double) -> Int {
        guard ready, sampleRate > 0 else { return 0 }
        var seconds: Float64 = 0
        switch backend {
        case .v2(let instance):
            var size = UInt32(MemoryLayout<Float64>.size)
            guard AudioUnitGetProperty(instance, kAudioUnitProperty_Latency,
                                       kAudioUnitScope_Global, 0, &seconds, &size) == noErr else {
                return 0
            }
        case .v3(let unit):
            seconds = unit.latency
        case nil:
            return 0
        }
        return min(Int((max(seconds, 0) * sampleRate).rounded()), 262_144)
    }

    @inline(__always)
    private func enqueue(status: UInt8, note: Int, value: Int, offset: Int) {
        guard ready else { return }
        if scheduledCount >= scheduled.count {
            // Never allocate on the audio thread. Dropping the oldest is better than a stall;
            // 512 queued events is far beyond any real block.
            emit(status: status, note: note, value: value, sampleOffset: 0)
            return
        }
        scheduled[scheduledCount] = ScheduledEvent(status: status,
                                                   note: UInt8(min(max(note, 0), 127)),
                                                   value: UInt8(min(max(value, 0), 127)),
                                                   offset: Int32(max(0, min(offset, 8_192))))
        scheduledCount += 1
    }

    @inline(__always)
    private func emit(status: UInt8, note: Int, value: Int, sampleOffset: Int = 0) {
        guard ready else { return }
        let pitch = UInt32(min(max(note, 0), 127))
        let amount = UInt32(min(max(value, 0), 127))
        let offset = UInt32(max(0, min(sampleOffset, 8_192)))
        switch backend {
        case .v2(let instance):
            MusicDeviceMIDIEvent(instance, UInt32(status), pitch, amount, offset)
        case .v3(let unit):
            guard let midi = unit.scheduleMIDIEventBlock else { return }
            midiBytes[0] = status
            midiBytes[1] = UInt8(pitch)
            midiBytes[2] = UInt8(amount)
            midi(AUEventSampleTime(offset), 0, 3, midiBytes)
        case nil:
            break
        }
    }

    // MARK: - Editor (main thread)

    /// The plugin's own editor. AUv2 generators publish a Cocoa view for the instance the
    /// renderer is using; AUv3 generators hand back a view controller.
    func requestEditor(_ completion: @escaping (NSViewController?) -> Void) {
        // Apple's AUs (and some third-party ones) only hand out their editor once; keep it for
        // the lifetime of this instance so closing and reopening the window works.
        if let cachedEditor {
            completion(cachedEditor)
            return
        }
        switch backend {
        case .v2(let instance):
            if let controller = PluginSlot.makeCocoaEditor(for: instance) {
                cachedEditor = controller
                completion(controller)
            } else {
                completion(nil)
            }
        case .v3(let unit):
            unit.requestViewController(completionHandler: { controller in
                if let controller { self.cachedEditor = controller }
                completion(controller)
            })
        case nil:
            completion(nil)
        }
    }
}
