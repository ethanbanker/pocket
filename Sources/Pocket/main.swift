import AppKit
import SwiftUI

if CommandLine.arguments.contains("--selftest") {
    exit(runSelfTest())
}

let runningUITest = CommandLine.arguments.contains("--uitest")
if runningUITest { UITestHooks.enabled = true }

final class PocketAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let appDelegate = PocketAppDelegate()

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = appDelegate

let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "About Pocket", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Quit Pocket", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
app.mainMenu = mainMenu

let model = SessionModel()

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "Pocket"
window.center()
window.contentView = NSHostingView(rootView: ContentView(model: model))
window.makeKeyAndOrderFront(nil)

/// Ableton-style shortcuts: space plays, ⌘E splits, ⌘J consolidates, ⌘D duplicates,
/// ⌘Z/⇧⌘Z undo and redo, ⌘L loops the time selection, ⌘C/⌘V copy and paste clips,
/// A shows automation, 0 deactivates, arrows nudge the selected note or clip.
/// A focused SwiftUI TextField installs an NSTextView field editor. The global shortcut
/// monitor must not treat that editor as the arrangement: Backspace has to edit the number,
/// not delete the selected clip, and Space/⌘C/arrow keys belong to the text too.
func isEditingText(in window: NSWindow?) -> Bool {
    guard let responder = window?.firstResponder else { return false }
    return responder is NSTextView || responder is NSTextField
}

NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    if isEditingText(in: event.window) { return event }
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    if mods.contains(.command) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s": model.saveProject(); return nil
        case "o": model.openProject(); return nil
        case "t": model.addTrack(); return nil
        case "e":
            if mods.contains(.option) { model.showEditor.toggle() }
            else { model.splitAtInsertMarker() }
            return nil
        case "j": model.consolidateSelectedClips(); return nil
        case "d":
            if mods.contains(.shift) {
                if let selection = model.timeSelection, !selection.isEmpty {
                    model.duplicateTime(start: selection.start, end: selection.end)
                }
            } else {
                switch model.focus {
                case .pianoRoll:
                    if model.selectedNote != nil { model.duplicateSelectedNote() }
                    else { model.status = "select a note to duplicate" }
                case .browser:
                    model.status = "drag the selected file onto a lane to place it"
                case .arrangement:
                    if !model.selectedClips.isEmpty || model.selectedTimeline != nil {
                        model.duplicateSelectedTimelineClip()
                    } else {
                        model.duplicateSelectedTrack()
                    }
                }
            }
            return nil
        case "z":
            if mods.contains(.shift) { model.redo() } else { model.undo() }
            return nil
        case "a": model.selectAllInFocusedPane(); return nil
        case "c":
            if model.focus == .pianoRoll { model.copySelectedNotes() }
            else { model.copySelectedClips() }
            return nil
        case "v":
            if model.focus == .pianoRoll { model.pasteNotes() }
            else { model.pasteClips() }
            return nil
        case "l":
            if let selection = model.timeSelection, !selection.isEmpty {
                model.loopSelection()
            } else {
                model.toggleLoop()
            }
            return nil
        case "b": model.showBrowser.toggle(); return nil
        case "r": model.toggleRecording(); return nil
        case "1": model.setSnap(.beat); return nil
        case "2": model.setSnap(.bar); return nil
        case "3": model.setSnap(.eighth); return nil
        case "4": model.setSnap(.sixteenth); return nil
        case "5": model.setSnap(model.snap == .off ? .bar : .off); return nil
        default: return event
        }
    }

    if mods.isEmpty {
        switch event.keyCode {
        case 49:   // space
            model.togglePlay()
            return nil
        case 51, 117:   // delete / forward delete
            model.deleteSelection()
            return nil
        case 123:   // left
            if model.focus == .pianoRoll, model.selectedNote != nil {
                model.nudgeSelectedNote(steps: -1)
            } else if model.focus == .arrangement {
                model.nudgeSelectedClip(steps: -model.snapSteps)
            }
            return nil
        case 124:   // right
            if model.focus == .pianoRoll, model.selectedNote != nil {
                model.nudgeSelectedNote(steps: 1)
            } else if model.focus == .arrangement {
                model.nudgeSelectedClip(steps: model.snapSteps)
            }
            return nil
        case 125:   // down
            if model.focus == .pianoRoll, model.selectedNote != nil {
                model.nudgeSelectedNote(pitch: -1)
            } else if model.focus == .arrangement {
                model.nudgeSelectedClip(tracks: 1)
            }
            return nil
        case 126:   // up
            if model.focus == .pianoRoll, model.selectedNote != nil {
                model.nudgeSelectedNote(pitch: 1)
            } else if model.focus == .arrangement {
                model.nudgeSelectedClip(tracks: -1)
            }
            return nil
        case 53:    // escape
            model.clearClipSelection()
            model.clearNoteSelection()
            model.timeSelection = nil
            model.focusArrangement()
            return nil
        case 115:   // home
            model.seek(to: 0)
            return nil
        case 29:    // 0
            if model.focus == .arrangement, let id = model.selectedTimeline {
                model.toggleClipActive(id)
            }
            return nil
        case 0:     // A
            model.showAutomation.toggle()
            return nil
        case 37:    // L
            model.addLocator()
            return nil
        case 6:     // Z
            model.zoomArrangement(by: 1.35)
            return nil
        case 7:     // X
            model.zoomArrangement(by: 1 / 1.35)
            return nil
        case 12:    // Q
            if model.focus == .pianoRoll { model.quantizeSelectedNotes() }
            return nil
        case 15:    // R
            model.toggleRecording()
            return nil
        default:
            return event
        }
    }

    if mods == .shift, model.focus == .pianoRoll, model.selectedNote != nil {
        switch event.keyCode {
        case 125: model.nudgeSelectedNote(pitch: -12); return nil
        case 126: model.nudgeSelectedNote(pitch: 12); return nil
        default: return event
        }
    }

    return event
}

