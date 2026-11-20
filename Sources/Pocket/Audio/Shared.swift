import Foundation

/// Per-track fixed parameters (set once at project load).
struct TrackParams: Codable {
    var waveform: Int32 = 1     // 0 = sine, 1 = saw, 2 = square
    var rootNote: Int32 = 60
    var attack: Float = 0.005
    var decay: Float = 0.2
    var sustain: Float = 0.5
    var release: Float = 0.2
    var gate: Float = 0.5
    var gain: Float = 0.3
    var pan: Float = 0
}

struct MidiEvent {
    var status: Int32 = 0
    var note: Int32 = 0
    var velocity: Int32 = 0
    var pad: Int32 = 0
}

/// One flat block of memory shared by the UI thread and the audio thread.
///
/// The UI only performs plain 32/64-bit loads and stores here, which are atomic on the
/// platforms we support. The audio thread never allocates, never locks, and never touches
/// a Swift collection — that is what keeps the render callback realtime-safe.
final class Shared: @unchecked Sendable {
    static let maxTracks = 16
    static let sceneCount = 64   // clip slots per track (one per timeline clip)
    static let maxSteps = 64
    static let maxNotes = 96          // notes per clip
    static let sampleSlots = 64
    static let maxTimeline = 64       // clips per track on the arrangement timeline
    static let maxAutoSteps = 65_536   // long-form songs: ~2.4 hours at 112 BPM in 4/4
    static let midiCapacity = 256
    static let maxInserts = 2         // plugin slots per track
    static let maxGroups = 4          // fixed group buses, 0 = master
    static let maxWarpMarkers = 8     // per clip
    static let maxCompRegions = 8     // comped take regions per clip
    static let maxClipPoints = 16     // clip gain envelope points
    static let arpChordMax = 8
    static let inputRingFrames = 32_768

    // MARK: transport (UI writes)
    var bpm: UnsafeMutablePointer<Double>
    var masterGain: UnsafeMutablePointer<Float>
    var returnLevel: UnsafeMutablePointer<Float>   // return A (tempo delay)
    var returnLevelB: UnsafeMutablePointer<Float>  // return B (reverb)
    var playing: UnsafeMutablePointer<Int32>
    var mode: UnsafeMutablePointer<Int32>          // 0 = session, 1 = arrangement
    var muteMask: UnsafeMutablePointer<Int32>
    var soloMask: UnsafeMutablePointer<Int32>
    var trackCount: UnsafeMutablePointer<Int32>

    var pending: UnsafeMutableBufferPointer<Int32> // per track x scene: launch request
    var stopReq: UnsafeMutableBufferPointer<Int32> // per track

    // MARK: clip patterns (polyphonic note lists)
    var noteCount: UnsafeMutableBufferPointer<Int32>        // per clip
    var noteStart: UnsafeMutableBufferPointer<Int32>        // clip x maxNotes, steps
    var noteLen: UnsafeMutableBufferPointer<Int32>          // clip x maxNotes, steps
    var notePitch: UnsafeMutableBufferPointer<UInt8>        // semitone offset from root
    var noteVel: UnsafeMutableBufferPointer<UInt8>
    var noteProb: UnsafeMutableBufferPointer<UInt8>        // 0...100
    var noteGroove: UnsafeMutableBufferPointer<Float>      // fraction of one step, 0...0.9
    var loops: UnsafeMutableBufferPointer<Int32>
    var hasClip: UnsafeMutableBufferPointer<UInt8>
    var trackParams: UnsafeMutableBufferPointer<TrackParams>

