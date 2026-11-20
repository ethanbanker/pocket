import AVFoundation
import AudioToolbox
import Foundation

/// Live input path. `AVAudioEngine` owns the microphone/interface stream; its tap feeds both a
/// lock-free monitoring ring (read by the AUHAL render callback) and, when armed, a CAF take.
/// Keeping the input engine separate is what lets Pocket choose an input device that is not the
/// same as the output interface.
final class InputMonitor {
    private let shared: Shared
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var recordingURL: URL?
    private var recordingFile: AVAudioFile?
    private(set) var isRunning = false
    private(set) var lastError: String?

    init(shared: Shared) {
        self.shared = shared
    }

    deinit {
        _ = stop()
    }

    /// Starts the selected input. Passing a URL records that take at the input's native format;
    /// passing nil monitors without writing anything to disk.
    func start(deviceUID: String?, monitor: Bool, recordTo url: URL?) throws {
        _ = stop()
        shared.inputHead.pointee = 0
        shared.inputTail.pointee = 0

        let input = engine.inputNode
        if let uid = deviceUID, let device = AudioDevices.inputID(uid: uid),
           let unit = input.audioUnit {
            var target = device
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &target, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                throw NSError(domain: "PocketInput", code: Int(status), userInfo: [
                    NSLocalizedDescriptionKey: "Could not select that audio input"
                ])
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "PocketInput", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The selected audio input has no usable channels"
            ])
        }
        shared.inputRate.pointee = format.sampleRate
        shared.monitorOn.pointee = monitor ? 1 : 0
        shared.monitorGain.pointee = 1.0

        recordingURL = url
        recordingFile = nil
        if let url {
            try? FileManager.default.removeItem(at: url)
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, monitor: monitor)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            shared.monitorOn.pointee = 0
            lastError = error.localizedDescription
            throw error
        }
        isRunning = true
        lastError = nil
    }

    /// Stops the stream and returns the completed take URL, if this run was recording one.
    @discardableResult
    func stop() -> URL? {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        shared.monitorOn.pointee = 0
        isRunning = false
        recordingFile = nil   // closes and flushes the CAF header
        let url = recordingURL
        recordingURL = nil
        return url
    }

    private func consume(_ buffer: AVAudioPCMBuffer, monitor: Bool) {
        guard let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        if monitor {
            let capacity = Shared.inputRingFrames
            let head = Int(shared.inputHead.pointee)
            var tail = Int(shared.inputTail.pointee)
            let left = channels[0]
            let right = buffer.format.channelCount > 1 ? channels[1] : channels[0]
            for i in 0..<count {
                if tail - head >= capacity { break }
                let slot = tail % capacity
                shared.inputL[slot] = left[i]
                shared.inputR[slot] = right[i]
                tail += 1
            }
            shared.inputTail.pointee = Int32(tail)
        }

        guard let url = recordingURL else { return }
        if recordingFile == nil {
            recordingFile = try? AVAudioFile(forWriting: url,
                                             settings: buffer.format.settings,
                                             commonFormat: .pcmFormatFloat32,
                                             interleaved: false)
        }
        try? recordingFile?.write(from: buffer)
    }
}
