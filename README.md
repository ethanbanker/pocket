# Pocket

A native macOS arrangement DAW: one linear song canvas, a full MIDI editor, audio clips with
region-based take comping, warp anchors and pitch-preserving time-stretch, clip gain envelopes,
four group buses and two real return tracks, an arpeggiator and MPE, real Audio Unit instruments
and effects, MIDI/audio recording with selectable input and live monitoring, stereo WAV and
multi-track stem export. Pocket
drives a direct CoreAudio **AUHAL** output unit, renders at the
selected device's **native sample rate**, saves full AU patch state, and aligns plugin latency.
There is no AVAudioEngine and no hidden output converter. No dependencies, no Xcode project,
and no Session View.

```
swift run Pocket              # open the app
swift run Pocket --selftest   # offline render/audio checks, no GUI
./scripts/uitest.sh           # real window + synthetic mouse regression suite
./scripts/package.sh          # build dist/Pocket.app + dist/Pocket-macOS.zip
```

Requires macOS 14+. Built with Command Line Tools only — no Xcode project.

## Layout

```
┌ transport: play · record · tempo/meter · position · master · export · save/open · MIDI ┐
├──────────┬──────────────────────────────────────────────────────────────────────────────┤
│ browser  │ Arrangement canvas — two-axis viewport with both scrollbars                  │
│ (⌘B)     ├──────────────────────────────────────────────────────────────────────────────┤
│          │ editor: track devices + 128-key piano roll + velocity lane                   │
└──────────┴──────────────────────────────────────────────────────────────────────────────┘
```

## Shortcuts

| key | action |
| --- | --- |
| space | play / stop |
| R | record on the armed track, or stop recording |
| ⌘T | add a track |
| ⌘D | duplicate the selected note(s), clip(s), or the track from its header |
| ⇧⌘D | duplicate the selected time range |
| ⌘E | split selected clips at the insert marker |
| ⌘J | consolidate selected MIDI clips, or selected audio clips on one track |
| ⌘Z / ⇧⌘Z | undo / redo, including note edits |
| ⌘C / ⌘V | copy/paste notes when the roll is focused, otherwise clips |
| ⌘A | select all notes or all clips in the focused pane |
| Q | quantize selected notes to the current grid |
| ⌘L | loop the time selection, or toggle the arrangement loop |
| ⌘B | show / hide the browser |
| ⌘S / ⌘O | save / open a project |
| ⌘1 / ⌘2 / ⌘3 / ⌘4 / ⌘5 | beat / bar / 1/8 / 1/16 / snap off |
| ← → | nudge selected notes; with clips selected, nudge by the snap grid |
| ↑ ↓ | transpose selected notes; with clips selected, move one track |
| ⇧↑ ⇧↓ | transpose selected notes one octave |
| 0 | deactivate / re-enable the selected clip |
| A | show / hide the automation lane |
| L | add a locator at the insert marker |
| Z / X | zoom in / out |
| Home | return the insert marker to the start |
| Esc | clear selections and return focus to the arrangement |
| ⌫ | delete selected notes, otherwise selected clips |

## Navigation and click behavior

The arrangement is one custom two-axis viewport. It deliberately does not use nested
`ScrollView`s, which previously stole clip drags and made two-finger scrolling inconsistent.

- Two-finger/wheel input pans horizontally and vertically. Shift-wheel pans horizontally.
- **⌘-scroll zooms around the pointer**; the −/+/FIT toolbar controls zoom around the viewport
  center or fit the song length.
- Persistent horizontal and vertical scrollbars are always visible.
- Hovering changes the cursor to match the action: crosshair over empty lanes, open hand over a
  clip, horizontal resize over clip edges/fade corners, and up-down over the new-track strip.
- Dragging near any viewport edge auto-scrolls the timeline or track stack, so a clip, fade or
  draw can be extended beyond the visible area without stopping the drag.
- A single click on empty lane space selects the lane, moves the insert marker, and focuses the
  arrangement. It never creates a track or clip.
- A double-click on **empty** lane space creates a one-bar clip there. The double-click target
  is the lane surface underneath the clips, so double-clicking a clip can never stack a second
  clip on top of it.
