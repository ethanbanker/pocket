# Pocket

Pocket is a native macOS arrangement DAW written in Swift and AppKit on top of CoreAudio. It
provides one linear timeline for audio and MIDI, a piano roll, take comping, warping and
pitch-preserving time-stretch, automation, group and return buses, Audio Unit hosting, recording,
and WAV/stem export.

There are no third-party dependencies, no Xcode project, and no Session View.

Requires macOS 14 or later and a Swift 6 toolchain (Command Line Tools are sufficient).

## Build and run

```bash
git clone https://github.com/ethanbanker/pocket.git
cd pocket
swift run Pocket
```

| Command | Purpose |
| --- | --- |
| `swift run Pocket` | Launch the app |
| `swift run Pocket --selftest` | Run offline engine and DSP checks, no GUI |
| `./scripts/uitest.sh` | Build and run the synthetic UI regression suite |
| `./scripts/package.sh` | Release build, ad-hoc sign, and produce `dist/Pocket.app` + `dist/Pocket-macOS.zip` |

`Package.swift` uses swift-tools 6.0 with Swift 5 language mode and defines a single executable
target.

## Features

### Timeline and editing

- One custom two-axis viewport: wheel/trackpad panning, pointer-anchored ⌘-scroll zoom,
  persistent scrollbars, and edge auto-scroll during drags.
- Draw, move across tracks, resize, split, duplicate, copy/paste, deactivate, and consolidate
  clips. Clips may touch end-to-end but never overlap; blocked edits show a red ghost and a
  status message.
- Grid snapping at beat, bar, 1/8, 1/16 (default), or off. Time selection, duplicate/delete time,
  locators, loop brace, and bar-quantized follow.
- Up to 16 tracks, reorderable with ▲/▼. Reordering carries clips, clip slots, inserts,
  instruments, automation, and mute/solo state.

### Audio

- WAV, AIFF, MP3, and CAF import, stereo, up to 30 minutes per file, decoded once into a
  64-slot pool.
- Trim, source offset, clip gain, fade-in/fade-out, and reverse.
- Explicit per-clip warp with anchors, plus a pitch-preserving stretch mode.
- Recorded takes with active-take switching and region-based comping.
- Per-clip gain automation envelope.
- Manual crossfades and an optional automatic crossfade mode for touching audio clips.
- Offline consolidation of a selected audio span.

### MIDI

- 128-key piano roll with draw, move, resize, velocity editing, marquee selection, group move,
  quantize, and undoable note edits.
- Per-note probability and groove offset; scale-constrained drawing; chord, octave, and fifth
  transformations.
- Per-track arpeggiator (up, down, up/down) at 1/16, 1/8, or 1/4.
- Rolling MIDI capture without transport recording, MIDI CC learn, and MPE input.

### Mixing and routing

- Per-track instrument, two insert slots, volume, pan, mute, solo, and record arm.
- Four group buses plus a master bus, with group volume and pan.
- Two return buses: A is a tempo-synced ping-pong delay, B is a Freeverb-style reverb. Every track
  has independent SEND A/SEND B amounts, and each return has its own level.
- Plugin delay compensation across instruments and insert chains.

### Recording and export

- Record MIDI or the explicitly selected audio input onto the armed track, with input monitoring
  and ±500 ms latency compensation.
- Audio takes are written as CAF files; recording into an existing audio clip appends a take.
- Export stereo 16-bit WAV for the whole song or a time selection.
- Export one stereo WAV per track as stems, including that track's instrument, inserts, fades,
  warp/reverse, send contribution, and automation.

## Architecture

### Engine and device handling

Pocket drives an AUHAL output unit directly. There is no `AVAudioEngine` and no hidden
sample-rate converter in the output path. The renderer, hosted Audio Units, and sample pool all
run at the selected device's nominal sample rate.

- Selecting an output stops the unit, sets `kAudioOutputUnitProperty_CurrentDevice`, reconfigures
  the stream format, and restarts it. The choice is remembered across launches.
- A nominal-rate change stops the unit, rebuilds the renderer at the new rate, re-decodes the
  sample pool, recreates the AU hosts, restores their state, and restarts audio.
- Buffer sizes of 64–2048 frames are offered where the device supports them. Device latency and
  safety offset are read from CoreAudio and reported as `AUHAL · rate · frames · ms`.
- Audio input is selected independently of the output. Monitoring runs through a separate
  `AVAudioEngine` tap and a lock-free ring, resampled into the AUHAL clock without opening a
  second audible output.

### Clock and realtime model

The AUHAL output callback owns the clock. Timing uses a fractional phase accumulator rather than
an integer step counter:

```text
stepPhase += 1 / samplesPerStep          // every rendered sample
if stepPhase >= 1 { advanceStep(offset: i); stepPhase -= 1 }
position = globalStep + stepPhase
```

A tempo whose step length is fractional therefore stays exact indefinitely. Notes are queued
with their sample offset and delivered to AUv2/AUv3 instruments at that offset inside the render
slice.