    // MARK: clip samples
    var clipSample: UnsafeMutableBufferPointer<Int32>      // pool slot, -1 = none
    var clipSampleGain: UnsafeMutableBufferPointer<Float>
    var clipSampleStart: UnsafeMutableBufferPointer<Float>  // 0..1 offset into the sample
    var clipFadeIn: UnsafeMutableBufferPointer<Float>      // seconds
    var clipFadeOut: UnsafeMutableBufferPointer<Float>     // seconds
    var clipSampleBPM: UnsafeMutableBufferPointer<Float>   // tempo the file was placed at
    var clipWarp: UnsafeMutableBufferPointer<Int32>        // follow the song tempo
    var clipReverse: UnsafeMutableBufferPointer<Int32>     // read the file backwards
    var clipWarpCount: UnsafeMutableBufferPointer<Int32>   // warp anchors per clip
    var clipWarpTimeline: UnsafeMutableBufferPointer<Float> // clip x maxWarpMarkers, steps
    var clipWarpSource: UnsafeMutableBufferPointer<Float>   // clip x maxWarpMarkers, seconds
    /// 1 = pitch-preserving time-stretch (granular), 0 = repitch when warp is on.
    var clipStretch: UnsafeMutableBufferPointer<Int32>
    /// Comped take regions: local clip steps -> pool slot. The last matching region wins.
    var clipRegionCount: UnsafeMutableBufferPointer<Int32>
    var clipRegionStart: UnsafeMutableBufferPointer<Float>  // clip x maxCompRegions, steps
    var clipRegionEnd: UnsafeMutableBufferPointer<Float>
    var clipRegionSlot: UnsafeMutableBufferPointer<Int32>
    /// Per-clip gain envelope, stored normalized 0...1 (0.5 = unity, mapped to 0...2 gain).
    var clipGainCount: UnsafeMutableBufferPointer<Int32>
    var clipGainStep: UnsafeMutableBufferPointer<Float>     // clip x maxClipPoints, local steps
    var clipGainValue: UnsafeMutableBufferPointer<Float>
    var samplePtr: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>?>
    /// Right channel for stereo files; nil means the sample is mono and samplePtr is used.
    var samplePtrR: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>?>
    var sampleLen: UnsafeMutableBufferPointer<Int32>

    // MARK: live mix controls (UI writes, smoothed in the renderer)
    var volume: UnsafeMutableBufferPointer<Float>
    var baseVolume: UnsafeMutableBufferPointer<Float>
    var groupOf: UnsafeMutableBufferPointer<Int32>          // 0 = master, 1...maxGroups
    var groupVolume: UnsafeMutableBufferPointer<Float>      // indexed by group, [0] unused
    var groupPan: UnsafeMutableBufferPointer<Float>
    var baseSend: UnsafeMutableBufferPointer<Float>
    var sendB: UnsafeMutableBufferPointer<Float>
    var baseSendB: UnsafeMutableBufferPointer<Float>
    var baseCutoff: UnsafeMutableBufferPointer<Float>
    var basePan: UnsafeMutableBufferPointer<Float>
    var send: UnsafeMutableBufferPointer<Float>
    var cutoff: UnsafeMutableBufferPointer<Float>
    var resonance: UnsafeMutableBufferPointer<Float>
    var drive: UnsafeMutableBufferPointer<Float>
    var arm: UnsafeMutableBufferPointer<Int32>
    var midiEffect: UnsafeMutableBufferPointer<Int32>      // MIDIEffect raw kind per track
    var arpMode: UnsafeMutableBufferPointer<Int32>          // 0 off, 1 up, 2 down, 3 up/down
    var arpRate: UnsafeMutableBufferPointer<Int32>          // steps between arp notes

    // MARK: live input monitoring (producer: AVAudioEngine input tap, consumer: renderer)
    var inputHead: UnsafeMutablePointer<Int32>
    var inputTail: UnsafeMutablePointer<Int32>
    var inputL: UnsafeMutableBufferPointer<Float>
    var inputR: UnsafeMutableBufferPointer<Float>
    var inputRate: UnsafeMutablePointer<Double>
    var monitorGain: UnsafeMutablePointer<Float>
    var monitorOn: UnsafeMutablePointer<Int32>
    var monitorTrack: UnsafeMutablePointer<Int32>

    // MARK: arrangement timeline
    var tlCount: UnsafeMutableBufferPointer<Int32>         // per track
    var tlStart: UnsafeMutableBufferPointer<Int32>         // track x maxTimeline, in steps
    var tlLen: UnsafeMutableBufferPointer<Int32>           // track x maxTimeline, in steps
    var tlScene: UnsafeMutableBufferPointer<Int32>         // track x maxTimeline, source session clip
    var tlOffset: UnsafeMutableBufferPointer<Int32>        // track x maxTimeline, source offset
    var arrLength: UnsafeMutablePointer<Int32>
    var loopStart: UnsafeMutablePointer<Int32>             // arrangement loop, in steps
    var loopLength: UnsafeMutablePointer<Int32>
    var loopEnabled: UnsafeMutablePointer<Int32>
    var seekTo: UnsafeMutablePointer<Int32>                // transport start / locator target
    var seekSeq: UnsafeMutablePointer<Int32>
    var autoVol: UnsafeMutableBufferPointer<Float>         // track x maxAutoSteps, -1 = none
    var autoPan: UnsafeMutableBufferPointer<Float>
    var autoSend: UnsafeMutableBufferPointer<Float>
    var autoSendB: UnsafeMutableBufferPointer<Float>
    var autoCutoff: UnsafeMutableBufferPointer<Float>