- Dragging empty lane space draws a clip of the dragged length. Editing a clip requires an
  actual drag; edge zones resize, audio top corners adjust fades.
- Every automation row has its own hit surface. Clicking or dragging automation can never enter
  the lane-drawing state, create a track, or paint a clip ghost.
- Arrangement tracks are collision-safe. Drawing, moving or resizing into occupied space shows
  a red ghost and is rejected with a status message. Clips may touch end-to-end but cannot be
  hidden inside one another.
- The dashed strip after the last track is still the explicit drag-to-add-track target. A click
  there does nothing; a drag or audio drop creates exactly one track.
- Dropping a file onto an automation row targets the underlying track, never the new-track strip.
  Vertical clip drags use actual lane geometry, so an open automation row cannot make a clip
  jump to the wrong track.
- Clicking a clip clears the piano-roll note selection and focuses the song, so **⌘D duplicates
  the clip**, not a stale note. Clicking a track header focuses the whole track so ⌘D duplicates
  the track.
- Clicking the piano roll (grid, keys or velocity lane) focuses it. Wheel/trackpad over the piano
  roll scrolls through the 128-key range.
- Clicking a browser file focuses the browser, auditions it, and never inserts anything.
  Placement is drag-only.

## Clips and timeline

- Drag empty lane space to draw a clip; double-click for one bar. Clips can be moved
  horizontally and across tracks, resized from either edge, split, duplicated, copied/pasted,
  deactivated, and consolidated. There is exactly one foreground clip per lane position; a
  blocked move/resize is shown in red and never silently creates a hidden second layer.
- Selected or hovered clips show left/right edge grips so the resize zones are visible.
- Recording refuses to start in an occupied range; the status bar explains the collision instead
  of entering a record state that cannot create a clip.
- Audio clips get their natural file duration, a trimmed waveform, gain, source start, fade-in
  and fade-out. Top-corner fade handles drag against the clip end. Files up to 30 minutes are
decoded in full; the old two-minute truncation is gone.
- **Warp** is an explicit per-clip switch. **MARK** stores a source/time anchor at the playhead;
  between anchors the renderer maps the file with piecewise-linear read positions. **STRETCH**
  switches from repitch to a real granular overlap-add time-stretch: the file follows the song
  tempo while keeping its pitch. **REV** reads the file backwards (reverse stays repitch-only).
- **TAKES · COMP** lists every recorded pass for the selected audio clip. Clicking a take makes
  it the active comp without re-encoding the file. **COMP TO SELECTION** assigns the active take
  to the ruler's time selection, so different parts of one placement can play different passes;
  each region is listed with its bar range and can be removed individually. Regions are clipped
  to the placement and saved with the project. Splitting a clip preserves its take list.
- **XFADE** makes a real overlap with the next touching audio clip on the same track and writes
  reciprocal fade-out/fade-in curves. **AUTO XF** applies the same real one-step overlap fade to
  touching audio clips after drags, drops, pastes and duplicates. Clips remain collision-safe
  everywhere else.
- **CLIP GAIN** is a per-clip automation envelope in the automation lane. It scales audio
  sample-accurately while the file plays and scales MIDI velocity at each note start; 0.5 is
  unity and the range is silent to +6 dB.
- **⌘J on audio** bounces the selected span of that track through the offline renderer and
  replaces the selected audio clips with one waveform clip.
- Time selection: Shift-drag empty space. INSERT, DUPLICATE TIME and DELETE TIME act across all
  tracks, split clips at the boundaries, and move locators/loop/insert positions.
- `SET LOCATOR` stores the insert position; `◀`/`▶` jump between locators. The loop brace
  supports moving and edge-dragging.
- **FOLLOW** scrolls the custom viewport by bar with the playhead.

## Tracks, meter and automation

- Add, rename, duplicate, delete and **reorder** tracks with the ▲/▼ buttons in each header.
  Reordering moves the lane's clips, clip slots, insert chains, hosted instrument, automation and
  mute/solo bits with it. Mute, solo, arm, volume and pan are available in the header/mixer. Each
  track routes to the master or one of four group buses, with group volume and pan, and sends
  independently to **return A** (tempo delay) and **return B** (reverb). The last track cannot be
  deleted. Maximum 16 tracks.
