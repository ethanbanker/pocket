import AppKit
import AVFoundation
import SwiftUI
import Combine
import UniformTypeIdentifiers

struct TrackInfo: Identifiable {
    let id: Int
    var name: String
    var color: Color
    var wave: String
}

struct ClipInfo {
    var exists = false
    var loopSteps = 16
    var notes: [NoteData] = []
    var samplePath: String? = nil
    var sampleName: String? = nil
    var sampleGain: Double = 0.9
    var sampleStart: Double = 0          // 0..1 into the file
    var sampleFadeIn: Double = 0.005     // seconds
    var sampleFadeOut: Double = 0.005    // seconds
    var sampleSourceBPM: Double = 112     // tempo the file was placed at
    var sampleWarp: Bool = false          // tempo-follow via repitching, never hidden
    var sampleReverse: Bool = false
    var takes: [AudioTake] = []
    var activeTake: Int = 0
    var warpMarkers: [WarpMarker] = []
    /// Pitch-preserving time-stretch when warp is on. Off means the older repitch behavior.
    var warpStretch: Bool = false
    var compRegions: [CompRegion] = []
    /// Clip gain automation in local steps, 0...1 normalized (0.5 = unity).
    var gainEnvelope: [AutomationPoint] = []
    var activeTakePath: String? {
        guard takes.indices.contains(activeTake) else { return nil }
        return takes[activeTake].path
    }
}

/// Small, real MIDI processors. They run in the sequencer before notes reach either the built-in
/// synth or a hosted AU, so playback and bounce use the same notes.
enum MIDIEffect: String, CaseIterable, Identifiable {
    case off, octave, fifth, chord
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "OFF"
        case .octave: return "+OCT"
        case .fifth: return "+5TH"
        case .chord: return "CHORD"
        }
    }
    var intervals: [Int] {
        switch self {
        case .off: return [0]
        case .octave: return [0, 12]
        case .fifth: return [0, 7]
        case .chord: return [0, 4, 7]
        }
    }

    var code: Int32 {
        switch self {
        case .off: return 0
        case .octave: return 1
        case .fifth: return 2
        case .chord: return 3
        }
    }
}

struct TrackFX {
    var volume: Double = 0.85
    var pan: Double = 0
    var send: Double = 0        // return A (tempo delay)
    var sendB: Double = 0       // return B (reverb)
    var cutoff: Double = 18000
    var resonance: Double = 0.1
    var drive: Double = 1
    var armed: Bool = false
    var group: Int = 0
    var midiEffect: MIDIEffect = .off
    var arpMode: ArpMode = .off
    var arpRate: ArpRate = .sixteenth
    var inputMonitor = false
}

struct Selection: Equatable {
    var track = 0
    var scene = 0
}

struct SessionSnapshot {
    var step: Int
    var active: [Int]
    var levels: [Float]
}

/// Piano roll drag in progress.
enum NoteDrag: Equatable {
    case idle
    case move(id: Int, start: Int, pitch: Int)
    case resize(id: Int, length: Int)
}

/// Timeline drag in progress. Kept off SwiftUI property wrappers, which this toolchain
/// cannot compile (no SwiftUI macro plugin in Command Line Tools).
enum ArrangementDrag: Equatable {
    case idle
    case move(id: Int, origin: Int)
    case resize(id: Int, origin: Int)
    case create(track: Int, startStep: Int)
}

/// Everything the arrangement editor can undo. Audio Unit objects are intentionally not part of
/// this: arrangement edits never load or unload a plugin.
struct ArrangementSnapshot {
    var tracks: [TrackInfo]
    var clips: [[ClipInfo]]
    var fx: [TrackFX]
    var timeline: [TimelineClip]
    var locators: [Locator]
    var loopStart: Int
    var loopLength: Int
    var loopEnabled: Bool
    var arrLength: Int
    var insertStep: Int
    var selectedClips: Set<Int>
    var inactiveClips: Set<Int>
    var selectedNote: Int?
    var selectedNotes: Set<Int>
    var automation: [Int: [AutomationPoint]]
    var panAutomation: [Int: [AutomationPoint]]
    var sendAutomation: [Int: [AutomationPoint]]
    var cutoffAutomation: [Int: [AutomationPoint]]
    var timeSigNumerator: Int
    var timeSigDenominator: Int
}

struct BrowserItem: Identifiable {
    let id: String
    let name: String
    let isFolder: Bool
}

final class SessionModel: ObservableObject {
    let shared = Shared()
    let interaction = ArrangementInteraction()
    var audio: AudioCore?
    private var samples: SamplePool?
    private(set) var inputMonitor: InputMonitor?
    private var captureTimer: DispatchSourceTimer?

    var nextNoteID = 1
    private var nextTakeID = 1
    private var nextClipID = 1
    private var openCaptureClips: [Int: Int] = [:]
    private var pluginSlots: [Int: PluginSlot] = [:]
    private var retiredPlugins: [PluginSlot] = []
    private var browserPreview: AVAudioPlayer?
    var audioRecorder: AVAudioRecorder?
    var recordStartStep = 0
    var recordClipIDs: [Int: Int] = [:]
    var recordNoteStarts: [Int: RecordedNote] = [:]
    var recordTrack: Int? = nil

    /// Rolling capture and MIDI CC learn are main-thread state. They are deliberately separate
    /// from the audio-thread ring so opening a menu can never block the render callback.
    @Published var capturedMIDIEvents: [CapturedMIDIEvent] = []
    @Published var midiCaptureCount = 0
    @Published var midiLearnTarget: MIDIMapTarget? = nil
    @Published var midiLearnTrack = 0
    @Published var midiMappings: [Int: MIDIMapping] = [:]
    private var cachedPlugins: [PluginSlot.Descriptor]?
    private var instrumentSlots: [Int: InstrumentSlot] = [:]
    private var retiredInstruments: [InstrumentSlot] = []
    private var cachedInstruments: [PluginSlot.Descriptor]?

    static let defaultStepsPerBar = 16
    static let maxPitch = 127

    static let palette: [Color] = [
        Color(red: 0.98, green: 0.62, blue: 0.26),
        Color(red: 0.36, green: 0.80, blue: 0.86),
        Color(red: 0.66, green: 0.52, blue: 0.98),
        Color(red: 0.35, green: 0.74, blue: 0.60),
        Color(red: 0.96, green: 0.48, blue: 0.62),
        Color(red: 0.95, green: 0.82, blue: 0.38),
        Color(red: 0.55, green: 0.72, blue: 0.98),
        Color(red: 0.86, green: 0.66, blue: 0.46)
    ]

    @Published var tracks: [TrackInfo]
    @Published var clips: [[ClipInfo]]
    @Published var fx: [TrackFX]
    @Published var inserts: [[String?]]
    @Published var instrumentNames: [String?]
    @Published var timeline: [TimelineClip] = []
    @Published var selectedTimeline: Int? = nil
    @Published var bpm: Double = 112
    @Published var master: Double = 0.85
    /// Global meter. Pocket keeps one meter for the song rather than pretending to support
    /// per-bar signature changes; bars, snapping, locators and time commands all use it.
    @Published var timeSigNumerator = 4
    @Published var timeSigDenominator = 4
    @Published var scaleRoot = 0
    @Published var scaleMode: ScaleMode = .chromatic

    /// A bar in sixteenth-note steps. 4/4 = 16, 3/4 = 12, 6/8 = 12, 7/8 = 14.
    var stepsPerBar: Int {
        max(1, timeSigNumerator * 16 / max(timeSigDenominator, 1))
    }

    /// Snap in steps, with BAR following the current meter instead of a hard-coded 4/4 bar.
    var snapSteps: Int {
        snap == .bar ? stepsPerBar : snap.steps
    }

    var beatsPerBar: Int { max(timeSigNumerator, 1) }
    @Published var isPlaying = false
    @Published var isArrangement = false
    @Published var muteMask = 0
    @Published var soloMask = 0
    @Published var selection = Selection()
    @Published var capturing = false
    @Published var arrLength = 64
    @Published var status = ""
    @Published var projectName = "Untitled"
    @Published var showBrowser = true
    @Published var browserPath: String = ""
    @Published var browserItems: [BrowserItem] = []
    @Published var browserSelection: String? = nil
    @Published var browserSearch = ""

    var filteredBrowserItems: [BrowserItem] {
        let query = browserSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return browserItems }
        return browserItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    @Published var selectedNote: Int? = nil
    @Published var selectedNotes: Set<Int> = []
    @Published var noteMarquee: CGRect? = nil
    @Published var noteMarqueeStart: CGPoint? = nil
    private var noteClipboard: [NoteData] = []
    private var noteDragSnapshot: [NoteData] = []
    /// The pane that owns keyboard commands. Arrangement, piano roll and browser each take focus
    /// when the user clicks in them, so a stale note cannot steal ⌘D or Delete.
    @Published var focus: PocketFocus = .arrangement
    /// Pitch currently held down on the piano roll keyboard, nil when nothing is pressed.
    @Published var auditionPitch: Int? = nil
    /// Bumped whenever a plugin parameter changes, so the device panel re-reads the AU.
    @Published var pluginRevision = 0

    // Arrangement workflow state.
    @Published var locators: [Locator] = []
    @Published var insertStep = 0
    @Published var timeSelection: TimeRange? = nil
    @Published var selectedClips: Set<Int> = []
    @Published var loopStart = 0
    @Published var loopLength = 64
    @Published var loopEnabled = true
    @Published var snap: SnapGrid = .sixteenth
    @Published var followPlayhead = false
    @Published var showAutomation = false
    @Published var automationTarget: AutomationTarget = .volume
    @Published var automation: [Int: [AutomationPoint]] = [:]
    @Published var panAutomation: [Int: [AutomationPoint]] = [:]
    @Published var sendAutomation: [Int: [AutomationPoint]] = [:]
    @Published var cutoffAutomation: [Int: [AutomationPoint]] = [:]
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var isBouncing = false
    @Published var isRecording = false
    @Published var recordMode: RecordMode = .midi
    @Published var audioOutputs: [AudioDeviceInfo] = []
    @Published var selectedAudioOutputUID: String? = nil
    @Published var audioHardwareRate: Double = AudioCore.renderSampleRate
    @Published var audioBufferFrames = 0
    @Published var audioLatencyMilliseconds = 0.0
    @Published var audioEngineName = AudioCore.engineName
    @Published var audioInputs: [AudioDeviceInfo] = []
    @Published var selectedAudioInputUID: String? = nil
    @Published var inputMonitoring = false
    @Published var recordingLatencyMilliseconds = 0.0
    @Published var groupVolumes = [Float](repeating: 1, count: Shared.maxGroups + 1)
    @Published var groupPans = [Float](repeating: 0, count: Shared.maxGroups + 1)
    @Published var returnLevel = 0.85
    @Published var returnLevelB = 0.85
    /// Automatic crossfades on adjacent audio clips after edits, and on drops.
    @Published var autoCrossfade = false
    private var undoStack: [ArrangementSnapshot] = []
    private var redoStack: [ArrangementSnapshot] = []
    private var nextLocatorID = 1
    private var gestureEditing = false
    private var clipClipboard: [(TimelineClip, ClipInfo)] = []
    private var inactiveClips: Set<Int> = []

    // Arrangement view state, held here so it survives SwiftUI view rebuilds.
    @Published var zoom: Double = 16
    @Published var ghost: CGRect? = nil
    /// True while a draw/move ghost would overlap an existing clip on the target lane.
    @Published var ghostBlocked = false
    /// First visible lane in the arrangement canvas, shared by the header and lane scrollers.
    @Published var laneTop: Int? = 0
    @Published var laneScroll: CGFloat = 0
    /// Horizontal viewport offset in pixels. The canvas is a real two-axis viewport now, so
    /// trackpad/mouse-wheel panning, the scrollbars and zooms all share one source of truth.
    @Published var timelineScroll: CGFloat = 0
    @Published var hoveredTrack: Int? = nil
    @Published var hoveredClipID: Int? = nil
    var arrangementCanvasFrame: CGRect = .zero
    var arrangementContentHeight: CGFloat = 0
    var arrangementContentWidth: CGFloat = 0
    var arrangementViewportHeight: CGFloat = 0
    var arrangementViewportWidth: CGFloat = 0
    /// Piano roll viewport, in MIDI note numbers. 60 = C4.
    @Published var rollFocusPitch = 60
    @Published var showEditor = true
    @Published var detailHeight: Double = 322
    var dragMode: ArrangementDrag = .idle
    var noteDrag: NoteDrag = .idle
    var editorDragStart: Double = 322
    var editorDragging = false
    var rollScrollStart: Double = 60
    var rollScrolling = false
    var pianoRollFrame: CGRect = .zero
    var noteEditBegan = false

