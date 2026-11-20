import AVFoundation
import Foundation

struct RecordedNote {
    var clipID: Int
    var noteID: Int
    var start: Int
    var velocity: Int
}

extension SessionModel {
    var armedTracks: [Int] {
        (0..<tracks.count).filter { fx[$0].armed }
    }

    /// One transport record button. The armed track determines the destination; if nothing is
    /// armed, the selected track is armed explicitly and the status line says so.
    func toggleRecording() {
        if isRecording {
            finishRecording()
            if isPlaying { stopTransport() }
        } else {
            beginRecording()
        }
    }

    func beginRecording() {
        guard !isRecording else { return }
        guard tracks.count > 0 else { return }
        var armed = armedTracks
        if armed.isEmpty {
            setFX(selection.track, armed: true)
            armed = [selection.track]
            status = "armed \(tracks[selection.track].name) for recording"
        }
        recordTrack = armed.first
        guard let track = recordTrack else { return }
        let liveStep = isPlaying ? currentStep() : insertStep
        recordStartStep = max(0, snappedStep(liveStep) - recordLatencySteps)
        // An audio take can deliberately land over the clip it is replacing. MIDI and first
        // takes still need empty arrangement space.
        let existingTake = recordMode == .audio && audioClip(at: track, step: recordStartStep) != nil
        guard existingTake || isRangeFree(track: track, start: recordStartStep, length: stepsPerBar) else {
            status = "cannot record there — move the insert marker to empty space on \(tracks[track].name)"
            return
        }
        recordClipIDs.removeAll()
        recordNoteStarts.removeAll()

        switch recordMode {
        case .midi:
            if !isPlaying {
                seek(to: recordStartStep)
                startTransport()
            }
            isRecording = true
            status = "recording MIDI on \(tracks[track].name) — play your controller"
        case .audio:
            // Do not start the transport before the input engine is actually running. Starting
            // the file after the clock is what used to put every take a few milliseconds late.
            requestAudioRecording(track: track)
        }
    }

