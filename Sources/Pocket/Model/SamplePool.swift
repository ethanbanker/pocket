import AVFoundation
import Foundation

/// Decodes audio files into float buffers at the engine sample rate and hands the raw pointers to
/// the audio thread through `Shared`. Stereo files keep both channels; mono files publish one
/// pointer. Loaded buffers are never freed while the app runs, so a pointer in `Shared` can never
/// dangle under the render thread.
final class SamplePool {
    struct Loaded {
        let left: UnsafeMutablePointer<Float>
        let right: UnsafeMutablePointer<Float>?
        let frames: Int
        let path: String
        let peaks: [Float]
    }

    enum LoadError: Error, LocalizedError {
        case unreadable
        case noPoolSlot
        case empty
        case tooLong
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Could not read that audio file"
            case .noPoolSlot: return "Sample pool is full (\(Shared.sampleSlots) slots)"
            case .empty: return "That file contains no audio"
            case .tooLong: return "That file is longer than Pocket's 30-minute sample limit"
            case .conversionFailed: return "Could not convert that audio file to the engine rate"
            }
        }
    }

    private let shared: Shared
    private let sampleRate: Double
    private(set) var loaded: [Int: Loaded] = [:]

    init(shared: Shared, sampleRate: Double) {
        self.shared = shared
        self.sampleRate = sampleRate
    }

    deinit {
        for entry in loaded.values {
            entry.left.deallocate()
            entry.right?.deallocate()
        }
    }

    var usedSlots: Int { loaded.count }

    /// Paths survive an engine sample-rate change; the model reloads them into a new pool.
    var pathsBySlot: [Int: String] {
        loaded.mapValues(\.path)
    }

    /// Downsampled absolute peaks for drawing the waveform in the timeline.
    func peaks(for slot: Int) -> [Float]? {
        loaded[slot]?.peaks
    }

    /// Length of a loaded sample in seconds, used to give a dropped clip its natural length.
    func duration(of slot: Int) -> Double? {
        guard let entry = loaded[slot] else { return nil }
        return Double(entry.frames) / sampleRate
    }

    func slot(forPath path: String) -> Int? {
        loaded.first { $0.value.path == path }?.key
    }

    func channelCount(for slot: Int) -> Int {
        loaded[slot]?.right == nil ? 1 : 2
    }

    /// Reuses an already decoded file instead of consuming another pool slot for every placement.
    func loadOrReuse(path: String) throws -> Int {
        if let existing = slot(forPath: path) { return existing }
        return try load(path: path)
    }

    /// Decodes and converts to the engine rate with AVAudioConverter, preserving the source
    /// channel layout up to stereo. Linear interpolation is kept only as a fallback for formats
    /// the converter rejects, so ordinary WAV/AIFF/MP3/CAF imports are not resampled by hand.
    func load(path: String) throws -> Int {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else { throw LoadError.unreadable }

        let sourceFormat = file.processingFormat
        let sourceRate = sourceFormat.sampleRate
        let sourceChannels = max(Int(sourceFormat.channelCount), 1)
        guard sourceRate > 0, file.length > 1 else { throw LoadError.empty }

        // Decode the whole file. Songs and field recordings routinely run past the old
        // two-minute cap; truncating there made a long import look like a blank clip. The cap is
        // now a wide safety bound (30 minutes) rather than a musical length limit. It is measured
        // in source frames, so high-rate files cannot silently allocate for an hour of audio.
        let maximumFrames = AVAudioFramePosition(sourceRate * 60 * 30)
        guard file.length <= maximumFrames else { throw LoadError.tooLong }
        let srcFrames = Int(file.length)
        guard srcFrames > 1 else { throw LoadError.empty }
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                            frameCapacity: AVAudioFrameCount(srcFrames)) else {
            throw LoadError.unreadable
        }
        try file.read(into: source, frameCount: AVAudioFrameCount(srcFrames))
        guard source.frameLength > 1, let sourceChannelsPtr = source.floatChannelData else {
            throw LoadError.unreadable
        }

        let targetChannels = min(sourceChannels, 2)
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                               channels: AVAudioChannelCount(targetChannels)) else {
            throw LoadError.unreadable
        }

        var converted: (left: UnsafeMutablePointer<Float>,
                        right: UnsafeMutablePointer<Float>?,
                        frames: Int)?
        if let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) {
            let capacity = AVAudioFrameCount(Int(ceil(Double(source.frameLength)
                                                      * sampleRate / sourceRate)) + 2048)
            if let output = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                             frameCapacity: max(capacity, 2)) {
                var supplied = false
                var conversionError: NSError?
                let inputBlock: AVAudioConverterInputBlock = { _, status in
                    if supplied {
                        status.pointee = .endOfStream
                        return nil
                    }
                    supplied = true
                    status.pointee = .haveData
                    return source
                }
                let status = converter.convert(to: output, error: &conversionError,
                                               withInputFrom: inputBlock)
                if status != .error, output.frameLength > 1,
                   let channels = output.floatChannelData {
                    let frames = Int(output.frameLength)
                    let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                    left.initialize(from: channels[0], count: frames)
                    var right: UnsafeMutablePointer<Float>?
                    if targetChannels > 1 {
                        let r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                        r.initialize(from: channels[1], count: frames)
                        right = r
                    }
                    converted = (left, right, frames)
                }
            }
        }

        if converted == nil {
            converted = try linearConvert(source: source, sourceRate: sourceRate,
                                          sourceChannels: sourceChannelsPtr,
                                          channelCount: sourceChannels)
        }
        guard let result = converted, result.frames > 1 else {
            throw LoadError.conversionFailed
        }

        let peaks = makePeaks(left: result.left, right: result.right, frames: result.frames)
        let slot = try allocateSlot()
        loaded[slot] = Loaded(left: result.left, right: result.right, frames: result.frames,
                              path: path, peaks: peaks)
        shared.sampleLen[slot] = Int32(result.frames)
        shared.samplePtrR[slot] = result.right
        shared.samplePtr[slot] = result.left   // publish the mono/last pointer last
        return slot
    }

    /// Fallback used only when AVAudioConverter cannot represent the source file. It preserves
    /// the first two channels and resamples with linear interpolation.
    private func linearConvert(source: AVAudioPCMBuffer, sourceRate: Double,
                               sourceChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
                               channelCount: Int) throws
        -> (left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frames: Int) {
        let srcFrames = Int(source.frameLength)
        guard srcFrames > 1 else { throw LoadError.empty }
        let outFrames = max(Int(Double(srcFrames) * sampleRate / sourceRate), 2)
        let ratio = sourceRate / sampleRate
        let left = UnsafeMutablePointer<Float>.allocate(capacity: outFrames)
        let right: UnsafeMutablePointer<Float>? = channelCount > 1
            ? UnsafeMutablePointer<Float>.allocate(capacity: outFrames)
            : nil
        let rightSource = sourceChannels[channelCount > 1 ? 1 : 0]
        for i in 0..<outFrames {
            let src = Double(i) * ratio
            let i0 = min(Int(src), srcFrames - 1)
            let i1 = min(i0 + 1, srcFrames - 1)
            let frac = Float(src - Double(i0))
            left[i] = sourceChannels[0][i0] * (1 - frac) + sourceChannels[0][i1] * frac
            right?[i] = rightSource[i0] * (1 - frac) + rightSource[i1] * frac
        }
        return (left, right, outFrames)
    }

    private func makePeaks(left: UnsafeMutablePointer<Float>,
                           right: UnsafeMutablePointer<Float>?, frames: Int) -> [Float] {
        let bucketCount = 512
        var peaks = [Float](repeating: 0, count: bucketCount)
        let perBucket = max(frames / bucketCount, 1)
        for bucket in 0..<bucketCount {
            let start = bucket * perBucket
            let end = min(start + perBucket, frames)
            guard start < end else { continue }
            var peak: Float = 0
            for i in start..<end {
                let value = max(abs(left[i]), right.map { abs($0[i]) } ?? 0)
                if value > peak { peak = value }
            }
            peaks[bucket] = min(peak, 1)
        }
        return peaks
    }

    /// Publishes an already-loaded sample into a fresh slot (used by project load).
    func slot(forExistingPath path: String) throws -> Int {
        try loadOrReuse(path: path)
    }

    private func allocateSlot() throws -> Int {
        for i in 0..<Shared.sampleSlots where loaded[i] == nil {
            return i
        }
        throw LoadError.noPoolSlot
    }

    func clearSlot(_ slot: Int) {
        guard slot >= 0, slot < Shared.sampleSlots, let entry = loaded[slot] else { return }
        loaded[slot] = nil
        shared.samplePtr[slot] = nil
        shared.samplePtrR[slot] = nil
        shared.sampleLen[slot] = 0
        // A slot can only be cleared while the engine is stopped. The renderer never sees this
        // pointer after `samplePtr` is cleared, but keep the old memory alive for one more beat
        // in case a UI waveform request is still reading it.
        _ = entry
    }
}
