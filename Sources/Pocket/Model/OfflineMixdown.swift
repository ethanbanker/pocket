import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Errors surfaced by the bounce path. The app never reports a successful export unless the
/// file was written and is long enough to contain the requested range.
enum MixdownError: Error, LocalizedError {
    case emptyRange
    case noTracks
    case tooLong
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .emptyRange: return "Select a non-empty range or draw some clips first"
        case .noTracks: return "There are no tracks to bounce"
        case .tooLong: return "That bounce is longer than 15 minutes"
        case .writeFailed: return "Could not write the WAV file"
        }
    }
}

extension SessionModel {
    /// End of the last clip, rounded up to a bar. This is what EXPORT uses when there is no time
    /// selection, so trailing silence is not baked into every file.
    func songEndStep() -> Int {
        let last = timeline.map { $0.start + $0.length }.max() ?? 0
        let bars = max(1, (last + stepsPerBar - 1) / stepsPerBar)
        return max(stepsPerBar, bars * stepsPerBar)
    }

    /// Snapshot only the mixer/renderer state the audio thread would read, trimmed to `range`.
    /// Sample buffers and AU instances are shared by pointer; the realtime engine is suspended
    /// for the duration of the bounce, so those instances are never touched concurrently.
    func makeMixdownState(start: Int, end: Int, onlyTrack: Int? = nil) -> Shared {
        let offline = Shared()
        offline.copyMixState(from: shared, start: start, end: end, onlyTrack: onlyTrack)
        return offline
    }

    /// Synchronous offline render used by tests, consolidation and the background export
    /// worker. The realtime graph is paused for the whole call so AU instances are not driven
    /// from two threads at once.
    @discardableResult
    func bounceMixdown(to url: URL, start: Int, end: Int, tail: Double = 1.5,
                       onlyTrack: Int? = nil) throws -> Double {
        guard end > start else { throw MixdownError.emptyRange }
        guard !tracks.isEmpty else { throw MixdownError.noTracks }
        let rate = audio?.sampleRate ?? 48_000
        let state = makeMixdownState(start: start, end: end, onlyTrack: onlyTrack)
        audio?.suspend()
        defer { audio?.resume() }
        try writeMixdownWAV(state: state, sampleRate: rate,
                            startStep: start, endStep: end, tailSeconds: tail, to: url)
        return Double(end - start) * 60.0 / bpm / 4.0 + max(tail, 0)
    }

    /// Writes one stereo WAV per track. Each stem includes that track's instrument, inserts,
    /// automation and send contribution, with all other tracks muted. The engine is suspended
    /// once so the stem set is a consistent snapshot.
    @discardableResult
    func bounceStems(to directory: URL) throws -> [URL] {
        let start = 0
        let end = songEndStep()
        guard end > start, !tracks.isEmpty else { throw MixdownError.noTracks }
        let rate = audio?.sampleRate ?? 48_000
        let project = projectName.replacingOccurrences(of: "/", with: "-")
        var written: [URL] = []
        audio?.suspend()
        defer { audio?.resume() }
        for t in tracks.indices {
            let stem = makeMixdownState(start: start, end: end, onlyTrack: t)
            let name = tracks[t].name.replacingOccurrences(of: "/", with: "-")
            let url = directory.appendingPathComponent(
                String(format: "%@ - %02d %@.wav", project, t + 1, name))
            try writeMixdownWAV(state: stem, sampleRate: rate,
                                startStep: start, endStep: end,
                                tailSeconds: 0.15, to: url)
            written.append(url)
        }
        return written
    }

