import Foundation
import AudioToolbox

private struct RunResult {
    var peaks: [Float]
    var overall: Float
    var finite: Bool
}

/// Renders `seconds` of audio offline and measures peak level inside each sample window.
private func renderRun(renderer: Renderer, seconds: Double, sampleRate: Double,
                       windows: [(Int, Int)]) -> RunResult {
    let frames = 512
    let byteSize = frames * MemoryLayout<Float>.size
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

    var peaks = [Float](repeating: 0, count: windows.count)
    var overall: Float = 0
    var finite = true
    var index = 0
    let total = Int(seconds * sampleRate)

    // Only whole blocks, so the run ends exactly at `total` and the step count is predictable.
    while index + frames <= total {
        _ = renderer.render(frames: frames, abl: list.unsafeMutablePointer)
        for channel in 0..<2 {
            let data = list[channel].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                let value = data[i]
                let position = index + i
                if !value.isFinite { finite = false }
                let amplitude = abs(value)
                if amplitude > overall { overall = amplitude }
                for (w, window) in windows.enumerated()
                where position >= window.0 && position < window.1 {
                    if amplitude > peaks[w] { peaks[w] = amplitude }
                }
            }
        }
        index += frames
    }

    return RunResult(peaks: peaks, overall: overall, finite: finite)
}

/// Autocorrelation pitch estimate. Granular crossfades can add zero crossings, so periodicity
/// is the honest way to prove the stretched tone still has its original fundamental.
private func dominantFrequency(_ samples: [Float], from: Int, to: Int,
                               sampleRate: Double) -> Double {
    let start = max(0, min(from, samples.count - 1))
    let end = max(start + 32, min(to, samples.count))
    let count = end - start
    let lagMin = max(2, Int(sampleRate / 900))
    let lagMax = min(count / 2, Int(sampleRate / 60))
    guard lagMax > lagMin else { return 0 }
    var bestLag = lagMin
    var best = -Double.greatestFiniteMagnitude
    for lag in lagMin...lagMax {
        var sum = 0.0
        for i in 0..<(count - lag) {
            sum += Double(samples[start + i]) * Double(samples[start + i + lag])
        }
        let normalized = sum / Double(count - lag)
        if normalized > best {
            best = normalized
            bestLag = lag
        }
    }
    return sampleRate / Double(bestLag)
}

/// Captures the left channel of an offline render for pitch/level analysis.
private func renderSamples(renderer: Renderer, seconds: Double,
                           sampleRate: Double) -> [Float] {
    let frames = 512
    let byteSize = frames * MemoryLayout<Float>.size
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
    var output = [Float](repeating: 0, count: Int(seconds * sampleRate))
    var index = 0
    while index + frames <= output.count {
        _ = renderer.render(frames: frames, abl: list.unsafeMutablePointer)
        let data = list[0].mData!.assumingMemoryBound(to: Float.self)
        for i in 0..<frames { output[index + i] = data[i] }
        index += frames
    }
    return output
}

/// Rough fundamental estimate from upward zero crossings — one per cycle, which stays stable
/// through granular crossfades and saw discontinuities. Accurate enough to tell 220 Hz from
/// 440 Hz and a bent note from a straight one.
private func zeroCrossingFrequency(_ samples: [Float], from: Int, to: Int,
                                   sampleRate: Double) -> Double {
    let start = max(0, min(from, samples.count - 1))
    let end = max(start + 1, min(to, samples.count))
    var crossings = 0
    var previous = samples[start]
    for i in (start + 1)..<end {
        let value = samples[i]
        if previous <= 0 && value > 0 { crossings += 1 }
        previous = value
    }
    let seconds = Double(end - start) / sampleRate
    return seconds > 0 ? Double(crossings) / seconds : 0
}

private func pushMIDI(_ shared: Shared, status: Int32, note: Int32, value: Int32) {
    let head = shared.midiHead.pointee
    let index = Int(head % Int32(Shared.midiCapacity))
    shared.midiEvents[index] = MidiEvent(status: status, note: note, velocity: value, pad: 0)
    shared.midiHead.pointee = head + 1
}

