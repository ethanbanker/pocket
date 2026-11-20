import SwiftUI

/// Bottom panel: the selected track's instrument + inserts on the left, the piano roll on the right.
struct DetailPanel: View {
    @ObservedObject var model: SessionModel

    private var trackIndex: Int { min(model.selection.track, model.tracks.count - 1) }
    private var track: TrackInfo { model.tracks[trackIndex] }
    private var clip: ClipInfo { model.clips[trackIndex][model.selection.scene] }
    private var fx: TrackFX { model.fx[trackIndex] }

    var body: some View {
        HStack(spacing: 0) {
            devices
            Rectangle().fill(Theme.stroke).frame(width: 1)
            editor
        }
        .background(Theme.panel)
    }

    // MARK: - Instrument + inserts

    private var devices: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Rectangle().fill(track.color).frame(width: 3, height: 15)
                    Text(track.name.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    FlagButton(label: "R", active: fx.armed, tint: Theme.record) {
                        model.setFX(trackIndex, armed: !fx.armed)
                    }
                }

                instrumentRow
                KnobRow(model: model, trackIndex: trackIndex)
                scaleRow
                midiEffectRow
                arpRow
                routingRow
                recordingRow
                noteInspector
                audioClipSection
                HStack(spacing: 10) {
                    Knob(label: "SEND A", value: fx.send, range: 0...1) {
                        model.setFX(trackIndex, send: $0)
                    }
                    Knob(label: "SEND B", value: fx.sendB, range: 0...1) {
                        model.setFX(trackIndex, sendB: $0)
                    }
                    Knob(label: "CUT", value: fx.cutoff, range: 120...18000,
                         format: { String(format: "%.0f", $0) }) {
                        model.setFX(trackIndex, cutoff: $0)
                    }
                    Knob(label: "RES", value: fx.resonance, range: 0...0.92) {
                        model.setFX(trackIndex, resonance: $0)
                    }
                    Knob(label: "DRIVE", value: fx.drive, range: 1...4) {
                        model.setFX(trackIndex, drive: $0)
                    }
                }

