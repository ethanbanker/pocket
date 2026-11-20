import Foundation

/// A note in a clip: polyphonic, with its own length and velocity.
struct NoteData: Codable, Identifiable, Equatable {
    var id: Int
    var start: Int        // step offset inside the clip
    var length: Int       // in steps
    var pitch: Int        // absolute MIDI note, 0...127
    var velocity: Int     // 1...127
    /// Optional keeps older project JSON valid. 100 = always play; 0 = never.
    var probability: Int? = nil
    /// Per-note late offset as a fraction of one step, 0...0.9.
    var groove: Double? = nil
}

/// One recorded or imported audio performance. A clip keeps every take; the active take is the
/// one the renderer plays. This is deliberately file-backed so switching comps never decodes or
/// re-encodes the source material.
struct AudioTake: Codable, Identifiable, Equatable {
    var id: Int
    var path: String
    var name: String
}

/// A warp anchor. `sourceSeconds` is measured from the start of the audio file, `timelineStep`
/// from the start of the clip. Between anchors the renderer reads the file linearly, so anchors
/// let a performance line up with the grid without rebuilding the file.
struct WarpMarker: Codable, Equatable {
    var sourceSeconds: Double
    var timelineStep: Double
}

/// A comped span of a clip. The region plays `take` instead of the clip's active take; regions
/// may touch but not overlap, and anything outside them falls back to the active take.
struct CompRegion: Codable, Equatable {
    var startStep: Int
    var endStep: Int
    var take: Int
}

/// Real arpeggiator patterns. They run in the step sequencer against the notes that are
/// sounding in the clip, so playback and bounce arpeggiate identically.
enum ArpMode: String, CaseIterable, Identifiable {
    case off, up, down, updown
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "OFF"
        case .up: return "UP"
        case .down: return "DOWN"
        case .updown: return "UP/DOWN"
        }
    }
    var code: Int32 {
        switch self {
        case .off: return 0
        case .up: return 1
        case .down: return 2
        case .updown: return 3
        }
    }
}

enum ArpRate: String, CaseIterable, Identifiable {
    case sixteenth, eighth, quarter
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sixteenth: return "1/16"
        case .eighth: return "1/8"
        case .quarter: return "1/4"
        }
    }
    var steps: Int {
        switch self {
        case .sixteenth: return 1
        case .eighth: return 2
        case .quarter: return 4
        }
    }
}

/// A clip placed on the arrangement timeline. It references the pattern/sample stored in a
/// session clip (track + scene), so editing the pattern updates every placement of it.
struct TimelineClip: Codable, Identifiable, Equatable {
    var id: Int
    var track: Int
    var scene: Int
    var start: Int        // steps from the top of the arrangement
    var length: Int       // steps
    var offset: Int = 0   // where inside the source pattern the placement begins
}

/// A named song position in the Arrangement ruler.
struct Locator: Codable, Identifiable, Equatable {
    var id: Int
    var name: String
    var step: Int
}

/// One breakpoint on a track volume automation envelope.
struct AutomationPoint: Codable, Equatable {
    var step: Int          // arrangement step
    var value: Double      // 0...1
}

struct TrackAutomation: Codable, Equatable {
    var track: Int
    var points: [AutomationPoint]
}

/// Editable arrangement envelopes. Values are stored normalized 0...1; the renderer maps pan
/// to -1...1 and cutoff to a logarithmic 80 Hz...18 kHz range.
enum AutomationTarget: String, CaseIterable, Identifiable {
    case volume, pan, send, cutoff, clipGain

    var id: String { rawValue }
    var label: String {
        switch self {
        case .volume: return "VOL"
        case .pan: return "PAN"
        case .send: return "SEND"
        case .cutoff: return "CUTOFF"
        case .clipGain: return "CLIP GAIN"
        }
    }
}

/// A timespan selected in the arrangement, in steps.
struct TimeRange: Equatable {
    var start: Int
    var end: Int
    var length: Int { max(0, end - start) }
    var isEmpty: Bool { end <= start }
}