- The transport meter menu sets a **global** time signature: 4/4, 3/4, 5/4, 7/4, 6/8, 7/8, 9/8
  or 12/8. Bars, bar snapping, the ruler, position readout and time commands follow it. Pocket
  does not support per-bar meter changes.
- The automation lane has four independent track envelopes: **VOL, PAN, SEND, CUTOFF**, plus the
  per-clip **CLIP GAIN** envelope. Choose the target from the toolbar or lane header, click to add
  points, drag points, and clear the current target. Clearing an envelope restores the mixer's
  base value. The automation row consumes its own pointer events; it is not part of the
  clip-drawing canvas.
- AU/device parameters and automation recording are not implemented. Clip gain is the only
  per-clip envelope; there is no per-clip pan/send envelope yet.
- **Delay compensation** delays every track to the slowest instrument/insert chain using the
  latency reported by each Audio Unit. This keeps a look-ahead limiter or linear-phase EQ from
  pushing one track late relative to the others.

## Recording

The transport record button (or R) records onto the armed track. If no track is armed, the
selected track is armed explicitly and the status line says so.

- **MIDI mode** captures incoming CoreMIDI notes into one timeline clip at the record start.
  Note-on/off timing is taken from the audio playhead. Held notes are finalized when recording
  stops. The track's built-in synth or loaded AU instrument plays them back.
- **AUDIO mode** records the selected input (not merely the system default) to a CAF file and
  places it on the armed track. The input picker and **MON** button live in the device panel;
  monitoring feeds the armed track through a lock-free ring into the AUHAL renderer. macOS asks
  for microphone permission; the app bundle includes `NSMicrophoneUsageDescription`.
- The **LAT** field compensates recording latency in milliseconds. Positive values pull MIDI
  notes and audio takes earlier by the same amount; audio recording starts the transport only
  after the input engine is running. Values are clamped to ±500 ms.
- Recording into an existing audio clip appends a take instead of refusing the range. The take
  list is saved with the project, so active-take comping survives reopen.
- Recording requires the transport; pressing stop finishes the take before stopping playback.

## Export

**EXPORT** writes a stereo 16-bit WAV. With a time selection it exports that range; otherwise it
exports from the start to the end of the last clip, rounded up to a bar. **STEMS** writes one
stereo WAV per track into a chosen folder, including that track's instrument, inserts, fades,
warp/reverse, send contribution and automation. The whole render path
is real: synth/AU instruments, inserts, sends, automation, sample clips, fades, reverse/warp and
the master bus are rendered offline with the realtime graph paused. Whole-song exports add a
1.5 s tail for reverb/release; range exports add 0.15 s.

## Browser

The left sidebar walks the filesystem. Folder clicks navigate; audio-file clicks audition and
select without placing. Search filters the current folder. Drag a file onto a lane or the
new-track strip to place it. The same targets accept Finder drags.

## Sound

- **Built-in synth** — 128-voice PolyBLEP saw/square/sine, per-track ADSR, gate and pan.
- **Audio Units** — AUv2 generators and effects, plus in-process AUv3 fallback where available.
  Instruments are rendered inside Pocket's callback; inserts run per block before the fader.
- **Return tracks** — two independent, preallocated return buses: **A** is a tempo-synced
  ping-pong delay and **B** is a Freeverb-style reverb. Every track has separate SEND A and SEND B
  amounts and each return has its own level. Bounce and stems include both returns.
- **Arpeggiator** — per-track UP, DOWN and UP/DOWN patterns at 1/16, 1/8 or 1/4, driven from the
  notes sounding in the clip. It runs through the same voice/instrument path as playback, so the
  offline bounce arpeggiates identically.
- **MPE** — CoreMIDI channel is preserved. Per-channel pitch bend retunes every voice on that
  channel in the built-in synth and is forwarded to hosted AUs as channelized note-on plus pitch
  bend, which is the real MPE per-note path.