The UI writes plain fixed-size values into one preallocated `Shared` block. The audio callback
does not allocate memory, take locks, or touch Swift collections.

### DSP graph

Each track renders an instrument, then two insert effects, then its fader and pan:

```text
instrument (built-in synth or AU generator)
  → insert 1 → insert 2
  → volume / pan
  → group bus or master
  → SEND A / SEND B
```

The built-in polyphonic synth provides PolyBLEP saw, square, and sine oscillators with per-track
ADSR, gate, and pan. Hosted Audio Units run inside Pocket's callback. Group buses and both returns
sum into the master bus; returns are preallocated and processed in the same render pass.

Plugin delay compensation delays every track to the slowest instrument/insert chain using the
latency reported by each Audio Unit, so a look-ahead processor does not push one track late
relative to the others.

### Audio files, warp, and stretch

Files are decoded once by `AVAudioConverter` into stereo buffers at the engine rate. Sources at
44.1, 48, 88.2, 96, or 192 kHz are converted at import; a manual interpolator handles files the
converter rejects.

- **Warp** is opt-in per clip. `MARK` stores a source-time/timeline anchor at the playhead, and
  the renderer maps between anchors with piecewise-linear read positions. Default warp changes
  pitch with speed.
- **STRETCH** replaces that mapping with a granular overlap-add time-stretch. Two grains with a
  raised-cosine crossfade read the source at unity rate while grain scheduling follows the tempo
  map, so pitch is preserved while the clip changes length.
- **REV** reads the source backwards. Reverse remains repitch-only.

### Comping

Each recorded pass is retained as a decoded pool slot. The active take applies to the whole
placement by default; comp regions override it for a local span. Regions are clipped to the
placement, saved with the project, listed with their bar ranges, and removable individually.
Splitting a clip preserves its take list. A region whose take cannot be resolved is dropped
rather than silencing the rest of the clip.

### Automation

The automation lane provides four independent track envelopes — volume, pan, send, and filter
cutoff — plus the per-clip gain envelope. Points are added by clicking and moved by dragging;
clearing an envelope restores the mixer's base value. Envelope segments are linear, and the
long-song buffer holds 65,536 steps.

Clip gain is applied sample-accurately to audio and scales MIDI velocity at each note start.
0.5 is unity, with a range from silence to +6 dB.

### MIDI, MPE, and arpeggiation

CoreMIDI input is delivered through a lock-free ring. The channel nibble is preserved and
0xE0 pitch-bend messages are parsed. Per-channel bend retunes every voice on that channel in the
built-in synth and is forwarded to hosted Audio Units as channelized note-on plus pitch bend,
which is the MPE per-note path.

The arpeggiator is driven from notes sounding in the clip and runs through the same voice and
instrument path as normal playback, so offline bounces arpeggiate identically. A rolling capture
buffer turns recently played notes into a clip, and CC learn maps a controller to master volume,
track volume, pan, send, or cutoff.

### Offline rendering

Export and consolidations use the same `Renderer` implementation on a separate `Shared` snapshot
while the realtime graph is paused. The offline pass includes instruments, inserts, sends, both
returns, automation, sample playback, fades, reverse/stretch, and the master bus. Whole-song
exports add a 1.5 s tail for reverb and release; range exports add 0.15 s.

### Project format

Projects are JSON (`.json`), currently version 9. A file stores tempo, master level, global meter,
per-track parameters, pan, devices, group and send routing, arp settings, clips, notes, sample
settings, take lists and active take, source BPM, warp/stretch/reverse flags, warp anchors, comp
regions, gain envelopes, timeline, loop, locators, inactive clips, automation, scale, note
probability/groove, MIDI effects, return levels, and the automatic-crossfade preference.

Insert and instrument Audio Units are saved by component identity plus full `ClassInfo`/`fullState`.
A reopened project restores the patch, and a native-rate rebuild reapplies that state to the new
instances instead of loading factory defaults. Version 9 adds pitch-preserving stretch, comp
regions, clip gain, return B, and the arpeggiator; version 7 automation is migrated into the
long-song envelope buffer.

### UI implementation

The arrangement is a single custom viewport rather than nested `ScrollView`s, so clip drags and
two-axis scrolling remain consistent. View state lives on `SessionModel`; the project avoids
`@State` and other SwiftUI macro property wrappers because the Command Line Tools toolchain does
not ship the SwiftUI macros plugin.

## Source layout