/// Ableton's editing grid choices, reduced to the ones Pocket's step clock can honour.
enum SnapGrid: String, CaseIterable, Identifiable {
    case bar, beat, eighth, sixteenth, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bar: return "BAR"
        case .beat: return "BEAT"
        case .eighth: return "1/8"
        case .sixteenth: return "1/16"
        case .off: return "OFF"
        }
    }
    var steps: Int {
        switch self {
        case .bar: return 16
        case .beat: return 4
        case .eighth: return 2
        case .sixteenth: return 1
        case .off: return 1
        }
    }
}

/// Which pane owns keyboard commands. Clicking a clip, a piano-roll grid/key, or a browser row
/// moves focus there, so ⌘D and Delete act on what the user is looking at instead of a stale
/// selection from another pane.
enum PocketFocus {
    case arrangement
    case pianoRoll
    case browser
}

/// What the transport record button captures. Audio capture lands on the armed track as a
/// normal waveform clip; MIDI capture builds a note clip there.
enum RecordMode: String, CaseIterable, Identifiable {
    case midi = "MIDI"
    case audio = "AUDIO"
    var id: String { rawValue }
}

/// A control destination that can be learned from an incoming MIDI CC.
/// Scale constraint for drawing and transposing MIDI notes. Chromatic is the default.
enum ScaleMode: String, CaseIterable, Identifiable {
    case chromatic, major, minor, dorian, mixolydian, pentatonicMinor, pentatonicMajor

    var id: String { rawValue }
    var label: String {
        switch self {
        case .chromatic: return "CHROMATIC"
        case .major: return "MAJOR"
        case .minor: return "MINOR"
        case .dorian: return "DORIAN"
        case .mixolydian: return "MIXOLYDIAN"
        case .pentatonicMinor: return "PENTA MINOR"
        case .pentatonicMajor: return "PENTA MAJOR"
        }
    }

    var intervals: [Int] {
        switch self {
        case .chromatic: return Array(0..<12)
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        case .dorian: return [0, 2, 3, 5, 7, 9, 10]
        case .mixolydian: return [0, 2, 4, 5, 7, 9, 10]
        case .pentatonicMinor: return [0, 3, 5, 7, 10]
        case .pentatonicMajor: return [0, 2, 4, 7, 9]
        }
    }

    func snap(_ pitch: Int, root: Int) -> Int {
        guard self != .chromatic else { return min(max(pitch, 0), 127) }
        let r = ((root % 12) + 12) % 12
        var best = min(max(pitch, 0), 127)
        var bestDistance = Int.max
        for candidate in 0...127 where intervals.contains((candidate - r + 144) % 12) {
            let distance = abs(candidate - pitch)
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }
}

enum MIDIMapTarget: String, CaseIterable, Identifiable {
    case master
    case trackVolume
    case trackPan
    case trackSend
    case trackCutoff