    // MARK: plugin inserts (Audio Units)
    var pluginPtr: UnsafeMutableBufferPointer<UnsafeMutableRawPointer?>  // track x maxInserts
    var pluginOn: UnsafeMutableBufferPointer<Int32>
    var pluginLatency: UnsafeMutableBufferPointer<Int32>  // track x maxInserts, frames

    // MARK: instrument (AU generator) per track
    var instPtr: UnsafeMutableBufferPointer<UnsafeMutableRawPointer?>
    var instOn: UnsafeMutableBufferPointer<Int32>
    var instrumentLatency: UnsafeMutableBufferPointer<Int32>  // frames

    // MARK: MIDI input ring
    var midiHead: UnsafeMutablePointer<Int32>
    var midiTail: UnsafeMutablePointer<Int32>
    var midiEvents: UnsafeMutableBufferPointer<MidiEvent>

    // MARK: note audition from the piano roll keyboard (UI writes)
    var previewOnSeq: UnsafeMutablePointer<Int32>
    var previewOffSeq: UnsafeMutablePointer<Int32>
    var previewPitch: UnsafeMutablePointer<Int32>
    var previewTrack: UnsafeMutablePointer<Int32>
    var previewVel: UnsafeMutablePointer<Int32>

    // MARK: audio -> UI
    var playhead: UnsafeMutablePointer<Int64>
    var playheadFrac: UnsafeMutablePointer<Float>    // 0..1 into the current step, for a smooth playhead
    var activeClip: UnsafeMutableBufferPointer<Int32>
    var trackLevel: UnsafeMutableBufferPointer<Float>