```text
Sources/Pocket/
  main.swift                 AppKit bootstrap, menus, shortcuts, wheel routing
  Audio/
    AudioCore.swift          AUHAL output, device switching, native-rate rebuild
    AudioDevices.swift       CoreAudio enumeration, buffer ranges, latency
    Shared.swift             preallocated realtime state block
    Renderer.swift           clock, timeline, voices, samples, warp, AUs, mix
    Voice.swift              oscillators, envelopes, limiter
    Effects.swift            state-variable filter, ping-pong delay, reverb
    PluginHost.swift         AU effect hosting
    InstrumentHost.swift     AU generator hosting, channelized events
    MIDIInput.swift          CoreMIDI ring, channel/bend parsing
    InputMonitor.swift       selected input, monitoring ring, CAF writer
  Model/
    SamplePool.swift         decode, stereo buffers, waveform peaks
    Project.swift            Codable project model
    SessionModel.swift       tracks, editing, focus, undo, recording
    Recording.swift          MIDI and microphone capture
    OfflineMixdown.swift     WAV writer, offline bounce, consolidation
  UI/
    ArrangementView.swift    viewport, lanes, clips, ruler, automation
    PianoRoll.swift          note editor, marquee, velocity lane
    DetailPanel.swift        instrument/insert/audio clip/warp controls
    TransportBar.swift       transport, meter, export, project actions
    BrowserView.swift        file browser, search, audition, drag provider
  SelfTest.swift             offline engine and DSP checks
  UITest.swift               real-window synthetic input regression suite
```

## Verification

`--selftest` exercises the offline render path without a window: clock accuracy, synth output,
sample playback, warp/reverse, pitch-preserving stretch, clip gain, comp-region take switching,
the arpeggiator, MPE pitch bend, AU loading/state, and WAV output. `--uitest` builds a real
window, drives it with synthetic mouse and keyboard events, and asserts on both the model and the
shared audio state.

The suite covers timeline editing and overlap rejection, focus handoff, scrolling and zoom,
automation hit surfaces, MIDI editing and undo, record-range refusal, AUHAL device switching and
native-rate rebuild, import conversion, meter and snapping, MIDI recording and capture, CC learn,
group routing, AU state restore, stem export, automation, take comping, automatic crossfade, track
reordering, and audio consolidation.

Current results on this machine: **SELFTEST PASS** and **UITEST PASS 164 checks, 2 skipped**. The
skips are the real global cursor drag when lane 1 is off-screen and the alternate-rate device test
when no second output with a different rate is attached. Measured checks include a 220 Hz source
staying at ~214 Hz under 2× stretch (granular artifacts, ±18 Hz tolerance), clip-gain and
comp-region attenuation, arpeggiator single-note output versus a full chord, and a held note
moving from 438.9 Hz to 493.7 Hz under a +2 semitone MPE bend.

These suites validate the DSP and routing paths; they do not replace a manual pass with real
microphone, instrument, and MPE hardware.

## Limits

- **Session View** is intentionally out of scope, and Pocket cannot open Ableton Live Sets.
- **Stretch quality**: the time-stretch is a genuine granular overlap-add algorithm, not a phase
  vocoder or élastique-class implementation. Large ratios and sustained tonal material can show
  granular artifacts. Complex warp modes are absent.
- **Comping**: manual take selection and manual regions only. There is no punch-in/out and no
  automatic best-take scoring.
- **Routing**: four fixed group buses and two fixed returns. No user-added returns, nested groups,
  or folder tracks.
- **Automation**: volume, pan, send, cutoff, and clip gain only. No device/AU parameter
  automation, no envelope curves, and no per-clip pan/send envelopes.
- **Meter**: one global time signature per project; no per-bar changes.
- **Plugins**: Audio Units only (AUv2 and in-process AUv3). No VST3. Out-of-process AUv3 and
  app-extension-only hosts may not instantiate.
- **MIDI**: no MIDI-out routing, Live-style generators, or chainable MIDI effect rack. No Ableton
  Link, control-surface support, or tempo following.
- **Capacity**: 16 tracks, 64 clip slots per track, 64 timeline clips per track, 64 pool slots.
- **Follow** advances by bar, not as a continuous pixel offset.
- **Undo** covers note and arrangement edits. Adding or removing tracks clears history; plugin
  loading and recording are not undoable.
- **Distribution**: the packaged app is ad-hoc signed, not notarized. On another Mac, Gatekeeper
  requires a one-time right-click → Open.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| Space | Play / stop |
| R | Record on the armed track, or stop recording |
| ⌘T | Add a track |
| ⌘D | Duplicate selected notes, clips, or the focused track |
| ⇧⌘D | Duplicate the selected time range |
| ⌘E | Split selected clips at the insert marker |
| ⌘J | Consolidate selected MIDI clips or audio clips |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘C / ⌘V | Copy / paste notes or clips, depending on focus |
| ⌘A | Select all notes or clips in the focused pane |
| Q | Quantize selected notes to the current grid |
| ⌘L | Loop the time selection or toggle the arrangement loop |
| ⌘B | Show / hide the browser |
| ⌘S / ⌘O | Save / open a project |
| ⌘1–⌘5 | Beat / bar / 1/8 / 1/16 / snap off |
| ← / → | Nudge notes, or clips by the snap grid |
| ↑ / ↓ | Transpose notes, or move clips one track |
| ⇧↑ / ⇧↓ | Transpose notes one octave |
| 0 | Deactivate / re-enable the selected clip |
| A | Show / hide the automation lane |
| L | Add a locator at the insert marker |
| Z / X | Zoom in / out |
| Home | Return the insert marker to the start |
| Esc | Clear selections and focus the arrangement |
| ⌫ | Delete selected notes, otherwise selected clips |
