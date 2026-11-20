import AudioToolbox
import CoreAudio
import Foundation

/// Direct CoreAudio output. This is an AUHAL (`kAudioUnitSubType_HALOutput`) output unit, not
/// AVAudioEngine. The renderer runs at the hardware device's nominal rate, so there is no hidden
/// sample-rate converter between the mix and the device. HAL gives us the real buffer size,
/// latency and device-switch signals, and the render callback is the only audio producer.
///
/// If a device change selects a different nominal rate, the output unit is stopped, the renderer
/// is rebuilt at the new rate, and `onSampleRateChange` asks the model to reload the sample pool
/// and AU hosts before the unit starts again. Nothing in the realtime callback allocates.
final class AudioCore: @unchecked Sendable {
    /// Fallback only. The live graph uses `sampleRate`, which follows the active output device.
    static let renderSampleRate = 48_000.0
    static let engineName = "AUHAL"

    let midi: MIDIInput

    private let shared: Shared
    private var renderer: Renderer
    private var unit: AudioComponentInstance?
    private var unitInitialized = false
    private var deviceID: AudioDeviceID?
    private var followingDefault = true
    private var suspendedForBounce = false
    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var sampleRate: Double

    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var currentDeviceListeners: [DeviceListener] = []

    private struct DeviceListener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    /// Called on the main thread after the graph restarts or the output changes.
    var onStateChange: (() -> Void)?
    /// Called while the output unit is stopped when the hardware rate changes. The model reloads
    /// sample buffers and AU instances at this new rate before audio starts again.
    var onSampleRateChange: ((Double) -> Void)?
    var onEngineFailure: ((String) -> Void)?

    init(shared: Shared) {
        self.shared = shared
        let target = AudioDevices.defaultOutputID()
        let initialRate = target.flatMap { AudioDevices.sampleRate($0) } ?? AudioCore.renderSampleRate
        self.sampleRate = initialRate > 0 ? initialRate : AudioCore.renderSampleRate
        self.renderer = Renderer(shared: shared, sampleRate: max(self.sampleRate, 8_000))
        self.midi = MIDIInput(shared: shared)
        self.deviceID = target

        do {
            try createOutputUnit()
            if let target {
                try configureUnit(device: target)
                try startUnit()
            }
        } catch {
            lastError = error.localizedDescription
            report(error.localizedDescription)
        }
        installGlobalListeners()
        if let target { installDeviceListeners(target) }
    }

    deinit {
        stopUnit()
        if let unit {
            if unitInitialized { AudioUnitUninitialize(unit) }
            AudioComponentInstanceDispose(unit)
        }
        removeAllListeners()
    }

    // MARK: - Public state

    var hardwareSampleRate: Double {
        if let deviceID {
            let rate = AudioDevices.sampleRate(deviceID)
            if rate > 0 { return rate }
        }
        return sampleRate
    }

    var hardwareChannels: Int {
        guard let deviceID else { return 2 }
        return max(AudioDevices.outputChannels(deviceID), 1)
    }

    var bufferFrames: Int {
        guard let deviceID else { return 0 }
        return AudioDevices.bufferFrameSize(deviceID)
    }

    /// Buffer + device latency + safety offset, in milliseconds. This is the real output path
    /// figure shown in the transport, not a hard-coded estimate.
    var latencyMilliseconds: Double {
        guard let deviceID else { return 0 }
        let frames = bufferFrames
            + AudioDevices.latencyFrames(deviceID)
            + AudioDevices.safetyOffset(deviceID)
        return sampleRate > 0 ? Double(frames) / sampleRate * 1000 : 0
    }

    var engineName: String { AudioCore.engineName }

    var engineLabel: String {
        guard isRunning else { return "AUHAL · offline" }
        let rate = Int(hardwareSampleRate.rounded())
        let frames = bufferFrames
        let ms = String(format: "%.1f", latencyMilliseconds)
        return "AUHAL · \(rate) Hz · \(frames) frames · \(ms) ms"
    }

    var currentOutputDeviceID: AudioDeviceID? {
        deviceID ?? AudioDevices.defaultOutputID()
    }

    var currentOutputName: String {
        guard let id = currentOutputDeviceID else { return "System Default" }
        return AudioDevices.outputs().first(where: { $0.id == id })?.name ?? "System Default"
    }

    func outputDevices() -> [AudioDeviceInfo] {
        AudioDevices.outputs()
    }

    // MARK: - Unit lifecycle

