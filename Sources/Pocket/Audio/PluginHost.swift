import AppKit
import AudioToolbox
import Foundation

/// Hosts one Audio Unit effect inside the source node's render callback.
///
/// The Audio Unit format is what macOS plays natively, and nearly every commercial plugin
/// (Serum, Vital, FabFilter, Valhalla, FL's own effects) ships an AU build alongside VST3.
/// Rendering: copy the track block into this slot's input buffers, call `AudioUnitRender`,
/// copy the result back. No locks and no allocation on the audio thread.
///
/// Slots are never disposed while the app runs, so a pointer published into `Shared` can
/// never dangle under the render thread.
final class PluginSlot: @unchecked Sendable {
    private var cachedEditor: NSViewController?
    static let maxFrames = 8192

    let name: String
    let type: OSType
    let subtype: OSType
    let manufacturer: OSType

    private var unit: AudioUnit?
    private let inL: UnsafeMutablePointer<Float>
    private let inR: UnsafeMutablePointer<Float>
    private let outL: UnsafeMutablePointer<Float>
    private let outR: UnsafeMutablePointer<Float>
    private let outABL: UnsafeMutablePointer<AudioBufferList>
    private var time: Double = 0
    private var ready = false

    var isReady: Bool { ready }

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

        let capacity = PluginSlot.maxFrames
        inL = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        inR = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        outL = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        outR = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        inL.initialize(repeating: 0, count: capacity)
        inR.initialize(repeating: 0, count: capacity)
        outL.initialize(repeating: 0, count: capacity)
        outR.initialize(repeating: 0, count: capacity)
        outABL = AudioBufferList.allocate(maximumBuffers: 2).unsafeMutablePointer
        outABL.pointee.mNumberBuffers = 2