- **Samples** — WAV/AIFF/MP3/CAF, decoded once and reused, stereo preserved, 64 pool slots,
  up to 30 minutes per file. Files at 44.1, 48, 88.2, 96 or 192 kHz are converted once with
  `AVAudioConverter` into the engine's current rate; the manual interpolator is only a fallback
  for unsupported files.
- **Output devices** — the transport **AUHAL** menu enumerates CoreAudio outputs (speakers,
  headphones, interfaces, aggregates, AirPlay) with their hardware rate. Selecting one stops
  the unit, switches `kAudioOutputUnitProperty_CurrentDevice`, reconfigures the stream format,
  and restarts. The choice is remembered across launches; hot-plugged devices refresh the menu.
- **Native-rate policy** — the renderer, Audio Units and sample pool all run at the active
  device's nominal rate. When a device or system rate change selects a different rate, the
  unit is stopped, the renderer and sample pool are rebuilt, and AU hosts are recreated before
  audio restarts. There is no output sample-rate converter in the hot path.
- **Buffer and latency** — the AUHAL menu exposes 64–2048-frame buffer choices where the device
  allows them. The transport reads the real buffer, device latency and safety offset from
  CoreAudio; the status line reports `AUHAL · rate · frames · ms`. Audio input is selected
  independently in the device panel and monitored through a separate AVAudioEngine tap; the
  renderer resamples it into the AUHAL clock without opening another audible output.
- **Piano roll** — 128 keys; draw, move, resize, velocity; Shift-drag marquee; shift-click
  multi-selection; group move; copy/paste; quantize; undoable note edits. Notes have per-note
  probability and groove offset, and drawing can be constrained to a root and scale.
- **Plugins** are saved by component identity plus full AU ClassInfo/fullState. A reopened
  project restores the patch, and a native-rate rebuild captures and reapplies state to the new
  instances instead of reloading the factory defaults.
- **MIDI capture and control** — notes played while the transport is not recording stay in a
  rolling capture buffer and can be turned into a clip with **CAPTURE**. MIDI CC learn maps a
  controller to master, track volume, pan, send or cutoff.

## Timing

The AUHAL output callback owns the clock. There is no integer step accumulator:

```
stepPhase += 1 / samplesPerStep          // every rendered sample
if stepPhase >= 1 { advanceStep(offset: i); stepPhase -= 1 }
position = globalStep + stepPhase
```

A BPM whose step length is fractional (for example 123 BPM at 48 kHz) therefore stays exact
indefinitely; the self-test checks a sub-microstep position after a full render. Timeline notes
are queued with their sample offset and delivered to AUv2/AUv3 instruments at that offset inside
the 512-frame render slice. UI writes plain fixed-size values into one preallocated block; the
callback does not allocate, lock or touch Swift collections. Offline export uses the same
`Renderer` on a separate `Shared` snapshot while the realtime graph is paused.

AUHAL also supplies the real device buffer and latency figures, and a nominal-rate change is
handled by stopping the unit, rebuilding the renderer at the new native rate, re-decoding the
sample pool, recreating AU hosts, and starting again. Ardour still goes further with separate
input-device selection, aggregate-device construction and xrun telemetry; those are not in
Pocket yet.

## Project files

JSON (`.json`) stores tempo, master, global meter, per-track params/pan/devices/group, every
clip's notes and sample settings, take list/active take, source BPM/warp/stretch/reverse, warp
anchors, comp regions, clip gain envelope, timeline, loop, locators, inactive clips,
volume/pan/send/cutoff automation, scale, note probability/groove, MIDI effect, arp settings,
return levels, automatic-crossfade preference, and full insert/instrument AU state. Version 9
adds pitch-preserving stretch, comp regions, clip gain, return B and the arpeggiator; v7
automation is migrated into the long-song envelope buffer.

## Source layout

