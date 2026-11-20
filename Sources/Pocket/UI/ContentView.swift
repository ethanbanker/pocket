import SwiftUI

struct ContentView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(model: model)
            hairline
            HStack(spacing: 0) {
                if model.showBrowser {
                    BrowserView(model: model)
                }
                VStack(spacing: 0) {
                    ArrangementView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.showEditor {
                        hairline
                        EditorDivider(model: model)
                        DetailPanel(model: model)
                            .frame(height: CGFloat(model.detailHeight))
                    }
                }
            }
            hairline
            StatusBar(model: model)
        }
        .background(Theme.bg)
        .coordinateSpace(name: "pocket")
        .frame(minWidth: 1180, minHeight: 800)
    }

    private var hairline: some View {
        Rectangle().fill(Theme.stroke).frame(height: 1)
    }
}

/// Draggable divider between arrangement and editor. Drag up for a taller piano roll, down to
/// give the song the space, or use the EDITOR toggle to hide it entirely.
struct EditorDivider: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        Rectangle()
            .fill(Theme.panelAlt)
            .frame(height: 6)
            .overlay(Rectangle().fill(Theme.stroke).frame(height: 1))
            .overlay(
                Capsule()
                    .fill(Theme.dim.opacity(0.55))
                    .frame(width: 42, height: 2)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !model.editorDragging {
                            model.editorDragStart = model.detailHeight
                            model.editorDragging = true
                        }
                        model.setDetailHeight(model.editorDragStart - Double(value.translation.height))
                    }
                    .onEnded { _ in
                        model.editorDragging = false
                    }
            )
            .background(FrameReporter(id: "editor.divider"))
    }
}

struct StatusBar: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        HStack(spacing: 10) {
            Text(model.status.isEmpty ? "ready" : model.status)
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Spacer()
            Text(hint)
                .foregroundStyle(Theme.dim.opacity(0.8))
                .lineLimit(1)
        }
        .font(.system(size: 9.5))
        .padding(.horizontal, 10)
        .frame(height: 20)
        .background(Theme.panel)
    }

    private var hint: String {
        switch model.focus {
        case .arrangement:
            return "ARRANGEMENT · click selects · drag the strip to add a track · ⌘D duplicates clip/track · space plays"
        case .pianoRoll:
            return "PIANO ROLL · click notes or keys here · ⌘D duplicates note · ⌫ deletes note"
        case .browser:
            return "BROWSER · click to audition · drag a file onto a lane to place it"
        }
    }
}