    init() {
        let tracks = Shared.maxTracks
        let clips = Shared.maxTracks * Shared.sceneCount

        bpm = Shared.allocPtr(1, 112.0)
        masterGain = Shared.allocPtr(1, Float(0.85))
        returnLevel = Shared.allocPtr(1, Float(0.85))
        returnLevelB = Shared.allocPtr(1, Float(0.85))
        playing = Shared.allocPtr(1, Int32(0))
        mode = Shared.allocPtr(1, Int32(0))
        muteMask = Shared.allocPtr(1, Int32(0))
        soloMask = Shared.allocPtr(1, Int32(0))
        trackCount = Shared.allocPtr(1, Int32(6))
        playhead = Shared.allocPtr(1, Int64(0))
        playheadFrac = Shared.allocPtr(1, Float(0))
        previewOnSeq = Shared.allocPtr(1, Int32(0))
        previewOffSeq = Shared.allocPtr(1, Int32(0))
        previewPitch = Shared.allocPtr(1, Int32(-1))
        previewTrack = Shared.allocPtr(1, Int32(0))
        previewVel = Shared.allocPtr(1, Int32(100))
        inputHead = Shared.allocPtr(1, Int32(0))
        inputTail = Shared.allocPtr(1, Int32(0))
        inputRate = Shared.allocPtr(1, Double(48_000))
        monitorGain = Shared.allocPtr(1, Float(1))
        monitorOn = Shared.allocPtr(1, Int32(0))
        monitorTrack = Shared.allocPtr(1, Int32(0))
        arrLength = Shared.allocPtr(1, Int32(64))
        loopStart = Shared.allocPtr(1, Int32(0))
        loopLength = Shared.allocPtr(1, Int32(64))
        loopEnabled = Shared.allocPtr(1, Int32(1))
        seekTo = Shared.allocPtr(1, Int32(0))
        seekSeq = Shared.allocPtr(1, Int32(0))
        midiHead = Shared.allocPtr(1, Int32(0))
        midiTail = Shared.allocPtr(1, Int32(0))

        pending = Shared.alloc(tracks * Shared.sceneCount, Int32(0))
        stopReq = Shared.alloc(tracks, Int32(0))

        noteCount = Shared.alloc(clips, Int32(0))
        noteStart = Shared.alloc(clips * Shared.maxNotes, Int32(0))
        noteLen = Shared.alloc(clips * Shared.maxNotes, Int32(1))
        notePitch = Shared.alloc(clips * Shared.maxNotes, UInt8(0))
        noteVel = Shared.alloc(clips * Shared.maxNotes, UInt8(0))
        noteProb = Shared.alloc(clips * Shared.maxNotes, UInt8(100))
        noteGroove = Shared.alloc(clips * Shared.maxNotes, Float(0))

        loops = Shared.alloc(clips, Int32(16))
        hasClip = Shared.alloc(clips, UInt8(0))
        trackParams = Shared.alloc(tracks, TrackParams())

        clipSample = Shared.alloc(clips, Int32(-1))
        clipSampleGain = Shared.alloc(clips, Float(0.9))
        clipSampleStart = Shared.alloc(clips, Float(0))
        clipFadeIn = Shared.alloc(clips, Float(0.005))
        clipFadeOut = Shared.alloc(clips, Float(0.005))
        clipSampleBPM = Shared.alloc(clips, Float(112))
        clipWarp = Shared.alloc(clips, Int32(0))
        clipReverse = Shared.alloc(clips, Int32(0))
        clipWarpCount = Shared.alloc(clips, Int32(0))
        clipWarpTimeline = Shared.alloc(clips * Shared.maxWarpMarkers, Float(0))
        clipWarpSource = Shared.alloc(clips * Shared.maxWarpMarkers, Float(0))
        clipStretch = Shared.alloc(clips, Int32(0))
        clipRegionCount = Shared.alloc(clips, Int32(0))
        clipRegionStart = Shared.alloc(clips * Shared.maxCompRegions, Float(0))
        clipRegionEnd = Shared.alloc(clips * Shared.maxCompRegions, Float(0))
        clipRegionSlot = Shared.alloc(clips * Shared.maxCompRegions, Int32(-1))
        clipGainCount = Shared.alloc(clips, Int32(0))
        clipGainStep = Shared.alloc(clips * Shared.maxClipPoints, Float(0))
        clipGainValue = Shared.alloc(clips * Shared.maxClipPoints, Float(0))
        samplePtr = Shared.alloc(Shared.sampleSlots, nil as UnsafeMutablePointer<Float>?)
        samplePtrR = Shared.alloc(Shared.sampleSlots, nil as UnsafeMutablePointer<Float>?)
        sampleLen = Shared.alloc(Shared.sampleSlots, Int32(0))

        volume = Shared.alloc(tracks, Float(1))
        baseVolume = Shared.alloc(tracks, Float(1))
        groupOf = Shared.alloc(tracks, Int32(0))
        groupVolume = Shared.alloc(Shared.maxGroups + 1, Float(1))
        groupPan = Shared.alloc(Shared.maxGroups + 1, Float(0))
        baseSend = Shared.alloc(tracks, Float(0))
        sendB = Shared.alloc(tracks, Float(0))
        baseSendB = Shared.alloc(tracks, Float(0))
        baseCutoff = Shared.alloc(tracks, Float(18000))
        basePan = Shared.alloc(tracks, Float(0))
        send = Shared.alloc(tracks, Float(0))
        cutoff = Shared.alloc(tracks, Float(18000))
        resonance = Shared.alloc(tracks, Float(0.1))
        drive = Shared.alloc(tracks, Float(1))
        arm = Shared.alloc(tracks, Int32(0))
        midiEffect = Shared.alloc(tracks, Int32(0))
        arpMode = Shared.alloc(tracks, Int32(0))
        arpRate = Shared.alloc(tracks, Int32(1))
        inputL = Shared.alloc(Shared.inputRingFrames, Float(0))
        inputR = Shared.alloc(Shared.inputRingFrames, Float(0))

        tlCount = Shared.alloc(tracks, Int32(0))
        tlStart = Shared.alloc(tracks * Shared.maxTimeline, Int32(0))
        tlLen = Shared.alloc(tracks * Shared.maxTimeline, Int32(0))
        tlScene = Shared.alloc(tracks * Shared.maxTimeline, Int32(-1))
        tlOffset = Shared.alloc(tracks * Shared.maxTimeline, Int32(0))
        autoVol = Shared.alloc(tracks * Shared.maxAutoSteps, Float(-1))
        autoPan = Shared.alloc(tracks * Shared.maxAutoSteps, Float(-1))
        autoSend = Shared.alloc(tracks * Shared.maxAutoSteps, Float(-1))
        autoSendB = Shared.alloc(tracks * Shared.maxAutoSteps, Float(-1))
        autoCutoff = Shared.alloc(tracks * Shared.maxAutoSteps, Float(-1))

        pluginPtr = Shared.alloc(tracks * Shared.maxInserts, nil as UnsafeMutableRawPointer?)
        pluginOn = Shared.alloc(tracks * Shared.maxInserts, Int32(0))
        pluginLatency = Shared.alloc(tracks * Shared.maxInserts, Int32(0))
        instPtr = Shared.alloc(tracks, nil as UnsafeMutableRawPointer?)
        instOn = Shared.alloc(tracks, Int32(0))
        instrumentLatency = Shared.alloc(tracks, Int32(0))

        midiEvents = Shared.alloc(Shared.midiCapacity, MidiEvent())
        activeClip = Shared.alloc(tracks, Int32(-1))
        trackLevel = Shared.alloc(tracks, Float(0))
    }