private func makeVoice(_ shared: Shared) {
    shared.bpm.pointee = 120
    shared.masterGain.pointee = 0.85
    shared.trackParams[0] = TrackParams(waveform: 1, rootNote: 40, attack: 0.002, decay: 0.1,
                                        sustain: 0.6, release: 0.05, gate: 0.5,
                                        gain: 0.5, pan: 0)
    shared.volume[0] = 1
    shared.cutoff[0] = 18000
    shared.playing.pointee = 1
}

/// Puts a clip on the arrangement timeline (the only playback path now).
private func placeOnTimeline(_ shared: Shared, track: Int = 0, scene: Int = 0,
                             start: Int = 0, length: Int = 16) {
    shared.mode.pointee = 1
    shared.arrLength.pointee = max(shared.arrLength.pointee, Int32(start + length))
    shared.tlCount[track] = 1
    let base = track * Shared.maxTimeline
    shared.tlStart[base] = Int32(start)
    shared.tlLen[base] = Int32(length)
    shared.tlScene[base] = Int32(scene)
    shared.tlOffset[base] = 0
}

/// Writes one polyphonic note into clip 0 (base index 0 in the flat note arrays).
private func addNote(_ shared: Shared, index: Int, start: Int, pitch: Int,
                     length: Int = 1, velocity: Int = 110) {
    shared.noteStart[index] = Int32(start)
    shared.noteLen[index] = Int32(length)
    shared.notePitch[index] = UInt8(pitch)
    shared.noteVel[index] = UInt8(velocity)
}


/// Hosts an Apple AU generator (DLS synth) and checks it produces signal for timeline notes.
/// Skipped (treated as passing) when no AU instrument is installed.
private func instrumentTest(rate: Double) -> Bool {
    let candidates = PluginSlot.availableInstruments()
    guard let pick = candidates.first(where: {
        $0.subtype == kAudioUnitSubType_DLSSynth && $0.manufacturer == kAudioUnitManufacturer_Apple
    }) ?? candidates.first else {
        print("au instrument  : skipped (no AU generator found)")
        return true
    }
    guard let slot = InstrumentSlot(component: pick.component, sampleRate: rate), slot.isReady else {
        print("au instrument  : skipped (\(pick.name) would not initialise)")
        return true
    }

    let shared = Shared()
    makeVoice(shared)
    shared.noteCount[0] = 1
    addNote(shared, index: 0, start: 0, pitch: 60, length: 4, velocity: 120)
    shared.loops[0] = 16
    shared.hasClip[0] = 1
    placeOnTimeline(shared)
    shared.instPtr[0] = Unmanaged.passUnretained(slot).toOpaque()
    shared.instOn[0] = 1

    let renderer = Renderer(shared: shared, sampleRate: rate)
    let result = withExtendedLifetime(slot) {
        renderRun(renderer: renderer, seconds: 1.2, sampleRate: rate,
                  windows: [(0, 48_000)])
    }

    print("au instrument  : \(pick.name)")
    print("au inst peak   : \(String(format: "%.4f", result.overall))")
    print("au inst finite : \(result.finite)")

    return result.finite && result.overall > 0.01
}

