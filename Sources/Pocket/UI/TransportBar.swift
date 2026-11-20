import SwiftUI

struct TransportBar: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        HStack(spacing: 12) {
            playButton
            recordBlock
            bpmBlock
            positionBlock
            Spacer(minLength: 10)
            masterBlock
            audioBlock
            FlatButton(title: model.showEditor ? "EDITOR ON" : "EDITOR OFF",
                       tint: model.showEditor ? Theme.accent : Theme.dim) {
                model.showEditor.toggle()
            }
            .background(FrameReporter(id: "editor.toggle"))
            .help("Show / hide the piano roll and devices (⌘⌥E)")
            Rectangle().fill(Theme.stroke).frame(width: 1, height: 26)
            FlatButton(title: model.isBouncing ? "BOUNCING…" : "EXPORT",
                       tint: model.isBouncing ? Theme.dim : Theme.text) {
                model.exportMixdown()
            }
            .disabled(model.isBouncing)
            .background(FrameReporter(id: "transport.export"))
            FlatButton(title: "STEMS", tint: model.isBouncing ? Theme.dim : Theme.text) {
                model.exportStems()
            }
            .disabled(model.isBouncing)
            .background(FrameReporter(id: "transport.stems"))
            FlatButton(title: "SAVE") { model.saveProject() }
            FlatButton(title: "OPEN") { model.openProject() }
            FlatButton(title: model.midiCaptureCount > 0 ? "CAPTURE \(model.midiCaptureCount)" : "CAPTURE",
                       tint: model.midiCaptureCount > 0 ? Theme.accent : Theme.dim) {
                model.captureMIDIToClip()
            }
            .disabled(model.midiCaptureCount == 0)
            .background(FrameReporter(id: "transport.capture"))
            FlatButton(title: "MIDI") { model.rescanMIDI() }
                .help(model.midiStatus())
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(Theme.panel)
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                Text(model.projectName)
                Spacer(minLength: 12)
                Text("\(model.currentAudioOutputName) · \(model.audioEngineLabel)")
                    .lineLimit(1)
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.dim.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.bottom, 3)
        }
    }

    private var playButton: some View {
        Button(action: { model.togglePlay() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(model.isPlaying ? Theme.record : Theme.go)
                Image(systemName: model.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black.opacity(0.8))
            }
            .frame(width: 46, height: 30)
        }
        .buttonStyle(.plain)
        .background(FrameReporter(id: "transport.play"))
        .help("Play / stop (space)")
    }

    private var recordBlock: some View {
        HStack(spacing: 4) {
            Button(action: { model.toggleRecording() }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(model.isRecording ? Theme.record : Theme.panelAlt)
                    Circle()
                        .fill(model.isRecording ? Color.white : Theme.record)
                        .frame(width: 11, height: 11)
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .background(FrameReporter(id: "transport.record"))
            .help(model.isRecording ? "Stop recording (R)" : "Record on the armed track (R)")

            Menu {
                ForEach(RecordMode.allCases) { mode in
                    Button(mode.rawValue) { model.recordMode = mode }
                }
            } label: {
                Text(model.recordMode.rawValue)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(model.isRecording ? Theme.record : Theme.dim)
                    .frame(width: 38, height: 20)
                    .background(Theme.panelAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(model.isRecording)
            .help("Record mode: MIDI notes or microphone audio")
        }
    }

    private var bpmBlock: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text("TEMPO")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                Text(String(format: "%.0f", model.bpm))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
            }
            VStack(spacing: 1) {
                stepButton("+") { model.setBPM(model.bpm + 1) }
                stepButton("−") { model.setBPM(model.bpm - 1) }
            }
            Menu {
                Button("4/4") { model.setTimeSignature(numerator: 4, denominator: 4) }
                Button("3/4") { model.setTimeSignature(numerator: 3, denominator: 4) }
                Button("5/4") { model.setTimeSignature(numerator: 5, denominator: 4) }
                Button("7/4") { model.setTimeSignature(numerator: 7, denominator: 4) }
                Button("6/8") { model.setTimeSignature(numerator: 6, denominator: 8) }
                Button("7/8") { model.setTimeSignature(numerator: 7, denominator: 8) }
                Button("9/8") { model.setTimeSignature(numerator: 9, denominator: 8) }
                Button("12/8") { model.setTimeSignature(numerator: 12, denominator: 8) }
            } label: {
                Text("\(model.timeSigNumerator)/\(model.timeSigDenominator)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 4)
                    .frame(height: 18)
                    .background(Theme.panelAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 38)
            .help("Song time signature")
        }
    }

    private var audioBlock: some View {
        Menu {
            Button {
                model.selectAudioOutput(nil)
            } label: {
                Text((model.selectedAudioOutputUID == nil ? "✓ " : "   ") + "System Default")
            }
            Divider()
            ForEach(model.audioOutputs) { device in
                Button {
                    model.selectAudioOutput(device)
                } label: {
                    Text((model.selectedAudioOutputUID == device.uid ? "✓ " : "   ")
                         + "\(device.name) · \(Int(device.sampleRate.rounded())) Hz")
                }
            }
            Divider()
            Menu("Buffer · \(model.audioBufferFrames) frames") {
                ForEach(model.audioBufferOptions, id: \.self) { frames in
                    Button("\(frames) frames") { model.setAudioBufferSize(frames) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Circle()
                    .fill(model.audio?.isRunning == true ? Theme.go : Theme.dim)
                    .frame(width: 4, height: 4)
                Text("AUHAL")
                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Theme.text)
            .frame(width: 52, height: 22)
            .background(Theme.panelAlt)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 54)
        .background(FrameReporter(id: "transport.audio"))
        .help("Output: \(model.currentAudioOutputName) · \(model.audioEngineLabel) · choose buffer size")
    }

    private func stepButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 12)
                .background(Theme.panelAlt)
                .foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .buttonStyle(.plain)
    }

    private var positionBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("POSITION")
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(Theme.dim)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                let step = max(Int(model.shared.playhead.pointee), 0)
                Text(model.positionText(step))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.playhead)
                    .frame(width: 78, alignment: .leading)
            }
        }
        .frame(width: 84, alignment: .leading)
    }

    private var masterBlock: some View {
        HStack(spacing: 6) {
            Text("MASTER")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.dim)
            Slider(value: Binding(get: { model.master }, set: { model.setMaster($0) }), in: 0...1)
                .frame(width: 90)
                .tint(Theme.accent)
            Text(String(format: "%.0f%%", model.master * 100))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.text)
                .frame(width: 28, alignment: .trailing)
        }
    }
}