    deinit {
        bpm.deallocate()
        masterGain.deallocate()
        returnLevel.deallocate()
        returnLevelB.deallocate()
        playing.deallocate()
        mode.deallocate()
        muteMask.deallocate()
        soloMask.deallocate()
        trackCount.deallocate()
        playhead.deallocate()
        playheadFrac.deallocate()
        previewOnSeq.deallocate()
        previewOffSeq.deallocate()
        previewPitch.deallocate()
        previewTrack.deallocate()
        previewVel.deallocate()
        inputHead.deallocate()
        inputTail.deallocate()
        inputRate.deallocate()
        monitorGain.deallocate()
        monitorOn.deallocate()
        monitorTrack.deallocate()
        inputL.deallocate()
        inputR.deallocate()
        arrLength.deallocate()
        loopStart.deallocate()
        loopLength.deallocate()
        loopEnabled.deallocate()
        seekTo.deallocate()
        seekSeq.deallocate()
        midiHead.deallocate()
        midiTail.deallocate()
        pending.deallocate()
        stopReq.deallocate()
        noteCount.deallocate()
        noteStart.deallocate()
        noteLen.deallocate()
        notePitch.deallocate()
        noteVel.deallocate()
        noteProb.deallocate()
        noteGroove.deallocate()
        loops.deallocate()
        hasClip.deallocate()
        trackParams.deallocate()
        clipSample.deallocate()
        clipSampleGain.deallocate()
        clipSampleStart.deallocate()
        clipFadeIn.deallocate()
        clipFadeOut.deallocate()
        clipSampleBPM.deallocate()
        clipWarp.deallocate()
        clipReverse.deallocate()
        clipWarpCount.deallocate()
        clipWarpTimeline.deallocate()
        clipWarpSource.deallocate()
        clipStretch.deallocate()
        clipRegionCount.deallocate()
        clipRegionStart.deallocate()
        clipRegionEnd.deallocate()
        clipRegionSlot.deallocate()
        clipGainCount.deallocate()
        clipGainStep.deallocate()
        clipGainValue.deallocate()
        samplePtr.deallocate()
        samplePtrR.deallocate()
        sampleLen.deallocate()
        volume.deallocate()
        baseVolume.deallocate()
        groupOf.deallocate()
        groupVolume.deallocate()
        groupPan.deallocate()
        baseSend.deallocate()
        sendB.deallocate()
        baseSendB.deallocate()
        baseCutoff.deallocate()
        basePan.deallocate()
        send.deallocate()
        cutoff.deallocate()
        resonance.deallocate()
        drive.deallocate()
        arm.deallocate()
        midiEffect.deallocate()
        arpMode.deallocate()
        arpRate.deallocate()
        tlCount.deallocate()
        tlStart.deallocate()
        tlLen.deallocate()
        tlScene.deallocate()
        tlOffset.deallocate()
        autoVol.deallocate()
        autoPan.deallocate()
        autoSend.deallocate()
        autoSendB.deallocate()
        autoCutoff.deallocate()
        pluginPtr.deallocate()
        pluginOn.deallocate()
        pluginLatency.deallocate()
        instPtr.deallocate()
        instOn.deallocate()
        instrumentLatency.deallocate()
        midiEvents.deallocate()
        activeClip.deallocate()
        trackLevel.deallocate()
    }

    static func alloc<T>(_ count: Int, _ value: T) -> UnsafeMutableBufferPointer<T> {
        let raw = UnsafeMutablePointer<T>.allocate(capacity: count)
        raw.initialize(repeating: value, count: count)
        return UnsafeMutableBufferPointer(start: raw, count: count)
    }

    static func allocPtr<T>(_ count: Int, _ value: T) -> UnsafeMutablePointer<T> {
        let raw = UnsafeMutablePointer<T>.allocate(capacity: count)
        raw.initialize(repeating: value, count: count)
        return raw
    }

    @inline(__always) static func clipIndex(track: Int, scene: Int) -> Int {
        track * sceneCount + scene
    }
}