/// Clicking anywhere outside the active text editor ends the edit before the click is
/// dispatched. That makes a BPM field commit (and stop owning Backspace) when the user clicks
/// a lane, a knob or another panel, instead of leaving a hidden field editor focused.
NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
    guard let window = event.window,
          let responder = window.firstResponder as? NSTextView else { return event }
    let hit = window.contentView?.hitTest(event.locationInWindow)
    var view = hit
    while let current = view {
        if current is NSTextField || current is NSTextView { return event }
        view = current.superview
    }
    // For a SwiftUI TextField the field editor is the first responder; the field itself is an
    // ancestor of that editor, but the click can land on a sibling within the same control.
    // Keep the editor when the hit is still inside its document view's superview chain.
    if let editor = responder.superview, let hit, hit.isDescendant(of: editor) { return event }
    window.makeFirstResponder(nil)
    return event
}

/// The arrangement is one custom two-axis viewport. Treat the wheel/trackpad consistently:
/// two-finger pan in both directions, Shift-wheel pans horizontally, ⌘-wheel zooms around the
/// pointer. Native nested ScrollViews are intentionally not used because they stole clip drags.
NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
    guard let window = NSApp.keyWindow, let view = window.contentView else { return event }
    let local = event.locationInWindow
    let root = CGPoint(x: local.x, y: view.bounds.height - local.y)
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 18
    let verticalDelta = -event.scrollingDeltaY * scale

    if model.pianoRollFrame.contains(root), abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
        let semitones = Int((verticalDelta / 11).rounded())
        if semitones != 0 { model.scrollPianoRoll(by: semitones) }
        return nil
    }

    guard model.arrangementCanvasFrame.contains(root) else { return event }
    if mods.contains(.command) {
        let anchor = root.x - model.arrangementCanvasFrame.minX
        let factor = event.scrollingDeltaY > 0 ? 1.08 : 0.925
        model.zoomArrangement(by: factor, anchorX: anchor)
        return nil
    }
    var dx = -event.scrollingDeltaX * scale
    var dy = verticalDelta
    if mods.contains(.shift), abs(dx) < 0.01 { dx = dy; dy = 0 }
    model.scrollArrangement(x: dx, y: dy)
    return nil
}

app.activate(ignoringOtherApps: true)

if runningUITest {
    app.finishLaunching()
    exit(runUITest(model: model, window: window))
}

app.run()