```
Sources/Pocket/
  main.swift                AppKit bootstrap, menu, shortcuts, two-axis wheel routing
  Audio/Shared.swift        fixed shared block: clock, clips, samples, automation, meters
  Audio/Renderer.swift      clock, timeline, voices, samples, warp/reverse, AUs, mix
  Audio/Voice.swift         oscillators, envelopes, limiter
  Audio/Effects.swift       SVF, ping-pong delay, reverb
  Audio/PluginHost.swift    AU effects
  Audio/InstrumentHost.swift AU generators
  Audio/MIDIInput.swift     CoreMIDI ring + record capture hook
  Audio/InputMonitor.swift  selected input, monitoring ring, CAF take writer
  Audio/AudioCore.swift     AUHAL output, native-rate rebuild, buffer/latency, device events
  Audio/AudioDevices.swift  CoreAudio enumeration, buffer ranges, latency, device rates
  Model/SamplePool.swift    AVAudioConverter decode, stereo buffers, waveform peaks
  Model/Project.swift       Codable project, notes, timeline, automation, meter
  Model/SessionModel.swift  tracks, editing, focus, undo, recording lifecycle
  Model/Recording.swift     MIDI/microphone capture
  Model/OfflineMixdown.swift WAV writer + audio consolidation
  UI/ArrangementView.swift  custom viewport, lanes, clips, ruler, automation, scrollbars
  UI/PianoRoll.swift        multi-select editor, marquee, velocity lane
  UI/DetailPanel.swift      instrument/insert controls, audio clip/warp controls
  UI/TransportBar.swift     play, record/mode, meter, export, project actions
  UI/BrowserView.swift      browser, audition, search, drag provider
  SelfTest.swift            offline clock, synth, sample, warp, AU checks
  UITest.swift              real-window synthetic click/drag regression suite
```

This project deliberately avoids `@State` and other SwiftUI macro property wrappers because a
Command Line Tools-only toolchain does not ship the SwiftUIMacros plugin. View state lives on
`SessionModel`.

## Verification

`./scripts/uitest.sh` builds a real window and drives it with synthetic mouse events, asserting
on the model and shared audio block. The current suite covers:

- no click-created tracks or clips; one-track drag/drop creation
- clip draw/move/resize/split/consolidate/time commands and undo
- overlap rejection for draw/move/resize, with touching clips still allowed
- automation-row events cannot create a track or clip
- clip focus handoff and track duplication
- two-axis scrolling, horizontal/vertical scrollbars, pointer-anchored zoom
- MIDI group selection, move, quantize, copy/paste, note undo/redo and roll scrolling
- recording refusal when the destination range is occupied
- direct AUHAL engine, native device rate, real buffer/latency and output restart
- a different-rate device rebuilds the engine and preserves an imported clip
- 48 kHz file import converted into a 44.1 kHz pool
- 1/16 default grid; a drop on occupied space lands in the next free gap
- global meter and bar snapping
- MIDI transport recording, held-note length and clip creation
- rolling MIDI capture into a clip without arming the transport
- MIDI CC learn and live track-volume control
- scale-constrained drawing plus per-note probability and groove
- group-bus routing and group volume
- full AU ClassInfo/fullState serialization and restore
- per-track stem export with RIFF and non-silent PCM checks
- separate volume and pan automation plus base-value restoration
- pitch-preserving stretch reaching the renderer, comp regions with take slots, clip gain
  automation, return B/send B, and arpeggiator mode/rate wiring
- automatic crossfade creating a real overlap, and lane reordering moving clips, automation and
  renderer state
- audio warp/reverse state and real offline audio consolidation
- a real WAV bounce with a RIFF header and non-silent PCM
- browser click-to-audition, drag provider, search
- AU generator/effect loading, rendering, state restore and editor windows

The last packaged run on this machine: **SELFTEST PASS**, **UITEST PASS 164 checks, 2 skipped**.
The skips are the real global cursor drag when lane 1 is off-screen and the alternate-rate
device test when no second output with a different rate is attached. The offline self-test now
also measures 2x time-stretch pitch (autocorrelation stays at 220 Hz), clip-gain attenuation,
comp-region take switching, single-note arpeggiator output, and an MPE bend moving a held note
from 440 Hz to 493.7 Hz. The UI suite also covers a >2-minute import, take switching, warp
anchors, MIDI chord expansion, latency math, manual and automatic crossfades, stretch/comp/gain/
return/arp wiring, lane reordering, and a real focused-text Backspace event that must not delete
the selected clip.

## Feature parity with Ableton

This is a conservative comparison against Ableton Live 12 Suite. It is not a file-compatibility
claim: Pocket cannot open Live Sets (`.als`) and intentionally has no Session View.