    private func requestAudioRecording(track: Int) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startAudioRecorder(track: track)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startAudioRecorder(track: track)
                    } else {
                        self.status = "microphone access denied — enable it in System Settings › Privacy"
                        if self.isPlaying { self.stopTransport() }
                    }
                }
            }
        default:
            status = "microphone access denied — enable it in System Settings › Privacy"
            if isPlaying { stopTransport() }
        }
    }

    private func startAudioRecorder(track: Int) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask)[0]
            .appendingPathComponent("Pocket/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("Take \(stamp).caf")
        guard let inputMonitor else {
            status = "audio input engine is not ready"
            return
        }
        do {
            try inputMonitor.start(deviceUID: selectedAudioInputUID,
                                   monitor: inputMonitoring, recordTo: url)
            shared.monitorTrack.pointee = Int32(track)
            isRecording = true
            if !isPlaying {
                seek(to: recordStartStep)
                startTransport()
            }
            status = "recording audio on \(tracks[track].name) — \(url.lastPathComponent)"
        } catch {
            status = "audio recording failed: \(error.localizedDescription)"
            if isPlaying { stopTransport() }
        }
    }

    /// Stop file/notes capture without stopping the transport. `stopTransport` calls this too.
    func finishRecording() {
        guard isRecording else { return }
        isRecording = false

        if let url = inputMonitor?.stop(), let track = recordTrack,
           FileManager.default.fileExists(atPath: url.path) {
            finishAudioTake(url: url, track: track)
            if inputMonitoring { restartInputMonitoringAfterTake() }
        }

        if recordMode == .midi {
            finalizeMIDIRecording()
        }
        recordTrack = nil
    }

    private func finishAudioTake(url: URL, track: Int) {
        if let hit = audioClip(at: track, step: recordStartStep) {
            let oldLength = timelineClip(id: hit.id)?.length ?? stepsPerBar
            _ = addTake(path: url.path, name: url.lastPathComponent,
                        track: hit.track, scene: hit.scene)
            if let placed = timelineClip(id: hit.id), placed.length < oldLength {
                _ = placed
            }
            selectedTimeline = hit.id
            selection = Selection(track: hit.track, scene: hit.scene)
            status = "recorded take on \(tracks[track].name) — \(url.lastPathComponent)"
        } else {
            dropAudio(path: url.path, track: track, start: recordStartStep)
            status = "recorded \(url.lastPathComponent) on \(tracks[track].name)"
        }
    }

    private func audioClip(at track: Int, step: Int) -> TimelineClip? {
        timeline.first {
            $0.track == track && $0.start <= step && step < $0.start + $0.length
                && clips[$0.track][$0.scene].samplePath != nil
        }
    }

    private func restartInputMonitoringAfterTake() {
        guard let inputMonitor else { return }
        do {
            try inputMonitor.start(deviceUID: selectedAudioInputUID, monitor: true, recordTo: nil)
            shared.monitorTrack.pointee = Int32(min(max(selection.track, 0), tracks.count - 1))
        } catch {
            inputMonitoring = false
            status = "monitoring stopped: \(error.localizedDescription)"
        }
    }

    /// Single entry point for CoreMIDI. Notes go to the recorder when recording; CCs go to the
    /// learn/apply path; everything note-shaped also lands in the rolling capture buffer.
    func handleMIDIEvent(status: UInt8, note: Int, velocity: Int) {
        let command = status & 0xF0
        if command == 0xB0 {
            handleMIDIControl(cc: note, value: velocity)
            return
        }
        guard command == 0x90 || command == 0x80 else { return }
        if !isRecording {
            appendMIDICapture(status: command, note: note, velocity: velocity)
        }
        handleRecordedMIDI(status: status, note: note, velocity: velocity)
    }

    func beginMIDILearn(_ target: MIDIMapTarget) {
        midiLearnTarget = target
        midiLearnTrack = min(max(selection.track, 0), max(tracks.count - 1, 0))
        status = "MIDI learn: move a control for \(target.label) on \(tracks[midiLearnTrack].name)"
    }

    func clearMIDIMappings() {
        midiMappings.removeAll()
        midiLearnTarget = nil
        status = "MIDI CC mappings cleared"
    }

    private func handleMIDIControl(cc: Int, value: Int) {
        guard cc >= 0, cc <= 127, value >= 0, value <= 127 else { return }
        let normalized = Double(value) / 127.0
        if let target = midiLearnTarget {
            let mapping = MIDIMapping(cc: cc, target: target, track: midiLearnTrack)
            midiMappings[cc] = mapping
            midiLearnTarget = nil
            applyMIDIMapping(mapping, normalized: normalized)
            status = "CC \(cc) → \(target.label) · \(tracks[min(midiLearnTrack, tracks.count - 1)].name)"
            return
        }
        guard let mapping = midiMappings[cc] else { return }
        applyMIDIMapping(mapping, normalized: normalized)
    }

    private func applyMIDIMapping(_ mapping: MIDIMapping, normalized: Double) {
        switch mapping.target {
        case .master:
            setMaster(normalized)
        case .trackVolume:
            setFX(mapping.track, volume: normalized)
        case .trackPan:
            setFX(mapping.track, pan: normalized * 2 - 1)
        case .trackSend:
            setFX(mapping.track, send: normalized)
        case .trackCutoff:
            setFX(mapping.track, cutoff: 120 * pow(18000.0 / 120.0, normalized))
        }
    }

    private func appendMIDICapture(status: UInt8, note: Int, velocity: Int) {
        guard note >= 0, note <= 127 else { return }
        let event = CapturedMIDIEvent(status: status, note: note, velocity: velocity,
                                      step: currentStep(), timestamp: Date.timeIntervalSinceReferenceDate)
        capturedMIDIEvents.append(event)
        if capturedMIDIEvents.count > 2048 {
            capturedMIDIEvents.removeFirst(capturedMIDIEvents.count - 2048)
        }
        midiCaptureCount = capturedMIDIEvents.count
    }

    func clearMIDICapture() {
        capturedMIDIEvents.removeAll()
        midiCaptureCount = 0
        status = "MIDI capture cleared"
    }

    /// Turns the rolling MIDI buffer into one editable timeline clip. This is the equivalent of
    /// Live's Capture MIDI: the notes exist even though the transport was never recording.
    @discardableResult
    func captureMIDIToClip() -> Int? {
        guard !capturedMIDIEvents.isEmpty else {
            status = "no MIDI captured yet — play your controller"
            return nil
        }
        let ordered = capturedMIDIEvents.sorted { $0.timestamp < $1.timestamp }
        var active: [Int: (start: Int, velocity: Int)] = [:]
        var notes: [CapturedMIDINote] = []
        for event in ordered {
            let command = event.status & 0xF0
            if command == 0x90, event.velocity > 0 {
                active[event.note] = (event.step, event.velocity)
            } else if command == 0x80 || (command == 0x90 && event.velocity == 0) {
                guard let start = active.removeValue(forKey: event.note) else { continue }
                notes.append(CapturedMIDINote(start: start.start,
                                              length: max(1, event.step - start.start),
                                              pitch: event.note,
                                              velocity: start.velocity))
            }
        }
        for (note, start) in active {
            notes.append(CapturedMIDINote(start: start.start,
                                          length: max(1, currentStep() - start.start),
                                          pitch: note, velocity: start.velocity))
        }
        guard !notes.isEmpty else {
            status = "MIDI capture has no complete notes"
            return nil
        }

        let first = notes.map(\.start).min() ?? insertStep
        let last = notes.map { $0.start + $0.length }.max() ?? (first + 1)
        let track = armedTracks.first ?? min(selection.track, tracks.count - 1)
        let requested = max(0, snappedStep(first))
        let length = max(stepsPerBar, last - requested)
        guard let placedStart = freePlacement(track: track, start: requested, length: length) else {
            status = "no free space on \(tracks[track].name) for the captured MIDI"
            return nil
        }
        guard let id = addTimelineClip(track: track, start: placedStart,
                                       length: length),
              let placed = timelineClip(id: id) else { return nil }
        var info = clips[placed.track][placed.scene]
        info.exists = true
        info.loopSteps = placed.length
        info.notes = notes.map { note in
            var data = NoteData(id: nextNoteID,
                                start: max(0, min(note.start - placedStart,
                                                  placed.length - 1)),
                                length: max(1, min(note.length, placed.length)),
                                pitch: note.pitch, velocity: max(1, min(note.velocity, 127)))
            data.probability = 100
            data.groove = 0
            nextNoteID += 1
            return data
        }
        notes.removeAll()
        clips[placed.track][placed.scene] = info
        syncNotes(track: placed.track, scene: placed.scene)
        syncTimeline()
        capturedMIDIEvents.removeAll()
        midiCaptureCount = 0
        status = "captured \(info.notes.count) MIDI notes on \(tracks[placed.track].name)"
        return id
    }

    func handleRecordedMIDI(status rawStatus: UInt8, note: Int, velocity: Int) {
        guard isRecording, recordMode == .midi, isPlaying, note >= 0, note <= 127 else { return }
        let command = rawStatus & 0xF0
        guard command == 0x90 || command == 0x80 else { return }
        guard let track = recordTrack else { return }
        let performanceStep = max(0, currentStep() - recordLatencySteps)
        let step = max(performanceStep, recordStartStep)

        if command == 0x90, velocity > 0 {
            guard recordNoteStarts[note] == nil else { return }
            guard let clipID = ensureRecordingClip(track: track) else { return }
            let local = max(0, step - recordStartStep)
            guard let localScene = scene(for: clipID) else { return }
            var info = clips[track][localScene]
            guard info.notes.count < Shared.maxNotes else {
                status = "recording clip is full"
                return
            }
            let id = nextNoteID
            nextNoteID += 1
            let recorded = NoteData(id: id, start: local, length: 1,
                                    pitch: note, velocity: max(1, min(velocity, 127)))
            info.notes.append(recorded)
            info.loopSteps = max(info.loopSteps, local + 1)
            clips[track][localScene] = info
            syncNotes(track: track, scene: localScene)
            extendRecordingClip(clipID: clipID, to: local + 1)
            recordNoteStarts[note] = RecordedNote(clipID: clipID, noteID: id,
                                                  start: local, velocity: Int(velocity))
            selectedNote = id
            selectedNotes = [id]
        } else if command == 0x80 || (command == 0x90 && velocity == 0) {
            guard let pending = recordNoteStarts.removeValue(forKey: note),
                  let scene = scene(for: pending.clipID),
                  track >= 0, track < tracks.count else { return }
            let localEnd = max(max(0, currentStep() - recordLatencySteps), recordStartStep) - recordStartStep
            extendRecordingClip(clipID: pending.clipID, to: localEnd)
            var info = clips[track][scene]
            guard let index = info.notes.firstIndex(where: { $0.id == pending.noteID }) else { return }
            info.notes[index].length = max(1, localEnd - pending.start)
            clips[track][scene] = info
            syncNotes(track: track, scene: scene)
        }
    }

    private func ensureRecordingClip(track: Int) -> Int? {
        if let existing = recordClipIDs[track], timelineClip(id: existing) != nil {
            return existing
        }
        guard let id = addTimelineClip(track: track, start: recordStartStep,
                                        length: stepsPerBar, minimumLength: 1) else {
            return nil
        }
        recordClipIDs[track] = id
        return id
    }

    private func extendRecordingClip(clipID: Int, to localLength: Int) {
        guard let index = timeline.firstIndex(where: { $0.id == clipID }) else { return }
        let needed = max(localLength, stepsPerBar)
        guard timeline[index].length < needed else { return }
        timeline[index].length = needed
        let clip = timeline[index]
        var info = clips[clip.track][clip.scene]
        info.loopSteps = needed
        clips[clip.track][clip.scene] = info
        shared.loops[Shared.clipIndex(track: clip.track, scene: clip.scene)] = Int32(needed)
        syncTimeline()
    }

    private func finalizeMIDIRecording() {
        for (note, pending) in recordNoteStarts {
            guard let scene = scene(for: pending.clipID),
                  let track = timelineClip(id: pending.clipID)?.track else { continue }
            let end = max(max(0, currentStep() - recordLatencySteps) - recordStartStep,
                          pending.start + 1)
            extendRecordingClip(clipID: pending.clipID, to: end)
            var info = clips[track][scene]
            guard let index = info.notes.firstIndex(where: { $0.id == pending.noteID }) else { continue }
            info.notes[index].length = max(1, end - pending.start)
            clips[track][scene] = info
            syncNotes(track: track, scene: scene)
            _ = note
        }
        recordNoteStarts.removeAll()
        for (_, id) in recordClipIDs {
            if timelineClip(id: id) != nil {
                let end = max(max(0, currentStep() - recordLatencySteps) - recordStartStep,
                              stepsPerBar)
                extendRecordingClip(clipID: id, to: end)
            }
        }
        if !recordClipIDs.isEmpty { syncTimeline() }
    }

    private func scene(for clipID: Int) -> Int? {
        timelineClip(id: clipID)?.scene
    }

}