    init() {
        // Start with one empty lane; the rest of the canvas is space you scroll into and draw on.
        tracks = [TrackInfo(id: 0, name: Self.defaultNames[0],
                            color: Self.palette[0], wave: "saw")]
        clips = Array(repeating: Array(repeating: ClipInfo(), count: Shared.sceneCount),
                      count: Shared.maxTracks)
        fx = Array(repeating: TrackFX(), count: Shared.maxTracks)
        inserts = Array(repeating: Array(repeating: nil, count: Shared.maxInserts),
                        count: Shared.maxTracks)
        instrumentNames = Array(repeating: nil, count: Shared.maxTracks)

        shared.trackCount.pointee = Int32(tracks.count)
        shared.trackParams[0] = TrackParams(waveform: 1, rootNote: 60, attack: 0.005,
                                            decay: 0.25, sustain: 0.45, release: 0.2,
                                            gate: 0.55, gain: 0.24, pan: 0)
        audio = AudioCore(shared: shared)
        audio?.onStateChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshAudioState() }
        }
        audio?.midi.onEvent = { [weak self] status, note, velocity in
            DispatchQueue.main.async {
                self?.handleMIDIEvent(status: status, note: Int(note), velocity: Int(velocity))
            }
        }
        refreshAudioState()
        if let uid = UserDefaults.standard.string(forKey: "PocketOutputDeviceUID"),
           let device = audioOutputs.first(where: { $0.uid == uid }) {
            try? audio?.selectOutputDevice(device.id)
            selectedAudioOutputUID = uid
            refreshAudioState()
        }
        if let rate = audio?.sampleRate {
            samples = SamplePool(shared: shared, sampleRate: rate)
        }
        inputMonitor = InputMonitor(shared: shared)
        if let uid = UserDefaults.standard.string(forKey: "PocketInputDeviceUID") {
            selectedAudioInputUID = uid
        }
        for g in 1...Shared.maxGroups {
            shared.groupVolume[g] = groupVolumes[g]
            shared.groupPan[g] = groupPans[g]
        }
        shared.returnLevel.pointee = Float(returnLevel)
        shared.returnLevelB.pointee = Float(returnLevelB)
        audio?.onSampleRateChange = { [weak self] rate in
            self?.rebuildAudioForSampleRate(rate)
        }
        audio?.onEngineFailure = { [weak self] message in
            self?.status = "audio engine: \(message)"
        }
        if let error = audio?.lastError {
            status = "audio engine: \(error)"
        }
        for t in 0..<tracks.count { pushFX(t) }
        syncTimeline()

        browserPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music").path
        refreshBrowser()
    }

    static let defaultNames = ["Track 1", "Track 2", "Track 3", "Track 4",
                               "Track 5", "Track 6", "Track 7", "Track 8",
                               "Track 9", "Track 10", "Track 11", "Track 12",
                               "Track 13", "Track 14", "Track 15", "Track 16"]
    static let defaultWaves = ["saw", "sqr", "saw", "sin", "sqr", "sin",
                               "saw", "sqr", "sin", "saw", "sqr", "sin",
                               "saw", "sqr", "sin", "saw"]

    // MARK: - Transport

    func togglePlay() {
        if isPlaying { stopTransport() } else { startTransport() }
    }

    func setTimeSignature(numerator: Int, denominator: Int) {
        let n = min(max(numerator, 1), 16)
        let d = [2, 4, 8, 16].contains(denominator) ? denominator : 4
        guard n != timeSigNumerator || d != timeSigDenominator else { return }
        pushUndo()
        let oldBar = stepsPerBar
        let bars = max(1, Int((Double(loopLength) / Double(max(oldBar, 1))).rounded()))
        timeSigNumerator = n
        timeSigDenominator = d
        loopLength = max(stepsPerBar, bars * stepsPerBar)
        arrLength = max(arrLength, stepsPerBar * 4)
        shared.arrLength.pointee = Int32(arrLength)
        syncLoop()
        syncTimeline()
        status = "time signature \(n)/\(d)"
    }

    func startTransport() {
        shared.seekTo.pointee = Int32(max(insertStep, 0))
        shared.playing.pointee = 1
        isPlaying = true
    }

    func stopTransport() {
        if isRecording { finishRecording() }
        shared.playing.pointee = 0
        isPlaying = false
        if capturing { capturing = false; stopCaptureTimer() }
    }

    func setBPM(_ value: Double) {
        let clamped = min(max(value, 60), 200)
        shared.bpm.pointee = clamped
        bpm = clamped
    }

    func setMaster(_ value: Double) {
        shared.masterGain.pointee = Float(min(max(value, 0), 1))
        master = value
    }

    var currentAudioOutputName: String {
        if let uid = selectedAudioOutputUID,
           let device = audioOutputs.first(where: { $0.uid == uid }) {
            return device.name
        }
        return audio?.currentOutputName ?? "System Default"
    }

    var audioRateLabel: String {
        let rate = audioHardwareRate > 0 ? audioHardwareRate : AudioCore.renderSampleRate
        return "\(Int(rate.rounded())) Hz"
    }

    var audioEngineLabel: String {
        audio?.engineLabel ?? "AUHAL · offline"
    }

    let audioBufferOptions = [64, 128, 256, 512, 1024, 2048]

    func refreshAudioState() {
        guard let audio else { return }
        audioOutputs = audio.outputDevices()
        audioInputs = AudioDevices.inputs()
        audioHardwareRate = audio.hardwareSampleRate
        audioBufferFrames = audio.bufferFrames
        audioLatencyMilliseconds = audio.latencyMilliseconds
        audioEngineName = AudioCore.engineName
    }

    // MARK: - Input and recording latency

    /// The selected interface is used by the monitoring engine and by audio takes. It is saved
    /// independently of the output so a singer can monitor through headphones on another device.
    func selectAudioInput(_ device: AudioDeviceInfo?) {
        selectedAudioInputUID = device?.uid
        if let uid = device?.uid {
            UserDefaults.standard.set(uid, forKey: "PocketInputDeviceUID")
        } else {
            UserDefaults.standard.removeObject(forKey: "PocketInputDeviceUID")
        }
        if inputMonitoring { restartInputMonitoring() }
        status = "audio input: \(device?.name ?? "System Default")"
    }

    func setInputMonitoring(_ enabled: Bool) {
        guard enabled != inputMonitoring else { return }
        inputMonitoring = enabled
        if enabled {
            requestInputAccess { [weak self] granted in
                guard let self else { return }
                if granted { self.restartInputMonitoring() }
                else {
                    self.inputMonitoring = false
                    self.status = "microphone access denied — enable it in System Settings › Privacy"
                }
            }
        } else {
            inputMonitor?.stop()
            shared.monitorOn.pointee = 0
            status = "input monitoring off"
        }
    }

    func setRecordingLatency(milliseconds: Double) {
        recordingLatencyMilliseconds = min(max(milliseconds, -500), 500)
        status = "record latency compensation \(String(format: "%.0f", recordingLatencyMilliseconds)) ms"
    }

    /// Positive values are milliseconds the captured performance arrived late. Negative values
    /// compensate for an interface that reports more latency than it actually has.
    var recordLatencySteps: Int {
        Int((recordingLatencyMilliseconds / 1000.0 * bpm / 60.0 * 4.0).rounded())
    }

    private func restartInputMonitoring() {
        guard let inputMonitor else { return }
        do {
            try inputMonitor.start(deviceUID: selectedAudioInputUID, monitor: true, recordTo: nil)
            shared.monitorTrack.pointee = Int32(min(max(selection.track, 0), tracks.count - 1))
            status = "monitoring \(audioInputs.first(where: { $0.uid == selectedAudioInputUID })?.name ?? "default input")"
        } catch {
            inputMonitoring = false
            status = "input monitoring failed: \(error.localizedDescription)"
        }
    }

    func requestInputAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func setMIDIEffect(_ effect: MIDIEffect, track: Int? = nil) {
        let index = min(max(track ?? selection.track, 0), tracks.count - 1)
        guard index < fx.count else { return }
        fx[index].midiEffect = effect
        shared.midiEffect[index] = effect.code
        status = "\(tracks[index].name) MIDI effect: \(effect.label)"
    }

    func selectAudioOutput(_ device: AudioDeviceInfo?) {
        guard let audio else { return }
        do {
            try audio.selectOutputDevice(device?.id)
            selectedAudioOutputUID = device?.uid
            if let uid = device?.uid {
                UserDefaults.standard.set(uid, forKey: "PocketOutputDeviceUID")
            } else {
                UserDefaults.standard.removeObject(forKey: "PocketOutputDeviceUID")
            }
            refreshAudioState()
            status = "audio output: \(device?.name ?? "System Default") · \(audio.engineLabel)"
        } catch {
            status = error.localizedDescription
            refreshAudioState()
        }
    }

    func setAudioBufferSize(_ frames: Int) {
        guard let audio else { return }
        do {
            try audio.setBufferSize(frames)
            refreshAudioState()
            status = "audio buffer: \(audio.bufferFrames) frames · \(String(format: "%.1f", audio.latencyMilliseconds)) ms I/O"
        } catch {
            status = error.localizedDescription
            refreshAudioState()
        }
    }

    /// Rebuild everything whose format is tied to the engine rate while the AUHAL unit is
    /// stopped. The decoded sample pool cannot be shared across sample rates, and AUv2/AUv3
    /// instances cannot be initialized at one rate and rendered at another.
    private func rebuildAudioForSampleRate(_ rate: Double) {
        let oldPaths = samples?.pathsBySlot ?? [:]
        samples = nil
        for slot in 0..<Shared.sampleSlots {
            shared.samplePtr[slot] = nil
            shared.samplePtrR[slot] = nil
            shared.sampleLen[slot] = 0
        }
        let pool = SamplePool(shared: shared, sampleRate: rate)
        for (_, path) in oldPaths.sorted(by: { $0.key < $1.key }) {
            _ = try? pool.load(path: path)
        }
        samples = pool
        for t in 0..<Shared.maxTracks {
            for s in 0..<Shared.sceneCount {
                guard t < clips.count, s < clips[t].count else { continue }
                let index = Shared.clipIndex(track: t, scene: s)
                if let path = clips[t][s].samplePath,
                   let slot = pool.slot(forPath: path) {
                    shared.clipSample[index] = Int32(slot)
                } else if clips[t][s].samplePath == nil {
                    shared.clipSample[index] = -1
                } else {
                    shared.clipSample[index] = -1
                }
            }
        }
        rebuildAudioUnits(at: rate)
        audioHardwareRate = rate
        refreshAudioState()
    }

    private func rebuildAudioUnits(at rate: Double) {
        AUWindowManager.shared.closeAll()
        let pluginDescriptors = pluginSlots.map { index, slot in
            (index, slot.name, slot.type, slot.subtype, slot.manufacturer, slot.fullState())
        }
        for (index, old) in pluginSlots {
            shared.pluginOn[index] = 0
            shared.pluginPtr[index] = nil
            retiredPlugins.append(old)
        }
        pluginSlots.removeAll()
        for (index, _, type, subtype, manufacturer, state) in pluginDescriptors {
            guard let component = PluginSlot.component(type: type, subtype: subtype,
                                                       manufacturer: manufacturer),
                  let instance = PluginSlot(component: component, sampleRate: rate),
                  instance.isReady else {
                inserts[index / Shared.maxInserts][index % Shared.maxInserts] = nil
                shared.pluginLatency[index] = 0
                continue
            }
            if let state { _ = instance.restoreState(state) }
            pluginSlots[index] = instance
            shared.pluginLatency[index] = Int32(instance.latencyFrames(at: rate))
            shared.pluginPtr[index] = Unmanaged.passUnretained(instance).toOpaque()
            shared.pluginOn[index] = 1
            inserts[index / Shared.maxInserts][index % Shared.maxInserts] = instance.name
        }

        let instrumentDescriptors = instrumentSlots.map { track, slot in
            (track, slot.name, slot.type, slot.subtype, slot.manufacturer, slot.fullState())
        }
        for (track, old) in instrumentSlots {
            shared.instOn[track] = 0
            shared.instPtr[track] = nil
            retiredInstruments.append(old)
        }
        instrumentSlots.removeAll()
        instrumentNames = Array(repeating: nil, count: Shared.maxTracks)
        for (track, _, type, subtype, manufacturer, state) in instrumentDescriptors {
            guard let component = PluginSlot.component(type: type, subtype: subtype,
                                                       manufacturer: manufacturer),
                  let instance = InstrumentSlot(component: component, sampleRate: rate),
                  instance.isReady else {
                shared.instrumentLatency[track] = 0
                continue
            }
            if let state { _ = instance.restoreState(state) }
            instrumentSlots[track] = instance
            shared.instrumentLatency[track] = Int32(instance.latencyFrames(at: rate))
            shared.instPtr[track] = Unmanaged.passUnretained(instance).toOpaque()
            shared.instOn[track] = 1
            instrumentNames[track] = instance.name
        }
    }

    func setArrangementMode(_ on: Bool) {
        isArrangement = on
        shared.mode.pointee = on ? 1 : 0
        if isPlaying { stopTransport(); startTransport() }
    }

    func toggleMute(_ track: Int) {
        muteMask ^= 1 << track
        shared.muteMask.pointee = Int32(muteMask)
    }

    func toggleSolo(_ track: Int) {
        soloMask ^= 1 << track
        shared.soloMask.pointee = Int32(soloMask)
    }

    // MARK: - Tracks

    func addTrack() {
        guard tracks.count < Shared.maxTracks else {
            status = "track limit reached (\(Shared.maxTracks))"
            return
        }
        let id = tracks.count
        tracks.append(TrackInfo(id: id, name: Self.defaultNames[id], color: Self.palette[id % Self.palette.count],
                                wave: Self.defaultWaves[id]))
        fx.append(TrackFX())
        inserts.append(Array(repeating: nil, count: Shared.maxInserts))
        shared.trackParams[id] = TrackParams(waveform: 1, rootNote: 60, attack: 0.005, decay: 0.25,
                                             sustain: 0.4, release: 0.2, gate: 0.5, gain: 0.22, pan: 0)
        shared.trackCount.pointee = Int32(tracks.count)
        pushFX(id)
        selection = Selection(track: id, scene: 0)
        focusArrangement()
        invalidateHistory()
        status = "added \(tracks[id].name)"
    }

    /// Clone the selected track and all of its material after it. Audio Unit instances are
    /// recreated from their component identity; plugin state is not copied because AUv2 has no
    /// generic state clone that is safe for every vendor.
    @discardableResult
    func duplicateTrack(at index: Int) -> Int? {
        guard tracks.count < Shared.maxTracks,
              index >= 0, index < tracks.count else {
            status = "track limit reached (\(Shared.maxTracks))"
            return nil
        }
        let sourceName = tracks[index].name
        let sourceColor = tracks[index].color
        let sourceWave = tracks[index].wave
        let sourceFX = fx[index]
        let sourceParams = shared.trackParams[index]
        let sourceClips = clips[index]
        let sourceTimeline = timeline.filter { $0.track == index }
        let sourceAutomation = automation[index] ?? []
        let sourceInstrument = instrumentData(index)
        let sourceInstrumentState = instrumentSlots[index]?.fullState()
        let sourceInsertStates = Dictionary(uniqueKeysWithValues: (0..<Shared.maxInserts).compactMap { slot in
            pluginInstance(track: index, slot: slot)?.fullState().map { (slot, $0) }
        })
        let sourceInserts: [(Int, PluginSlot.Descriptor)] = (0..<Shared.maxInserts).compactMap { slot in
            guard let instance = pluginInstance(track: index, slot: slot),
                  let component = PluginSlot.component(type: instance.type,
                                                       subtype: instance.subtype,
                                                       manufacturer: instance.manufacturer) else {
                return nil
            }
            return (slot, PluginSlot.Descriptor(name: instance.name, component: component,
                                                type: instance.type, subtype: instance.subtype,
                                                manufacturer: instance.manufacturer))
        }

        addTrack()
        guard let new = tracks.last?.id, new != index else { return nil }
        tracks[new].name = "\(sourceName) copy"
        tracks[new].color = sourceColor
        tracks[new].wave = sourceWave
        shared.trackParams[new] = sourceParams
        fx[new] = sourceFX
        pushFX(new)
        clips[new] = sourceClips
        for scene in 0..<Shared.sceneCount where clips[new][scene].exists {
            syncNotes(track: new, scene: scene)
            let src = Shared.clipIndex(track: index, scene: scene)
            let dst = Shared.clipIndex(track: new, scene: scene)
            shared.clipSample[dst] = shared.clipSample[src]
            shared.clipSampleStart[dst] = shared.clipSampleStart[src]
            shared.clipSampleGain[dst] = shared.clipSampleGain[src]
            shared.clipFadeIn[dst] = shared.clipFadeIn[src]
            shared.clipFadeOut[dst] = shared.clipFadeOut[src]
            shared.clipSampleBPM[dst] = shared.clipSampleBPM[src]
            shared.clipWarp[dst] = shared.clipWarp[src]
            shared.clipReverse[dst] = shared.clipReverse[src]
        }

        var copiedClips: Set<Int> = []
        for source in sourceTimeline {
            let copy = TimelineClip(id: nextClipID, track: new, scene: source.scene,
                                    start: source.start, length: source.length,
                                    offset: source.offset)
            nextClipID += 1
            timeline.append(copy)
            copiedClips.insert(copy.id)
        }
        if !sourceAutomation.isEmpty { automation[new] = sourceAutomation }

        if let instrument = sourceInstrument,
           let component = PluginSlot.component(type: instrument.type,
                                                subtype: instrument.subtype,
                                                manufacturer: instrument.manufacturer) {
            loadInstrument(track: new, descriptor: PluginSlot.Descriptor(
                name: instrument.name, component: component, type: instrument.type,
                subtype: instrument.subtype, manufacturer: instrument.manufacturer),
                state: sourceInstrumentState)
        }
        for (slot, descriptor) in sourceInserts {
            loadPlugin(track: new, slot: slot, descriptor: descriptor,
                       state: sourceInsertStates[slot])
        }

        selectedClips = copiedClips
        selectedTimeline = copiedClips.first
        selection = Selection(track: new, scene: copiedClips.first.flatMap {
            timelineClip(id: $0)?.scene
        } ?? 0)
        syncTimeline()
        invalidateHistory()
        status = "duplicated \(sourceName)"
        return new
    }

    @discardableResult
    func duplicateSelectedTrack() -> Int? {
        duplicateTrack(at: selection.track)
    }

    func removeLastTrack() {
        guard tracks.count > 1 else { return }
        let id = tracks.count - 1
        focusArrangement()
        audio?.releaseVoices(onTrack: id)
        shared.instOn[id] = 0
        shared.instPtr[id] = nil
        shared.instrumentLatency[id] = 0
        if let old = instrumentSlots[id] { retiredInstruments.append(old) }
        instrumentSlots[id] = nil
        instrumentNames[id] = nil
        AUWindowManager.shared.close(key: "inst-\(id)")
        shared.trackCount.pointee = Int32(id)
        shared.tlCount[id] = 0
        for k in 0..<Shared.maxInserts {
            let index = id * Shared.maxInserts + k
            shared.pluginOn[index] = 0
            shared.pluginPtr[index] = nil
            shared.pluginLatency[index] = 0
            if let old = pluginSlots[index] { retiredPlugins.append(old) }
            pluginSlots[index] = nil
        }
        shared.activeClip[id] = -1
        tracks.removeLast()
        fx.removeLast()
        inserts.removeLast()
        timeline.removeAll { $0.track == id }
        if selection.track >= tracks.count { selection = Selection(track: tracks.count - 1, scene: 0) }
        syncTimeline()
        invalidateHistory()
        status = "removed track \(id + 1)"
    }

    // MARK: - Clips

    func select(track: Int, scene: Int) {
        selection = Selection(track: track, scene: scene)
    }

    // MARK: - Pane focus

    /// Clicking the song (clip, lane, ruler, header) takes keyboard focus away from the piano
    /// roll. That is what makes ⌘D duplicate a clip instead of the last note.
    func focusArrangement() {
        focus = .arrangement
        selectedNote = nil
        selectedNotes.removeAll()
        noteMarquee = nil
        noteMarqueeStart = nil
        if auditionPitch != nil { audition(pitch: nil) }
    }

    func focusPianoRoll() {
        focus = .pianoRoll
    }

    func focusBrowser() {
        focus = .browser
        selectedNote = nil
        if auditionPitch != nil { audition(pitch: nil) }
    }

    /// Clicking a track header selects the whole track, not one of its clips, so ⌘D clones the
    /// track. Clips are cleared so there is no ambiguity about the target.
    func selectTrackHeader(_ track: Int) {
        guard track >= 0, track < tracks.count else { return }
        focusArrangement()
        selectedClips.removeAll()
        selectedTimeline = nil
        selection = Selection(track: track, scene: 0)
    }

    func prepareLaneClick(track: Int) {
        focusArrangement()
        selectedClips.removeAll()
        selectedTimeline = nil
        if track >= 0, track < tracks.count {
            selection = Selection(track: track, scene: selection.scene)
        }
    }

    /// A double-click on empty lane space is an explicit shortcut for a one-bar clip at the
    /// insert marker. A single click still only selects and moves the marker; no track appears.
    func createClipOnLane(track: Int) {
        guard track >= 0, track < tracks.count else { return }
        prepareLaneClick(track: track)
        if let hit = timeline.first(where: {
            $0.track == track && $0.start <= insertStep && insertStep < $0.start + $0.length
        }) {
            selectClip(hit.id)
            status = "clip selected"
            return
        }
        pushUndo()
        _ = addTimelineClip(track: track, start: insertStep, length: stepsPerBar)
    }

    /// Create exactly one lane for a real canvas drag/drop. Unlike the old `ensureTrack`, this
    /// never fills gaps with invisible empty tracks.
    @discardableResult
    func appendTrackForCanvas() -> Int? {
        guard tracks.count < Shared.maxTracks else {
            status = "track limit reached (\(Shared.maxTracks))"
            return nil
        }
        addTrack()
        return tracks.last?.id
    }

    /// Bar the playhead is currently in, used when a click/drop has no explicit position.
    func playheadBar() -> Int {
        let step = max(Int(shared.playhead.pointee), 0)
        return step / stepsPerBar * stepsPerBar
    }

    // MARK: - Notes

    func note(for id: Int) -> NoteData? {
        clips[selection.track][selection.scene].notes.first { $0.id == id }
    }

    @discardableResult
    func addNote(step: Int, pitch: Int, length: Int = 1, velocity: Int = 100) -> Int? {
        guard selection.track >= 0, selection.track < tracks.count else { return nil }
        pushUndo()
        if !clips[selection.track][selection.scene].exists {
            guard addTimelineClip(track: selection.track, scene: -1,
                                  start: playheadBar(), length: stepsPerBar) != nil else {
                return nil
            }
        }
        let (t, s) = (selection.track, selection.scene)
        var info = clips[t][s]
        guard info.notes.count < Shared.maxNotes else {
            status = "note limit reached (\(Shared.maxNotes) per clip)"
            return nil
        }
        let note = NoteData(id: nextNoteID,
                            start: max(0, min(step, info.loopSteps - 1)),
                            length: max(1, length),
                            pitch: scaleMode.snap(pitch, root: scaleRoot),
                            velocity: max(1, min(velocity, 127)))
        nextNoteID += 1
        info.notes.append(note)
        clips[t][s] = info
        syncNotes(track: t, scene: s)
        selectedNote = note.id
        selectedNotes = [note.id]
        focusPianoRoll()
        return note.id
    }

    func updateNote(_ id: Int, start: Int? = nil, length: Int? = nil,
                    pitch: Int? = nil, velocity: Int? = nil) {
        let (t, s) = (selection.track, selection.scene)
        var info = clips[t][s]
        guard let index = info.notes.firstIndex(where: { $0.id == id }) else { return }
        if let value = start { info.notes[index].start = max(0, min(value, info.loopSteps - 1)) }
        if let value = pitch {
            info.notes[index].pitch = scaleMode.snap(value, root: scaleRoot)
        }
        if let value = length {
            info.notes[index].length = max(1, min(value, info.loopSteps - info.notes[index].start))
        }
        if let value = velocity { info.notes[index].velocity = max(1, min(value, 127)) }
        clips[t][s] = info
        syncNotes(track: t, scene: s)
    }

    func setScale(root: Int, mode: ScaleMode) {
        scaleRoot = min(max(root, 0), 11)
        scaleMode = mode
        status = "scale \(Self.noteName(scaleRoot)) \(mode.label.lowercased())"
    }

    static func noteName(_ pitch: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return names[((pitch % 12) + 12) % 12]
    }

    func setSelectedNoteProbability(_ value: Int) {
        let ids = selectedNotes.isEmpty ? (selectedNote.map { [$0] } ?? []) : Array(selectedNotes)
        guard !ids.isEmpty else { return }
        let (t, s) = (selection.track, selection.scene)
        var info = clips[t][s]
        for id in ids {
            guard let index = info.notes.firstIndex(where: { $0.id == id }) else { continue }
            info.notes[index].probability = max(0, min(value, 100))
        }
        clips[t][s] = info
        syncNotes(track: t, scene: s)
        status = "probability \(max(0, min(value, 100)))%"
    }

    func setSelectedNoteGroove(_ value: Double) {
        let ids = selectedNotes.isEmpty ? (selectedNote.map { [$0] } ?? []) : Array(selectedNotes)
        guard !ids.isEmpty else { return }
        let (t, s) = (selection.track, selection.scene)
        var info = clips[t][s]
        for id in ids {
            guard let index = info.notes.firstIndex(where: { $0.id == id }) else { continue }
            info.notes[index].groove = max(0, min(value, 0.9))
        }
        clips[t][s] = info
        syncNotes(track: t, scene: s)
        status = "groove +\(Int((max(0, min(value, 0.9))) * 100))%"
    }

    func deleteNote(_ id: Int) {
        let (t, s) = (selection.track, selection.scene)
        var info = clips[t][s]
        info.notes.removeAll { $0.id == id }
        clips[t][s] = info
        selectedNotes.remove(id)
        if selectedNote == id { selectedNote = selectedNotes.first }
        if selectedNotes.isEmpty { selectedNote = nil }
        syncNotes(track: t, scene: s)
    }

    func deleteSelectedNotes() {
        guard !selectedNotes.isEmpty else {
            status = "select notes to delete"
            return
        }
        pushUndo()
        let count = selectedNotes.count
        for id in Array(selectedNotes) { deleteNote(id) }
        selectedNotes.removeAll()
        selectedNote = nil
        status = "deleted \(count) note\(count == 1 ? "" : "s")"
    }

    func selectNote(_ id: Int, additive: Bool = false) {
        focusPianoRoll()
        if additive {
            if selectedNotes.contains(id) {
                selectedNotes.remove(id)
                selectedNote = selectedNotes.first
            } else {
                selectedNotes.insert(id)
                selectedNote = id
            }
        } else {
            if !selectedNotes.contains(id) { selectedNotes = [id] }
            selectedNote = id
        }
    }

    func selectNotes(_ ids: Set<Int>, additive: Bool = false) {
        focusPianoRoll()
        if additive { selectedNotes.formUnion(ids) } else { selectedNotes = ids }
        selectedNote = selectedNotes.first
        status = "\(selectedNotes.count) note\(selectedNotes.count == 1 ? "" : "s") selected"
    }

    func clearNoteSelection() {
        selectedNotes.removeAll()
        selectedNote = nil
    }

    func selectAllNotes() {
        let notes = clips[selection.track][selection.scene].notes
        guard !notes.isEmpty else {
            status = "this clip has no notes"
            return
        }
        focusPianoRoll()
        selectedNotes = Set(notes.map(\.id))
        selectedNote = notes.first?.id
        status = "selected all \(notes.count) notes"
    }

    func prepareNoteMove(anchor: Int) {
        if selectedNotes.isEmpty { selectNote(anchor) }
        let selected = selectedNotes
        noteDragSnapshot = clips[selection.track][selection.scene].notes
            .filter { selected.contains($0.id) }
    }

    /// Moves every selected note from the snapshot captured at mouse-down, preserving the
    /// intervals of a chord instead of collapsing it onto the anchor.
    func moveSelectedNotes(stepDelta: Int, pitchDelta: Int) {
        guard !noteDragSnapshot.isEmpty else { return }
        let (t, s) = (selection.track, selection.scene)
        var info = clips[t][s]
        for base in noteDragSnapshot {
            guard let index = info.notes.firstIndex(where: { $0.id == base.id }) else { continue }
            info.notes[index].start = max(0, min(base.start + stepDelta, info.loopSteps - 1))
            info.notes[index].pitch = scaleMode.snap(base.pitch + pitchDelta, root: scaleRoot)
        }
        clips[t][s] = info
        syncNotes(track: t, scene: s)
    }

    /// ⌘D with notes selected: copy the whole selection after its own span.
    func duplicateSelectedNote() {
        let ids = selectedNotes.isEmpty ? (selectedNote.map { [$0] } ?? []) : Array(selectedNotes)
        let notes = clips[selection.track][selection.scene].notes.filter { ids.contains($0.id) }
        guard let first = notes.min(by: { $0.start < $1.start }) else { return }
        pushUndo()
        let end = notes.map { $0.start + $0.length }.max() ?? first.start + first.length
        let shift = max(1, end - first.start)
        var copies: Set<Int> = []
        for note in notes {
            let info = clips[selection.track][selection.scene]
            guard info.notes.count < Shared.maxNotes else { break }
            let copy = NoteData(id: nextNoteID, start: min(note.start + shift, info.loopSteps - 1),
                                length: note.length, pitch: note.pitch, velocity: note.velocity,
                                probability: note.probability, groove: note.groove)
            nextNoteID += 1
            clips[selection.track][selection.scene].notes.append(copy)
            copies.insert(copy.id)
        }
        syncNotes(track: selection.track, scene: selection.scene)
        selectedNotes = copies
        selectedNote = copies.first
        status = "duplicated \(copies.count) note\(copies.count == 1 ? "" : "s")"
    }

    /// Arrow keys move every selected note together.
    func nudgeSelectedNote(steps: Int = 0, pitch: Int = 0) {
        let ids = selectedNotes.isEmpty ? (selectedNote.map { [$0] } ?? []) : Array(selectedNotes)
        guard !ids.isEmpty else { return }
        pushUndo()
        let (t, s) = (selection.track, selection.scene)
        var info = clips[t][s]
        for id in ids {
            guard let index = info.notes.firstIndex(where: { $0.id == id }) else { continue }
            info.notes[index].start = max(0, min(info.notes[index].start + steps,
                                                 info.loopSteps - 1))
            info.notes[index].pitch = scaleMode.snap(info.notes[index].pitch + pitch,
                                                      root: scaleRoot)
        }
        clips[t][s] = info
        syncNotes(track: t, scene: s)
    }

    func copySelectedNotes() {
        let ids = selectedNotes.isEmpty ? (selectedNote.map { [$0] } ?? []) : Array(selectedNotes)
        let notes = clips[selection.track][selection.scene].notes.filter { ids.contains($0.id) }
        guard !notes.isEmpty else {
            status = "select notes to copy"
            return
        }
        noteClipboard = notes
        status = "copied \(notes.count) note\(notes.count == 1 ? "" : "s")"
    }

    func pasteNotes() {
        guard !noteClipboard.isEmpty else {
            status = "note clipboard is empty"
            return
        }
        pushUndo()
        let info = clips[selection.track][selection.scene]
        guard info.exists else {
            status = "draw a clip before pasting notes"
            return
        }
        let base = noteClipboard.map(\.start).min() ?? 0
        let target = selectedNote.flatMap { note(for: $0)?.start } ?? base
        var pasted: Set<Int> = []
        for note in noteClipboard {
            guard clips[selection.track][selection.scene].notes.count < Shared.maxNotes else { break }
            var copy = note
            copy.id = nextNoteID
            nextNoteID += 1
            copy.start = max(0, min(target + (note.start - base), info.loopSteps - 1))
            clips[selection.track][selection.scene].notes.append(copy)
            pasted.insert(copy.id)
        }
        syncNotes(track: selection.track, scene: selection.scene)
        selectedNotes = pasted
        selectedNote = pasted.first
        focusPianoRoll()
        status = "pasted \(pasted.count) note\(pasted.count == 1 ? "" : "s")"
    }

    func quantizeSelectedNotes() {
        let ids = selectedNotes.isEmpty ? (selectedNote.map { [$0] } ?? []) : Array(selectedNotes)
        guard !ids.isEmpty else {
            status = "select notes to quantize"
            return
        }
        pushUndo()
        let grid = max(1, snapSteps)
        let (t, s) = (selection.track, selection.scene)
        var info = clips[t][s]
        for id in ids {
            guard let index = info.notes.firstIndex(where: { $0.id == id }) else { continue }
            info.notes[index].start = min(((info.notes[index].start + grid / 2) / grid) * grid,
                                          max(info.loopSteps - 1, 0))
        }
        clips[t][s] = info
        syncNotes(track: t, scene: s)
        status = "quantized \(ids.count) note\(ids.count == 1 ? "" : "s") to \(snap.label) grid"
    }

    func shiftRollOctave(_ delta: Int) {
        let octave = min(max(rollFocusPitch / 12 + delta, 0), 9)
        rollFocusPitch = octave * 12
    }

    func scrollPianoRoll(by semitones: Int) {
        rollFocusPitch = min(max(rollFocusPitch + semitones, 0), 127)
    }

    func setDetailHeight(_ height: Double) {
        detailHeight = min(max(height, 150), 720)
    }

    /// Piano roll keyboard: press a key to hear it on the selected track.
    /// Passing nil releases whatever is held.
    func audition(pitch: Int?) {
        if let pitch {
            guard pitch >= 0, pitch <= Self.maxPitch else { return }
            guard auditionPitch != pitch else { return }
            if auditionPitch != nil { shared.previewOffSeq.pointee &+= 1 }
            auditionPitch = pitch
            shared.previewTrack.pointee = Int32(min(max(selection.track, 0), tracks.count - 1))
            shared.previewPitch.pointee = Int32(pitch)
            shared.previewVel.pointee = 100
            shared.previewOnSeq.pointee &+= 1
        } else {
            guard auditionPitch != nil else { return }
            auditionPitch = nil
            shared.previewOffSeq.pointee &+= 1
        }
    }

    func clearNotes() {
        let (t, s) = (selection.track, selection.scene)
        guard clips[t][s].exists else { return }
        clips[t][s].notes = []
        selectedNote = nil
        syncNotes(track: t, scene: s)
        status = "cleared scene \(s + 1) notes"
    }

    func setLoopLength(_ steps: Int) {
        let (t, s) = (selection.track, selection.scene)
        guard clips[t][s].exists else { return }
        var info = clips[t][s]
        info.loopSteps = steps
        for i in info.notes.indices where info.notes[i].start >= steps {
            info.notes[i].start = steps - 1
        }
        for i in info.notes.indices {
            let maxLength = steps - info.notes[i].start
            if info.notes[i].length > maxLength { info.notes[i].length = max(1, maxLength) }
        }
        clips[t][s] = info
        shared.loops[Shared.clipIndex(track: t, scene: s)] = Int32(steps)
        if let id = selectedTimeline, let i = timeline.firstIndex(where: { $0.id == id }) {
            timeline[i].length = steps
        }
        syncNotes(track: t, scene: s)
        syncTimeline()
        status = "clip is now \(formattedBars(steps))"
    }

    @discardableResult
    func ensureClip(track: Int, scene: Int) -> Bool {
        guard track >= 0, track < tracks.count, scene >= 0, scene < Shared.sceneCount else { return false }
        if clips[track][scene].exists { return true }
        var info = ClipInfo()
        info.exists = true
        info.loopSteps = 16
        clips[track][scene] = info
        let index = Shared.clipIndex(track: track, scene: scene)
        shared.loops[index] = 16
        shared.hasClip[index] = 1
        shared.noteCount[index] = 0
        shared.clipSampleStart[index] = 0
        shared.clipFadeIn[index] = Float(info.sampleFadeIn)
        shared.clipFadeOut[index] = Float(info.sampleFadeOut)
        return true
    }

    func syncNotes(track: Int, scene: Int) {
        let clip = Shared.clipIndex(track: track, scene: scene)
        let info = clips[track][scene]
        let base = clip * Shared.maxNotes
        let count = min(info.notes.count, Shared.maxNotes)
        for i in 0..<count {
            let note = info.notes[i]
            shared.noteStart[base + i] = Int32(max(0, note.start))
            shared.noteLen[base + i] = Int32(max(1, note.length))
            shared.notePitch[base + i] = UInt8(max(0, min(note.pitch, Self.maxPitch)))
            shared.noteVel[base + i] = UInt8(max(1, min(note.velocity, 127)))
            shared.noteProb[base + i] = UInt8(max(0, min(note.probability ?? 100, 100)))
            shared.noteGroove[base + i] = Float(max(0, min(note.groove ?? 0, 0.9)))
        }
        shared.noteCount[clip] = Int32(count)
        shared.loops[clip] = Int32(info.loopSteps)
        shared.hasClip[clip] = info.exists ? 1 : 0
        shared.clipWarp[clip] = info.sampleWarp ? 1 : 0
        shared.clipStretch[clip] = info.warpStretch ? 1 : 0
        shared.clipReverse[clip] = info.sampleReverse ? 1 : 0
        syncWarpMarkers(track: track, scene: scene)
        syncCompRegions(track: track, scene: scene)
        syncClipGain(track: track, scene: scene)
    }

    // MARK: - Samples

    /// Handles a browser or Finder drop onto a lane. Returns true when a file URL was found.
    @discardableResult
    func acceptAudioDrop(_ providers: [NSItemProvider], track: Int, startStep: Int) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) else {
            status = "drop an audio file"
            return false
        }
        let identifier = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            ? UTType.fileURL.identifier
            : UTType.url.identifier
        provider.loadItem(forTypeIdentifier: identifier, options: nil) { [weak self] item, _ in
            var url: URL?
            if let data = item as? Data {
                if let text = String(data: data, encoding: .utf8), let parsed = URL(string: text) {
                    url = parsed
                } else {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                }
            } else if let raw = item as? URL {
                url = raw
            } else if let nsurl = item as? NSURL {
                url = nsurl as URL
            } else if let string = item as? String {
                url = URL(string: string)
            }
            guard let url = url, url.isFileURL else {
                DispatchQueue.main.async { [weak self] in
                    self?.status = "could not read the dropped file URL"
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.dropAudio(path: url.path, track: track, start: startStep)
            }
        }
        return true
    }

    /// Audio is a one-shot on the timeline: its own clip, its natural length, no session copy.
    func dropAudio(path: String, track: Int, start: Int) {
        guard let pool = samples else {
            status = "audio decoder is not ready"
            return
        }
        guard track >= 0, track < tracks.count else {
            status = "cannot import into that lane"
            return
        }
        stopBrowserPreview()
        do {
            // Reuse a decoded file when it is already in the pool. Loading every drag into a
            // fresh slot exhausts the pool after a handful of duplicates.
            let slot = try pool.loadOrReuse(path: path)
            let duration = pool.duration(of: slot) ?? 0
            // One-shots do not warp, so the clip lasts exactly as long as the file. The old
            // bar-rounded length left up to a bar of silence on every import.
            let steps = max(1, Int(ceil(duration * bpm / 60 * 4)))
            let requested = max(0, snappedStep(start))
            guard let placement = freePlacement(track: track, start: requested, length: steps) else {
                status = "no free space on \(tracks[track].name) for \(pool.duration(of: slot) ?? 0)s of audio"
                return
            }
            guard let id = addTimelineClip(track: track, scene: -1, start: placement,
                                           length: steps, minimumLength: 1),
                  let placed = timelineClip(id: id) else {
                // addTimelineClip has already put the reason in status. Keep the imported file
                // in the pool so the next drop reuses it instead of decoding it again.
                return
            }
            let scene = placed.scene
            let index = Shared.clipIndex(track: track, scene: scene)
            shared.clipSample[index] = Int32(slot)
            shared.hasClip[index] = 1
            shared.clipSampleStart[index] = 0
            shared.clipFadeIn[index] = 0.005
            shared.clipFadeOut[index] = 0.01
            shared.clipSampleBPM[index] = Float(bpm)
            shared.clipWarp[index] = 0
            shared.clipReverse[index] = 0
            shared.loops[index] = Int32(placed.length)
            var info = clips[track][scene]
            info.samplePath = path
            info.sampleName = (path as NSString).lastPathComponent
            info.sampleStart = 0
            info.sampleFadeIn = 0.005
            info.sampleFadeOut = 0.01
            info.sampleGain = 0.9
            info.sampleSourceBPM = bpm
            info.sampleWarp = false
            info.sampleReverse = false
            info.takes = [AudioTake(id: nextTakeID, path: path,
                                    name: (path as NSString).lastPathComponent)]
            nextTakeID += 1
            info.activeTake = 0
            info.warpMarkers = []
            info.warpStretch = false
            info.compRegions = []
            info.gainEnvelope = []
            info.loopSteps = placed.length
            clips[track][scene] = info
            syncWarpMarkers(track: track, scene: scene)
            syncCompRegions(track: track, scene: scene)
            syncClipGain(track: track, scene: scene)
            shared.clipStretch[index] = 0
            shared.clipSampleGain[index] = Float(info.sampleGain)
            if autoCrossfade { applyAutoCrossfades() }
            selectedClips = [id]
            selectedTimeline = id
            selection = Selection(track: track, scene: scene)
            focus = .arrangement
            let whereText = placement == requested
                ? "bar \(barNumber(at: placed.start))"
                : "next free bar \(barNumber(at: placed.start))"
            status = "\(info.sampleName ?? "sample") · \(whereText) · \(steps) steps"
        } catch {
            status = "import failed: \(error.localizedDescription)"
        }
    }

    /// Find the closest free range for an imported file. A drop on top of an existing clip is
    /// moved forward on the same lane instead of disappearing; if the lane has no gap large
    /// enough, nothing is inserted and the status line explains why.
    func freePlacement(track: Int, start: Int, length: Int) -> Int? {
        if isRangeFree(track: track, start: start, length: length) { return start }
        let stride = max(1, snapSteps)
        var cursor = start
        while cursor < Shared.maxAutoSteps {
            cursor += stride
            if isRangeFree(track: track, start: cursor, length: length) { return cursor }
        }
        cursor = start
        while cursor > 0 {
            cursor = max(0, cursor - stride)
            if isRangeFree(track: track, start: cursor, length: length) { return cursor }
            if cursor == 0 { break }
        }
        return nil
    }

    func clearSample() {
        let (t, s) = (selection.track, selection.scene)
        let index = Shared.clipIndex(track: t, scene: s)
        // Keep the decoded pool entry: another timeline placement may use the same file, and
        // clearing slots on one clip used to silence every duplicate of that sample.
        shared.clipSample[index] = -1
        shared.clipSampleStart[index] = 0
        shared.clipFadeIn[index] = 0.005
        shared.clipFadeOut[index] = 0.005
        shared.clipWarp[index] = 0
        shared.clipReverse[index] = 0
        clips[t][s].samplePath = nil
        clips[t][s].sampleName = nil
        clips[t][s].sampleStart = 0
        clips[t][s].sampleFadeIn = 0.005
        clips[t][s].sampleFadeOut = 0.005
        clips[t][s].takes = []
        clips[t][s].activeTake = 0
        clips[t][s].warpMarkers = []
        clips[t][s].compRegions = []
        clips[t][s].gainEnvelope = []
        clips[t][s].warpStretch = false
        shared.clipStretch[index] = 0
        shared.clipRegionCount[index] = 0
        shared.clipGainCount[index] = 0
        syncWarpMarkers(track: t, scene: s)
        status = "sample cleared"
    }

    // MARK: - Takes and comping

    /// Adds a recorded file to the selected audio clip. The current take stays on disk, so
    /// switching comps is instant and non-destructive.
    @discardableResult
    func addTake(path: String, name: String? = nil, track: Int, scene: Int) -> Int? {
        guard let pool = samples,
              track >= 0, track < clips.count,
              scene >= 0, scene < clips[track].count,
              clips[track][scene].samplePath != nil,
              let slot = try? pool.loadOrReuse(path: path) else { return nil }
        let take = AudioTake(id: nextTakeID,
                             path: path,
                             name: name ?? (path as NSString).lastPathComponent)
        nextTakeID += 1
        clips[track][scene].takes.append(take)
        clips[track][scene].activeTake = clips[track][scene].takes.count - 1
        clips[track][scene].samplePath = path
        clips[track][scene].sampleName = take.name
        let index = Shared.clipIndex(track: track, scene: scene)
        shared.clipSample[index] = Int32(slot)
        shared.hasClip[index] = 1
        status = "take \(clips[track][scene].takes.count) · \(take.name)"
        return take.id
    }

    /// Active-take comping. The timeline keeps its length; only the source file changes.
    func useTake(track: Int, scene: Int, index: Int) {
        guard let pool = samples,
              track >= 0, track < clips.count,
              scene >= 0, scene < clips[track].count,
              clips[track][scene].takes.indices.contains(index),
              let slot = try? pool.loadOrReuse(path: clips[track][scene].takes[index].path)
        else { return }
        let take = clips[track][scene].takes[index]
        clips[track][scene].activeTake = index
        clips[track][scene].samplePath = take.path
        clips[track][scene].sampleName = take.name
        let clip = Shared.clipIndex(track: track, scene: scene)
        shared.clipSample[clip] = Int32(slot)
        status = "comp take \(index + 1) · \(take.name)"
    }

    func takeNames(track: Int, scene: Int) -> [String] {
        guard track >= 0, track < clips.count, scene >= 0, scene < clips[track].count else {
            return []
        }
        return clips[track][scene].takes.map(\.name)
    }

    // MARK: - Region comping

    /// Assigns a take to a span of the selected clip. Spans are arrangement steps and are
    /// clamped to the placement, so a time selection that runs past the clip ends at the clip.
    func setCompRegion(take index: Int, from: Int? = nil, to: Int? = nil) {
        guard let id = selectedTimeline, let clip = timelineClip(id: id),
              clips[clip.track][clip.scene].takes.indices.contains(index),
              clips[clip.track][clip.scene].samplePath != nil else {
            status = "select an audio clip with takes to comp"
            return
        }
        var info = clips[clip.track][clip.scene]
        let end = clip.start + clip.length
        let startStep = max(clip.start, min(from ?? currentStep(), end - 1))
        let endStep = max(startStep + 1, min(to ?? end, end))
        let localStart = startStep - clip.start
        let localEnd = max(localStart + 1, min(endStep - clip.start, clip.length))
        pushUndo()
        info.compRegions.removeAll { $0.startStep < localEnd && $0.endStep > localStart }
        info.compRegions.append(CompRegion(startStep: localStart, endStep: localEnd, take: index))
        info.compRegions.sort { $0.startStep < $1.startStep }
        clips[clip.track][clip.scene] = info
        syncCompRegions(track: clip.track, scene: clip.scene)
        status = "comp · take \(index + 1) · bars \(barNumber(at: startStep))–\(barNumber(at: max(startStep, endStep - 1)))"
    }

    func removeCompRegion(at index: Int) {
        guard let id = selectedTimeline, let clip = timelineClip(id: id),
              clips[clip.track][clip.scene].compRegions.indices.contains(index) else { return }
        clips[clip.track][clip.scene].compRegions.remove(at: index)
        syncCompRegions(track: clip.track, scene: clip.scene)
        status = "comp region removed"
    }

    func clearCompRegions() {
        guard let id = selectedTimeline, let clip = timelineClip(id: id) else { return }
        clips[clip.track][clip.scene].compRegions = []
        syncCompRegions(track: clip.track, scene: clip.scene)
        status = "comp regions cleared"
    }

    /// Resolves each region's take to a decoded pool slot. A missing file drops that region
    /// from the render map instead of silencing the clip's active take.
    func syncCompRegions(track: Int, scene: Int) {
        guard track >= 0, track < clips.count, scene >= 0, scene < clips[track].count else { return }
        let index = Shared.clipIndex(track: track, scene: scene)
        let info = clips[track][scene]
        let all = info.compRegions.sorted { $0.startStep < $1.startStep }
        let regions = Array(all.prefix(Shared.maxCompRegions))
        shared.clipRegionCount[index] = Int32(regions.count)
        let base = index * Shared.maxCompRegions
        for i in 0..<Shared.maxCompRegions {
            guard i < regions.count else {
                shared.clipRegionStart[base + i] = 0
                shared.clipRegionEnd[base + i] = 0
                shared.clipRegionSlot[base + i] = -1
                continue
            }
            let region = regions[i]
            shared.clipRegionStart[base + i] = Float(max(0, region.startStep))
            shared.clipRegionEnd[base + i] = Float(max(region.startStep + 1, region.endStep))
            var slot = -1
            if info.takes.indices.contains(region.take), let pool = samples {
                if let resolved = pool.slot(forPath: info.takes[region.take].path) {
                    slot = resolved
                } else if let loaded = try? pool.loadOrReuse(path: info.takes[region.take].path) {
                    slot = loaded
                }
            }
            shared.clipRegionSlot[base + i] = Int32(slot)
        }
    }

    /// Clip gain envelope, normalized 0...1 (0.5 = unity). The renderer applies it to audio
    /// sample-accurately and to MIDI velocity at each note start.
    func syncClipGain(track: Int, scene: Int) {
        guard track >= 0, track < clips.count, scene >= 0, scene < clips[track].count else { return }
        let index = Shared.clipIndex(track: track, scene: scene)
        let all = clips[track][scene].gainEnvelope.sorted { $0.step < $1.step }
        let points = Array(all.prefix(Shared.maxClipPoints))
        shared.clipGainCount[index] = Int32(points.count)
        let base = index * Shared.maxClipPoints
        for i in 0..<Shared.maxClipPoints {
            if i < points.count {
                shared.clipGainStep[base + i] = Float(max(0, points[i].step))
                shared.clipGainValue[base + i] = Float(min(max(points[i].value, 0), 1))
            } else {
                shared.clipGainStep[base + i] = 0
                shared.clipGainValue[base + i] = 0.5
            }
        }
    }

    func setSampleGain(_ value: Double) {
        let (t, s) = (selection.track, selection.scene)
        shared.clipSampleGain[Shared.clipIndex(track: t, scene: s)] = Float(value)
        clips[t][s].sampleGain = value
    }

    /// Start point inside the file, 0...1.
    func setSampleStart(_ value: Double) {
        let (t, s) = (selection.track, selection.scene)
        let duration = sampleDurationSteps(track: t, scene: s) ?? 0
        let maxStart = duration > 1 ? min(0.95, (duration - 1) / duration) : 0
        let clamped = min(max(value, 0), maxStart)
        shared.clipSampleStart[Shared.clipIndex(track: t, scene: s)] = Float(clamped)
        clips[t][s].sampleStart = clamped
    }

    func setSampleFadeIn(_ value: Double) {
        let clamped = min(max(value, 0), 4)
        let (t, s) = (selection.track, selection.scene)
        shared.clipFadeIn[Shared.clipIndex(track: t, scene: s)] = Float(clamped)
        clips[t][s].sampleFadeIn = clamped
    }

    func setSampleFadeOut(_ value: Double) {
        let clamped = min(max(value, 0), 4)
        let (t, s) = (selection.track, selection.scene)
        shared.clipFadeOut[Shared.clipIndex(track: t, scene: s)] = Float(clamped)
        clips[t][s].sampleFadeOut = clamped
    }

    func setSampleWarp(_ enabled: Bool, sourceBPM: Double? = nil) {
        let (t, s) = (selection.track, selection.scene)
        guard clips[t][s].samplePath != nil else { return }
        var info = clips[t][s]
        info.sampleWarp = enabled
        if let sourceBPM { info.sampleSourceBPM = min(max(sourceBPM, 20), 300) }
        let index = Shared.clipIndex(track: t, scene: s)
        clips[t][s] = info
        shared.clipWarp[index] = enabled ? 1 : 0
        shared.clipSampleBPM[index] = Float(info.sampleSourceBPM)
        status = enabled
            ? "warp on · \(String(format: "%.1f", info.sampleSourceBPM)) BPM source · \(info.warpStretch ? "stretch" : "repitch")"
            : "warp off · one-shot at natural speed"
    }

    /// Pitch-preserving warp. Off is the classic repitch behavior; on runs a granular
    /// time-stretch in the renderer so the file keeps its pitch while following the song tempo.
    func setSampleWarpStretch(_ enabled: Bool) {
        let (t, s) = (selection.track, selection.scene)
        guard clips[t][s].samplePath != nil else { return }
        clips[t][s].warpStretch = enabled
        if enabled { clips[t][s].sampleWarp = true }
        let index = Shared.clipIndex(track: t, scene: s)
        shared.clipStretch[index] = enabled ? 1 : 0
        shared.clipWarp[index] = clips[t][s].sampleWarp ? 1 : 0
        status = enabled
            ? "warp · pitch-preserving stretch \(String(format: "%.1f", bpm)) / \(String(format: "%.1f", clips[t][s].sampleSourceBPM))"
            : "warp · repitch (pitch follows tempo)"
    }

    func setSampleSourceBPM(_ value: Double) {
        let (t, s) = (selection.track, selection.scene)
        guard clips[t][s].samplePath != nil else { return }
        let clamped = min(max(value, 20), 300)
        clips[t][s].sampleSourceBPM = clamped
        shared.clipSampleBPM[Shared.clipIndex(track: t, scene: s)] = Float(clamped)
    }

    func setSampleReverse(_ enabled: Bool) {
        let (t, s) = (selection.track, selection.scene)
        guard clips[t][s].samplePath != nil else { return }
        clips[t][s].sampleReverse = enabled
        shared.clipReverse[Shared.clipIndex(track: t, scene: s)] = enabled ? 1 : 0
        status = enabled ? "audio reversed" : "audio forward"
    }

    /// Peaks for drawing the waveform of an audio clip.
    func waveform(track: Int, slot: Int) -> [Float]? {
        guard let path = clips[track][slot].samplePath,
              let pool = samples, let sampleSlot = pool.slot(forPath: path) else { return nil }
        return pool.peaks(for: sampleSlot)
    }

    // MARK: - Warp markers

    /// Adds an anchor at the playhead. The marker stores both sides of the mapping, so moving the
    /// song tempo later does not destroy the timing the user just matched.
    func addWarpMarker(at step: Int? = nil) {
        guard let id = selectedTimeline,
              let clip = timelineClip(id: id),
              let pool = samples,
              let path = clips[clip.track][clip.scene].samplePath,
              let slot = pool.slot(forPath: path),
              let duration = pool.duration(of: slot) else { return }
        var info = clips[clip.track][clip.scene]
        guard info.warpMarkers.count < Shared.maxWarpMarkers else {
            status = "warp marker limit reached (\(Shared.maxWarpMarkers))"
            return
        }
        let target = max(clip.start, min(step ?? currentStep(), clip.start + clip.length))
        let localStep = Double(target - clip.start) + Double(clip.offset)
        let timelineSeconds = localStep * 60.0 / bpm / 4.0
        let rate = info.sampleWarp ? bpm / info.sampleSourceBPM : 1
        let source = min(duration, max(0, info.sampleStart * duration + timelineSeconds * rate))
        info.warpMarkers.append(WarpMarker(sourceSeconds: source,
                                           timelineStep: localStep))
        info.warpMarkers.sort { $0.timelineStep < $1.timelineStep }
        if !info.sampleWarp { info.sampleWarp = true }
        clips[clip.track][clip.scene] = info
        shared.clipWarp[Shared.clipIndex(track: clip.track, scene: clip.scene)] = 1
        syncWarpMarkers(track: clip.track, scene: clip.scene)
        status = "warp marker \(info.warpMarkers.count) at bar \(barNumber(at: target))"
    }

    func clearWarpMarkers() {
        guard let id = selectedTimeline, let clip = timelineClip(id: id) else { return }
        clips[clip.track][clip.scene].warpMarkers = []
        syncWarpMarkers(track: clip.track, scene: clip.scene)
        status = "warp markers cleared"
    }

    func removeWarpMarker(at index: Int) {
        guard let id = selectedTimeline, let clip = timelineClip(id: id),
              clips[clip.track][clip.scene].warpMarkers.indices.contains(index) else { return }
        clips[clip.track][clip.scene].warpMarkers.remove(at: index)
        syncWarpMarkers(track: clip.track, scene: clip.scene)
        status = "warp marker removed"
    }

    func syncWarpMarkers(track: Int, scene: Int) {
        guard track >= 0, track < clips.count, scene >= 0, scene < clips[track].count else { return }
        let index = Shared.clipIndex(track: track, scene: scene)
        let markers = clips[track][scene].warpMarkers
            .sorted { $0.timelineStep < $1.timelineStep }
            .prefix(Shared.maxWarpMarkers)
        shared.clipWarpCount[index] = Int32(markers.count)
        let base = index * Shared.maxWarpMarkers
        for i in 0..<Shared.maxWarpMarkers {
            if i < markers.count {
                shared.clipWarpTimeline[base + i] = Float(markers[i].timelineStep)
                shared.clipWarpSource[base + i] = Float(markers[i].sourceSeconds)
            } else {
                shared.clipWarpTimeline[base + i] = 0
                shared.clipWarpSource[base + i] = 0
            }
        }
    }

    /// Natural duration of an audio file expressed in sixteenth-note steps at the current tempo.
    /// The timeline draws and trims the waveform against this, not against a bar-rounded guess.
    func sampleDurationSteps(track: Int, scene: Int) -> Double? {
        guard track >= 0, track < clips.count, scene >= 0, scene < Shared.sceneCount,
              let path = clips[track][scene].samplePath,
              let pool = samples, let slot = pool.slot(forPath: path),
              let duration = pool.duration(of: slot) else { return nil }
        let info = clips[track][scene]
        let referenceBPM = info.sampleWarp ? info.sampleSourceBPM : bpm
        return duration * referenceBPM / 60 * 4
    }

    /// Duration and channel count for the audio camera in the device panel.
    func sampleInfo(track: Int, scene: Int) -> (seconds: Double, channels: Int)? {
        guard track >= 0, track < clips.count, scene >= 0, scene < Shared.sceneCount,
              let path = clips[track][scene].samplePath,
              let pool = samples, let slot = pool.slot(forPath: path),
              let duration = pool.duration(of: slot) else { return nil }
        return (duration, pool.channelCount(for: slot))
    }

    // MARK: - Browser

    func refreshBrowser() {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: browserPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            browserItems = []
            return
        }
        let audioExtensions: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "flac", "caf", "ogg", "opus"]
        var items: [BrowserItem] = []
        if let entries = try? fm.contentsOfDirectory(atPath: browserPath) {
            for name in entries.sorted() where !name.hasPrefix(".") {
                let full = (browserPath as NSString).appendingPathComponent(name)
                var dir: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &dir)
                if dir.boolValue {
                    items.append(BrowserItem(id: full, name: name, isFolder: true))
                } else if audioExtensions.contains((name as NSString).pathExtension.lowercased()) {
                    items.append(BrowserItem(id: full, name: name, isFolder: false))
                }
            }
        }
        browserItems = items
    }

    /// Folder clicks navigate. Audio clicks select the file for dragging; they never place it,
    /// which is the browser's drag-only contract.
    func openBrowserItem(_ item: BrowserItem) {
        if item.isFolder {
            stopBrowserPreview()
            browserPath = item.id
            browserSelection = nil
            refreshBrowser()
        } else {
            selectBrowserItem(item)
        }
    }

    func selectBrowserItem(_ item: BrowserItem) {
        guard !item.isFolder else { return openBrowserItem(item) }
        browserSelection = item.id
        focusBrowser()
        stopBrowserPreview()
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: item.id)) else {
            status = "selected \(item.name) — drag it onto a lane to place"
            return
        }
        player.volume = 0.55
        player.prepareToPlay()
        if player.play() { browserPreview = player }
        status = "previewing \(item.name) — drag it onto a lane to place"
    }

    func stopBrowserPreview() {
        browserPreview?.stop()
        browserPreview = nil
    }

    func browserUp() {
        let parent = (browserPath as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != browserPath else { return }
        browserPath = parent
        refreshBrowser()
    }

    func chooseBrowserFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to browse for samples"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        browserPath = url.path
        refreshBrowser()
    }

    // MARK: - Track FX

    func setFX(_ track: Int, volume: Double? = nil, pan: Double? = nil,
               send: Double? = nil, sendB: Double? = nil, cutoff: Double? = nil,
               resonance: Double? = nil, drive: Double? = nil, armed: Bool? = nil) {
        guard track >= 0, track < fx.count else { return }
        var f = fx[track]
        if let v = volume { f.volume = v }
        if let v = pan { f.pan = min(max(v, -1), 1) }
        if let v = send { f.send = v }
        if let v = sendB { f.sendB = v }
        if let v = cutoff { f.cutoff = v }
        if let v = resonance { f.resonance = v }
        if let v = drive { f.drive = v }
        if let v = armed { f.armed = v }
        fx[track] = f
        pushFX(track)
        if armed == true { audio?.midi.rescan() }
    }

    private func pushFX(_ track: Int) {
        let f = fx[track]
        shared.volume[track] = Float(f.volume)
        shared.baseVolume[track] = Float(f.volume)
        shared.send[track] = Float(f.send)
        shared.baseSend[track] = Float(f.send)
        shared.sendB[track] = Float(f.sendB)
        shared.baseSendB[track] = Float(f.sendB)
        shared.cutoff[track] = Float(f.cutoff)
        shared.baseCutoff[track] = Float(f.cutoff)
        shared.trackParams[track].pan = Float(f.pan)
        shared.basePan[track] = Float(f.pan)
        shared.resonance[track] = Float(f.resonance)
        shared.drive[track] = Float(f.drive)
        shared.arm[track] = f.armed ? 1 : 0
        shared.groupOf[track] = Int32(min(max(f.group, 0), Shared.maxGroups))
        shared.midiEffect[track] = f.midiEffect.code
        shared.arpMode[track] = f.arpMode.code
        shared.arpRate[track] = Int32(max(f.arpRate.steps, 1))
        if f.armed { shared.monitorTrack.pointee = Int32(track) }
    }

    func setGroup(_ track: Int, group: Int) {
        guard track >= 0, track < fx.count else { return }
        fx[track].group = min(max(group, 0), Shared.maxGroups)
        shared.groupOf[track] = Int32(fx[track].group)
        status = fx[track].group == 0
            ? "\(tracks[track].name) → master"
            : "\(tracks[track].name) → group \(fx[track].group)"
    }

    func setGroupVolume(_ group: Int, value: Double) {
        guard group > 0, group <= Shared.maxGroups else { return }
        groupVolumes[group] = Float(min(max(value, 0), 1.5))
        shared.groupVolume[group] = groupVolumes[group]
    }

    func setGroupPan(_ group: Int, value: Double) {
        guard group > 0, group <= Shared.maxGroups else { return }
        groupPans[group] = Float(min(max(value, -1), 1))
        shared.groupPan[group] = groupPans[group]
    }

    func setReturnLevel(_ value: Double) {
        returnLevel = min(max(value, 0), 1.5)
        shared.returnLevel.pointee = Float(returnLevel)
    }

    func setReturnLevelB(_ value: Double) {
        returnLevelB = min(max(value, 0), 1.5)
        shared.returnLevelB.pointee = Float(returnLevelB)
    }

    func setArp(mode: ArpMode? = nil, rate: ArpRate? = nil, track: Int? = nil) {
        let index = min(max(track ?? selection.track, 0), tracks.count - 1)
        guard index < fx.count else { return }
        if let mode { fx[index].arpMode = mode }
        if let rate { fx[index].arpRate = rate }
        pushFX(index)
        status = "\(tracks[index].name) arp: \(fx[index].arpMode.label) · \(fx[index].arpRate.label)"
    }

    func midiStatus() -> String {
        guard let midi = audio?.midi else { return "no audio" }
        return midi.sourceCount == 0 ? "no MIDI source" : "\(midi.sourceCount) MIDI in"
    }

    func rescanMIDI() {
        audio?.midi.rescan()
        status = midiStatus()
    }

    // MARK: - Plugin inserts

    func availablePlugins() -> [PluginSlot.Descriptor] {
        if let cachedPlugins { return cachedPlugins }
        let list = PluginSlot.availableEffects()
        cachedPlugins = list
        return list
    }

    func pluginInstance(track: Int, slot: Int) -> PluginSlot? {
        pluginSlots[track * Shared.maxInserts + slot]
    }

    func loadPlugin(track: Int, slot: Int, descriptor: PluginSlot.Descriptor,
                    state: Data? = nil) {
        guard let audio else { return }
        guard track >= 0, track < tracks.count, slot >= 0, slot < Shared.maxInserts else { return }
        let index = track * Shared.maxInserts + slot
        if let old = pluginSlots[index] {
            shared.pluginOn[index] = 0
            shared.pluginPtr[index] = nil
            shared.pluginLatency[index] = 0
            retiredPlugins.append(old)
        }
        pluginSlots[index] = nil

        guard let instance = PluginSlot(component: descriptor.component, sampleRate: audio.sampleRate),
              instance.isReady else {
            inserts[track][slot] = nil
            shared.pluginLatency[index] = 0
            status = "could not load \(descriptor.name)"
            return
        }
        if let state { _ = instance.restoreState(state) }
        pluginSlots[index] = instance
        shared.pluginLatency[index] = Int32(instance.latencyFrames(at: audio.sampleRate))
        shared.pluginPtr[index] = Unmanaged.passUnretained(instance).toOpaque()   // pointer first
        shared.pluginOn[index] = 1                                                // then enable
        inserts[track][slot] = instance.name
        status = "insert: \(instance.name)"
    }

    func removePlugin(track: Int, slot: Int) {
        guard track >= 0, track < tracks.count, slot >= 0, slot < Shared.maxInserts else { return }
        let index = track * Shared.maxInserts + slot
        shared.pluginOn[index] = 0
        shared.pluginPtr[index] = nil
        shared.pluginLatency[index] = 0
        if let old = pluginSlots[index] { retiredPlugins.append(old) }
        pluginSlots[index] = nil
        inserts[track][slot] = nil
        status = "insert removed"
    }

    func pluginParameters(track: Int, slot: Int) -> [PluginSlot.Parameter] {
        pluginInstance(track: track, slot: slot)?.parameters() ?? []
    }

    /// Opens the plugin's own editor. Effects edit the instance the renderer is using.
    func openPluginUI(track: Int, slot: Int) {
        guard let instance = pluginInstance(track: track, slot: slot) else { return }
        AUWindowManager.shared.show(
            key: "insert-\(track)-\(slot)", title: instance.name,
            request: { completion in completion(instance.makeEditorViewController()) },
            onFailure: { [weak self] in
                self?.status = "\(instance.name) exposes no Audio Unit editor"
            })
    }

    // MARK: - AU instruments (generators)

    func availableInstruments() -> [PluginSlot.Descriptor] {
        if let cachedInstruments { return cachedInstruments }
        let list = PluginSlot.availableInstruments()
        cachedInstruments = list
        return list
    }

    func instrumentInstance(track: Int) -> InstrumentSlot? {
        instrumentSlots[track]
    }

    func hasInstrument(track: Int) -> Bool {
        instrumentNames[track] != nil
    }

    /// Replaces the built-in synth on this track with a real AU generator.
    func loadInstrument(track: Int, descriptor: PluginSlot.Descriptor,
                        state: Data? = nil) {
        guard let audio else { return }
        guard track >= 0, track < tracks.count else { return }
        shared.instOn[track] = 0
        shared.instPtr[track] = nil
        shared.instrumentLatency[track] = 0
        if let old = instrumentSlots[track] { retiredInstruments.append(old) }
        instrumentSlots[track] = nil
        instrumentNames[track] = nil
        AUWindowManager.shared.close(key: "inst-\(track)")

        guard let instance = InstrumentSlot(component: descriptor.component,
                                            sampleRate: audio.sampleRate),
              instance.isReady else {
            status = "could not load \(descriptor.name)"
            return
        }
        if let state { _ = instance.restoreState(state) }
        instrumentSlots[track] = instance
        shared.instrumentLatency[track] = Int32(instance.latencyFrames(at: audio.sampleRate))
        shared.instPtr[track] = Unmanaged.passUnretained(instance).toOpaque()
        shared.instOn[track] = 1
        instrumentNames[track] = instance.name
        status = "instrument: \(instance.name)"
    }

    func removeInstrument(track: Int) {
        guard track >= 0, track < tracks.count else { return }
        shared.instOn[track] = 0
        shared.instPtr[track] = nil
        shared.instrumentLatency[track] = 0
        if let old = instrumentSlots[track] { retiredInstruments.append(old) }
        instrumentSlots[track] = nil
        instrumentNames[track] = nil
        AUWindowManager.shared.close(key: "inst-\(track)")
        status = "back to the built-in synth"
    }

    func openInstrumentUI(track: Int) {
        guard let instance = instrumentInstance(track: track) else {
            status = "load an instrument first"
            return
        }
        AUWindowManager.shared.show(
            key: "inst-\(track)", title: instance.name,
            request: { completion in instance.requestEditor(completion) },
            onFailure: { [weak self] in
                self?.status = "\(instance.name) exposes no AU editor"
            })
    }

    func setPluginParameter(track: Int, slot: Int, id: UInt32, value: Double) {
        pluginInstance(track: track, slot: slot)?.setParameter(id, value: value)
        pluginRevision &+= 1
    }

    // MARK: - Timeline

    func timelineClip(id: Int) -> TimelineClip? {
        timeline.first { $0.id == id }
    }

    /// Arrangement tracks are monophonic in time: two clips may touch but never stack. That
    /// includes muted/deactivated clips, because a hidden overlap is still impossible to edit.
    func isRangeFree(track: Int, start: Int, length: Int, excluding: Int? = nil) -> Bool {
        let a = max(0, start)
        let b = a + max(1, length)
        return !timeline.contains { other in
            guard other.track == track, other.id != excluding else { return false }
            return other.start < b && a < other.start + other.length
        }
    }

    func selectTimeline(_ id: Int?) {
        selectedTimeline = id
        guard let id, let clip = timelineClip(id: id) else { return }
        selection = Selection(track: clip.track, scene: clip.scene)
        focusArrangement()
    }

    /// Each placement owns its own clip slot, so editing one never changes another.
    private func allocateSlot(track: Int, length: Int) -> Int? {
        let used = Set(timeline.filter { $0.track == track }.map { $0.scene })
        guard let slot = (0..<Shared.sceneCount).first(where: { !used.contains($0) }) else {
            status = "that track has no free clip slot"
            return nil
        }
        var info = ClipInfo()
        info.exists = true
        info.loopSteps = length
        clips[track][slot] = info
        let index = Shared.clipIndex(track: track, scene: slot)
        shared.loops[index] = Int32(length)
        shared.hasClip[index] = 1
        shared.noteCount[index] = 0
        shared.clipSample[index] = -1
        shared.clipSampleStart[index] = 0
        shared.clipSampleBPM[index] = Float(bpm)
        shared.clipWarp[index] = 0
        shared.clipReverse[index] = 0
        shared.clipStretch[index] = 0
        shared.clipWarpCount[index] = 0
        shared.clipRegionCount[index] = 0
        shared.clipGainCount[index] = 0
        return slot
    }

    @discardableResult
    func addTimelineClip(track: Int, scene: Int = -1, start: Int, length: Int? = nil,
                         minimumLength: Int = 16) -> Int? {
        guard track >= 0, track < tracks.count else { return nil }
        guard timeline.filter({ $0.track == track }).count < Shared.maxTimeline else {
            status = "that track's timeline is full (\(Shared.maxTimeline) clips)"
            return nil
        }
        let startStep = max(0, snappedStep(start))
        let desired = max(max(1, minimumLength), length ?? stepsPerBar)
        guard isRangeFree(track: track, start: startStep, length: desired) else {
            status = "cannot place a clip there — it would overlap another clip on \(tracks[track].name)"
            return nil
        }

        let source: Int
        if scene >= 0, scene < Shared.sceneCount, clips[track][scene].exists {
            source = scene
        } else {
            guard let slot = allocateSlot(track: track, length: desired) else { return nil }
            source = slot
        }

        let clip = TimelineClip(id: nextClipID, track: track, scene: source,
                                start: startStep, length: desired, offset: 0)
        nextClipID += 1
        timeline.append(clip)
        selectedTimeline = clip.id
        selection = Selection(track: track, scene: source)
        selectedNote = nil
        focus = .arrangement
        syncTimeline()
        status = "clip at bar \(barNumber(at: startStep)) on \(tracks[track].name)"
        return clip.id
    }

    @discardableResult
    func moveTimelineClip(_ id: Int, to start: Int, track target: Int? = nil) -> Bool {
        guard let i = timeline.firstIndex(where: { $0.id == id }) else { return false }
        let snapped = max(0, snappedStep(start))
        let old = timeline[i]
        let targetTrack = min(max(target ?? old.track, 0), tracks.count - 1)
        guard isRangeFree(track: targetTrack, start: snapped, length: old.length,
                          excluding: id) else {
            status = "cannot move there — another clip already occupies that range"
            return false
        }
        guard old.start != snapped || old.track != targetTrack else { return true }
        var newScene = old.scene

        if targetTrack != old.track {
            guard let slot = allocateSlot(track: targetTrack, length: old.length) else {
                return false
            }
            let oldIndex = Shared.clipIndex(track: old.track, scene: old.scene)
            let newIndex = Shared.clipIndex(track: targetTrack, scene: slot)
            var info = clips[old.track][old.scene]
            info.notes = info.notes.map { note in
                var copy = note
                copy.id = nextNoteID
                nextNoteID += 1
                return copy
            }
            clips[targetTrack][slot] = info
            shared.clipSample[newIndex] = shared.clipSample[oldIndex]
            shared.clipSampleStart[newIndex] = shared.clipSampleStart[oldIndex]
            shared.clipSampleGain[newIndex] = shared.clipSampleGain[oldIndex]
            shared.clipFadeIn[newIndex] = shared.clipFadeIn[oldIndex]
            shared.clipFadeOut[newIndex] = shared.clipFadeOut[oldIndex]
            shared.clipSampleBPM[newIndex] = shared.clipSampleBPM[oldIndex]
            shared.clipWarp[newIndex] = shared.clipWarp[oldIndex]
            shared.clipReverse[newIndex] = shared.clipReverse[oldIndex]
            shared.clipStretch[newIndex] = shared.clipStretch[oldIndex]
            syncNotes(track: targetTrack, scene: slot)
            newScene = slot
            if !timeline.contains(where: {
                $0.track == old.track && $0.scene == old.scene && $0.id != id
            }) {
                clips[old.track][old.scene] = ClipInfo()
                shared.hasClip[oldIndex] = 0
                shared.noteCount[oldIndex] = 0
                shared.clipSample[oldIndex] = -1
                shared.clipWarp[oldIndex] = 0
                shared.clipStretch[oldIndex] = 0
                shared.clipReverse[oldIndex] = 0
                shared.clipRegionCount[oldIndex] = 0
                shared.clipGainCount[oldIndex] = 0
            }
            selection = Selection(track: targetTrack, scene: slot)
        }

        timeline[i].start = snapped
        timeline[i].track = targetTrack
        timeline[i].scene = newScene
        syncTimeline()
        return true
    }

    func resizeTimelineClipLeft(_ id: Int, to start: Int) {
        guard let i = timeline.firstIndex(where: { $0.id == id }) else { return }
        let clip = timeline[i]
        let end = clip.start + clip.length
        let previousEnd = timeline
            .filter { $0.track == clip.track && $0.id != clip.id && $0.start < clip.start }
            .map { $0.start + $0.length }
            .max() ?? 0
        let newStart = min(max(max(0, snappedStep(start)), previousEnd), end - 1)
        guard newStart != clip.start else { return }
        timeline[i].start = newStart
        timeline[i].length = end - newStart
        timeline[i].offset = max(0, clip.offset + (newStart - clip.start))
        syncTimeline()
    }

    func resizeTimelineClip(_ id: Int, length: Int) {
        guard let i = timeline.firstIndex(where: { $0.id == id }) else { return }
        let nextStart = timeline
            .filter { $0.track == timeline[i].track && $0.id != id && $0.start > timeline[i].start }
            .map(\.start)
            .min()
        let maxLength = nextStart.map { max(1, $0 - timeline[i].start) } ?? Int.max
        let minimum = min(max(snap.steps, 1), maxLength)
        let snapped = min(max(minimum, snappedStep(max(length, 0))), maxLength)
        guard timeline[i].length != snapped else { return }
        timeline[i].length = snapped
        let clip = timeline[i]
        var info = clips[clip.track][clip.scene]
        if info.exists {
            info.loopSteps = snapped
            for j in info.notes.indices where info.notes[j].start >= snapped {
                info.notes[j].start = snapped - 1
            }
            for j in info.notes.indices {
                let room = snapped - info.notes[j].start
                if info.notes[j].length > room { info.notes[j].length = max(1, room) }
            }
            clips[clip.track][clip.scene] = info
            shared.loops[Shared.clipIndex(track: clip.track, scene: clip.scene)] = Int32(snapped)
            syncNotes(track: clip.track, scene: clip.scene)
        }
        syncTimeline()
    }

    func deleteTimelineClip(_ id: Int) {
        guard let doomed = timeline.first(where: { $0.id == id }) else { return }
        timeline.removeAll { $0.id == id }
        let stillUsed = timeline.contains { $0.track == doomed.track && $0.scene == doomed.scene }
        if !stillUsed {
            clips[doomed.track][doomed.scene] = ClipInfo()
            let index = Shared.clipIndex(track: doomed.track, scene: doomed.scene)
            shared.clipSample[index] = -1
            shared.hasClip[index] = 0
            shared.noteCount[index] = 0
            shared.loops[index] = 16
            shared.clipWarp[index] = 0
            shared.clipStretch[index] = 0
            shared.clipReverse[index] = 0
            shared.clipWarpCount[index] = 0
            shared.clipRegionCount[index] = 0
            shared.clipGainCount[index] = 0
        }
        selectedClips.remove(id)
        inactiveClips.remove(id)
        if selectedTimeline == id { selectedTimeline = nil }
        syncTimeline()
        status = "clip deleted"
    }

    func deleteSelectedClip() {
        deleteSelectedClips()
    }

    /// Delete key follows the focused pane, not whichever selection happens to be oldest.
    func deleteSelection() {
        switch focus {
        case .pianoRoll:
            if selectedNotes.count > 1 { deleteSelectedNotes(); return }
            guard let note = selectedNote else {
                status = "select a note to delete"
                return
            }
            pushUndo()
            deleteNote(note)
        case .browser:
            status = "nothing to delete in the browser"
        case .arrangement:
            deleteSelectedClip()
        }
    }

    func selectAllInFocusedPane() {
        switch focus {
        case .pianoRoll:
            selectAllNotes()
        case .arrangement:
            let ids = Set(timeline.map(\.id))
            guard !ids.isEmpty else { return }
            selectedClips = ids
            selectedTimeline = timeline.first?.id
            status = "selected all \(ids.count) clips"
        case .browser:
            status = "nothing to select in the browser"
        }
    }

    /// ⌘D: copy every selected placement after itself, each in its own free slot.
    func duplicateSelectedTimelineClip() {
        let ids = selectedClips.isEmpty
            ? (selectedTimeline.map { [$0] } ?? [])
            : Array(selectedClips)
        let chosen = timeline.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }
        pushUndo()
        var copies: Set<Int> = []
        for clip in chosen {
            guard let source = self.timelineClip(id: clip.id) else { continue }
            guard let copyID = addTimelineClip(track: source.track, scene: -1,
                                               start: source.start + source.length,
                                               length: source.length),
                  let copy = timelineClip(id: copyID) else { continue }
            var info = clips[source.track][source.scene]
            info.notes = info.notes.map { note in
                var duplicate = note
                duplicate.id = nextNoteID
                nextNoteID += 1
                return duplicate
            }
            clips[copy.track][copy.scene] = info
            let index = Shared.clipIndex(track: copy.track, scene: copy.scene)
            if let path = info.samplePath, let pool = samples, let slot = pool.slot(forPath: path) {
                shared.clipSample[index] = Int32(slot)
                shared.hasClip[index] = 1
            }
            shared.clipSampleStart[index] = Float(info.sampleStart)
            shared.clipFadeIn[index] = Float(info.sampleFadeIn)
            shared.clipFadeOut[index] = Float(info.sampleFadeOut)
            shared.clipSampleGain[index] = Float(info.sampleGain)
            shared.clipSampleBPM[index] = Float(info.sampleSourceBPM)
            shared.clipWarp[index] = info.sampleWarp ? 1 : 0
            shared.clipReverse[index] = info.sampleReverse ? 1 : 0
            syncNotes(track: copy.track, scene: copy.scene)
            copies.insert(copyID)
        }
        selectedClips = copies
        selectedTimeline = copies.first
        syncTimeline()
        if autoCrossfade { applyAutoCrossfades() }
        status = "duplicated \(copies.count) clip\(copies.count == 1 ? "" : "s")"
    }

    func clearTimeline() {
        timeline = []
        selectedTimeline = nil
        selectedClips.removeAll()
        inactiveClips.removeAll()
        syncTimeline()
        status = "timeline cleared"
    }

    /// Mirrors the Swift timeline into the flat arrays the render thread reads.
    func syncTimeline() {
        let sorted = timeline.sorted { $0.start < $1.start }
        if sorted != timeline { timeline = sorted }

        var counts = [Int](repeating: 0, count: Shared.maxTracks)
        var endStep = 64

        for clip in sorted {
            guard clip.track >= 0, clip.track < Shared.maxTracks else { continue }
            endStep = max(endStep, max(clip.start, 0) + max(clip.length, stepsPerBar))
            guard !inactiveClips.contains(clip.id) else { continue }
            let k = counts[clip.track]
            guard k < Shared.maxTimeline else { continue }
            let base = clip.track * Shared.maxTimeline + k
            let length = max(clip.length, 1)
            shared.tlStart[base] = Int32(max(clip.start, 0))
            shared.tlLen[base] = Int32(length)
            shared.tlScene[base] = Int32(clip.scene)
            shared.tlOffset[base] = Int32(max(clip.offset, 0))
            counts[clip.track] = k + 1
            endStep = max(endStep, max(clip.start, 0) + length)
        }

        for t in 0..<Shared.maxTracks {
            shared.tlCount[t] = Int32(counts[t])
            let base = t * Shared.maxTimeline
            for k in counts[t]..<Shared.maxTimeline {
                shared.tlStart[base + k] = 0
                shared.tlLen[base + k] = 0
                shared.tlScene[base + k] = -1
                shared.tlOffset[base + k] = 0
            }
        }

        let rounded = (endStep + stepsPerBar - 1) / stepsPerBar * stepsPerBar
        arrLength = min(max(stepsPerBar * 4, rounded), Shared.maxAutoSteps)
        shared.arrLength.pointee = Int32(arrLength)
        syncLoop()
        syncAutomation()
    }

    // MARK: - Capture

    func startCapture() {
        if !isPlaying { startTransport() }
        timeline = []
        selectedTimeline = nil
        openCaptureClips.removeAll()
        for i in 0..<(Shared.maxTracks * Shared.maxAutoSteps) { shared.autoVol[i] = -1 }
        syncTimeline()
        capturing = true
        status = "capturing — launch clips to write them into the timeline"
        startCaptureTimer()
    }

    func stopCapture() {
        capturing = false
        stopCaptureTimer()
        let bar = currentBar()
        for (_, id) in openCaptureClips {
            if let i = timeline.firstIndex(where: { $0.id == id }) {
                timeline[i].length = max(stepsPerBar, bar - timeline[i].start)
            }
        }
        openCaptureClips.removeAll()
        syncTimeline()
        status = "captured \(max(arrLength / stepsPerBar, 1)) bars into the timeline"
    }

    private func currentBar() -> Int {
        let step = max(Int(shared.playhead.pointee), 0)
        return (step + stepsPerBar / 2) / stepsPerBar * stepsPerBar
    }

    private func recordLaunch(track: Int, scene: Int) {
        guard capturing else { return }
        let bar = currentBar()

        if let openID = openCaptureClips[track], let i = timeline.firstIndex(where: { $0.id == openID }) {
            timeline[i].length = max(stepsPerBar, bar - timeline[i].start)
        }
        for i in timeline.indices where timeline[i].track == track {
            let end = timeline[i].start + timeline[i].length
            if timeline[i].start < bar && end > bar {
                timeline[i].length = max(stepsPerBar, bar - timeline[i].start)
            }
        }
        guard clips[track][scene].exists else { syncTimeline(); return }
        if let id = addTimelineClip(track: track, scene: scene, start: bar) {
            openCaptureClips[track] = id
        }
    }

    private func closeCaptureClip(track: Int) {
        guard let id = openCaptureClips[track],
              let i = timeline.firstIndex(where: { $0.id == id }) else { return }
        let bar = currentBar()
        timeline[i].length = max(stepsPerBar, bar - timeline[i].start)
        openCaptureClips[track] = nil
        syncTimeline()
    }

    private func startCaptureTimer() {
        stopCaptureTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.recordAutomation() }
        timer.resume()
        captureTimer = timer
    }

    private func stopCaptureTimer() {
        captureTimer?.cancel()
        captureTimer = nil
    }

    private func recordAutomation() {
        guard capturing, isPlaying else { return }
        let step = max(Int(shared.playhead.pointee), 0)
        guard step < Shared.maxAutoSteps else { return }
        for t in 0..<tracks.count {
            shared.autoVol[t * Shared.maxAutoSteps + step] = Float(fx[t].volume)
        }
    }

    // MARK: - Project files

    func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(projectName).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var clipData: [ClipData] = []
        for t in 0..<tracks.count {
            for s in 0..<Shared.sceneCount where clips[t][s].exists {
                let info = clips[t][s]
                clipData.append(ClipData(track: t, scene: s, loopSteps: info.loopSteps,
                                         notes: info.notes, samplePath: info.samplePath,
                                         sampleGain: Float(info.sampleGain),
                                         sampleStart: Float(info.sampleStart),
                                         sampleFadeIn: Float(info.sampleFadeIn),
                                         sampleFadeOut: Float(info.sampleFadeOut),
                                         sampleSourceBPM: info.sampleSourceBPM,
                                         sampleWarp: info.sampleWarp,
                                         sampleReverse: info.sampleReverse,
                                         takes: info.takes,
                                         activeTake: info.activeTake,
                                         warpMarkers: info.warpMarkers,
                                         warpStretch: info.warpStretch,
                                         compRegions: info.compRegions,
                                         gainEnvelope: info.gainEnvelope))
            }
        }

        var trackData: [TrackData] = []
        for t in 0..<tracks.count {
            let f = fx[t]
            var plugins: [PluginData] = []
            for slot in 0..<Shared.maxInserts {
                guard let instance = pluginSlotInstance(track: t, slot: slot), inserts[t][slot] != nil else { continue }
                plugins.append(PluginData(slot: slot, name: instance.name,
                                          type: instance.type, subtype: instance.subtype,
                                          manufacturer: instance.manufacturer,
                                          state: instance.fullState()))
            }
            trackData.append(TrackData(name: tracks[t].name, params: shared.trackParams[t],
                                       volume: f.volume, send: f.send, cutoff: f.cutoff,
                                       resonance: f.resonance, drive: f.drive, group: f.group,
                                       midiEffect: f.midiEffect.rawValue,
                                       inserts: plugins, instrument: instrumentData(t),
                                       sendB: f.sendB, arpMode: f.arpMode.rawValue,
                                       arpRate: f.arpRate.rawValue))
        }

        // The sparse `automationPoints` below are the project's source of truth. Do not also
        // write the old flattened envelope: at long-song lengths that array adds tens of
        // megabytes of redundant JSON and makes saving feel broken.
        let project = ProjectFile(bpm: bpm, master: master, tracks: trackData, clips: clipData,
                                  timeline: timeline, arrLength: arrLength, automation: nil,
                                  locators: locators, loopStart: loopStart, loopLength: loopLength,
                                  loopEnabled: loopEnabled,
                                  inactiveClips: Array(inactiveClips).sorted(),
                                  automationPoints: self.automation.keys.sorted().map {
                                      TrackAutomation(track: $0, points: self.automation[$0] ?? [])
                                  },
                                  automationByTarget: [
                                      AutomationTarget.pan.rawValue: panAutomation.keys.sorted().map {
                                          TrackAutomation(track: $0, points: panAutomation[$0] ?? [])
                                      },
                                      AutomationTarget.send.rawValue: sendAutomation.keys.sorted().map {
                                          TrackAutomation(track: $0, points: sendAutomation[$0] ?? [])
                                      },
                                      AutomationTarget.cutoff.rawValue: cutoffAutomation.keys.sorted().map {
                                          TrackAutomation(track: $0, points: cutoffAutomation[$0] ?? [])
                                      }
                                  ],
                                  timeSigNumerator: timeSigNumerator,
                                  timeSigDenominator: timeSigDenominator,
                                  scaleRoot: scaleRoot,
                                  scaleMode: scaleMode.rawValue,
                                  returnLevel: returnLevel,
                                  returnLevelB: returnLevelB,
                                  autoCrossfade: autoCrossfade)
        do {
            let data = try JSONEncoder().encode(project)
            try data.write(to: url)
            projectName = url.deletingPathExtension().lastPathComponent
            status = "saved \(url.lastPathComponent)"
        } catch {
            status = "save failed: \(error.localizedDescription)"
        }
    }

    private func pluginSlotInstance(track: Int, slot: Int) -> PluginSlot? {
        pluginInstance(track: track, slot: slot)
    }

    private func instrumentData(_ track: Int) -> PluginData? {
        guard let instance = instrumentSlots[track] else { return nil }
        return PluginData(slot: 0, name: instance.name, type: instance.type,
                          subtype: instance.subtype, manufacturer: instance.manufacturer,
                          state: instance.fullState())
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let project = try JSONDecoder().decode(ProjectFile.self, from: data)
            apply(project)
            projectName = url.deletingPathExtension().lastPathComponent
            status = "opened \(url.lastPathComponent)"
        } catch {
            status = "open failed: \(error.localizedDescription)"
        }
    }

    private func apply(_ project: ProjectFile) {
        stopTransport()

        let trackCount = min(max(project.tracks.count, 1), Shared.maxTracks)
        tracks = (0..<trackCount).map { i in
            TrackInfo(id: i, name: project.tracks[i].name,
                      color: Self.palette[i % Self.palette.count],
                      wave: Self.defaultWaves[min(i, Self.defaultWaves.count - 1)])
        }
        shared.trackCount.pointee = Int32(trackCount)
        fx = Array(repeating: TrackFX(), count: Shared.maxTracks)
        inserts = Array(repeating: Array(repeating: nil, count: Shared.maxInserts),
                        count: Shared.maxTracks)
        clips = Array(repeating: Array(repeating: ClipInfo(), count: Shared.sceneCount),
                      count: Shared.maxTracks)
        for index in pluginSlots.keys {
            shared.pluginOn[index] = 0
            shared.pluginPtr[index] = nil
        }
        for (_, slot) in pluginSlots { retiredPlugins.append(slot) }
        pluginSlots.removeAll()
        AUWindowManager.shared.closeAll()
        for t in 0..<Shared.maxTracks {
            shared.instOn[t] = 0
            shared.instPtr[t] = nil
            shared.instrumentLatency[t] = 0
            shared.groupOf[t] = 0
            instrumentNames[t] = nil
        }
        for (_, instance) in instrumentSlots { retiredInstruments.append(instance) }
        instrumentSlots.removeAll()

        setBPM(project.bpm)
        setMaster(project.master)
        returnLevel = min(max(project.returnLevel ?? 0.85, 0), 1.5)
        returnLevelB = min(max(project.returnLevelB ?? 0.85, 0), 1.5)
        autoCrossfade = project.autoCrossfade ?? false
        shared.returnLevel.pointee = Float(returnLevel)
        shared.returnLevelB.pointee = Float(returnLevelB)
        timeSigNumerator = min(max(project.timeSigNumerator ?? 4, 1), 16)
        timeSigDenominator = [2, 4, 8, 16].contains(project.timeSigDenominator ?? 4)
            ? (project.timeSigDenominator ?? 4) : 4
        scaleRoot = min(max(project.scaleRoot ?? 0, 0), 11)
        scaleMode = ScaleMode(rawValue: project.scaleMode ?? "") ?? .chromatic
        locators = project.locators ?? []
        loopStart = project.loopStart ?? 0
        loopLength = project.loopLength ?? 64
        loopEnabled = project.loopEnabled ?? true
        inactiveClips = Set(project.inactiveClips ?? [])
        automation = Dictionary(uniqueKeysWithValues: (project.automationPoints ?? []).map {
            ($0.track, $0.points)
        })
        func map(_ key: String) -> [Int: [AutomationPoint]] {
            Dictionary(uniqueKeysWithValues: (project.automationByTarget?[key] ?? []).map {
                ($0.track, $0.points)
            })
        }
        panAutomation = map(AutomationTarget.pan.rawValue)
        sendAutomation = map(AutomationTarget.send.rawValue)
        cutoffAutomation = map(AutomationTarget.cutoff.rawValue)
        nextLocatorID = (locators.map(\.id).max() ?? 0) + 1
        selectedClips.removeAll()

        for t in 0..<trackCount {
            let track = project.tracks[t]
            shared.trackParams[t] = track.params
            fx[t] = TrackFX(volume: track.volume, pan: Double(track.params.pan),
                            send: track.send, sendB: track.sendB ?? 0, cutoff: track.cutoff,
                            resonance: track.resonance, drive: track.drive, armed: false,
                            group: min(max(track.group ?? 0, 0), Shared.maxGroups),
                            midiEffect: MIDIEffect(rawValue: track.midiEffect ?? "") ?? .off,
                            arpMode: ArpMode(rawValue: track.arpMode ?? "") ?? .off,
                            arpRate: ArpRate(rawValue: track.arpRate ?? "") ?? .sixteenth)
            pushFX(t)
        }

        for t in 0..<Shared.maxTracks {
            for s in 0..<Shared.sceneCount {
                let index = Shared.clipIndex(track: t, scene: s)
                let base = index * Shared.maxNotes
                for i in 0..<Shared.maxNotes {
                    shared.noteStart[base + i] = 0
                    shared.noteLen[base + i] = 1
                    shared.notePitch[base + i] = 0
                    shared.noteVel[base + i] = 0
                    shared.noteProb[base + i] = 100
                    shared.noteGroove[base + i] = 0
                }
                shared.noteCount[index] = 0
                shared.loops[index] = 16
                shared.hasClip[index] = 0
                shared.clipSample[index] = -1
                shared.clipSampleStart[index] = 0
                shared.clipSampleGain[index] = 0.9
                shared.clipFadeIn[index] = 0.005
                shared.clipFadeOut[index] = 0.005
                shared.clipSampleBPM[index] = Float(project.bpm)
                shared.clipWarp[index] = 0
                shared.clipReverse[index] = 0
            }
        }

        var maxNoteID = 0
        for clip in project.clips {
            guard clip.track < trackCount, clip.scene < Shared.sceneCount else { continue }
            var notes = clip.notes
            if project.version < 4 {
                // Older projects stored pitches as semitone offsets from the track root.
                let root = Int(project.tracks[clip.track].params.rootNote)
                for i in notes.indices {
                    notes[i].pitch = min(max(notes[i].pitch + root, 0), 127)
                }
            }
            for i in notes.indices {
                maxNoteID = max(maxNoteID, notes[i].id)
                notes[i].pitch = min(max(notes[i].pitch, 0), 127)
            }
            notes.sort { $0.start < $1.start }
            var info = ClipInfo(exists: true, loopSteps: clip.loopSteps,
                                notes: notes, samplePath: clip.samplePath,
                                sampleName: clip.samplePath.map { ($0 as NSString).lastPathComponent },
                                sampleGain: Double(clip.sampleGain))
            info.sampleStart = Double(clip.sampleStart ?? 0)
            info.sampleFadeIn = Double(clip.sampleFadeIn ?? 0.005)
            info.sampleFadeOut = Double(clip.sampleFadeOut ?? 0.005)
            info.sampleSourceBPM = clip.sampleSourceBPM ?? project.bpm
            info.sampleWarp = clip.sampleWarp ?? false
            info.sampleReverse = clip.sampleReverse ?? false
            info.takes = clip.takes ?? []
            info.activeTake = min(max(clip.activeTake ?? 0, 0), max(info.takes.count - 1, 0))
            info.warpMarkers = clip.warpMarkers ?? []
            info.warpStretch = clip.warpStretch ?? false
            info.compRegions = clip.compRegions ?? []
            info.gainEnvelope = clip.gainEnvelope ?? []
            clips[clip.track][clip.scene] = info
            syncNotes(track: clip.track, scene: clip.scene)
            syncWarpMarkers(track: clip.track, scene: clip.scene)
            let index = Shared.clipIndex(track: clip.track, scene: clip.scene)
            shared.clipSampleStart[index] = Float(info.sampleStart)
            shared.clipFadeIn[index] = Float(info.sampleFadeIn)
            shared.clipFadeOut[index] = Float(info.sampleFadeOut)
            shared.clipSampleGain[index] = Float(info.sampleGain)
            shared.clipSampleBPM[index] = Float(info.sampleSourceBPM)
            shared.clipWarp[index] = info.sampleWarp ? 1 : 0
            shared.clipReverse[index] = info.sampleReverse ? 1 : 0
            if let path = clip.samplePath, let pool = samples {
                if let slot = try? pool.slot(forExistingPath: path) {
                    shared.clipSample[index] = Int32(slot)
                }
            }
        }
        nextNoteID = maxNoteID + 1

        for t in 0..<min(project.tracks.count, trackCount) {
            guard let plugins = project.tracks[t].inserts else { continue }
            for plugin in plugins where plugin.slot >= 0 && plugin.slot < Shared.maxInserts {
                guard let component = PluginSlot.component(type: plugin.type, subtype: plugin.subtype,
                                                           manufacturer: plugin.manufacturer) else { continue }
                let descriptor = PluginSlot.Descriptor(name: plugin.name, component: component,
                                                       type: plugin.type, subtype: plugin.subtype,
                                                       manufacturer: plugin.manufacturer)
                loadPlugin(track: t, slot: plugin.slot, descriptor: descriptor,
                           state: plugin.state)
            }
        }

        for t in 0..<min(project.tracks.count, trackCount) {
            guard let plugin = project.tracks[t].instrument else { continue }
            guard let component = PluginSlot.component(type: plugin.type, subtype: plugin.subtype,
                                                       manufacturer: plugin.manufacturer) else {
                status = "\(plugin.name) is not installed"
                continue
            }
            let descriptor = PluginSlot.Descriptor(name: plugin.name, component: component,
                                                   type: plugin.type, subtype: plugin.subtype,
                                                   manufacturer: plugin.manufacturer)
            loadInstrument(track: t, descriptor: descriptor, state: plugin.state)
        }

        timeline = (project.timeline ?? []).filter {
            $0.track >= 0 && $0.track < trackCount && $0.scene >= 0 && $0.scene < Shared.sceneCount
        }
        nextClipID = (timeline.map(\.id).max() ?? 0) + 1
        selectedTimeline = timeline.first?.id
        selectedClips = selectedTimeline.map { [$0] } ?? []
        if let first = timeline.first { selection = Selection(track: first.track, scene: first.scene) }
        else { selection = Selection(track: 0, scene: 0) }

        if let automation = project.automation,
           automation.count == Shared.maxTracks * Shared.maxAutoSteps {
            for i in 0..<automation.count { shared.autoVol[i] = automation[i] }
        } else if let automation = project.automation,
                  automation.count == Shared.maxTracks * 4096 {
            // v7 and earlier wrote a fixed 4096-step legacy envelope. Copy it into the front of
            // the larger long-song buffer instead of discarding automation just because the
            // buffer size changed.
            for track in 0..<Shared.maxTracks {
                for step in 0..<4096 {
                    shared.autoVol[track * Shared.maxAutoSteps + step]
                        = automation[track * 4096 + step]
                }
            }
            syncAutomation()
        } else {
            syncAutomation()
        }
        syncLoop()
        syncTimeline()
        invalidateHistory()
    }


    // MARK: - Arrangement workflow

    func currentStep() -> Int { max(Int(shared.playhead.pointee), 0) }

    func snappedStep(_ step: Int) -> Int {
        guard snap != .off else { return max(0, step) }
        return max(0, step / snapSteps * snapSteps)
    }

    func barNumber(at step: Int) -> Int { max(0, step) / stepsPerBar + 1 }

    func barStart(containing step: Int) -> Int {
        max(0, step) / stepsPerBar * stepsPerBar
    }

    func positionText(_ step: Int) -> String {
        let position = max(step, 0)
        let bar = position / stepsPerBar + 1
        let inBar = position % stepsPerBar
        let subdivision = max(stepsPerBar / beatsPerBar, 1)
        let beat = inBar / subdivision + 1
        let tick = inBar % subdivision + 1
        return String(format: "%03d.%d.%d", bar, beat, tick)
    }

    func setSnap(_ value: SnapGrid) {
        snap = value
    }

    func seek(to step: Int, announce: Bool = false) {
        let target = max(0, step)
        insertStep = target
        shared.seekTo.pointee = Int32(target)
        shared.seekSeq.pointee &+= 1
        if !isPlaying {
            shared.playhead.pointee = Int64(target)
            shared.playheadFrac.pointee = 0
        }
        if announce { status = "at bar \(barNumber(at: target))" }
    }

    func nudgeInsertMarker(_ delta: Int) {
        seek(to: insertStep + delta * snapSteps)
    }

    func formattedBars(_ steps: Int) -> String {
        let bars = Double(steps) / Double(max(stepsPerBar, 1))
        return "\(bars.formatted(.number.precision(.fractionLength(0...2)))) bar\(abs(bars - 1) < 0.001 ? "" : "s")"
    }

    func scrollLanes(by delta: CGFloat) {
        let maximum = max(arrangementContentHeight - arrangementViewportHeight, 0)
        laneScroll = min(max(laneScroll + delta, 0), maximum)
    }

    func scrollLanes(to offset: CGFloat) {
        let maximum = max(arrangementContentHeight - arrangementViewportHeight, 0)
        laneScroll = min(max(offset, 0), maximum)
    }

    /// One entry point for wheel, trackpad, scrollbar and programmatic navigation. Positive x
    /// reveals later bars; positive y reveals lower tracks.
    func scrollArrangement(x: CGFloat = 0, y: CGFloat = 0) {
        let maxX = max(arrangementContentWidth - arrangementViewportWidth, 0)
        let maxY = max(arrangementContentHeight - arrangementViewportHeight, 0)
        timelineScroll = min(max(timelineScroll + x, 0), maxX)
        laneScroll = min(max(laneScroll + y, 0), maxY)
    }

    func scrollArrangement(toX value: CGFloat) {
        let maximum = max(arrangementContentWidth - arrangementViewportWidth, 0)
        timelineScroll = min(max(value, 0), maximum)
    }

    func scrollArrangement(toY value: CGFloat) {
        let maximum = max(arrangementContentHeight - arrangementViewportHeight, 0)
        laneScroll = min(max(value, 0), maximum)
    }

    func updateArrangementViewport(width: CGFloat, height: CGFloat,
                                   contentWidth: CGFloat, contentHeight: CGFloat) {
        arrangementViewportWidth = max(width, 1)
        arrangementViewportHeight = max(height, 1)
        arrangementContentWidth = max(contentWidth, 1)
        arrangementContentHeight = max(contentHeight, 1)
        scrollArrangement(toX: timelineScroll)
        scrollLanes(to: laneScroll)
    }

    /// Zoom while keeping the musical position under `anchorX` stationary. Passing nil anchors
    /// on the middle of the visible canvas, which is what the −/+ buttons use.
    func zoomArrangement(by factor: Double, anchorX: CGFloat? = nil) {
        let oldZoom = max(zoom, 1)
        let anchor = anchorX ?? arrangementViewportWidth / 2
        let stepAtAnchor = (timelineScroll + anchor) / oldZoom
        zoom = min(max(oldZoom * factor, 4), 96)
        timelineScroll = CGFloat(stepAtAnchor) * zoom - anchor
        scrollArrangement(toX: timelineScroll)
    }

    func zoomToFit(contentSteps: Int) {
        guard contentSteps > 0, arrangementViewportWidth > 0 else { return }
        zoom = min(max(Double(arrangementViewportWidth) / Double(contentSteps), 4), 96)
        timelineScroll = 0
        scrollArrangement(toX: 0)
    }

    var loopEnd: Int { loopStart + loopLength }

    func syncLoop() {
        shared.loopStart.pointee = Int32(max(loopStart, 0))
        shared.loopLength.pointee = Int32(max(loopLength, stepsPerBar))
        shared.loopEnabled.pointee = loopEnabled ? 1 : 0
    }

    func setLoop(start: Int, length: Int) {
        loopStart = max(0, snappedStep(start))
        loopLength = max(stepsPerBar, snappedStep(max(length, stepsPerBar)))
        syncLoop()
    }

    func setLoopStart(_ step: Int) {
        let end = max(loopEnd, loopStart + stepsPerBar)
        loopStart = max(0, snappedStep(step))
        loopLength = max(stepsPerBar, end - loopStart)
        syncLoop()
    }

    func setLoopEnd(_ step: Int) {
        let end = max(loopStart + stepsPerBar, snappedStep(step))
        loopLength = end - loopStart
        syncLoop()
    }

    func toggleLoop() {
        loopEnabled.toggle()
        syncLoop()
        status = loopEnabled ? "arrangement loop on" : "arrangement loop off"
    }

    func loopSelection() {
        guard let selection = timeSelection, !selection.isEmpty else { return }
        setLoop(start: selection.start, length: selection.length)
        loopEnabled = true
        syncLoop()
        status = "loop set to bars \(barNumber(at: loopStart))–\(barNumber(at: max(loopEnd - 1, loopStart)))"
    }

    // MARK: - Locators

    func addLocator(at step: Int? = nil, name: String? = nil) {
        pushUndo()
        let position = snappedStep(step ?? insertStep)
        guard !locators.contains(where: { $0.step == position }) else {
            status = "a locator is already there"
            return
        }
        let locator = Locator(id: nextLocatorID, name: name ?? "Locator \(locators.count + 1)",
                              step: position)
        nextLocatorID += 1
        locators.append(locator)
        locators.sort { $0.step < $1.step }
        status = "\(locator.name) at bar \(barNumber(at: position))"
    }

    func deleteLocator(_ id: Int) {
        pushUndo()
        locators.removeAll { $0.id == id }
        status = "locator deleted"
    }

    func renameLocator(_ id: Int, name: String) {
        guard let index = locators.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        locators[index].name = name
        status = "locator renamed"
    }

    func jumpToLocator(forward: Bool) {
        let sorted = locators.sorted { $0.step < $1.step }
        guard !sorted.isEmpty else {
            status = "no locators yet — press SET LOCATOR"
            return
        }
        let target = forward
            ? sorted.first(where: { $0.step > insertStep }) ?? sorted[0]
            : sorted.last(where: { $0.step < insertStep }) ?? sorted[sorted.count - 1]
        seek(to: target.step)
        if isPlaying { stopTransport(); startTransport() }
        status = target.name
    }

    // MARK: - Selection

    func isClipSelected(_ id: Int) -> Bool {
        selectedClips.contains(id)
    }

    func selectClip(_ id: Int, additive: Bool = false) {
        focusArrangement()
        hoveredTrack = timelineClip(id: id)?.track
        if additive {
            if selectedClips.contains(id) { selectedClips.remove(id) }
            else { selectedClips.insert(id) }
            selectedTimeline = selectedClips.first
            if let first = selectedTimeline, let clip = timelineClip(id: first) {
                selection = Selection(track: clip.track, scene: clip.scene)
            }
        } else {
            selectedClips = [id]
            selectedTimeline = id
            if let clip = timelineClip(id: id) {
                selection = Selection(track: clip.track, scene: clip.scene)
            }
        }
    }

    func clearClipSelection() {
        selectedClips.removeAll()
        selectedTimeline = nil
    }

    func deleteSelectedClips() {
        let ids = selectedClips.isEmpty
            ? (selectedTimeline.map { [$0] } ?? [])
            : Array(selectedClips)
        guard !ids.isEmpty else { return }
        pushUndo()
        for id in ids { deleteTimelineClip(id) }
        selectedClips.removeAll()
        selectedTimeline = nil
        status = ids.count == 1 ? "clip deleted" : "\(ids.count) clips deleted"
    }

    func toggleClipActive(_ id: Int) {
        guard let clip = timelineClip(id: id) else { return }
        pushUndo()
        if inactiveClips.contains(id) {
            inactiveClips.remove(id)
            status = "clip enabled"
        } else {
            inactiveClips.insert(id)
            status = "clip deactivated"
        }
        selection = Selection(track: clip.track, scene: clip.scene)
        syncTimeline()
    }

    func isClipActive(_ id: Int) -> Bool { !inactiveClips.contains(id) }

    // MARK: - Clip editing

    func clipInfo(_ id: Int) -> ClipInfo? {
        guard let clip = timelineClip(id: id) else { return nil }
        return clips[clip.track][clip.scene]
    }

    private func splitTimelineRecord(_ id: Int, at step: Int) -> Int? {
        guard let index = timeline.firstIndex(where: { $0.id == id }) else { return nil }
        let clip = timeline[index]
        guard step > clip.start, step < clip.start + clip.length else { return nil }
        let right = TimelineClip(id: nextClipID, track: clip.track, scene: clip.scene,
                                 start: step, length: clip.start + clip.length - step,
                                 offset: clip.offset + (step - clip.start))
        nextClipID += 1
        timeline[index].length = step - clip.start
        timeline.append(right)
        return right.id
    }

    @discardableResult
    func splitClip(_ id: Int, at step: Int) -> Int? {
        pushUndo()
        let right = splitTimelineRecord(id, at: step)
        syncTimeline()
        if right != nil { status = "split at bar \(barNumber(at: step))" }
        return right
    }

    /// Cmd-E: split every selected clip at the insert marker (or everything under it when
    /// nothing is selected), matching Live's selection-based split.
    func splitAtInsertMarker() {
        let target = insertStep
        var ids = selectedClips.isEmpty
            ? (selectedTimeline.map { [$0] } ?? [])
            : Array(selectedClips)
        if ids.isEmpty {
            ids = timeline.filter { $0.start < target && target < $0.start + $0.length }.map(\.id)
        }
        let candidates = ids.filter { id in
            guard let clip = timelineClip(id: id) else { return false }
            return clip.start < target && target < clip.start + clip.length
        }
        guard !candidates.isEmpty else {
            status = "move the insert marker inside a clip to split"
            return
        }
        pushUndo()
        for id in candidates { _ = splitTimelineRecord(id, at: target) }
        selectedClips = Set(candidates.compactMap { id in
            timeline.first(where: { $0.id == id })?.id
        })
        syncTimeline()
        status = "split \(candidates.count) clip\(candidates.count == 1 ? "" : "s")"
    }

    func splitSelectedAtPlayhead() {
        seek(to: currentStep())
        splitAtInsertMarker()
    }

    /// Cmd-J: combine the selected clips on each track into one new MIDI clip. Audio would
    /// require an offline bounce, so Pocket says so instead of pretending.
    func consolidateSelectedClips() {
        let ids = selectedClips.isEmpty
            ? (selectedTimeline.map { [$0] } ?? [])
            : Array(selectedClips)
        let chosen = timeline.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else {
            status = "select clips to consolidate"
            return
        }
        if chosen.contains(where: { clips[$0.track][$0.scene].samplePath != nil }) {
            consolidateAudioClips(chosen)
            return
        }
        pushUndo()
        var newTimeline: [TimelineClip] = []
        var newIDs: Set<Int> = []
        for track in Set(chosen.map(\.track)).sorted() {
            let group = chosen.filter { $0.track == track }.sorted { $0.start < $1.start }
            guard !group.isEmpty else { continue }
            let start = group.map(\.start).min()!
            let end = group.map { $0.start + $0.length }.max()!
            guard let slot = allocateSlot(track: track, length: end - start) else { continue }
            var info = ClipInfo(exists: true, loopSteps: end - start, notes: [])
            for clip in group {
                let source = clips[clip.track][clip.scene]
                for note in source.notes {
                    let global = clip.start - clip.offset + note.start
                    guard global >= start, global < end else { continue }
                    var copy = note
                    copy.id = nextNoteID
                    nextNoteID += 1
                    copy.start = global - start
                    copy.length = max(1, min(note.length, end - global))
                    info.notes.append(copy)
                }
            }
            clips[track][slot] = info
            syncNotes(track: track, scene: slot)
            let id = nextClipID
            nextClipID += 1
            newTimeline.append(TimelineClip(id: id, track: track, scene: slot,
                                            start: start, length: end - start, offset: 0))
            newIDs.insert(id)
        }
        guard !newTimeline.isEmpty else { return }
        let removed = Set(chosen.map(\.id))
        timeline.removeAll { removed.contains($0.id) }
        timeline.append(contentsOf: newTimeline)
        selectedClips = newIDs
        selectedTimeline = newIDs.first
        if let first = newIDs.first, let clip = timelineClip(id: first) {
            selection = Selection(track: clip.track, scene: clip.scene)
        }
        syncTimeline()
        status = "consolidated \(chosen.count) clips"
    }

    /// Join selected audio clips on one track using the real offline renderer, replacing them
    /// with one waveform clip. The selected span on that track is bounced; this is the same
    /// contract as Live's audio consolidate rather than a raw file append.
    private func consolidateAudioClips(_ chosen: [TimelineClip]) {
        guard Set(chosen.map(\.track)).count == 1, let track = chosen.first?.track else {
            status = "select audio clips on one track to consolidate"
            return
        }
        guard chosen.allSatisfy({ clips[$0.track][$0.scene].samplePath != nil }) else {
            status = "select only audio clips to use audio consolidate"
            return
        }
        let start = chosen.map(\.start).min() ?? 0
        let end = chosen.map { $0.start + $0.length }.max() ?? start
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pocket-Consolidate-\(UUID().uuidString).wav")
        do {
            try bounceMixdown(to: url, start: start, end: end, tail: 0, onlyTrack: track)
        } catch {
            status = "audio consolidate failed: \(error.localizedDescription)"
            return
        }
        pushUndo()
        for clip in chosen { deleteTimelineClip(clip.id) }
        dropAudio(path: url.path, track: track, start: start)
        guard let newID = selectedTimeline,
              let index = timeline.firstIndex(where: { $0.id == newID }) else { return }
        timeline[index].length = end - start
        let clip = timeline[index]
        var info = clips[clip.track][clip.scene]
        info.loopSteps = end - start
        clips[clip.track][clip.scene] = info
        shared.loops[Shared.clipIndex(track: clip.track, scene: clip.scene)] = Int32(end - start)
        syncTimeline()
        selectedClips = [newID]
        status = "consolidated \(chosen.count) audio clip\(chosen.count == 1 ? "" : "s")"
    }

    func copySelectedClips() {
        let ids = selectedClips.isEmpty
            ? (selectedTimeline.map { [$0] } ?? [])
            : Array(selectedClips)
        let chosen = timeline.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }
        clipClipboard = chosen.map { ($0, clips[$0.track][$0.scene]) }
        status = "copied \(chosen.count) clip\(chosen.count == 1 ? "" : "s")"
    }

    func pasteClips() {
        guard !clipClipboard.isEmpty else {
            status = "clipboard is empty"
            return
        }
        pushUndo()
        let base = clipClipboard.map(\.0.start).min() ?? 0
        let targetBase = max(0, insertStep)
        var pasted: Set<Int> = []
        for (clip, info) in clipClipboard {
            let track = min(max(clip.track, 0), tracks.count - 1)
            let start = targetBase + (clip.start - base)
            guard let id = addTimelineClip(track: track, scene: -1,
                                           start: start, length: clip.length),
                  let copy = timelineClip(id: id) else { continue }
            var copied = info
            copied.notes = copied.notes.map { note in
                var next = note
                next.id = nextNoteID
                nextNoteID += 1
                return next
            }
            clips[copy.track][copy.scene] = copied
            let index = Shared.clipIndex(track: copy.track, scene: copy.scene)
            if let path = copied.samplePath, let pool = samples, let slot = pool.slot(forPath: path) {
                shared.clipSample[index] = Int32(slot)
            }
            shared.clipSampleStart[index] = Float(copied.sampleStart)
            shared.clipFadeIn[index] = Float(copied.sampleFadeIn)
            shared.clipFadeOut[index] = Float(copied.sampleFadeOut)
            shared.clipSampleGain[index] = Float(copied.sampleGain)
            shared.clipSampleBPM[index] = Float(copied.sampleSourceBPM)
            shared.clipWarp[index] = copied.sampleWarp ? 1 : 0
            shared.clipReverse[index] = copied.sampleReverse ? 1 : 0
            syncNotes(track: copy.track, scene: copy.scene)
            pasted.insert(id)
        }
        selectedClips = pasted
        selectedTimeline = pasted.first
        syncTimeline()
        if autoCrossfade { applyAutoCrossfades() }
        status = "pasted at bar \(barNumber(at: targetBase))"
    }

    /// Creates a real overlap between two adjacent audio clips and puts reciprocal fades on the
    /// join. The clips start sharing the lane for a few steps, which is what makes this a
    /// crossfade rather than two unrelated fade handles touching end-to-end.
    @discardableResult
    func crossfadeSelectedClip(overlapSteps: Int? = nil) -> Bool {
        guard let id = selectedTimeline, let left = timelineClip(id: id),
              clips[left.track][left.scene].samplePath != nil else {
            status = "select an audio clip to crossfade"
            return false
        }
        guard let right = timeline
            .filter({ $0.track == left.track && $0.id != id && $0.start == left.start + left.length })
            .min(by: { $0.start < $1.start }),
              clips[right.track][right.scene].samplePath != nil else {
            status = "the next clip must touch this one on the same track"
            return false
        }
        guard crossfade(leftID: left.id, rightID: right.id, overlapSteps: overlapSteps,
                        recordUndo: true) else { return false }
        selectedTimeline = left.id
        selectedClips = [left.id]
        return true
    }

    @discardableResult
    private func crossfade(leftID: Int, rightID: Int, overlapSteps: Int?,
                           recordUndo: Bool) -> Bool {
        guard let left = timelineClip(id: leftID), let right = timelineClip(id: rightID),
              left.track == right.track,
              clips[left.track][left.scene].samplePath != nil,
              clips[right.track][right.scene].samplePath != nil,
              right.start == left.start + left.length,
              left.length > 2, right.length > 2 else { return false }
        let requested = max(1, overlapSteps ?? max(snapSteps, 1))
        let overlap = min(requested, left.length - 1, right.length - 1)
        guard overlap > 0 else { return false }
        if recordUndo { pushUndo() }
        guard let leftIndex = timeline.firstIndex(where: { $0.id == left.id }),
              let rightIndex = timeline.firstIndex(where: { $0.id == right.id }) else {
            return false
        }
        timeline[leftIndex].length += overlap
        timeline[rightIndex].start -= overlap
        // Preserve the right clip's source alignment where possible. A first-take file has
        // offset zero, so it simply starts earlier in the file; a split clip keeps its source
        // position by moving its offset back with the timeline edge.
        timeline[rightIndex].offset = max(0, timeline[rightIndex].offset - overlap)
        let seconds = Double(overlap) * 60.0 / bpm / 4.0
        setClipFade(left.id, fadeOut: seconds)
        setClipFade(right.id, fadeIn: seconds)
        syncTimeline()
        status = "crossfade · \(overlap) step\(overlap == 1 ? "" : "s")"
        return true
    }

    /// Automatic crossfades: after a drag or a drop, every pair of audio clips that still touch
    /// gets the same real overlap fade the XFADE button makes. Re-running is a no-op because the
    /// clips no longer touch once the overlap exists.
    func applyAutoCrossfades() {
        guard autoCrossfade else { return }
        var changed = false
        for track in 0..<tracks.count {
            let ordered = timeline.filter {
                $0.track == track && clips[$0.track][$0.scene].samplePath != nil
            }.sorted { $0.start < $1.start }
            guard ordered.count > 1 else { continue }
            for i in 0..<(ordered.count - 1) {
                guard let left = timelineClip(id: ordered[i].id),
                      let right = timelineClip(id: ordered[i + 1].id) else { continue }
                guard right.start == left.start + left.length else { continue }
                if crossfade(leftID: left.id, rightID: right.id, overlapSteps: 1,
                             recordUndo: false) {
                    changed = true
                }
            }
        }
        if changed {
            syncTimeline()
            status = "auto crossfade · adjacent audio clips"
        }
    }

    func setClipFade(_ id: Int, fadeIn: Double? = nil, fadeOut: Double? = nil) {
        guard let clip = timelineClip(id: id) else { return }
        var info = clips[clip.track][clip.scene]
        let index = Shared.clipIndex(track: clip.track, scene: clip.scene)
        if let value = fadeIn {
            info.sampleFadeIn = min(max(value, 0), 4)
            shared.clipFadeIn[index] = Float(info.sampleFadeIn)
        }
        if let value = fadeOut {
            info.sampleFadeOut = min(max(value, 0), 4)
            shared.clipFadeOut[index] = Float(info.sampleFadeOut)
        }
        clips[clip.track][clip.scene] = info
    }

    func nudgeSelectedClip(steps: Int = 0, tracks delta: Int = 0) {
        let ids = selectedClips.isEmpty
            ? (selectedTimeline.map { [$0] } ?? [])
            : Array(selectedClips)
        guard !ids.isEmpty else { return }
        pushUndo()
        for id in ids {
            guard let clip = timelineClip(id: id) else { continue }
            if delta != 0 {
                moveTimelineClip(id, to: clip.start,
                                 track: min(max(clip.track + delta, 0), tracks.count - 1))
            } else {
                moveTimelineClip(id, to: clip.start + steps)
            }
        }
    }

    // MARK: - …Time commands

    private func splitAllClips(at step: Int) {
        let ids = timeline.filter { $0.start < step && step < $0.start + $0.length }.map(\.id)
        for id in ids { _ = splitTimelineRecord(id, at: step) }
    }

    func insertTime(at step: Int, length: Int) {
        let at = max(0, step)
        let amount = max(1, length)
        pushUndo()
        splitAllClips(at: at)
        for i in timeline.indices where timeline[i].start >= at {
            timeline[i].start += amount
        }
        for i in locators.indices where locators[i].step >= at { locators[i].step += amount }
        if loopStart >= at { loopStart += amount }
        if insertStep >= at { insertStep += amount }
        syncTimeline()
        status = "inserted \(formattedBars(amount))"
    }

    func deleteTime(start: Int, end: Int) {
        let a = max(0, min(start, end))
        let b = max(start, end)
        guard b > a else { return }
        pushUndo()
        splitAllClips(at: a)
        splitAllClips(at: b)
        timeline.removeAll { $0.start >= a && $0.start + $0.length <= b }
        let amount = b - a
        for i in timeline.indices where timeline[i].start >= b { timeline[i].start -= amount }
        locators.removeAll { $0.step >= a && $0.step < b }
        for i in locators.indices where locators[i].step >= b { locators[i].step -= amount }
        if loopStart >= b { loopStart = max(0, loopStart - amount) }
        else if loopStart > a { loopStart = a }
        if insertStep >= b { insertStep = max(0, insertStep - amount) }
        else if insertStep > a { insertStep = a }
        selectedClips.removeAll()
        selectedTimeline = nil
        syncTimeline()
        timeSelection = nil
        status = "deleted \(formattedBars(amount))"
    }

    func duplicateTime(start: Int, end: Int) {
        let a = max(0, min(start, end))
        let b = max(start, end)
        guard b > a else { return }
        pushUndo()
        splitAllClips(at: a)
        splitAllClips(at: b)
        let amount = b - a
        let inside = timeline.filter { $0.start >= a && $0.start + $0.length <= b }
        for i in timeline.indices where timeline[i].start >= b { timeline[i].start += amount }
        for clip in inside {
            var copy = clip
            copy.id = nextClipID
            nextClipID += 1
            copy.start += amount
            timeline.append(copy)
        }
        let copiedLocators = locators.filter { $0.step >= a && $0.step < b }
        for i in locators.indices where locators[i].step >= b { locators[i].step += amount }
        for locator in copiedLocators {
            var copy = locator
            copy.id = nextLocatorID
            nextLocatorID += 1
            copy.step += amount
            locators.append(copy)
        }
        if loopStart >= b { loopStart += amount }
        if insertStep >= b { insertStep += amount }
        syncTimeline()
        timeSelection = nil
        status = "duplicated \(formattedBars(amount))"
    }

    // MARK: - Automation

    func automationPoints(track: Int) -> [AutomationPoint] {
        automationPoints(track: track, target: automationTarget)
    }

    func automationPoints(track: Int, target: AutomationTarget) -> [AutomationPoint] {
        switch target {
        case .volume: return automation[track] ?? []
        case .pan: return panAutomation[track] ?? []
        case .send: return sendAutomation[track] ?? []
        case .cutoff: return cutoffAutomation[track] ?? []
        case .clipGain:
            guard let clip = gainClip(for: track) else { return [] }
            return clips[clip.track][clip.scene].gainEnvelope.map {
                AutomationPoint(step: clip.start + $0.step, value: $0.value)
            }
        }
    }

    /// The clip whose gain envelope the CLIP GAIN lane edits: the selected placement, else the
    /// first placement on that lane. Clip gain lives with the clip, so placements share it.
    private func gainClip(for track: Int) -> TimelineClip? {
        if let id = selectedTimeline, let clip = timelineClip(id: id), clip.track == track {
            return clip
        }
        return timeline.filter { $0.track == track }.min { $0.start < $1.start }
    }

    private func setAutomationPoints(_ points: [AutomationPoint], track: Int,
                                     target: AutomationTarget) {
        switch target {
        case .volume: automation[track] = points
        case .pan: panAutomation[track] = points
        case .send: sendAutomation[track] = points
        case .cutoff: cutoffAutomation[track] = points
        case .clipGain:
            guard let clip = gainClip(for: track) else { return }
            let last = max(clip.length - 1, 0)
            let local = points.map {
                AutomationPoint(step: max(0, min($0.step - clip.start, last)), value: $0.value)
            }
            clips[clip.track][clip.scene].gainEnvelope = local
            syncClipGain(track: clip.track, scene: clip.scene)
        }
    }

    func setAutomationTarget(_ target: AutomationTarget) {
        automationTarget = target
        status = "automation: \(target.label)"
    }

    func addAutomationPoint(track: Int, step: Int, value: Double,
                            target: AutomationTarget? = nil) {
        guard track >= 0, track < tracks.count else { return }
        let chosen = target ?? automationTarget
        var points = automationPoints(track: track, target: chosen)
        let position = max(0, min(step, Shared.maxAutoSteps - 1))
        let level = min(max(value, 0), 1)
        if let index = points.firstIndex(where: { abs($0.step - position) <= 1 }) {
            points[index].value = level
        } else {
            points.append(AutomationPoint(step: position, value: level))
        }
        points.sort { $0.step < $1.step }
        setAutomationPoints(points, track: track, target: chosen)
        syncAutomation()
    }

    func moveAutomationPoint(track: Int, index: Int, step: Int, value: Double,
                             target: AutomationTarget? = nil) {
        let chosen = target ?? automationTarget
        guard var points = Optional(automationPoints(track: track, target: chosen)),
              index >= 0, index < points.count else { return }
        points[index].step = max(0, min(step, Shared.maxAutoSteps - 1))
        points[index].value = min(max(value, 0), 1)
        points.sort { $0.step < $1.step }
        setAutomationPoints(points, track: track, target: chosen)
        syncAutomation()
    }

    func clearAutomation(track: Int, target: AutomationTarget? = nil) {
        pushUndo()
        let chosen = target ?? automationTarget
        setAutomationPoints([], track: track, target: chosen)
        syncAutomation()
        status = "\(chosen.label) automation cleared"
    }

    func syncAutomation() {
        writeAutomation(automation, into: shared.autoVol)
        writeAutomation(panAutomation, into: shared.autoPan)
        writeAutomation(sendAutomation, into: shared.autoSend)
        writeAutomation(cutoffAutomation, into: shared.autoCutoff)
    }

    /// Rebuilds every per-track shared region after a reorder. Track order is real: clip rows,
    /// insert chains and instrument pointers all follow the lane.
    private func resyncTrackState() {
        for t in 0..<Shared.maxTracks {
            for s in 0..<Shared.sceneCount {
                let index = Shared.clipIndex(track: t, scene: s)
                shared.noteCount[index] = 0
                shared.loops[index] = 16
                shared.hasClip[index] = 0
                shared.clipSample[index] = -1
                shared.clipWarp[index] = 0
                shared.clipStretch[index] = 0
                shared.clipReverse[index] = 0
                shared.clipWarpCount[index] = 0
                shared.clipRegionCount[index] = 0
                shared.clipGainCount[index] = 0
            }
        }
        for t in 0..<tracks.count {
            pushFX(t)
            for s in 0..<Shared.sceneCount {
                let info = clips[t][s]
                guard info.exists else { continue }
                syncNotes(track: t, scene: s)
                let index = Shared.clipIndex(track: t, scene: s)
                if let path = info.samplePath, let pool = samples,
                   let slot = pool.slot(forPath: path) {
                    shared.clipSample[index] = Int32(slot)
                }
                shared.clipSampleStart[index] = Float(info.sampleStart)
                shared.clipSampleGain[index] = Float(info.sampleGain)
                shared.clipFadeIn[index] = Float(info.sampleFadeIn)
                shared.clipFadeOut[index] = Float(info.sampleFadeOut)
                shared.clipSampleBPM[index] = Float(info.sampleSourceBPM)
                shared.clipWarp[index] = info.sampleWarp ? 1 : 0
                shared.clipReverse[index] = info.sampleReverse ? 1 : 0
                shared.clipStretch[index] = info.warpStretch ? 1 : 0
            }
        }
    }

    private func writeAutomation(_ map: [Int: [AutomationPoint]],
                                 into buffer: UnsafeMutableBufferPointer<Float>) {
        for i in 0..<buffer.count { buffer[i] = -1 }
        guard !map.isEmpty else { return }
        let limit = min(max(max(arrLength, loopEnd), stepsPerBar * 4), Shared.maxAutoSteps)
        for (track, raw) in map where track >= 0 && track < tracks.count {
            let points = raw.sorted { $0.step < $1.step }
            guard let first = points.first, let last = points.last else { continue }
            for step in 0..<limit {
                let level: Double
                if step <= first.step { level = first.value }
                else if step >= last.step { level = last.value }
                else if let upper = points.firstIndex(where: { $0.step >= step }) {
                    let b = points[upper]
                    let a = points[max(upper - 1, 0)]
                    let span = max(b.step - a.step, 1)
                    let t = Double(step - a.step) / Double(span)
                    level = a.value + (b.value - a.value) * t
                } else { level = last.value }
                buffer[track * Shared.maxAutoSteps + step] = Float(level)
            }
        }
    }

    // MARK: - Track management

    func renameTrack(_ track: Int, _ name: String) {
        guard track >= 0, track < tracks.count else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tracks[track].name = trimmed
        status = "track renamed to \(trimmed)"
    }

    func setPan(_ track: Int, _ value: Double) {
        guard track >= 0, track < tracks.count else { return }
        setFX(track, pan: value)
    }

    /// Moves a whole lane, not just its label. Clips, clip slots, insert chains, the hosted
    /// instrument, automation and the mute/solo bits all travel with the track.
    func moveTrack(_ index: Int, by delta: Int) {
        guard delta != 0, tracks.count > 1, index >= 0, index < tracks.count else { return }
        let target = min(max(index + delta, 0), tracks.count - 1)
        guard target != index else { return }
        pushUndo()
        let selectedWas = selection.track
        var current = index
        while current != target {
            let step = current < target ? 1 : -1
            swapTracks(current, current + step)
            current += step
        }
        tracks = tracks.enumerated().map {
            TrackInfo(id: $0.offset, name: $0.element.name,
                      color: $0.element.color, wave: $0.element.wave)
        }
        if selectedWas == index {
            selection.track = target
        } else if index < target, selectedWas > index, selectedWas <= target {
            selection.track = selectedWas - 1
        } else if target < index, selectedWas >= target, selectedWas < index {
            selection.track = selectedWas + 1
        }
        resyncTrackState()
        shared.trackCount.pointee = Int32(tracks.count)
        selection.track = min(max(selection.track, 0), tracks.count - 1)
        syncTimeline()
        status = "moved \(tracks[target].name) to lane \(target + 1)"
    }

    private func swapTracks(_ a: Int, _ b: Int) {
        guard a != b else { return }
        let track = tracks[a]; tracks[a] = tracks[b]; tracks[b] = track
        let effect = fx[a]; fx[a] = fx[b]; fx[b] = effect
        let row = clips[a]; clips[a] = clips[b]; clips[b] = row
        let chain = inserts[a]; inserts[a] = inserts[b]; inserts[b] = chain
        let names = instrumentNames[a]; instrumentNames[a] = instrumentNames[b]; instrumentNames[b] = names

        let params = shared.trackParams[a]; shared.trackParams[a] = shared.trackParams[b]; shared.trackParams[b] = params
        let instPtr = shared.instPtr[a]; shared.instPtr[a] = shared.instPtr[b]; shared.instPtr[b] = instPtr
        let instOn = shared.instOn[a]; shared.instOn[a] = shared.instOn[b]; shared.instOn[b] = instOn
        let instLatency = shared.instrumentLatency[a]
        shared.instrumentLatency[a] = shared.instrumentLatency[b]
        shared.instrumentLatency[b] = instLatency
        let instA = instrumentSlots[a]; instrumentSlots[a] = instrumentSlots[b]; instrumentSlots[b] = instA

        for slot in 0..<Shared.maxInserts {
            let ai = a * Shared.maxInserts + slot
            let bi = b * Shared.maxInserts + slot
            let p = shared.pluginPtr[ai]; shared.pluginPtr[ai] = shared.pluginPtr[bi]; shared.pluginPtr[bi] = p
            let on = shared.pluginOn[ai]; shared.pluginOn[ai] = shared.pluginOn[bi]; shared.pluginOn[bi] = on
            let latency = shared.pluginLatency[ai]
            shared.pluginLatency[ai] = shared.pluginLatency[bi]
            shared.pluginLatency[bi] = latency
            let pluginA = pluginSlots[ai]; pluginSlots[ai] = pluginSlots[bi]; pluginSlots[bi] = pluginA
        }

        for i in timeline.indices {
            if timeline[i].track == a { timeline[i].track = b }
            else if timeline[i].track == b { timeline[i].track = a }
        }
        swapAutomation(&automation, a, b)
        swapAutomation(&panAutomation, a, b)
        swapAutomation(&sendAutomation, a, b)
        swapAutomation(&cutoffAutomation, a, b)

        let muteA = (muteMask >> a) & 1
        let muteB = (muteMask >> b) & 1
        if muteA != muteB { muteMask ^= (1 << a) | (1 << b) }
        let soloA = (soloMask >> a) & 1
        let soloB = (soloMask >> b) & 1
        if soloA != soloB { soloMask ^= (1 << a) | (1 << b) }
        shared.muteMask.pointee = Int32(muteMask)
        shared.soloMask.pointee = Int32(soloMask)
    }

    private func swapAutomation(_ map: inout [Int: [AutomationPoint]], _ a: Int, _ b: Int) {
        let first = map[a]
        map[a] = map[b]
        map[b] = first
    }

    /// Delete any track, compacting the track-dependent arrays and clip slots.
    func removeTrack(at index: Int) {
        guard tracks.count > 1, index >= 0, index < tracks.count else { return }
        audio?.releaseVoices(onTrack: index)
        AUWindowManager.shared.closeAll()

        if let instrument = instrumentSlots[index] {
            shared.instOn[index] = 0
            shared.instPtr[index] = nil
            retiredInstruments.append(instrument)
        }
        for slot in 0..<Shared.maxInserts {
            let key = index * Shared.maxInserts + slot
            if let plugin = pluginSlots[key] {
                shared.pluginOn[key] = 0
                shared.pluginPtr[key] = nil
                retiredPlugins.append(plugin)
            }
        }

        for t in index..<(tracks.count - 1) {
            instrumentSlots[t] = instrumentSlots[t + 1]
            instrumentNames[t] = instrumentNames[t + 1]
            shared.instPtr[t] = shared.instPtr[t + 1]
            shared.instOn[t] = shared.instOn[t + 1]
            shared.instrumentLatency[t] = shared.instrumentLatency[t + 1]
            shared.groupOf[t] = shared.groupOf[t + 1]
            shared.trackParams[t] = shared.trackParams[t + 1]
            for slot in 0..<Shared.maxInserts {
                let dst = t * Shared.maxInserts + slot
                let src = (t + 1) * Shared.maxInserts + slot
                pluginSlots[dst] = pluginSlots[src]
                shared.pluginPtr[dst] = shared.pluginPtr[src]
                shared.pluginOn[dst] = shared.pluginOn[src]
                shared.pluginLatency[dst] = shared.pluginLatency[src]
            }
            clips[t] = clips[t + 1]
        }
        let last = tracks.count - 1
        instrumentSlots[last] = nil
        instrumentNames[last] = nil
        shared.instPtr[last] = nil
        shared.instOn[last] = 0
        shared.instrumentLatency[last] = 0
        shared.groupOf[last] = 0
        for slot in 0..<Shared.maxInserts {
            let key = last * Shared.maxInserts + slot
            pluginSlots[key] = nil
            shared.pluginPtr[key] = nil
            shared.pluginOn[key] = 0
            shared.pluginLatency[key] = 0
        }
        clips[last] = Array(repeating: ClipInfo(), count: Shared.sceneCount)
        for slot in 0..<Shared.maxInserts {
            let key = last * Shared.maxInserts + slot
            shared.pluginPtr[key] = nil
            shared.pluginOn[key] = 0
        }

        timeline.removeAll { $0.track == index }
        for i in timeline.indices where timeline[i].track > index { timeline[i].track -= 1 }
        inactiveClips.removeAll()
        tracks.remove(at: index)
        fx.remove(at: index)
        inserts.remove(at: index)
        shared.trackCount.pointee = Int32(tracks.count)
        for t in 0..<tracks.count { pushFX(t) }
        for g in 1...Shared.maxGroups {
            shared.groupVolume[g] = groupVolumes[g]
            shared.groupPan[g] = groupPans[g]
        }
        shared.returnLevel.pointee = Float(returnLevel)
        selectedClips.removeAll()
        selectedTimeline = nil
        selection = Selection(track: min(index, tracks.count - 1), scene: 0)
        focusArrangement()
        resyncTrackState()
        syncTimeline()
        invalidateHistory()
        status = "track deleted"
    }

    // MARK: - Undo

    func beginGestureEdit() {
        guard !gestureEditing else { return }
        pushUndo()
        gestureEditing = true
    }

    func endGestureEdit() {
        gestureEditing = false
        if autoCrossfade { applyAutoCrossfades() }
    }

    func invalidateHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        canUndo = false
        canRedo = false
    }

    private func snapshot() -> ArrangementSnapshot {
        ArrangementSnapshot(tracks: tracks, clips: clips, fx: fx, timeline: timeline,
                            locators: locators, loopStart: loopStart, loopLength: loopLength,
                            loopEnabled: loopEnabled, arrLength: arrLength,
                            insertStep: insertStep, selectedClips: selectedClips,
                            inactiveClips: inactiveClips, selectedNote: selectedNote,
                            selectedNotes: selectedNotes, automation: automation,
                            panAutomation: panAutomation, sendAutomation: sendAutomation,
                            cutoffAutomation: cutoffAutomation,
                            timeSigNumerator: timeSigNumerator,
                            timeSigDenominator: timeSigDenominator)
    }

    func pushUndo() {
        undoStack.append(snapshot())
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let snap = undoStack.popLast() else {
            status = "nothing to undo"
            return
        }
        redoStack.append(snapshot())
        restore(snap)
        status = "undo"
    }

    func redo() {
        guard let snap = redoStack.popLast() else {
            status = "nothing to redo"
            return
        }
        undoStack.append(snapshot())
        restore(snap)
        status = "redo"
    }

    private func restore(_ snap: ArrangementSnapshot) {
        tracks = snap.tracks
        clips = snap.clips
        fx = snap.fx
        timeline = snap.timeline
        locators = snap.locators
        loopStart = snap.loopStart
        loopLength = snap.loopLength
        loopEnabled = snap.loopEnabled
        arrLength = snap.arrLength
        insertStep = snap.insertStep
        selectedClips = snap.selectedClips
        inactiveClips = snap.inactiveClips
        selectedNote = snap.selectedNote
        selectedNotes = snap.selectedNotes
        automation = snap.automation
        panAutomation = snap.panAutomation
        sendAutomation = snap.sendAutomation
        cutoffAutomation = snap.cutoffAutomation
        timeSigNumerator = snap.timeSigNumerator
        timeSigDenominator = snap.timeSigDenominator
        shared.trackCount.pointee = Int32(tracks.count)

        for t in 0..<min(tracks.count, fx.count) { pushFX(t) }
        for t in 0..<Shared.maxTracks {
            for s in 0..<Shared.sceneCount {
                let index = Shared.clipIndex(track: t, scene: s)
                shared.noteCount[index] = 0
                shared.hasClip[index] = 0
                shared.clipSample[index] = -1
                shared.loops[index] = 16
            }
        }
        for t in 0..<min(tracks.count, clips.count) {
            for s in 0..<Shared.sceneCount {
                let info = clips[t][s]
                guard info.exists else { continue }
                syncNotes(track: t, scene: s)
                let index = Shared.clipIndex(track: t, scene: s)
                if let path = info.samplePath, let pool = samples,
                   let slot = pool.slot(forPath: path) {
                    shared.clipSample[index] = Int32(slot)
                }
                shared.clipSampleStart[index] = Float(info.sampleStart)
                shared.clipSampleGain[index] = Float(info.sampleGain)
                shared.clipFadeIn[index] = Float(info.sampleFadeIn)
                shared.clipFadeOut[index] = Float(info.sampleFadeOut)
                shared.clipSampleBPM[index] = Float(info.sampleSourceBPM)
                shared.clipWarp[index] = info.sampleWarp ? 1 : 0
                shared.clipReverse[index] = info.sampleReverse ? 1 : 0
                shared.clipStretch[index] = info.warpStretch ? 1 : 0
            }
        }
        nextClipID = (timeline.map(\.id).max() ?? 0) + 1
        var maxNote = 0
        for row in clips { for info in row { for note in info.notes { maxNote = max(maxNote, note.id) } } }
        nextNoteID = maxNote + 1
        if selection.track >= tracks.count {
            selection = Selection(track: max(tracks.count - 1, 0), scene: 0)
        }
        selectedTimeline = selectedClips.first
        syncTimeline()
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Setup

}