/// Hosts a real Apple Audio Unit on track 0 and checks audio still comes out.
/// Skipped (treated as passing) when the machine has no suitable AU installed.
private func pluginTest(rate: Double) -> Bool {
    let candidates = PluginSlot.availableEffects()
    let pick = candidates.first { $0.name.uppercased().contains("GRAPHICEQ") }
        ?? candidates.first { $0.name.uppercased().contains("PEAKLIMITER") }
    guard let descriptor = pick else {
        print("au insert      : skipped (no EQ/limiter AU found)")
        return true
    }
    guard let slot = PluginSlot(component: descriptor.component, sampleRate: rate), slot.isReady else {
        print("au insert      : skipped (\(descriptor.name) would not initialise)")
        return true
    }

    let shared = Shared()
    makeVoice(shared)
    shared.noteCount[0] = 1
    addNote(shared, index: 0, start: 0, pitch: 40, length: 16, velocity: 120)
    shared.loops[0] = 16
    shared.hasClip[0] = 1
    placeOnTimeline(shared)
    shared.pluginPtr[0] = Unmanaged.passUnretained(slot).toOpaque()
    shared.pluginOn[0] = 1

    let renderer = Renderer(shared: shared, sampleRate: rate)
    let result = withExtendedLifetime(slot) {
        renderRun(renderer: renderer, seconds: 1, sampleRate: rate, windows: [(0, 48_000)])
    }

    print("au insert      : \(descriptor.name)")
    print("au peak        : \(String(format: "%.4f", result.overall))")
    print("au finite      : \(result.finite)")

    return result.finite && result.overall > 0.01
}