    var id: String { rawValue }
    var label: String {
        switch self {
        case .master: return "MASTER"
        case .trackVolume: return "TRACK VOLUME"
        case .trackPan: return "TRACK PAN"
        case .trackSend: return "TRACK SEND"
        case .trackCutoff: return "TRACK CUTOFF"
        }
    }
}

struct MIDIMapping {
    var cc: Int
    var target: MIDIMapTarget
    var track: Int
}

/// One event in the rolling MIDI capture buffer. Kept on the main thread; the realtime note
/// path still uses the lock-free ring in `Shared`.
struct CapturedMIDIEvent {
    var status: UInt8
    var note: Int
    var velocity: Int
    var step: Int
    var timestamp: TimeInterval
}

struct CapturedMIDINote {
    var start: Int
    var length: Int
    var pitch: Int
    var velocity: Int
}

/// Transient arrangement gestures. Stored on the session model because this toolchain has no
/// SwiftUI macro plugin, so `@State` is not available.
enum ArrangementBackgroundMode {
    case none
    case create(track: Int, start: Int)
    case newTrack(start: Int)
    case time(start: Int)
}

enum ArrangementRulerMode {
    case none
    case seek
    case loopStart
    case loopEnd
    case loopMove(origin: Int)
}

final class ArrangementInteraction {
    var backgroundMode: ArrangementBackgroundMode = .none
    var rulerMode: ArrangementRulerMode = .none
    var rulerOriginStep = 0
    var moveOrigin: (start: Int, track: Int)? = nil
    var moveTargetStart: Int? = nil
    var moveTargetTrack: Int? = nil
    var dragClipID: Int? = nil
    var dragClipOriginStart = 0
    var dragClipOriginTrack = 0
    var dragClipTargetStart = 0
    var dragClipTargetTrack = 0
    var dragClipBegan = false
    var scrollbarStart: CGFloat? = nil
    var timelineScrollbarStart: CGFloat? = nil
    var resizeClipID: Int? = nil
    var resizeLeftEdge = false
    var resizeOriginStart = 0
    var resizeOriginLength = 0
    var resizeBegan = false
    var fadeClipID: Int? = nil
    var fadeIsOut = false
    var fadeOrigin = 0.0
    var fadeBegan = false
    var resizeOrigin: Int? = nil
    var resizeStartOrigin: Int? = nil
    var fadeInOrigin: Double? = nil
    var fadeOutOrigin: Double? = nil
    var automationDragIndex: Int? = nil
}

/// A hosted Audio Unit insert, stored by component identity plus its full AU state.
/// `state` is optional so older Pocket projects still open; when it is absent the plugin
/// loads at its defaults exactly as before.
struct PluginData: Codable {
    var slot: Int
    var name: String
    var type: UInt32
    var subtype: UInt32
    var manufacturer: UInt32
    var state: Data? = nil
}

struct ClipData: Codable {
    var track: Int
    var scene: Int
    var loopSteps: Int
    var notes: [NoteData]
    var samplePath: String?
    var sampleGain: Float
    var sampleStart: Float? = nil
    var sampleFadeIn: Float? = nil
    var sampleFadeOut: Float? = nil
    var sampleSourceBPM: Double? = nil
    var sampleWarp: Bool? = nil
    var sampleReverse: Bool? = nil
    var takes: [AudioTake]? = nil
    var activeTake: Int? = nil
    var warpMarkers: [WarpMarker]? = nil
    var warpStretch: Bool? = nil
    var compRegions: [CompRegion]? = nil
    var gainEnvelope: [AutomationPoint]? = nil
}

struct TrackData: Codable {
    var name: String
    var params: TrackParams
    var volume: Double
    var send: Double
    var cutoff: Double
    var resonance: Double
    var drive: Double
    var group: Int? = nil
    var midiEffect: String? = nil
    var inserts: [PluginData]? = nil
    var instrument: PluginData? = nil
    var sendB: Double? = nil
    var arpMode: String? = nil
    var arpRate: String? = nil
}

struct ProjectFile: Codable {
    var version: Int = 9   // v9: stretch warp, comp regions, clip gain, returns B, arp
    var bpm: Double
    var master: Double
    var tracks: [TrackData]
    var clips: [ClipData]
    var timeline: [TimelineClip]? = nil
    var arrLength: Int? = nil
    var automation: [Float]? = nil   // trackCount x maxAutoSteps, flattened, -1 = none
    var locators: [Locator]? = nil
    var loopStart: Int? = nil
    var loopLength: Int? = nil
    var loopEnabled: Bool? = nil
    var inactiveClips: [Int]? = nil
    var automationPoints: [TrackAutomation]? = nil
    var automationByTarget: [String: [TrackAutomation]]? = nil
    var timeSigNumerator: Int? = nil
    var timeSigDenominator: Int? = nil
    var scaleRoot: Int? = nil
    var scaleMode: String? = nil
    var returnLevel: Double? = nil
    var returnLevelB: Double? = nil
    var autoCrossfade: Bool? = nil
}