        var instance: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &instance) == noErr,
              let inst = instance else { return nil }
        unit = inst

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitSetProperty(inst, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0, &format, formatSize)
        AudioUnitSetProperty(inst, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 0, &format, formatSize)

        var maxSlice = UInt32(PluginSlot.maxFrames)
        AudioUnitSetProperty(inst, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &maxSlice,
                             UInt32(MemoryLayout<UInt32>.size))

        var callback = AURenderCallbackStruct(
            inputProc: { inRefCon, _, _, _, inNumberFrames, ioData in
                let slot = Unmanaged<PluginSlot>.fromOpaque(inRefCon).takeUnretainedValue()
                return slot.fillInput(ioData, frames: Int(inNumberFrames))
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())

        let callbackStatus = AudioUnitSetProperty(
            inst, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        guard callbackStatus == noErr, AudioUnitInitialize(inst) == noErr else {
            AudioComponentInstanceDispose(inst)
            unit = nil
            return nil
        }
        ready = true
    }

    // MARK: - Render thread

    /// Called from the render callback. Never allocate here.
    fileprivate func fillInput(_ ioData: UnsafeMutablePointer<AudioBufferList>?, frames: Int) -> OSStatus {
        guard let ioData else { return noErr }
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        let n = min(max(frames, 0), PluginSlot.maxFrames)
        if list.count > 0 {
            list[0].mNumberChannels = 1
            list[0].mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
            list[0].mData = UnsafeMutableRawPointer(inL)
        }
        if list.count > 1 {
            list[1].mNumberChannels = 1
            list[1].mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
            list[1].mData = UnsafeMutableRawPointer(inR)
        }
        return noErr
    }

    /// Processes one block of a track in place.
    func process(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        guard ready, let unit, frames > 0 else { return }
        let n = min(frames, PluginSlot.maxFrames)
        let bytes = n * MemoryLayout<Float>.size
        memcpy(inL, left, bytes)
        memcpy(inR, right, bytes)

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
        timestamp.mFlags = .sampleTimeValid
        time += Double(n)

        let status = AudioUnitRender(unit, &flags, &timestamp, 0, UInt32(n), outABL)
        if status == noErr {
            memcpy(left, outL, bytes)
            memcpy(right, outR, bytes)
        }
    }

    // MARK: - Parameters (main thread)

    struct Parameter {
        var id: UInt32
        var name: String
        var minimum: Double
        var maximum: Double
        var value: Double
    }

    func parameters(limit: Int = 8) -> [Parameter] {
        guard ready, let unit else { return [] }
        var listSize: UInt32 = 0
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_ParameterList,
                                       kAudioUnitScope_Global, 0, &listSize, nil) == noErr,
              listSize > 0 else { return [] }

        let count = Int(listSize) / MemoryLayout<AudioUnitParameterID>.size
        var ids = [AudioUnitParameterID](repeating: 0, count: count)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterList,
                                   kAudioUnitScope_Global, 0, &ids, &listSize) == noErr else { return [] }

        var result: [Parameter] = []
        for id in ids {
            var info = AudioUnitParameterInfo()
            var size = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
            guard AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterInfo,
                                       kAudioUnitScope_Global, id, &info, &size) == noErr else { continue }
            // kAudioUnitParameterFlag_IsWritable == 1 << 0, spelled out because the
            // constant is not imported into Swift from the anonymous C enum.
            guard (info.flags.rawValue & UInt32(1 << 0)) != 0 else { continue }

            var value: AudioUnitParameterValue = 0
            AudioUnitGetParameter(unit, id, kAudioUnitScope_Global, 0, &value)

            let name: String = withUnsafeBytes(of: &info.name) { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "Param" }
                return String(cString: base)
            }
            result.append(Parameter(id: id, name: name.isEmpty ? "Param" : name,
                                    minimum: Double(info.minValue), maximum: Double(info.maxValue),
                                    value: Double(value)))
            if result.count >= limit { break }
        }
        return result
    }

    func setParameter(_ id: UInt32, value: Double) {
        guard ready, let unit else { return }
        AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, Float(value), 0)
    }

    /// Full AU state (ClassInfo) as a portable plist. This is what makes a saved project
    /// reopen with the actual patch instead of the plugin's factory defaults.
    func fullState() -> Data? {
        guard ready, let unit else { return nil }
        var classInfo: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_ClassInfo,
                                   kAudioUnitScope_Global, 0, &classInfo, &size) == noErr,
              let value = classInfo?.takeRetainedValue() else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: value,
                                                    format: .binary, options: 0)
    }

    @discardableResult
    func restoreState(_ state: Data) -> Bool {
        guard ready, let unit,
              let plist = try? PropertyListSerialization.propertyList(
                from: state, options: [], format: nil) else { return false }
        var value = plist as CFPropertyList
        let status = AudioUnitSetProperty(unit, kAudioUnitProperty_ClassInfo,
                                          kAudioUnitScope_Global, 0, &value,
                                          UInt32(MemoryLayout<CFPropertyList>.size))
        return status == noErr
    }

    /// Reported processing latency in frames. The renderer uses this for automatic delay
    /// compensation so a look-ahead limiter or linear-phase EQ does not push one track late.
    func latencyFrames(at sampleRate: Double) -> Int {
        guard ready, let unit else { return 0 }
        var seconds: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_Latency,
                                          kAudioUnitScope_Global, 0, &seconds, &size)
        guard status == noErr, seconds > 0, sampleRate > 0 else { return 0 }
        return min(Int((seconds * sampleRate).rounded()), 262_144)
    }

    // MARK: - Editor (main thread)

    /// The AU's own Cocoa view, for effects and AUv2 instruments that publish
    /// `kAudioUnitProperty_CocoaUI`. Shared by effect inserts and instrument hosts.
    ///
    /// `uiViewForAudioUnit:withSize:` is an Objective-C method reached through its IMP, so Swift
    /// does not apply ARC's return-value conventions. It returns an autoreleased view: treating
    /// it as +1 (`takeRetainedValue`) over-released Apple's editors and crashed on close.
    static func makeCocoaEditor(for unit: AudioUnit,
                                preferredSize: NSSize = NSSize(width: 760, height: 520))
        -> NSViewController? {
        var size: UInt32 = 0
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_CocoaUI,
                                       kAudioUnitScope_Global, 0, &size, nil) == noErr,
              size >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size) else { return nil }

        let info = UnsafeMutablePointer<AudioUnitCocoaViewInfo>.allocate(capacity: 1)
        defer { info.deallocate() }
        var dataSize = size
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI,
                                   kAudioUnitScope_Global, 0, info, &dataSize) == noErr else {
            return nil
        }

        let location = info.pointee.mCocoaAUViewBundleLocation.takeUnretainedValue() as URL
        let className = info.pointee.mCocoaAUViewClass.takeUnretainedValue() as String
        let bundle = Bundle(url: location)
        guard let cls = (NSClassFromString(className) ?? bundle?.classNamed(className)) as? NSObject.Type else {
            return nil
        }
        let factory = cls.init()
        // `AUCocoaUIBase` is not visible to Swift in this SDK, so call the factory method
        // through its Objective-C implementation.
        let selector = NSSelectorFromString("uiViewForAudioUnit:withSize:")
        guard factory.responds(to: selector) else { return nil }
        typealias ViewFactory = @convention(c) (AnyObject, Selector, AudioUnit, NSSize) -> Unmanaged<NSView>?
        let makeView = unsafeBitCast(factory.method(for: selector), to: ViewFactory.self)
        guard let view = makeView(factory, selector, unit, preferredSize)?.takeUnretainedValue() else {
            return nil
        }
        let controller = AUEditorViewController()
        controller.factory = factory      // keep the factory that owns the view alive
        controller.view = view            // retains the autoreleased view
        if view.frame.width > 80 && view.frame.height > 80 {
            controller.preferredContentSize = view.frame.size
        } else {
            controller.preferredContentSize = preferredSize
        }
        return controller
    }

    func makeEditorViewController() -> NSViewController? {
        if let cachedEditor { return cachedEditor }
        guard ready, let unit else { return nil }
        cachedEditor = PluginSlot.makeCocoaEditor(for: unit)
        return cachedEditor
    }

    // MARK: - Discovery

    struct Descriptor {
        var name: String
        var component: AudioComponent
        var type: OSType
        var subtype: OSType
        var manufacturer: OSType
    }

    static func availableEffects() -> [Descriptor] {
        available(type: kAudioUnitType_Effect)
    }

    /// Generators: Serum, Kontakt, AUv3 synths, Apple's DLS synth, anything registered as aumu.
    static func availableInstruments() -> [Descriptor] {
        available(type: kAudioUnitType_MusicDevice)
    }

    static func available(type: OSType) -> [Descriptor] {
        var result: [Descriptor] = []
        var desc = AudioComponentDescription(componentType: type,
                                             componentSubType: 0,
                                             componentManufacturer: 0,
                                             componentFlags: 0,
                                             componentFlagsMask: 0)
        var component = AudioComponentFindNext(nil, &desc)
        while let current = component {
            var found = AudioComponentDescription()
            if AudioComponentGetDescription(current, &found) == noErr {
                var cfName: Unmanaged<CFString>?
                var name = "Audio Unit"
                if AudioComponentCopyName(current, &cfName) == noErr,
                   let cf = cfName?.takeRetainedValue() {
                    name = cf as String
                }
                result.append(Descriptor(name: name, component: current,
                                         type: found.componentType,
                                         subtype: found.componentSubType,
                                         manufacturer: found.componentManufacturer))
            }
            component = AudioComponentFindNext(current, &desc)
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func component(type: OSType, subtype: OSType, manufacturer: OSType) -> AudioComponent? {
        var desc = AudioComponentDescription(componentType: type,
                                             componentSubType: subtype,
                                             componentManufacturer: manufacturer,
                                             componentFlags: 0,
                                             componentFlagsMask: 0)
        return AudioComponentFindNext(nil, &desc)
    }
}


/// Retains the CocoaUI factory object for as long as its view lives; some AU views keep a back
/// pointer to the factory that created them.
private final class AUEditorViewController: NSViewController {
    var factory: AnyObject?
}