/// Offline render check: proves the step clock, polyphonic note triggering, the synth,
/// the FX chain, the arrangement timeline and an Audio Unit insert produce signal
/// where they should — without listening.
func runSelfTest() -> Int32 {
    let rate = 48_000.0
    var ok = true

    // MARK: session playback
    let shared = Shared()
    makeVoice(shared)
    shared.send[0] = 1          // exercise the send FX path
    shared.resonance[0] = 0.6
    shared.drive[0] = 1.5

    shared.noteCount[0] = 4
    for (i, step) in [0, 4, 8, 12].enumerated() {
        addNote(shared, index: i, start: step, pitch: 40)
    }
    shared.loops[0] = 16
    shared.hasClip[0] = 1
    placeOnTimeline(shared)

    let renderer = Renderer(shared: shared, sampleRate: rate)
    let session = renderRun(renderer: renderer, seconds: 1, sampleRate: rate,
                            windows: [(0, 48_000)])

    let playhead = Int(shared.playhead.pointee)
    let active = Int(shared.activeClip[0])
    let expectedSteps = 7   // 120 BPM at 48 kHz: 8 sixteenths in the first second

    print("session frames  : 48000")
    print("playhead step   : \(playhead) (expected \(expectedSteps))")
    print("active clip     : \(active) (expected 0)")
    print("session peak    : \(String(format: "%.4f", session.overall))")
    print("session finite  : \(session.finite)")

    ok = ok && playhead == expectedSteps && active == 0
    ok = ok && session.overall > 0.01 && session.overall < 4 && session.finite

    // MARK: playhead smoothness — the fraction into the current step must track the clock
    let ph = Shared()
    makeVoice(ph)
    let phRenderer = Renderer(shared: ph, sampleRate: rate)
    _ = renderRun(renderer: phRenderer, seconds: 0.3, sampleRate: rate, windows: [])
    let phStep = Int(ph.playhead.pointee)
    let phFrac = ph.playheadFrac.pointee
    print("playhead step   : \(phStep) (expected 2)")
    print("playhead frac   : \(String(format: "%.3f", phFrac)) (0..1, expected ~0.39)")
    ok = ok && phStep == 2 && phFrac > 0.2 && phFrac < 0.6

    // MARK: fractional timing — a BPM whose step length is not a whole number of samples
    let precise = Shared()
    makeVoice(precise)
    precise.bpm.pointee = 123
    let preciseRenderer = Renderer(shared: precise, sampleRate: rate)
    _ = renderRun(renderer: preciseRenderer, seconds: 1, sampleRate: rate, windows: [])
    let precisePosition = Double(precise.playhead.pointee) + Double(precise.playheadFrac.pointee)
    // renderRun deliberately renders whole 512-frame blocks.
    let preciseFrames = Double((Int(1.0 * rate) / 512) * 512)
    let preciseExpected = preciseFrames * 123.0 * 4.0 / (60.0 * rate)
    print("precise step    : \(String(format: "%.9f", precisePosition)) (expected \(preciseExpected))")
    ok = ok && abs(precisePosition - preciseExpected) < 0.000_001

    // MARK: piano roll key audition — sounds while stopped, releases on mouse up
    let audition = Shared()
    makeVoice(audition)
    audition.playing.pointee = 0          // audition must not need the transport
    audition.previewTrack.pointee = 0
    audition.previewPitch.pointee = 60
    audition.previewVel.pointee = 110
    audition.previewOnSeq.pointee = 1
    let auditionRenderer = Renderer(shared: audition, sampleRate: rate)
    let auditionOn = renderRun(renderer: auditionRenderer, seconds: 0.4, sampleRate: rate,
                               windows: [(0, 19_200)])
    audition.previewOffSeq.pointee = 1
    let auditionOff = renderRun(renderer: auditionRenderer, seconds: 0.6, sampleRate: rate,
                                windows: [(26_880, 28_800)])
    print("audition peak   : \(String(format: "%.4f", auditionOn.overall)) (expected > 0.01)")
    print("audition tail   : \(String(format: "%.4f", auditionOff.peaks[0])) (expected ~0)")
    ok = ok && auditionOn.overall > 0.01 && auditionOn.finite
    ok = ok && auditionOff.peaks[0] < 0.002

    // MARK: audio clip playback — natural rate, clip-start fade, no runaway gain
    let sampleShared = Shared()
    makeVoice(sampleShared)
    let sampleFrames = 48_000
    let sampleBuffer = UnsafeMutablePointer<Float>.allocate(capacity: sampleFrames)
    for i in 0..<sampleFrames {
        sampleBuffer[i] = Float(sin(2.0 * Double.pi * 220.0 * Double(i) / rate)) * 0.6
    }
    sampleShared.samplePtr[0] = sampleBuffer
    sampleShared.sampleLen[0] = Int32(sampleFrames)
    sampleShared.clipSample[0] = 0
    sampleShared.clipSampleGain[0] = 1
    sampleShared.clipSampleStart[0] = 0
    sampleShared.clipFadeIn[0] = 0.05
    sampleShared.clipFadeOut[0] = 0.1
    sampleShared.mode.pointee = 1
    sampleShared.arrLength.pointee = 64
    sampleShared.tlCount[0] = 1
    sampleShared.tlStart[0] = 0
    sampleShared.tlLen[0] = 8
    sampleShared.tlScene[0] = 0
    sampleShared.tlOffset[0] = 0
    sampleShared.loops[0] = 8
    sampleShared.hasClip[0] = 1
    let sampleRenderer = Renderer(shared: sampleShared, sampleRate: rate)
    let sampleRun = renderRun(renderer: sampleRenderer, seconds: 1, sampleRate: rate,
                              windows: [(0, 1200), (12_000, 24_000), (46_800, 47_800)])
    sampleBuffer.deallocate()
    print("sample fade-in  : \(String(format: "%.4f", sampleRun.peaks[0])) (expected quieter)")
    print("sample body     : \(String(format: "%.4f", sampleRun.peaks[1])) (expected > 0.01)")
    print("sample clip-end : \(String(format: "%.4f", sampleRun.peaks[2])) (expected quieter)")
    print("sample finite   : \(sampleRun.finite)")
    ok = ok && sampleRun.peaks[0] < sampleRun.peaks[1] * 0.5
    ok = ok && sampleRun.peaks[1] > 0.01 && sampleRun.finite
    ok = ok && sampleRun.peaks[2] < sampleRun.peaks[1] * 0.5

    // MARK: tempo-following audio — warp reads the source faster when the song is faster
    let warpShared = Shared()
    makeVoice(warpShared)
    warpShared.bpm.pointee = 120
    let warpFrames = 48_000
    let warpBuffer = UnsafeMutablePointer<Float>.allocate(capacity: warpFrames)
    for i in 0..<warpFrames {
        warpBuffer[i] = Float(sin(2.0 * Double.pi * 220.0 * Double(i) / rate)) * 0.6
    }
    warpShared.samplePtr[0] = warpBuffer
    warpShared.sampleLen[0] = Int32(warpFrames)
    warpShared.clipSample[0] = 0
    warpShared.clipSampleGain[0] = 1
    warpShared.clipSampleStart[0] = 0
    warpShared.clipFadeIn[0] = 0
    warpShared.clipFadeOut[0] = 0
    warpShared.clipSampleBPM[0] = 60
    warpShared.clipWarp[0] = 1
    warpShared.mode.pointee = 1
    warpShared.arrLength.pointee = 64
    warpShared.tlCount[0] = 1
    warpShared.tlStart[0] = 0
    warpShared.tlLen[0] = 16
    warpShared.tlScene[0] = 0
    warpShared.tlOffset[0] = 0
    warpShared.loops[0] = 16
    warpShared.hasClip[0] = 1
    let warpRenderer = Renderer(shared: warpShared, sampleRate: rate)
    let warpRun = renderRun(renderer: warpRenderer, seconds: 1, sampleRate: rate,
                            windows: [(12_000, 18_000), (31_200, 40_800)])
    warpBuffer.deallocate()
    print("warp body       : \(String(format: "%.4f", warpRun.peaks[0])) (expected > 0.01)")
    print("warp end        : \(String(format: "%.4f", warpRun.peaks[1])) (expected ~0 at 2x)")
    ok = ok && warpRun.peaks[0] > 0.01 && warpRun.peaks[1] < 0.002 && warpRun.finite

    // MARK: pitch-preserving stretch — 2x tempo, but the tone must still be 220 Hz
    let stretchShared = Shared()
    makeVoice(stretchShared)
    stretchShared.bpm.pointee = 120
    let stretchFrames = 48_000
    let stretchBuffer = UnsafeMutablePointer<Float>.allocate(capacity: stretchFrames)
    for i in 0..<stretchFrames {
        stretchBuffer[i] = Float(sin(2.0 * Double.pi * 220.0 * Double(i) / rate)) * 0.6
    }
    stretchShared.samplePtr[0] = stretchBuffer
    stretchShared.sampleLen[0] = Int32(stretchFrames)
    stretchShared.clipSample[0] = 0
    stretchShared.clipSampleGain[0] = 1
    stretchShared.clipSampleStart[0] = 0
    stretchShared.clipFadeIn[0] = 0
    stretchShared.clipFadeOut[0] = 0
    stretchShared.clipSampleBPM[0] = 60
    stretchShared.clipWarp[0] = 1
    stretchShared.clipStretch[0] = 1
    stretchShared.mode.pointee = 1
    stretchShared.arrLength.pointee = 64
    placeOnTimeline(stretchShared, length: 8)
    stretchShared.loops[0] = 8
    stretchShared.hasClip[0] = 1
    let stretchRenderer = Renderer(shared: stretchShared, sampleRate: rate)
    let stretchRun = renderSamples(renderer: stretchRenderer,
                                  seconds: 0.4, sampleRate: rate)
    stretchBuffer.deallocate()
    let stretchPitch = dominantFrequency(stretchRun, from: 12_000, to: 19_200,
                                         sampleRate: rate)
    print("stretch pitch   : \(String(format: "%.1f", stretchPitch)) Hz (expected 220)")
    ok = ok && abs(stretchPitch - 220) < 18

    // MARK: clip gain — the envelope must quiet the rendered audio, not just the UI
    let gainShared = Shared()
    makeVoice(gainShared)
    gainShared.bpm.pointee = 120
    let gainFrames = 96_000
    let gainBuffer = UnsafeMutablePointer<Float>.allocate(capacity: gainFrames)
    for i in 0..<gainFrames {
        gainBuffer[i] = Float(sin(2.0 * Double.pi * 220.0 * Double(i) / rate)) * 0.6
    }
    gainShared.samplePtr[0] = gainBuffer
    gainShared.sampleLen[0] = Int32(gainFrames)
    gainShared.clipSample[0] = 0
    gainShared.clipSampleGain[0] = 1
    gainShared.clipFadeIn[0] = 0
    gainShared.clipFadeOut[0] = 0
    gainShared.mode.pointee = 1
    gainShared.arrLength.pointee = 64
    placeOnTimeline(gainShared, length: 16)
    gainShared.loops[0] = 16
    gainShared.hasClip[0] = 1
    gainShared.clipGainCount[0] = 2
    gainShared.clipGainStep[0] = 0
    gainShared.clipGainValue[0] = 0.5        // unity
    gainShared.clipGainStep[1] = 8
    gainShared.clipGainValue[1] = 0.05       // -26 dB
    let gainRun = renderRun(renderer: Renderer(shared: gainShared, sampleRate: rate),
                            seconds: 1.4, sampleRate: rate,
                            windows: [(0, 14_400), (52_800, 67_200)])
    gainBuffer.deallocate()
    print("clip gain early : \(String(format: "%.4f", gainRun.peaks[0]))")
    print("clip gain late  : \(String(format: "%.4f", gainRun.peaks[1])) (expected much quieter)")
    ok = ok && gainRun.peaks[0] > 0.3
    ok = ok && gainRun.peaks[1] > 0.002 && gainRun.peaks[1] < gainRun.peaks[0] * 0.35

    // MARK: comp regions — the second region must play a different take's audio
    let compShared = Shared()
    makeVoice(compShared)
    compShared.bpm.pointee = 120
    let compFrames = 96_000
    let compLoud = UnsafeMutablePointer<Float>.allocate(capacity: compFrames)
    let compQuiet = UnsafeMutablePointer<Float>.allocate(capacity: compFrames)
    for i in 0..<compFrames {
        let tone = Float(sin(2.0 * Double.pi * 220.0 * Double(i) / rate))
        compLoud[i] = tone * 0.6
        compQuiet[i] = tone * 0.06
    }
    compShared.samplePtr[0] = compLoud
    compShared.sampleLen[0] = Int32(compFrames)
    compShared.samplePtr[1] = compQuiet
    compShared.sampleLen[1] = Int32(compFrames)
    compShared.clipSample[0] = 0
    compShared.clipSampleGain[0] = 1
    compShared.clipFadeIn[0] = 0
    compShared.clipFadeOut[0] = 0
    compShared.clipRegionCount[0] = 1
    compShared.clipRegionStart[0] = 8
    compShared.clipRegionEnd[0] = 16
    compShared.clipRegionSlot[0] = 1
    compShared.mode.pointee = 1
    compShared.arrLength.pointee = 64
    placeOnTimeline(compShared, length: 16)
    compShared.loops[0] = 16
    compShared.hasClip[0] = 1
    let compRun = renderRun(renderer: Renderer(shared: compShared, sampleRate: rate),
                            seconds: 1.4, sampleRate: rate,
                            windows: [(0, 24_000), (52_800, 67_200)])
    compLoud.deallocate()
    compQuiet.deallocate()
    print("comp take one   : \(String(format: "%.4f", compRun.peaks[0]))")
    print("comp take two   : \(String(format: "%.4f", compRun.peaks[1])) (expected quieter)")
    ok = ok && compRun.peaks[0] > 0.3
    ok = ok && compRun.peaks[1] > 0.002 && compRun.peaks[1] < compRun.peaks[0] * 0.3

    // MARK: arpeggiator — one note per tick, quieter than the full chord
    let arp = Shared()
    makeVoice(arp)
    arp.noteCount[0] = 3
    addNote(arp, index: 0, start: 0, pitch: 40, length: 16)
    addNote(arp, index: 1, start: 0, pitch: 44, length: 16)
    addNote(arp, index: 2, start: 0, pitch: 47, length: 16)
    arp.loops[0] = 16
    arp.hasClip[0] = 1
    arp.arpMode[0] = 1     // up
    arp.arpRate[0] = 1     // one tick per sixteenth
    placeOnTimeline(arp)
    let arpRun = renderRun(renderer: Renderer(shared: arp, sampleRate: rate),
                           seconds: 0.6, sampleRate: rate, windows: [(0, 28_800)])
    let chord = Shared()
    makeVoice(chord)
    chord.noteCount[0] = 3
    addNote(chord, index: 0, start: 0, pitch: 40, length: 16)
    addNote(chord, index: 1, start: 0, pitch: 44, length: 16)
    addNote(chord, index: 2, start: 0, pitch: 47, length: 16)
    chord.loops[0] = 16
    chord.hasClip[0] = 1
    placeOnTimeline(chord)
    let chordRun = renderRun(renderer: Renderer(shared: chord, sampleRate: rate),
                             seconds: 0.6, sampleRate: rate, windows: [(0, 28_800)])
    print("arp peak        : \(String(format: "%.4f", arpRun.overall)) (expected single-note level)")
    print("chord peak      : \(String(format: "%.4f", chordRun.overall)) (expected higher)")
    ok = ok && arpRun.overall > 0.01 && arpRun.finite
    ok = ok && arpRun.overall < chordRun.overall

    // MARK: MPE — a bend on the note's channel must retune that note
    let mpe = Shared()
    makeVoice(mpe)
    mpe.arm[0] = 1
    pushMIDI(mpe, status: 0x92, note: 69, value: 110)
    let mpeRenderer = Renderer(shared: mpe, sampleRate: rate)
    let beforeBend = renderSamples(renderer: mpeRenderer,
                                   seconds: 0.25, sampleRate: rate)
    let mpeBefore = zeroCrossingFrequency(beforeBend, from: 4_000, to: 11_000, sampleRate: rate)
    pushMIDI(mpe, status: 0xE2, note: 127, value: 127)   // +2 semitones on channel 2
    let afterBend = renderSamples(renderer: mpeRenderer,
                                  seconds: 0.25, sampleRate: rate)
    let mpeAfter = zeroCrossingFrequency(afterBend, from: 4_000, to: 11_000, sampleRate: rate)
    print("mpe pitch before: \(String(format: "%.1f", mpeBefore)) Hz (expected 440)")
    print("mpe pitch after : \(String(format: "%.1f", mpeAfter)) Hz (expected ~494)")
    ok = ok && abs(mpeBefore - 440) < 20 && abs(mpeAfter - 494) < 24

    // MARK: polyphony — three notes starting on the same step must be louder than one
    let mono = Shared()
    makeVoice(mono)
    mono.noteCount[0] = 1
    addNote(mono, index: 0, start: 0, pitch: 40, length: 16)
    mono.loops[0] = 16
    mono.hasClip[0] = 1
    placeOnTimeline(mono)
    let monoRun = renderRun(renderer: Renderer(shared: mono, sampleRate: rate),
                            seconds: 0.5, sampleRate: rate, windows: [(0, 24_000)])

    let poly = Shared()
    makeVoice(poly)
    poly.noteCount[0] = 3
    addNote(poly, index: 0, start: 0, pitch: 40, length: 16)
    addNote(poly, index: 1, start: 0, pitch: 44, length: 16)
    addNote(poly, index: 2, start: 0, pitch: 47, length: 16)
    poly.loops[0] = 16
    poly.hasClip[0] = 1
    placeOnTimeline(poly)
    let polyRun = renderRun(renderer: Renderer(shared: poly, sampleRate: rate),
                            seconds: 0.5, sampleRate: rate, windows: [(0, 24_000)])

    print("mono peak       : \(String(format: "%.4f", monoRun.overall))")
    print("poly peak       : \(String(format: "%.4f", polyRun.overall)) (expected higher)")

    ok = ok && polyRun.overall > monoRun.overall * 1.05 && polyRun.finite

    // MARK: arrangement timeline
    // One placement at bar 3 (steps 32...47) of a 4-bar pattern, nothing before bar 3.
    let tshared = Shared()
    makeVoice(tshared)
    tshared.noteCount[0] = 2
    addNote(tshared, index: 0, start: 0, pitch: 40, length: 2, velocity: 120)
    addNote(tshared, index: 1, start: 8, pitch: 47, length: 2, velocity: 120)
    tshared.loops[0] = 16
    tshared.hasClip[0] = 1

    tshared.mode.pointee = 1
    tshared.arrLength.pointee = 64
    tshared.tlCount[0] = 1
    tshared.tlStart[0] = 32
    tshared.tlLen[0] = 16
    tshared.tlScene[0] = 0
    tshared.tlOffset[0] = 0

    let timelineRenderer = Renderer(shared: tshared, sampleRate: rate)
    // 8 seconds = 4 bars at 120 BPM. 6000 samples per step at 48 kHz.
    let timeline = renderRun(renderer: timelineRenderer, seconds: 8, sampleRate: rate,
                             windows: [(0, 96_000),      // bars 1-2: nothing placed
                                       (192_000, 288_000), // bar 3: the placement
                                       (288_000, 384_000)]) // bar 4: placement has ended

    print("timeline empty  : \(String(format: "%.4f", timeline.peaks[0])) (expected 0)")
    print("timeline placed : \(String(format: "%.4f", timeline.peaks[1])) (expected > 0.01)")
    print("timeline after  : \(String(format: "%.4f", timeline.peaks[2])) (expected 0)")
    print("timeline finite : \(timeline.finite)")

    ok = ok && timeline.peaks[0] < 0.002
    ok = ok && timeline.peaks[1] > 0.01
    ok = ok && timeline.peaks[2] < 0.002
    ok = ok && timeline.finite

    // MARK: arrangement loop brace
    let loopShared = Shared()
    makeVoice(loopShared)
    loopShared.noteCount[0] = 1
    addNote(loopShared, index: 0, start: 0, pitch: 40, length: 1, velocity: 120)
    loopShared.loops[0] = 16
    loopShared.hasClip[0] = 1
    loopShared.mode.pointee = 1
    loopShared.arrLength.pointee = 64
    loopShared.loopStart.pointee = 0
    loopShared.loopLength.pointee = 8
    loopShared.loopEnabled.pointee = 1
    placeOnTimeline(loopShared, start: 0, length: 16)

    let loopRenderer = Renderer(shared: loopShared, sampleRate: rate)
    let loopBuffer = AudioBufferList.allocate(maximumBuffers: 2)
    loopBuffer.count = 2
    for i in 0..<2 {
        loopBuffer[i].mNumberChannels = 1
        loopBuffer[i].mDataByteSize = UInt32(512 * MemoryLayout<Float>.size)
        loopBuffer[i].mData = UnsafeMutableRawPointer.allocate(byteCount: 512 * MemoryLayout<Float>.size,
                                                              alignment: 16)
    }
    var maxLoopStep = 0
    var loopPeak: Float = 0
    for _ in 0..<240 {
        _ = loopRenderer.render(frames: 512, abl: loopBuffer.unsafeMutablePointer)
        maxLoopStep = max(maxLoopStep, Int(loopShared.playhead.pointee))
        let data = loopBuffer[0].mData!.assumingMemoryBound(to: Float.self)
        for i in 0..<512 { loopPeak = max(loopPeak, abs(data[i])) }
    }
    for i in 0..<2 { loopBuffer[i].mData?.deallocate() }
    free(loopBuffer.unsafeMutablePointer)
    print("loop max step   : \(maxLoopStep) (expected < 8)")
    print("loop peak       : \(String(format: "%.4f", loopPeak))")
    ok = ok && maxLoopStep < 8 && loopPeak > 0.01

    // MARK: Audio Unit instrument
    ok = ok && instrumentTest(rate: rate)

    // MARK: Audio Unit insert
    ok = ok && pluginTest(rate: rate)

    print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
    return ok ? 0 : 1
}