    func exportStems() {
        guard !isBouncing else {
            status = "a bounce is already running"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for the multi-track stems"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        isBouncing = true
        status = "exporting \(tracks.count) stems…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let urls = try self.bounceStems(to: directory)
                DispatchQueue.main.async {
                    self.isBouncing = false
                    self.status = "exported \(urls.count) stems to \(directory.lastPathComponent)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBouncing = false
                    self.status = "stem export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func exportMixdown() {
        guard !isBouncing else {
            status = "a bounce is already running"
            return
        }
        let start = timeSelection?.start ?? 0
        let end = timeSelection?.end ?? songEndStep()
        guard end > start else {
            status = "draw clips or select time before exporting"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(projectName).wav"
        panel.message = timeSelection == nil
            ? "Export the whole arrangement as a stereo WAV"
            : "Export the selected time range as a stereo WAV"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let tail = timeSelection == nil ? 1.5 : 0.15
        let rate = audio?.sampleRate ?? 48_000
        let state = makeMixdownState(start: start, end: end)
        isBouncing = true
        status = "bouncing \(formattedBars(end - start))…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Double, Error>
            do {
                try writeMixdownWAV(state: state, sampleRate: rate,
                                    startStep: start, endStep: end,
                                    tailSeconds: tail, to: url)
                let seconds = Double(end - start) * 60.0 / max(state.bpm.pointee, 20) / 4.0 + tail
                result = .success(seconds)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBouncing = false
                switch result {
                case .success(let seconds):
                    self.status = "exported \(url.lastPathComponent) · \(String(format: "%.1f", seconds))s"
                case .failure(let error):
                    self.status = "export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

extension Shared {
    /// Copy the render-relevant state into a fresh `Shared` and trim the timeline to the
    /// requested absolute step range. The destination owns no sample/AU memory: the pointers
    /// are borrowed from the live engine, which is paused while the offline renderer runs.
    func copyMixState(from source: Shared, start: Int, end: Int, onlyTrack: Int? = nil) {
        bpm.pointee = source.bpm.pointee
        masterGain.pointee = source.masterGain.pointee
        returnLevel.pointee = source.returnLevel.pointee
        returnLevelB.pointee = source.returnLevelB.pointee
        muteMask.pointee = source.muteMask.pointee
        soloMask.pointee = source.soloMask.pointee
        if let onlyTrack {
            muteMask.pointee = Int32.max ^ (1 << onlyTrack)
            soloMask.pointee = 0
        }
        trackCount.pointee = source.trackCount.pointee
        arrLength.pointee = Int32(max(end, 1))
        loopEnabled.pointee = 0
        loopStart.pointee = 0
        loopLength.pointee = Int32(max(end - start, 1))
        seekTo.pointee = Int32(max(start, 0))
        seekSeq.pointee = 1
        playing.pointee = 1
        mode.pointee = 1

        for t in 0..<Shared.maxTracks {
            volume[t] = source.volume[t]
            baseVolume[t] = source.baseVolume[t]
            groupOf[t] = source.groupOf[t]
            baseSend[t] = source.baseSend[t]
            sendB[t] = source.sendB[t]
            baseSendB[t] = source.baseSendB[t]
            arpMode[t] = source.arpMode[t]
            arpRate[t] = source.arpRate[t]
            baseCutoff[t] = source.baseCutoff[t]
            basePan[t] = source.basePan[t]
            send[t] = source.send[t]
            cutoff[t] = source.cutoff[t]
            resonance[t] = source.resonance[t]
            drive[t] = source.drive[t]
            trackParams[t] = source.trackParams[t]
            arm[t] = 0
            instPtr[t] = source.instPtr[t]
            instOn[t] = source.instOn[t]
            instrumentLatency[t] = source.instrumentLatency[t]
            for slot in 0..<Shared.maxInserts {
                let index = t * Shared.maxInserts + slot
                pluginPtr[index] = source.pluginPtr[index]
                pluginOn[index] = source.pluginOn[index]
                pluginLatency[index] = source.pluginLatency[index]
            }
        }

        for g in 0...Shared.maxGroups {
            groupVolume[g] = source.groupVolume[g]
            groupPan[g] = source.groupPan[g]
        }

        for i in 0..<autoVol.count {
            autoVol[i] = source.autoVol[i]
            autoPan[i] = source.autoPan[i]
            autoSend[i] = source.autoSend[i]
            autoSendB[i] = source.autoSendB[i]
            autoCutoff[i] = source.autoCutoff[i]
        }

        let clipCount = Shared.maxTracks * Shared.sceneCount
        for index in 0..<clipCount {
            noteCount[index] = source.noteCount[index]
            loops[index] = source.loops[index]
            hasClip[index] = source.hasClip[index]
            clipSample[index] = source.clipSample[index]
            clipSampleGain[index] = source.clipSampleGain[index]
            clipSampleStart[index] = source.clipSampleStart[index]
            clipFadeIn[index] = source.clipFadeIn[index]
            clipFadeOut[index] = source.clipFadeOut[index]
            clipSampleBPM[index] = source.clipSampleBPM[index]
            clipWarp[index] = source.clipWarp[index]
            clipReverse[index] = source.clipReverse[index]
            clipStretch[index] = source.clipStretch[index]
            clipWarpCount[index] = source.clipWarpCount[index]
            clipRegionCount[index] = source.clipRegionCount[index]
            clipGainCount[index] = source.clipGainCount[index]
        }
        for index in 0..<(clipCount * Shared.maxWarpMarkers) {
            clipWarpTimeline[index] = source.clipWarpTimeline[index]
            clipWarpSource[index] = source.clipWarpSource[index]
        }
        for index in 0..<(clipCount * Shared.maxCompRegions) {
            clipRegionStart[index] = source.clipRegionStart[index]
            clipRegionEnd[index] = source.clipRegionEnd[index]
            clipRegionSlot[index] = source.clipRegionSlot[index]
        }
        for index in 0..<(clipCount * Shared.maxClipPoints) {
            clipGainStep[index] = source.clipGainStep[index]
            clipGainValue[index] = source.clipGainValue[index]
        }
        for index in 0..<(clipCount * Shared.maxNotes) {
            noteStart[index] = source.noteStart[index]
            noteLen[index] = source.noteLen[index]
            notePitch[index] = source.notePitch[index]
            noteVel[index] = source.noteVel[index]
            noteProb[index] = source.noteProb[index]
            noteGroove[index] = source.noteGroove[index]
        }
        for slot in 0..<Shared.sampleSlots {
            samplePtr[slot] = source.samplePtr[slot]
            samplePtrR[slot] = source.samplePtrR[slot]
            sampleLen[slot] = source.sampleLen[slot]
        }

        for t in 0..<Shared.maxTracks {
            tlCount[t] = 0
            let sourceBase = t * Shared.maxTimeline
            let count = min(Int(source.tlCount[t]), Shared.maxTimeline)
            var written = 0
            for i in 0..<count {
                let originalStart = Int(source.tlStart[sourceBase + i])
                let originalLength = max(Int(source.tlLen[sourceBase + i]), 1)
                let clipStart = max(start, originalStart)
                let clipEnd = min(end, originalStart + originalLength)
                guard clipEnd > clipStart, written < Shared.maxTimeline else { continue }
                let base = t * Shared.maxTimeline + written
                tlStart[base] = Int32(clipStart)
                tlLen[base] = Int32(clipEnd - clipStart)
                tlScene[base] = source.tlScene[sourceBase + i]
                tlOffset[base] = source.tlOffset[sourceBase + i]
                    + Int32(clipStart - originalStart)
                written += 1
            }
            tlCount[t] = Int32(written)
        }
    }
}

/// Render the already-prepared state into a 16-bit stereo WAV. This is deliberately separate
/// from the app's realtime callback: it runs as fast as the CPU allows and never opens an output
/// device.
func writeMixdownWAV(state: Shared, sampleRate: Double, startStep: Int, endStep: Int,
                     tailSeconds: Double, to url: URL) throws {
    guard endStep > startStep else { throw MixdownError.emptyRange }
    let bpm = max(state.bpm.pointee, 20)
    let framesPerStep = sampleRate * 60.0 / bpm / 4.0
    let bodyFrames = Int(ceil(Double(endStep - startStep) * framesPerStep))
    let tailFrames = max(0, Int(tailSeconds * sampleRate))
    let totalFrames = bodyFrames + tailFrames
    guard totalFrames > 0 else { throw MixdownError.emptyRange }
    guard totalFrames < 48_000 * 60 * 15 else { throw MixdownError.tooLong }

    let block = 512
    let byteSize = block * MemoryLayout<Float>.size
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    list.count = 2
    for i in 0..<2 {
        list[i].mNumberChannels = 1
        list[i].mDataByteSize = UInt32(byteSize)
        list[i].mData = UnsafeMutableRawPointer.allocate(byteCount: byteSize, alignment: 16)
    }
    defer {
        for i in 0..<2 { list[i].mData?.deallocate() }
        free(list.unsafeMutablePointer)
    }

    let interleaved = UnsafeMutablePointer<Int16>.allocate(capacity: totalFrames * 2)
    defer { interleaved.deallocate() }

    let renderer = Renderer(shared: state, sampleRate: sampleRate)
    var rendered = 0
    while rendered < totalFrames {
        let frames = min(block, totalFrames - rendered)
        _ = renderer.render(frames: frames, abl: list.unsafeMutablePointer)
        let left = list[0].mData!.assumingMemoryBound(to: Float.self)
        let right = list[1].mData!.assumingMemoryBound(to: Float.self)
        for i in 0..<frames {
            let l = max(-1, min(1, left[i]))
            let r = max(-1, min(1, right[i]))
            let out = (rendered + i) * 2
            interleaved[out] = Int16(l * 32767)
            interleaved[out + 1] = Int16(r * 32767)
        }
        rendered += frames
    }
    state.playing.pointee = 0

    var header = Data()
    func le32(_ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
    }
    func le16(_ value: UInt16) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
    }
    let dataBytes = UInt32(totalFrames * 2 * MemoryLayout<Int16>.size)
    header.append(contentsOf: "RIFF".utf8)
    le32(36 + dataBytes)
    header.append(contentsOf: "WAVE".utf8)
    header.append(contentsOf: "fmt ".utf8)
    le32(16)
    le16(1)                              // PCM
    le16(2)                              // stereo
    le32(UInt32(sampleRate))
    le32(UInt32(sampleRate) * 4)         // byte rate
    le16(4)                              // block align
    le16(16)                             // bits
    header.append(contentsOf: "data".utf8)
    le32(dataBytes)

    var output = header
    output.append(Data(bytes: interleaved, count: Int(dataBytes)))
    try? FileManager.default.removeItem(at: url)
    do {
        try output.write(to: url, options: .atomic)
    } catch {
        throw MixdownError.writeFailed
    }
}