    private func createOutputUnit() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioDeviceError.noOutputUnit
        }
        var instance: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &instance) == noErr,
              let instance else {
            throw AudioDeviceError.couldNotCreateUnit
        }
        unit = instance

        var enable: UInt32 = 1
        let outputEnable = AudioUnitSetProperty(
            instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &enable, UInt32(MemoryLayout<UInt32>.size))
        var disable: UInt32 = 0
        let inputDisable = AudioUnitSetProperty(
            instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &disable, UInt32(MemoryLayout<UInt32>.size))
        guard outputEnable == noErr, inputDisable == noErr else {
            throw AudioDeviceError.couldNotConfigure(outputEnable != noErr ? outputEnable : inputDisable)
        }

        var callback = AURenderCallbackStruct(
            inputProc: pocketOutputRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let callbackStatus = AudioUnitSetProperty(
            instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard callbackStatus == noErr else {
            throw AudioDeviceError.couldNotConfigure(callbackStatus)
        }

        var maxFrames = UInt32(Renderer.maximumFrames)
        AudioUnitSetProperty(instance, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &maxFrames,
                             UInt32(MemoryLayout<UInt32>.size))
    }

    private func configureUnit(device: AudioDeviceID) throws {
        guard let unit else { throw AudioDeviceError.noOutputUnit }
        stopUnit()
        if unitInitialized {
            AudioUnitUninitialize(unit)
            unitInitialized = false
        }

        var target = device
        let deviceStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &target, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard deviceStatus == noErr else {
            throw AudioDeviceError.couldNotSelectDevice(deviceStatus)
        }

        let deviceChannels = max(AudioDevices.outputChannels(device), 1)
        // The mixer is stereo. Two client channels is the correct path for stereo devices and
        // is the layout most multichannel interfaces expose for the first output pair. If a
        // device rejects two, fall back to its native channel count and leave unused channels
        // silent.
        var channels = min(deviceChannels, 2)
        var format = streamFormat(channels: channels)
        var formatStatus = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if formatStatus != noErr, deviceChannels > 2 {
            channels = deviceChannels
            format = streamFormat(channels: channels)
            formatStatus = AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        }
        guard formatStatus == noErr else {
            throw AudioDeviceError.couldNotConfigure(formatStatus)
        }

        var maxFrames = UInt32(Renderer.maximumFrames)
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &maxFrames,
                             UInt32(MemoryLayout<UInt32>.size))

        let initStatus = AudioUnitInitialize(unit)
        guard initStatus == noErr else {
            throw AudioDeviceError.couldNotInitialize(initStatus)
        }
        unitInitialized = true
        deviceID = device
    }

    private func streamFormat(channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(max(channels, 1)),
            mBitsPerChannel: 32,
            mReserved: 0)
    }

    private func startUnit() throws {
        guard let unit else { throw AudioDeviceError.noOutputUnit }
        if !unitInitialized {
            guard let deviceID else { throw AudioDeviceError.noOutputDevice }
            try configureUnit(device: deviceID)
        }
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw AudioDeviceError.couldNotStart("AudioOutputUnitStart \(status)")
        }
        isRunning = true
        lastError = nil
    }

    private func stopUnit() {
        if let unit { AudioOutputUnitStop(unit) }
        isRunning = false
    }

    // MARK: - Device selection

    /// Select a real hardware output. `nil` means "follow the current system default".
    func selectOutputDevice(_ requested: AudioDeviceID?) throws {
        let target = requested ?? AudioDevices.defaultOutputID()
        guard let target else { throw AudioDeviceError.noOutputDevice }
        let newRate = AudioDevices.sampleRate(target)
        guard newRate > 0 else { throw AudioDeviceError.noOutputDevice }

        stopUnit()
        removeDeviceListeners()

        if abs(newRate - sampleRate) > 0.5 {
            sampleRate = newRate
            renderer = Renderer(shared: shared, sampleRate: sampleRate)
            // The model owns sample pointers and AU instances. Ask it to rebuild them while the
            // unit is stopped, then configure and start at the new rate.
            onSampleRateChange?(newRate)
        }

        followingDefault = requested == nil
        try configureUnit(device: target)
        installDeviceListeners(target)
        if !suspendedForBounce {
            do {
                try startUnit()
            } catch {
                lastError = error.localizedDescription
                report(error.localizedDescription)
                throw error
            }
        }
        onStateChange?()
    }

    func setBufferSize(_ frames: Int) throws {
        guard let deviceID else { throw AudioDeviceError.noOutputDevice }
        let wasSuspended = suspendedForBounce
        stopUnit()
        let status = AudioDevices.setBufferFrameSize(deviceID, frames: frames)
        guard status == noErr else {
            throw AudioDeviceError.couldNotConfigure(status)
        }
        try configureUnit(device: deviceID)
        if !wasSuspended {
            try startUnit()
        }
        onStateChange?()
    }

    // MARK: - Transport / bounce

    func stop() {
        stopUnit()
    }

    /// Pause the realtime graph while an offline renderer borrows the same AU instances.
    func suspend() {
        guard isRunning else {
            suspendedForBounce = true
            return
        }
        stopUnit()
        suspendedForBounce = true
    }

    func resume() {
        guard !isRunning else { return }
        suspendedForBounce = false
        do {
            try startUnit()
            onStateChange?()
        } catch {
            lastError = error.localizedDescription
            report(error.localizedDescription)
            onEngineFailure?(error.localizedDescription)
        }
    }

    func releaseVoices(onTrack track: Int) {
        renderer.releaseVoices(onTrack: track)
    }

    // MARK: - Realtime callback

    fileprivate func render(frames: Int, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        renderer.render(frames: frames, abl: ioData)
    }

    private func report(_ message: String) {
        FileHandle.standardError.write("audio engine: \(message)\n".data(using: .utf8)!)
    }

    // MARK: - Listeners

    private func installGlobalListeners() {
        var devices = AudioDevices.address(kAudioHardwarePropertyDevices)
        let deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.deviceListChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &devices, DispatchQueue.main,
                                               deviceBlock) == noErr {
            deviceListListener = deviceBlock
        }

        var defaultAddress = AudioDevices.address(kAudioHardwarePropertyDefaultOutputDevice)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.defaultDeviceChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &defaultAddress, DispatchQueue.main,
                                               defaultBlock) == noErr {
            defaultDeviceListener = defaultBlock
        }
    }

    private func installDeviceListeners(_ device: AudioDeviceID) {
        removeDeviceListeners()
        func add(_ selector: AudioObjectPropertySelector) {
            var address = AudioDevices.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async { self?.currentDeviceChanged() }
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main,
                                                   block) == noErr {
                currentDeviceListeners.append(DeviceListener(object: device,
                                                             address: address,
                                                             block: block))
            }
        }
        add(kAudioDevicePropertyNominalSampleRate)
        add(kAudioDevicePropertyBufferFrameSize)
    }

    private func removeDeviceListeners() {
        for listener in currentDeviceListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address,
                                                   DispatchQueue.main, listener.block)
        }
        currentDeviceListeners.removeAll()
    }

    private func removeAllListeners() {
        removeDeviceListeners()
        if let deviceListListener {
            var address = AudioDevices.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address, DispatchQueue.main,
                                                   deviceListListener)
        }
        if let defaultDeviceListener {
            var address = AudioDevices.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address, DispatchQueue.main,
                                                   defaultDeviceListener)
        }
    }

    private func deviceListChanged() {
        onStateChange?()
        guard let current = deviceID else { return }
        let stillPresent = AudioDevices.outputs().contains { $0.id == current }
        guard !stillPresent else { return }
        do {
            try selectOutputDevice(nil)
        } catch {
            lastError = error.localizedDescription
            onEngineFailure?(error.localizedDescription)
        }
    }

    private func defaultDeviceChanged() {
        guard followingDefault else {
            onStateChange?()
            return
        }
        guard let newDefault = AudioDevices.defaultOutputID(), newDefault != deviceID else {
            onStateChange?()
            return
        }
        do {
            try selectOutputDevice(nil)
        } catch {
            lastError = error.localizedDescription
            onEngineFailure?(error.localizedDescription)
        }
    }

    private func currentDeviceChanged() {
        guard let deviceID else { return }
        let rate = AudioDevices.sampleRate(deviceID)
        guard rate > 0 else { return }
        guard abs(rate - sampleRate) > 0.5 else {
            onStateChange?()
            return
        }
        let wasRunning = isRunning
        stopUnit()
        sampleRate = rate
        renderer = Renderer(shared: shared, sampleRate: rate)
        onSampleRateChange?(rate)
        do {
            try configureUnit(device: deviceID)
            if wasRunning && !suspendedForBounce { try startUnit() }
            onStateChange?()
        } catch {
            lastError = error.localizedDescription
            report(error.localizedDescription)
            onEngineFailure?(error.localizedDescription)
        }
    }
}

/// Top-level C callback. It must not capture Swift context; the unretained AudioCore is the
/// refCon installed in `createOutputUnit()`.
private func pocketOutputRenderCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let core = Unmanaged<AudioCore>.fromOpaque(inRefCon).takeUnretainedValue()
    return core.render(frames: Int(inNumberFrames), ioData: ioData)
}

enum AudioDeviceError: LocalizedError {
    case noOutputDevice
    case noOutputUnit
    case couldNotCreateUnit
    case couldNotSelectDevice(OSStatus)
    case couldNotConfigure(OSStatus)
    case couldNotInitialize(OSStatus)
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .noOutputDevice:
            return "No audio output device is available"
        case .noOutputUnit:
            return "macOS did not provide a HAL output unit"
        case .couldNotCreateUnit:
            return "Could not create the CoreAudio output unit"
        case .couldNotSelectDevice(let status):
            return "CoreAudio refused the output device (\(status))"
        case .couldNotConfigure(let status):
            return "CoreAudio refused the output format (\(status))"
        case .couldNotInitialize(let status):
            return "Could not initialize the CoreAudio output unit (\(status))"
        case .couldNotStart(let message):
            return "Audio output failed to start: \(message)"
        }
    }
}