Pocket is now roughly **50% of Live 12 Suite overall**, and roughly **66% of a linear
Arrangement-view workflow**. The old 86% figure counted only the surface Pocket had chosen and
gave full marks to areas that were incomplete. It has been retired.

| area | Pocket state |
| --- | --- |
| Session View and clip launching | none; intentionally out of scope |
| Arrangement timeline and clip editing | strong core: split, move, resize, fades, time commands, loop, locators, consolidate, groups of clips |
| Tracks, routing and mixing | flat tracks with reordering, four group buses and two returns (delay/reverb); no groups-of-tracks as folders or nested groups |
| Recording and comping | selectable input, live monitoring, latency compensation, active-take comping and region comping; no punch recording or automatic best-take assembly |
| MIDI editing | solid basics plus scale, probability/groove, capture, CC learn, chord/octave/fifth effects, arpeggiator and MPE; no generators or MIDI out |
| Audio clips and warping | trim, gain, fades, reverse, repitch warp, pitch-preserving stretch, warp anchors, manual and automatic crossfades; no phase-vocoder-quality stretch or complex warp modes |
| Instruments, effects and devices | AUv2/AUv3 hosting with full state and PDC; one built-in synth, two insert slots, no Live devices, racks, macros, Max or VST3 |
| Browser and library | filesystem navigation, search, audition and drag; no tags, collections, packs, presets or Splice |
| Export | stereo 16-bit WAV and per-track stereo stems; no other formats, sample-rate choice, normalization or stem options |
| Automation | volume/pan/send/cutoff track envelopes plus clip gain; no device automation, envelope curves or recording |
| Control and integration | MIDI CC learn; no control surfaces, Ableton Link, MIDI mapping of plugin parameters or tempo following |

## Not implemented, and why

- **Session View.** Explicitly out of scope for this pass.
- **Punch recording and automatic best-take comping.** Region comping is manual: you choose the
  take and the span. There is no punch-in/out and no automatic take scoring.
- **Group nesting, arbitrary returns and folders.** Four fixed group buses and two fixed returns
  exist. There are no user-added return tracks, nested groups or folder tracks.
- **Device automation.** Track volume, pan, send and filter cutoff plus clip gain are automated.
  AU/device parameters are not, and envelope curves stay linear.
- **Per-bar time signatures.** One global meter is supported; changing meter mid-song is not.
- **Studio-grade time-stretch.** The stretch mode is a real granular overlap-add time-stretch
  that preserves pitch, but it is not a phase vocoder/élastique-class algorithm; large ratios and
  sustained tonal material can show granular artifacts. Complex Pro-style warp modes are absent.
- **VST3.** Audio Units only; VST3 would add the Steinberg SDK dependency.
- **Out-of-process AUv3.** AUv2 uses `AudioComponentInstanceNew`; AUv3 uses in-process
  `AUAudioUnit`. App-extension-only hosts may refuse to instantiate.
- **Full MIDI effect rack and generators.** Chord/octave/fifth transformers, arpeggiator, scale,
  probability, groove, capture, CC learn and MPE input exist. There are no Live-style generators,
  MIDI-out routing, or a chainable MIDI effect rack.
- **Track count.** 16 tracks, 64 clip slots/track, 64 sample pool slots, 64 timeline clips/track.
- **Follow** moves by bar, not a continuous pixel offset.
- **Per-clip envelopes beyond gain.** CLIP GAIN exists; per-clip pan, send, device and MIDI
  envelopes do not. Automatic crossfades only join audio clips that touch end-to-end; dragging
  one clip over another is still rejected rather than converted into an overlap.
- **Aggregate construction and xrun telemetry.** Output is native-rate AUHAL with selectable
  buffer size, real device latency and an independently selected input. It does not build
  aggregate devices or report xrun counts like Ardour's full CoreAudio backend.
- **Undo scope.** Note and arrangement edits undo; adding/removing tracks still clears history;
  plugin loading/state and recording actions are not undoable.

The app is ad-hoc signed, not notarized: copying it to another Mac trips Gatekeeper once
(right-click → Open).
