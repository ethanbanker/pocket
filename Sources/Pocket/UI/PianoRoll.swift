import SwiftUI

/// FL Studio-style piano roll: a visible window of the full 128-key range, piano keys on the
/// left, draw / drag / resize notes in the grid, octave jumps and a drag scrollbar, and a
/// velocity lane pinned underneath the grid.
struct PianoRoll: View {
    @ObservedObject var model: SessionModel

    private let cellW: CGFloat = 16
    private let cellH: CGFloat = 13
    private let keysWidth: CGFloat = 46
    private let velocityHeight: CGFloat = 42
    private let barHeight: CGFloat = 24

    private var steps: Int { max(model.clips[model.selection.track][model.selection.scene].loopSteps, 16) }
    private var notes: [NoteData] { model.clips[model.selection.track][model.selection.scene].notes }
    private var color: Color { model.tracks[model.selection.track].color }
    private var scale: [Int] { [0, 2, 3, 5, 7, 8, 10] }   // C minor, the default sketch key

    var body: some View {
        GeometryReader { geo in
            let count = visibleCount(height: geo.size.height)
            let top = topPitch(count: count)
            VStack(spacing: 0) {
                octaveBar
                HStack(alignment: .top, spacing: 0) {
                    keyboard(count: count, top: top)
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(spacing: 0) {
                            grid(count: count, top: top)
                            velocityLane
                        }
                    }
                }
                .overlay(alignment: .trailing) { scrollBar(count: count) }
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { model.pianoRollFrame = geometry.frame(in: .named("pocket")) }
                            .onChange(of: geometry.size) { _, _ in
                                model.pianoRollFrame = geometry.frame(in: .named("pocket"))
                            }
                    }
                )
            }
        }
        .background(Color(white: 0.075))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(model.focus == .pianoRoll
                                  ? Theme.accent.opacity(0.55) : Theme.stroke.opacity(0.6),
                                  lineWidth: 1)
                    .allowsHitTesting(false))
    }

    /// How many semitones fit in the space the editor gives us. Always at least an octave.
    private func visibleCount(height: CGFloat) -> Int {
        let usable = height - barHeight - velocityHeight - 2
        return max(12, Int(usable / cellH))
    }

    /// Highest visible pitch. The focused pitch stays near the middle so octave jumps put the
    /// new octave in view whether the viewport is tall or short.
    private func topPitch(count: Int) -> Int {
        var top = model.rollFocusPitch + count / 2
        if top > 127 { top = 127 }
        if top - count + 1 < 0 { top = count - 1 }
        return max(top, count - 1)
    }

    // MARK: - Octaves

    private var octaveBar: some View {
        HStack(spacing: 6) {
            Text("OCT")
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            FlatButton(title: "−", width: 20) { model.shiftRollOctave(-1) }
                .background(FrameReporter(id: "roll.oct.down"))
            Text(noteName(model.rollFocusPitch))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .frame(width: 26)
            FlatButton(title: "+", width: 20) { model.shiftRollOctave(1) }
                .background(FrameReporter(id: "roll.oct.up"))
            FlatButton(title: "ALL", width: 32) { model.selectAllNotes() }
                .help("Select every note in this clip (⌘A)")
            FlatButton(title: "Q", width: 24) { model.quantizeSelectedNotes() }
                .help("Quantize selected notes to the current grid (Q)")
            FlatButton(title: "COPY", width: 40) { model.copySelectedNotes() }
                .help("Copy selected notes (⌘C)")
            FlatButton(title: "PASTE", width: 44) { model.pasteNotes() }
                .help("Paste notes (⌘V)")
            Spacer(minLength: 4)
            Text("\(notes.count) NOTE\(notes.count == 1 ? "" : "S") · \(model.selectedNotes.count) SEL · \(String(format: "%.2g", Double(steps) / Double(model.stepsPerBar))) BARS")
                .font(.system(size: 7.5, design: .monospaced))
                .foregroundStyle(Theme.dim.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: barHeight)
        .background(Theme.panelAlt)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    private func noteName(_ pitch: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let clamped = min(max(pitch, 0), 127)
        return "\(names[clamped % 12])\(clamped / 12 - 1)"
    }

    /// Slim vertical scrollbar: drag it to reach the other 100-odd keys.
    private func scrollBar(count: Int) -> some View {
        GeometryReader { track in
            let height = max(track.size.height, 1)
            let thumb = max(22, height * CGFloat(count) / 128)
            let travel = max(height - thumb, 0)
            let top = topPitch(count: count)
            let progress = CGFloat(127 - top) / CGFloat(max(127 - count + 1, 1))
            Capsule()
                .fill(Theme.dim.opacity(0.5))
                .frame(width: 3, height: thumb)
                .offset(x: 1.5, y: min(max(travel * progress, 0), travel))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle().size(width: 10, height: height))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !model.rollScrolling {
                                model.rollScrollStart = Double(model.rollFocusPitch)
                                model.rollScrolling = true
                            }
                            let delta = Int((value.translation.height / height) * 128)
                            model.rollFocusPitch = min(max(Int(model.rollScrollStart) + delta, 0), 127)
                        }
                        .onEnded { _ in
                            model.rollScrolling = false
                        }
                )
        }
        .frame(width: 7)
    }

    // MARK: - Keyboard

    private func keyboard(count: Int, top: Int) -> some View {
        Canvas { context, size in
            for row in 0..<count {
                let y = CGFloat(row) * cellH
                let pitch = top - row
                guard pitch >= 0, pitch <= 127 else { continue }
                let isBlack = [1, 3, 6, 8, 10].contains(pitch % 12)
                let held = model.auditionPitch == pitch
                let white: Double = held ? 0.45 : 0.80
                let black: Double = held ? 0.06 : 0.14
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: cellH)),
                             with: .color(isBlack ? Color(white: black) : Color(white: white)))
                if held {
                    context.fill(Path(CGRect(x: 0, y: y, width: 3, height: cellH)),
                                 with: .color(Theme.playhead))
                }
                if pitch % 12 == 0 {
                    context.draw(Text(noteName(pitch))
                                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.black.opacity(0.65)),
                                 at: CGPoint(x: size.width - 6, y: y + cellH / 2), anchor: .trailing)
                }
                context.fill(Path(CGRect(x: 0, y: y + cellH - 0.5, width: size.width, height: 0.5)),
                             with: .color(Color.black.opacity(0.25)))
            }
        }
        .frame(width: keysWidth, height: CGFloat(count) * cellH)
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.stroke).frame(width: 1) }
        .overlay(keyFrames(count: count, top: top))
        .overlay(hitLayer(gesture: keyboardGesture(top: top)))
        .help("Click a key to hear the note on this track")
    }

    private func keyboardGesture(top: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                model.focusPianoRoll()
                model.audition(pitch: pitchAt(value.location.y, top: top))
            }
            .onEnded { _ in
                model.audition(pitch: nil)
            }
    }

    /// `Canvas` has no hit shape of its own in this SwiftUI build, so gestures live on a
    /// transparent layer above it.
    private func hitLayer<G: Gesture>(gesture: G) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .gesture(gesture)
    }

    // MARK: - Grid

    private func grid(count: Int, top: Int) -> some View {
        Canvas { context, size in
            for row in 0..<count {
                let y = CGFloat(row) * cellH
                let pitch = top - row
                guard pitch >= 0, pitch <= 127 else { continue }
                let isBlack = [1, 3, 6, 8, 10].contains(pitch % 12)
                let inScale = scale.contains(pitch % 12)
                let base: Double = isBlack ? 0.095 : 0.13
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: cellH)),
                             with: .color(Color(white: inScale ? base + 0.025 : base)))
                context.fill(Path(CGRect(x: 0, y: y + cellH - 0.5, width: size.width, height: 0.5)),
                             with: .color(Color.black.opacity(0.22)))
                if pitch % 12 == 0 {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                                 with: .color(Color.white.opacity(0.10)))
                }
            }

            for step in 0..<steps {
                let x = CGFloat(step) * cellW
                let beat = step % 4 == 0
                let bar = step % model.stepsPerBar == 0
                context.fill(Path(CGRect(x: x, y: 0,
                                         width: bar ? 1.2 : (beat ? 0.8 : 0.4),
                                         height: size.height)),
                             with: .color(Color.white.opacity(bar ? 0.20 : (beat ? 0.10 : 0.04))))
            }
            let loopX = CGFloat(steps) * cellW
            context.fill(Path(CGRect(x: loopX - 1, y: 0, width: 1, height: size.height)),
                         with: .color(Theme.record.opacity(0.5)))

            for note in notes {
                guard note.pitch <= top, note.pitch > top - count else { continue }
                let rect = noteRect(note, top: top)
                let selected = model.selectedNotes.contains(note.id)
                let anchor = model.selectedNote == note.id
                let fill = color.opacity(selected ? 1.0 : 0.82)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(fill))
                context.stroke(Path(roundedRect: rect, cornerRadius: 2),
                               with: .color(anchor ? Color.white
                                                   : (selected ? Theme.accent
                                                               : Color.black.opacity(0.45))),
                               lineWidth: anchor ? 1.4 : 1)
                if rect.width > 18 {
                    context.fill(Path(CGRect(x: rect.maxX - 2, y: rect.minY + 2,
                                             width: 1.4, height: rect.height - 4)),
                                 with: .color(Color.black.opacity(0.25)))
                }
            }

            if let marquee = model.noteMarquee {
                context.fill(Path(marquee), with: .color(Theme.accent.opacity(0.16)))
                context.stroke(Path(marquee), with: .color(Theme.accent.opacity(0.85)), lineWidth: 1)
            }
        }
        .frame(width: CGFloat(steps) * cellW, height: CGFloat(count) * cellH)
        .contentShape(Rectangle())
        .overlay(hitLayer(gesture: gridGesture(top: top)))
        .background(FrameReporter(id: "roll.grid"))
    }

    /// One invisible row per visible key so the UI test can press a specific pitch.
    private func keyFrames(count: Int, top: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { row in
                Color.clear
                    .frame(height: cellH)
                    .background(FrameReporter(id: "key.\(top - row)"))
            }
        }
        .allowsHitTesting(false)
    }

    private func gridGesture(top: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if model.noteDrag == .idle && model.noteMarqueeStart == nil {
                    begin(at: value.startLocation, top: top)
                }
                update(value: value)
            }
            .onEnded { _ in
                finishMarquee(top: top)
                model.noteDrag = .idle
                if model.noteEditBegan {
                    model.noteEditBegan = false
                    model.endGestureEdit()
                }
            }
    }

    private func begin(at point: CGPoint, top: Int) {
        model.focusPianoRoll()
        let step = Int(point.x / cellW)
        let pitch = pitchAt(point.y, top: top)
        let flags = NSEvent.modifierFlags
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)

        if let hit = hitTest(point, top: top) {
            if option {
                model.selectNote(hit.note.id)
                model.deleteSelectedNotes()
                model.noteDrag = .idle
                return
            }
            if shift {
                model.selectNote(hit.note.id, additive: true)
                if !model.selectedNotes.contains(hit.note.id) { model.noteDrag = .idle; return }
            } else if !model.selectedNotes.contains(hit.note.id) {
                model.selectNote(hit.note.id)
            } else {
                model.selectNote(hit.note.id)
            }
            if hit.onEdge {
                model.noteDrag = .resize(id: hit.note.id, length: hit.note.length)
            } else {
                model.prepareNoteMove(anchor: hit.note.id)
                model.noteDrag = .move(id: hit.note.id, start: hit.note.start, pitch: hit.note.pitch)
            }
            return
        }

        if shift {
            model.clearNoteSelection()
            model.noteMarqueeStart = point
            model.noteMarquee = CGRect(origin: point, size: .zero)
            model.noteDrag = .idle
            return
        }
        if option { return }
        guard let id = model.addNote(step: step, pitch: pitch, length: 1) else { return }
        model.noteDrag = .resize(id: id, length: 1)
    }

    private func update(value: DragGesture.Value) {
        if let start = model.noteMarqueeStart {
            let rect = CGRect(x: min(start.x, value.location.x),
                              y: min(start.y, value.location.y),
                              width: abs(value.location.x - start.x),
                              height: abs(value.location.y - start.y))
            model.noteMarquee = rect
            return
        }

        let stepDelta = Int((value.translation.width / cellW).rounded())
        let pitchDelta = Int((-value.translation.height / cellH).rounded())

        if model.noteDrag != .idle, !model.noteEditBegan,
           abs(value.translation.width) > 1 || abs(value.translation.height) > 1 {
            model.beginGestureEdit()
            model.noteEditBegan = true
        }

        switch model.noteDrag {
        case .move:
            model.moveSelectedNotes(stepDelta: stepDelta, pitchDelta: pitchDelta)
        case .resize(let id, let length):
            model.updateNote(id, length: length + stepDelta)
        case .idle:
            break
        }
    }

    private func finishMarquee(top: Int) {
        guard let rect = model.noteMarquee else { return }
        let ids = Set(notes.filter { noteRect($0, top: top).intersects(rect) }.map(\.id))
        model.noteMarquee = nil
        model.noteMarqueeStart = nil
        if !ids.isEmpty { model.selectNotes(ids) }
        else { model.clearNoteSelection() }
    }

    // MARK: - Velocity

    private var velocityLane: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.10)))
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 0.5)),
                         with: .color(Color.white.opacity(0.08)))
            for note in notes {
                let x = CGFloat(note.start) * cellW
                let h = size.height * CGFloat(note.velocity) / 127
                let selected = model.selectedNote == note.id
                let rect = CGRect(x: x + 1, y: size.height - h, width: max(cellW - 2, 2), height: h)
                context.fill(Path(rect), with: .color(color.opacity(selected ? 1.0 : 0.55)))
            }
        }
        .frame(width: CGFloat(steps) * cellW, height: velocityHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    model.focusPianoRoll()
                    if !model.noteEditBegan {
                        model.beginGestureEdit()
                        model.noteEditBegan = true
                    }
                    let step = Int(value.startLocation.x / cellW)
                    let velocity = Int((1 - value.location.y / velocityHeight) * 127)
                    let targets = model.selectedNotes.isEmpty
                        ? notes.filter { $0.start == step }
                        : notes.filter { model.selectedNotes.contains($0.id) }
                    for note in targets {
                        model.updateNote(note.id, velocity: velocity)
                    }
                }
                .onEnded { _ in
                    if model.noteEditBegan {
                        model.noteEditBegan = false
                        model.endGestureEdit()
                    }
                }
        )
        .overlay(alignment: .topLeading) {
            Text("VELOCITY")
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim.opacity(0.65))
                .padding(3)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Geometry

    private func noteRect(_ note: NoteData, top: Int) -> CGRect {
        let row = top - min(max(note.pitch, 0), 127)
        return CGRect(x: CGFloat(note.start) * cellW + 0.5,
                      y: CGFloat(row) * cellH + 1,
                      width: max(CGFloat(note.length) * cellW - 1, 4),
                      height: cellH - 2)
    }

    private func pitchAt(_ y: CGFloat, top: Int) -> Int {
        let row = min(max(Int(y / cellH), 0), max(top, 0))
        return min(max(top - row, 0), 127)
    }

    private func hitTest(_ point: CGPoint, top: Int) -> (note: NoteData, onEdge: Bool)? {
        for note in notes.reversed() {
            let rect = noteRect(note, top: top)
            if rect.contains(point) {
                return (note, point.x >= rect.maxX - 5)
            }
        }
        return nil
    }
}