                Text("INSERTS · AUDIO UNITS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .padding(.top, 1)

                insertRow(0)
                insertRow(1)
                parameters

                midiMapRow

                Text("MIDI IN · \(model.midiStatus().uppercased())")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.65))
                    .lineLimit(1)
            }
            .padding(12)
        }
        .frame(width: 300)
    }

    private var instruments: [PluginSlot.Descriptor] { model.availableInstruments() }

    private var instrumentRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("INSTRUMENT · AUDIO UNITS")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.dim)

            HStack(spacing: 5) {
                Menu {
                    Button("Pocket Synth (built-in)") {
                        model.removeInstrument(track: trackIndex)
                    }
                    Divider()
                    if instruments.isEmpty {
                        Text("No AU generators found")
                    }
                    ForEach(instruments.indices, id: \.self) { i in
                        Button(instruments[i].name) {
                            model.loadInstrument(track: trackIndex, descriptor: instruments[i])
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "pianokeys")
                            .font(.system(size: 8))
                        Text(model.instrumentNames[trackIndex] ?? "Pocket Synth (built-in)")
                            .font(.system(size: 9, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7))
                    }
                    .foregroundStyle(model.instrumentNames[trackIndex] == nil ? Theme.text : Theme.accent)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(Color(white: 0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity)
                .background(FrameReporter(id: "instrument.menu"))

                if model.instrumentNames[trackIndex] != nil {
                    FlatButton(title: "UI", width: 26) {
                        model.openInstrumentUI(track: trackIndex)
                    }
                    .background(FrameReporter(id: "instrument.ui"))
                    .help("Open the instrument's own editor")
                }
            }
        }
    }

    private var scaleRow: some View {
        HStack(spacing: 5) {
            Text("SCALE")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            Menu {
                ForEach(0..<12, id: \.self) { root in
                    Button(SessionModel.noteName(root)) {
                        model.setScale(root: root, mode: model.scaleMode)
                    }
                }
            } label: {
                Text(SessionModel.noteName(model.scaleRoot))
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .frame(width: 24, height: 20)
                    .background(Theme.panelAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            Menu {
                ForEach(ScaleMode.allCases) { mode in
                    Button(mode.label) {
                        model.setScale(root: model.scaleRoot, mode: mode)
                    }
                }
            } label: {
                Text(model.scaleMode.label)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .frame(height: 20)
                    .background(Theme.panelAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            Spacer(minLength: 0)
        }
    }

    private var midiEffectRow: some View {
        HStack(spacing: 5) {
            Text("MIDI FX")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            Menu {
                ForEach(MIDIEffect.allCases) { effect in
                    Button(effect.label) { model.setMIDIEffect(effect, track: trackIndex) }
                }
            } label: {
                Text(fx.midiEffect.label)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .frame(height: 20)
                    .background(fx.midiEffect == .off ? Theme.panelAlt : Theme.accent.opacity(0.2))
                    .foregroundStyle(fx.midiEffect == .off ? Theme.text : Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Note transformer for this track. OCT/5TH add voices; CHORD adds a triad.")
            Text("recorded MIDI and drawn notes both pass through it")
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(Theme.dim.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var recordingRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Text("INPUT")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Menu {
                    Button("System Default") { model.selectAudioInput(nil) }
                    Divider()
                    ForEach(model.audioInputs) { device in
                        Button("\(device.name) · \(device.channels) ch") {
                            model.selectAudioInput(device)
                        }
                    }
                } label: {
                    Text(model.audioInputs.first(where: { $0.uid == model.selectedAudioInputUID })?.name
                         ?? "System Default")
                        .font(.system(size: 8, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 5)
                        .frame(height: 20)
                        .background(Theme.panelAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: 105)

                FlatButton(title: model.inputMonitoring ? "MON ON" : "MON",
                           tint: model.inputMonitoring ? Theme.record : Theme.dim,
                           width: 48) {
                    model.setInputMonitoring(!model.inputMonitoring)
                }
                .help("Monitor the selected input on the armed track")

                Text("LAT")
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                TextField("0", value: Binding(
                    get: { model.recordingLatencyMilliseconds },
                    set: { model.setRecordingLatency(milliseconds: $0) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 8, design: .monospaced))
                    .frame(width: 38)
                Text("ms")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Spacer(minLength: 0)
            }
            Text("positive latency pulls MIDI and audio takes earlier by this many milliseconds")
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(Theme.dim.opacity(0.65))
                .lineLimit(1)
        }
    }

    private var routingRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Text("OUTPUT")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Menu {
                    Button("Master") { model.setGroup(trackIndex, group: 0) }
                    ForEach(1...Shared.maxGroups, id: \.self) { group in
                        Button("Group \(group)") { model.setGroup(trackIndex, group: group) }
                    }
                } label: {
                    Text(fx.group == 0 ? "MASTER" : "GROUP \(fx.group)")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .frame(height: 20)
                        .background(Theme.panelAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                Text("RET A")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Slider(value: Binding(
                    get: { model.returnLevel },
                    set: { model.setReturnLevel($0) }), in: 0...1.5)
                .controlSize(.mini)
                .frame(width: 46)
                Text("RET B")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Slider(value: Binding(
                    get: { model.returnLevelB },
                    set: { model.setReturnLevelB($0) }), in: 0...1.5)
                .controlSize(.mini)
                .frame(width: 46)
                Spacer(minLength: 0)
            }
            Text("RETURN A · TEMPO DELAY     RETURN B · REVERB")
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(Theme.dim.opacity(0.65))
                .lineLimit(1)
            if fx.group > 0 {
                HStack(spacing: 5) {
                    Text("G\(fx.group) VOL")
                        .font(.system(size: 7.5, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    Slider(value: Binding(
                        get: { Double(model.groupVolumes[fx.group]) },
                        set: { model.setGroupVolume(fx.group, value: $0) }), in: 0...1.5)
                    .controlSize(.mini)
                    Text("PAN")
                        .font(.system(size: 7.5, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    Slider(value: Binding(
                        get: { Double(model.groupPans[fx.group]) },
                        set: { model.setGroupPan(fx.group, value: $0) }), in: -1...1)
                    .controlSize(.mini)
                }
            }
        }
    }

    @ViewBuilder
    private var noteInspector: some View {
        if let id = model.selectedNote, let note = model.note(for: id) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("NOTE \(SessionModel.noteName(note.pitch))\(note.pitch / 12 - 1)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    Text("PROB \(note.probability ?? 100)%")
                        .font(.system(size: 7.5, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    Text("GROOVE \(Int((note.groove ?? 0) * 100))%")
                        .font(.system(size: 7.5, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(note.probability ?? 100) },
                        set: { model.setSelectedNoteProbability(Int($0.rounded())) }
                    ), in: 0...100)
                    .controlSize(.mini)
                    Slider(value: Binding(
                        get: { note.groove ?? 0 },
                        set: { model.setSelectedNoteGroove($0) }
                    ), in: 0...0.9)
                    .controlSize(.mini)
                }
            }
        }
    }

    private var midiMapRow: some View {
        HStack(spacing: 5) {
            Text("MIDI MAP")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            Menu {
                ForEach(MIDIMapTarget.allCases) { target in
                    Button("Learn \(target.label)") { model.beginMIDILearn(target) }
                }
                Divider()
                Button("Clear mappings") { model.clearMIDIMappings() }
            } label: {
                Text(model.midiLearnTarget == nil
                     ? "\(model.midiMappings.count) mapped"
                     : "MOVE A CC…")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(model.midiLearnTarget == nil ? Theme.panelAlt : Theme.accent.opacity(0.2))
                    .foregroundStyle(model.midiLearnTarget == nil ? Theme.text : Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            Spacer(minLength: 0)
        }
    }

    private var plugins: [PluginSlot.Descriptor] { model.availablePlugins() }

    private func insertRow(_ slot: Int) -> some View {
        let name = model.inserts[trackIndex][slot]
        return HStack(spacing: 5) {
            Menu {
                Button("Empty") {
                    model.removePlugin(track: trackIndex, slot: slot)
                }
                if !plugins.isEmpty {
                    Divider()
                    ForEach(plugins.indices, id: \.self) { i in
                        Button(plugins[i].name) {
                            model.loadPlugin(track: trackIndex, slot: slot, descriptor: plugins[i])
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 8))
                    Text(name ?? "select Audio Unit…")
                        .font(.system(size: 9, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7))
                }
                .foregroundStyle(name == nil ? Theme.dim : Theme.accent)
                .padding(.horizontal, 6)
                .frame(height: 21)
                .background(Color(white: 0.10))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity)

            if name != nil {
                FlatButton(title: "UI", width: 24) {
                    model.openPluginUI(track: trackIndex, slot: slot)
                }
                .help("Open this effect's own editor")
                FlatButton(title: "X", width: 22) {
                    model.removePlugin(track: trackIndex, slot: slot)
                }
            }
        }
    }

    private var parameters: some View {
        let _ = model.pluginRevision
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<Shared.maxInserts, id: \.self) { slot in
                let params = model.pluginParameters(track: trackIndex, slot: slot)
                if !params.isEmpty {
                    Text("\(slot + 1) · \(model.inserts[trackIndex][slot] ?? "").uppercased()")
                        .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.dim.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 2)
                    ForEach(params, id: \.id) { parameter in
                        parameterRow(slot: slot, parameter)
                    }
                }
            }
        }
    }

    private func parameterRow(slot: Int, _ parameter: PluginSlot.Parameter) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(parameter.name.uppercased())
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(String(format: "%.2f", parameter.value))
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            Slider(value: Binding(
                get: { parameter.value },
                set: { model.setPluginParameter(track: trackIndex, slot: slot,
                                                id: parameter.id, value: $0) }
            ), in: parameter.minimum...Swift.max(parameter.minimum + 0.0001, parameter.maximum))
            .controlSize(.mini)
            .tint(track.color)
        }
    }

    // MARK: - Piano roll

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            PianoRoll(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(track.name.uppercased()) · \(clip.exists ? "CLIP \(String(format: "%.2g", Double(clip.loopSteps) / Double(model.stepsPerBar))) BARS" : "NO CLIP")")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)

            if !clip.exists {
                Text("DRAW A CLIP IN THE ARRANGEMENT")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.75))
            }

            Text(model.focus == .pianoRoll ? "KEY FOCUS" : "CLICK ROLL TO FOCUS")
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .foregroundStyle(model.focus == .pianoRoll ? Theme.accent : Theme.dim.opacity(0.55))

            if clip.exists {
                FlatButton(title: "CLEAR") { model.clearNotes() }
            }

            Spacer(minLength: 4)

            if let id = model.selectedTimeline, let placed = model.timelineClip(id: id) {
                Text("BAR \(model.barNumber(at: placed.start)) · \(String(format: "%.2g", Double(placed.length) / Double(model.stepsPerBar)))B")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.playhead)
                FlatButton(title: "DELETE", tint: Theme.record) {
                    model.deleteTimelineClip(id)
                }
            }

            if let name = clip.sampleName {
                HStack(spacing: 3) {
                    Image(systemName: "waveform").font(.system(size: 8))
                    Text(name)
                        .font(.system(size: 8, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 110, alignment: .trailing)
                }
                .foregroundStyle(Theme.accent)
            }
        }
    }

    /// Controls for the audio clip in the selected scene. Audio plays at 1x; these shape it.
    private var audioClipSection: some View {
        Group {
            if let name = clip.sampleName {
                Text("AUDIO CLIP")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .padding(.top, 2)

                HStack(spacing: 4) {
                    Knob(label: "GAIN", value: clip.sampleGain, range: 0...2) {
                        model.setSampleGain($0)
                    }
                    Knob(label: "START", value: clip.sampleStart, range: 0...0.95,
                         format: { String(format: "%.0f%%", $0 * 100) }) {
                        model.setSampleStart($0)
                    }
                    Knob(label: "FADE I", value: clip.sampleFadeIn, range: 0...2,
                         format: { String(format: "%.0f ms", $0 * 1000) }) {
                        model.setSampleFadeIn($0)
                    }
                    Knob(label: "FADE O", value: clip.sampleFadeOut, range: 0...2,
                         format: { String(format: "%.0f ms", $0 * 1000) }) {
                        model.setSampleFadeOut($0)
                    }
                }

                HStack(spacing: 5) {
                    Text(name)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let info = model.sampleInfo(track: trackIndex, scene: model.selection.scene) {
                        Text("\(info.channels == 2 ? "STEREO" : "MONO") · \(String(format: "%.2fs", info.seconds))")
                            .font(.system(size: 7.5, design: .monospaced))
                            .foregroundStyle(Theme.accent.opacity(0.8))
                    }
                    Spacer(minLength: 0)
                    FlatButton(title: "REMOVE", tint: Theme.record, width: 58) {
                        model.clearSample()
                    }
                }

                HStack(spacing: 5) {
                    FlagButton(label: "W", active: clip.sampleWarp, tint: Theme.accent) {
                        model.setSampleWarp(!clip.sampleWarp)
                    }
                    .help("Tempo-follow the file. Repitch changes pitch with tempo.")
                    Text("WARP BPM")
                        .font(.system(size: 7.5, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    TextField("", value: Binding(
                        get: { clip.sampleSourceBPM },
                        set: { model.setSampleSourceBPM($0) }), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 8, design: .monospaced))
                        .frame(width: 44)
                    FlatButton(title: clip.sampleReverse ? "REV ON" : "REV",
                               tint: clip.sampleReverse ? Theme.accent : Theme.dim,
                               width: 48) {
                        model.setSampleReverse(!clip.sampleReverse)
                    }
                    FlatButton(title: "MARK", width: 42) { model.addWarpMarker() }
                        .help("Add a warp anchor at the playhead")
                    FlatButton(title: "CLR", tint: Theme.dim, width: 30) {
                        model.clearWarpMarkers()
                    }
                    FlatButton(title: clip.warpStretch ? "STRETCH ON" : "STRETCH",
                               tint: clip.warpStretch ? Theme.go : Theme.dim, width: 68) {
                        model.setSampleWarpStretch(!clip.warpStretch)
                    }
                    .help("Pitch-preserving granular time-stretch instead of repitch")
                    Spacer(minLength: 0)
                    Text(clip.sampleWarp
                         ? (clip.warpStretch ? "TEMPO FOLLOW · STRETCH" : "TEMPO FOLLOW · REPITCH")
                         : "ONE-SHOT · 1×")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(Theme.dim.opacity(0.75))
                }

                if !clip.warpMarkers.isEmpty {
                    HStack(spacing: 4) {
                        Text("ANCHORS")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                        ForEach(Array(clip.warpMarkers.enumerated()), id: \.offset) { index, marker in
                            HStack(spacing: 2) {
                                Text(String(format: "BAR %@ · %.2fs",
                                            model.barNumber(at: Int(marker.timelineStep)).description,
                                            marker.sourceSeconds))
                                    .font(.system(size: 7, design: .monospaced))
                                    .foregroundStyle(Theme.dim)
                                Button {
                                    model.removeWarpMarker(at: index)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 6, weight: .bold))
                                        .foregroundStyle(Theme.record)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 4)
                            .frame(height: 16)
                            .background(Theme.panelAlt)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                        Spacer(minLength: 0)
                    }
                }

                if !clip.takes.isEmpty {
                    HStack(spacing: 4) {
                        Text("TAKES · COMP")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                        Spacer(minLength: 0)
                    }
                    ForEach(Array(clip.takes.enumerated()), id: \.element.id) { index, take in
                        Button {
                            model.useTake(track: trackIndex, scene: model.selection.scene,
                                          index: index)
                        } label: {
                            HStack(spacing: 4) {
                                Text(clip.activeTake == index ? "●" : "○")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(clip.activeTake == index ? Theme.accent : Theme.dim)
                                Text("TAKE \(index + 1)")
                                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(clip.activeTake == index ? Theme.text : Theme.dim)
                                Text(take.name)
                                    .font(.system(size: 7.5, design: .monospaced))
                                    .foregroundStyle(Theme.dim.opacity(0.75))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 5)
                            .frame(height: 19)
                            .background(clip.activeTake == index
                                        ? Theme.accent.opacity(0.16) : Color.white.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 4) {
                        FlatButton(title: "COMP TO SELECTION", width: 122) {
                            let range = model.timeSelection
                            model.setCompRegion(take: clip.activeTake,
                                                from: range?.start, to: range?.end)
                        }
                        FlatButton(title: "CLR COMP", tint: Theme.dim, width: 62) {
                            model.clearCompRegions()
                        }
                        Spacer(minLength: 0)
                    }
                    Text("select time in the ruler, pick a take, then comp that span")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(Theme.dim.opacity(0.6))
                        .lineLimit(1)

                    ForEach(Array(clip.compRegions.enumerated()), id: \.offset) { index, region in
                        HStack(spacing: 3) {
                            Text("BAR \(model.barNumber(at: placedStart + region.startStep))–\(model.barNumber(at: placedStart + max(region.startStep, region.endStep - 1)))")
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(Theme.text)
                            Text("TAKE \(region.take + 1)")
                                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                            Spacer(minLength: 0)
                            Button {
                                model.removeCompRegion(at: index)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 6, weight: .bold))
                                    .foregroundStyle(Theme.record)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 5)
                        .frame(height: 17)
                        .background(Color.white.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                }
            }
        }
    }

    private var placedStart: Int {
        model.selectedTimeline.flatMap { model.timelineClip(id: $0)?.start } ?? 0
    }

    private var arpRow: some View {
        HStack(spacing: 5) {
            Text("ARPEGGIATOR")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            Menu {
                ForEach(ArpMode.allCases) { mode in
                    Button(mode.label) { model.setArp(mode: mode) }
                }
            } label: {
                Text(fx.arpMode.label)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .frame(height: 20)
                    .background(fx.arpMode == .off ? Theme.panelAlt : Theme.accent.opacity(0.2))
                    .foregroundStyle(fx.arpMode == .off ? Theme.text : Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            Menu {
                ForEach(ArpRate.allCases) { rate in
                    Button(rate.label) { model.setArp(rate: rate) }
                }
            } label: {
                Text(fx.arpRate.label)
                    .font(.system(size: 8, design: .monospaced))
                    .padding(.horizontal, 5)
                    .frame(height: 20)
                    .background(Theme.panelAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            Spacer(minLength: 0)
        }
    }
}

/// Volume + the three filter knobs. Split out so `DetailPanel` stays readable.
private struct KnobRow: View {
    // This child owns no @State, so without observing the model SwiftUI can keep the original
    // knob geometry even though the audio value is changing. Volume/pan then "work" but never
    // move under the pointer.
    @ObservedObject var model: SessionModel
    let trackIndex: Int

    private var fx: TrackFX { model.fx[trackIndex] }

    var body: some View {
        HStack(spacing: 10) {
            Knob(label: "VOL", value: fx.volume, range: 0...1.5) {
                model.setFX(trackIndex, volume: $0)
            }
            Knob(label: "PAN", value: fx.pan, range: -1...1,
                 format: { value in
                     if abs(value) < 0.01 { return "C" }
                     return value < 0 ? String(format: "L%.0f", abs(value) * 100)
                                      : String(format: "R%.0f", value * 100)
                 }) {
                model.setFX(trackIndex, pan: $0)
            }
            Spacer(minLength: 0)
        }
    }
}
