import AppKit
import AVFoundation
import ApplicationServices
import AudioToolbox
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Instrumentation

/// Frames reported by the real views while `--uitest` runs. They give the harness the coordinates
/// to click the actual widgets instead of calling the model, so a test failing means the UI wiring
/// broke, not just the model.
final class UITestHooks {
    static let shared = UITestHooks()
    static var enabled = false

    private var frames: [String: CGRect] = [:]

    private init() {}

    func report(_ id: String, _ frame: CGRect) {
        guard Self.enabled else { return }
        frames[id] = frame
    }

    func frame(_ id: String) -> CGRect? { frames[id] }
}

/// Reports the view's frame in the window-root coordinate space used by the harness.
struct FrameReporter: View {
    let id: String
    var offset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("pocket"))
                .offsetBy(dx: offset.width, dy: offset.height)
            Color.clear
                .onAppear { UITestHooks.shared.report(id, frame) }
                .onChange(of: id) { _, new in UITestHooks.shared.report(new, frame) }
                .onChange(of: frame) { _, new in UITestHooks.shared.report(id, new) }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Entry point

func runUITest(model: SessionModel, window: NSWindow) -> Int32 {
    UITest(model: model, window: window).run()
}

// MARK: - Harness

/// Drives the real window with synthetic AppKit mouse events. No Accessibility permission is
/// needed because the events are delivered in-process with `NSWindow.sendEvent`.
private final class UITest {
    private let model: SessionModel
    private let window: NSWindow
    private var passed = 0
    private var failed = 0
    private var skipped = 0
    private var failures: [String] = []

    init(model: SessionModel, window: NSWindow) {
        self.model = model
        self.window = window
    }

    func run() -> Int32 {
        print("UITEST start")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        pump(0.8)

        testEmptyProject()
        testDrawClip()
        testEditorToggle()
        testAudition()
        testDrawNote()
        testOctaves()
        testTransport()
        testLanes()
        testDragPipeline()
        testInstruments()
        testInstrumentWindow()
        testSerumRender()
        testEffectEditor()
        testEffectWindow()
        testCanvasAddTrack()
        testCanvasScroll()
        testSecondLaneGeometry()
        testClipFocus()
        testTrackDuplicate()
        testArrangementWorkflow()
        testConsolidate()
        testTrackDelete()
        testTimelineNavigation()
        testMIDIGroupEditing()
        testTimeSignature()
        testMIDIRecording()
        testMIDICaptureAndCC()
        testScaleProbabilityAndRouting()
        testAutomationTargets()
        testAudioWarpAndReverse()
        testBrowserSearch()
        testNoteUndoAndRollScroll()
        testClipOverlapPrevention()
        testRecordingRefusesOccupiedRange()
        testAudioOutputRouting()
        testStems()
        testMixdown()
        testLongAudioImport()
        testTakesWarpAndMIDIEffect()
        testCrossfade()
        testStretchCompGainReturnsArp()
        testAutoCrossfadeAndTrackOrder()
        testRecordingLatencyMath()
        testTextEditingKeepsClipSelection()

        printSummary()
        return failed == 0 ? 0 : 1
    }

    // MARK: Tests

    private func testEmptyProject() {
        let anyClip = model.clips.flatMap { $0 }.contains { $0.exists }
        check("project starts with no clips", !anyClip)
        check("the default editing grid is 1/16", model.snap == .sixteenth,
              model.snap.label)
    }

    private func testDrawClip() {
        guard let lane = waitFor("lane.0") else { return fail("lane.0 never reported a frame") }
        let start = CGPoint(x: lane.minX + 8, y: lane.midY)
        let end = CGPoint(x: lane.minX + 8 + 32 * 16, y: lane.midY)
        dragGesture(from: start, to: end)
        check("dragging on a lane draws a clip", model.timeline.count == 1)
        check("the drawn clip has content to edit", model.clips[0][0].exists)
        check("the drawn clip spans the dragged length", model.timeline.first?.length == 32)
    }

    /// The editor is a toggle now: hiding it must give the arrangement the full window.
    private func testEditorToggle() {
        guard let toggle = waitFor("editor.toggle") else {
            return fail("editor.toggle never reported a frame")
        }
        click(center(toggle))
        pump(0.3)
        check("the editor toggle hides the piano roll", !model.showEditor)
        click(center(toggle))
        pump(0.4)
        check("the editor toggle brings it back", model.showEditor)
    }

    private func testAudition() {
        guard let key = waitFor("key.60") else { return fail("key.60 never reported a frame") }
        let onBefore = model.shared.previewOnSeq.pointee
        let offBefore = model.shared.previewOffSeq.pointee

        press(center(key), nudging: 2)
        check("piano key press holds the pitch", model.auditionPitch == 60)
        check("piano key press asks the renderer for a note",
              model.shared.previewOnSeq.pointee > onBefore)

        release(center(key))
        check("piano key release frees the pitch", model.auditionPitch == nil)
        check("piano key release asks the renderer to stop",
              model.shared.previewOffSeq.pointee > offBefore)
    }

    private func testDrawNote() {
        guard let grid = waitFor("roll.grid") else { return fail("roll.grid never reported a frame") }
        guard let key = UITestHooks.shared.frame("key.60") else {
            return fail("key.60 frame vanished before the grid test")
        }
        click(CGPoint(x: grid.minX + 2 * 16 + 8, y: key.midY), nudging: 2)
        let notes = model.clips[0][0].notes
        check("clicking the grid draws a note", notes.count == 1)
        check("the drawn note uses the clicked pitch", notes.first?.pitch == 60)
    }

    /// The roll starts at C4; two octave-downs must actually move the editable rows.
    private func testOctaves() {
        guard let down = waitFor("roll.oct.down") else {
            return fail("roll.oct.down never reported a frame")
        }
        click(center(down))
        pump(0.35)
        click(center(down))
        pump(0.5)
        check("octave buttons move the piano roll", model.rollFocusPitch == 36)
        guard let key = waitFor("key.36") else { return fail("key.36 never became visible") }
        guard let grid = UITestHooks.shared.frame("roll.grid") else { return fail("roll.grid vanished") }
        click(CGPoint(x: grid.minX + 6 * 16 + 8, y: key.midY))
        check("a note can be drawn two octaves down",
              model.clips[0][0].notes.contains { $0.pitch == 36 })
    }

    private func testTransport() {
        guard let play = waitFor("transport.play") else {
            return fail("transport.play never reported a frame")
        }
        click(center(play))
        pump(0.2)
        check("the play button starts the transport", model.isPlaying)

        var steps = 0
        var lastStep = Int(model.shared.playhead.pointee)
        var fracs = Set<Int>()
        let end = Date().addingTimeInterval(0.9)
        while Date() < end {
            pump(0.03)
            let step = Int(model.shared.playhead.pointee)
            if step > lastStep {
                steps += step - lastStep
                lastStep = step
            }
            fracs.insert(Int(model.shared.playheadFrac.pointee * 20))
        }
        check("the playhead advances while playing", steps >= 3, "advanced \(steps) steps")
        check("the playhead moves faster than the step grid", fracs.count >= 3,
              "\(fracs.count) sub-step positions")

        click(center(play))
        pump(0.15)
        check("the play button stops the transport", !model.isPlaying)
    }

    private func testDragPipeline() {
        model.clearTimeline()
        model.showAutomation = false
        model.seek(to: 0)
        pump(0.2)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketUITest", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tone = directory.appendingPathComponent("tone.wav")
        guard makeTone(at: tone) else { return fail("could not write the test WAV") }

        let conversionPool = SamplePool(shared: Shared(), sampleRate: 44_100)
        if let slot = try? conversionPool.load(path: tone.path),
           let duration = conversionPool.duration(of: slot) {
            check("file import converts to a non-48k engine rate cleanly",
                  abs(duration - 1.0) < 0.03, String(format: "%.4f s", duration))
        } else {
            fail("the 44.1 kHz sample conversion failed")
        }

        model.browserPath = directory.path
        model.refreshBrowser()
        pump(0.2)
        check("the browser lists the test file",
              model.browserItems.contains { $0.name == "tone.wav" })

        guard let row = waitFor("browser.tone.wav") else {
            return fail("browser.tone.wav never reported a frame")
        }

        let beforeBrowserClick = model.timeline.count
        click(center(row))
        pump(0.25)
        check("clicking a browser file selects it without placing audio",
              model.browserSelection == tone.path && model.timeline.count == beforeBrowserClick)
        check("clicking the browser takes keyboard focus there", model.focus == .browser)

        func audioClip() -> TimelineClip? {
            model.timeline.first { model.clips[$0.track][$0.scene].sampleName == "tone.wav" }
        }

        let provider = FileDrag.makeProvider(url: tone, name: "tone.wav")
        check("browser drag provider advertises file-url",
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        check("browser drag provider yields the file path", loadPath(from: provider) == tone.path)

        let accepted = model.acceptAudioDrop([provider], track: 0, startStep: 0)
        check("the drop handler accepts the browser provider", accepted)
        check("the drop loads the sample into a clip", waitUntil(2) { audioClip() != nil })
        check("the drop places the clip at the bar", waitUntil(2) { audioClip()?.start == 0 })
        if let clip = audioClip() {
            let info = model.clips[clip.track][clip.scene]
            check("the one-shot clip length follows the file, not a whole bar",
                  info.loopSteps >= 7 && info.loopSteps < 16,
                  "\(info.loopSteps) steps")
            check("the decoder published a sample slot",
                  model.shared.clipSample[Shared.clipIndex(track: clip.track, scene: clip.scene)] >= 0)
            check("the timeline can draw the waveform",
                  model.waveform(track: clip.track, slot: clip.scene)?.isEmpty == false)
        }

        let beforeSecondDrop = model.timeline.count
        model.dropAudio(path: tone.path, track: 0, start: 0)
        check("a drop on occupied space moves to the next free gap instead of vanishing",
              model.timeline.count == beforeSecondDrop + 1,
              "\(model.timeline.count) clips · \(model.status)")

        guard let lane = waitFor("lane.1") else {
            skipped += 1
            print("SKIP  real mouse drag: lane.1 is not on screen")
            return
        }
        guard AXIsProcessTrusted() else {
            skipped += 1
            print("SKIP  real mouse drag: this binary lacks Accessibility permission")
            print("      (the provider + drop checks above cover the same code path)")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
        pump(0.5)
        guard NSApp.isActive else {
            skipped += 1
            print("SKIP  real mouse drag: Pocket is not the active app, so a global drag would "
                  + "land in whatever window is in front")
            return
        }
        drag(from: center(row), to: center(lane))
        check("dragging the file onto a lane places it on that track",
              waitUntil(2) { model.timeline.contains { $0.track == 1 } })
    }

    /// Actually put the AU editor in a window, not just ask for the controller: this is the path
    /// that crashed for Apple's DLS synth.
    private func testInstrumentWindow() {
        let list = model.availableInstruments()
        guard let dls = list.first(where: { $0.subtype == kAudioUnitSubType_DLSSynth
                                            && $0.manufacturer == kAudioUnitManufacturer_Apple })
                ?? list.first(where: { $0.name.uppercased().contains("DLS") }) else {
            skipped += 1
            print("SKIP  AU editor window: no DLS synth on this machine")
            return
        }
        model.loadInstrument(track: 0, descriptor: dls)
        pump(0.3)
        guard let button = waitFor("instrument.ui") else {
            return fail("instrument.ui never reported a frame")
        }
        let title = model.instrumentNames[0]
        for attempt in 0..<2 {
            window.makeKeyAndOrderFront(nil)
            pump(0.2)
            window.makeKeyAndOrderFront(nil)
            pump(0.2)
            click(center(button))
            pump(1.0)
            let open = NSApp.windows.contains { $0.isVisible && $0.title == title }
            check("the AU editor opens its own window (\(attempt + 1))", open)
            AUWindowManager.shared.close(key: "inst-0")
            pump(0.3)
        }
        model.removeInstrument(track: 0)
    }

    /// Serum loads and now renders through the AUv2 instrument host.
    private func testSerumRender() {
        guard let descriptor = model.availableInstruments().first(where: {
            $0.name.uppercased().contains("SERUM")
        }) else {
            skipped += 1
            print("SKIP  Serum render: not installed")
            return
        }
        guard let slot = InstrumentSlot(component: descriptor.component, sampleRate: 48_000),
              slot.isReady else {
            fail("Serum would not initialise")
            return
        }
        let n = 512
        let left = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { left.deallocate(); right.deallocate() }
        slot.noteOn(60, velocity: 110)
        var peak: Float = 0
        for _ in 0..<16 {
            peak = max(peak, slot.render(frames: n, left: left, right: right))
        }
        print("Serum host peak: \(peak)")
        slot.allNotesOff()
        check("Serum renders audio for a scheduled note", peak > 0.001)

        model.select(track: 0, scene: 0)
        model.loadInstrument(track: 0, descriptor: descriptor)
        pump(0.5)
        if let button = waitFor("instrument.ui") {
            window.makeKeyAndOrderFront(nil)
            pump(0.2)
            click(center(button))
            pump(1.8)
            let title = model.instrumentNames[0]
            check("Serum opens its own editor window",
                  NSApp.windows.contains { $0.isVisible && $0.title == title })
            AUWindowManager.shared.close(key: "inst-0")
            pump(0.3)
        } else {
            fail("Serum's UI button never reported a frame")
        }
        model.removeInstrument(track: 0)
    }

    /// Apple's CocoaUI effect editors are a different path from AU view controllers; show one.
    private func testEffectWindow() {
        let effects = model.availablePlugins()
        guard let eq = effects.first(where: { $0.name.uppercased().contains("GRAPHICEQ") })
                ?? effects.first else {
            skipped += 1
            print("SKIP  effect editor window: no effect Audio Unit installed")
            return
        }
        model.loadPlugin(track: 0, slot: 0, descriptor: eq)
        model.openPluginUI(track: 0, slot: 0)
        pump(1.2)
        let title = model.inserts[0][0]
        let open = NSApp.windows.contains { $0.isVisible && $0.title == title }
        check("the effect editor opens its own window", open)
        AUWindowManager.shared.close(key: "insert-0-0")
        pump(0.3)
        model.removePlugin(track: 0, slot: 0)
    }

    /// Effect inserts must hand back a real editor view for the hosted instance.
    private func testEffectEditor() {
        let effects = model.availablePlugins()
        guard let eq = effects.first(where: { $0.name.uppercased().contains("GRAPHICEQ") })
                ?? effects.first else {
            skipped += 1
            print("SKIP  AU effect editor: no effect Audio Unit installed")
            return
        }
        model.loadPlugin(track: 0, slot: 0, descriptor: eq)
        check("an AU effect can be inserted", model.inserts[0][0]?.isEmpty == false)
        if let instance = model.pluginInstance(track: 0, slot: 0),
           instance.makeEditorViewController() != nil {
            check("the effect hands back its AU editor", true)
        } else {
            skipped += 1
            print("SKIP  AU effect editor: \(eq.name) exposes no Cocoa view")
        }
        model.removePlugin(track: 0, slot: 0)
        check("removing the AU effect clears the insert", model.inserts[0][0] == nil)
    }

    /// The explicit new-track strip is drag-only. A click must never leave an empty ghost lane.
    private func testCanvasAddTrack() {
        model.laneTop = 0
        pump(0.4)
        guard let zone = waitFor("arr.newTrack") else {
            return fail("the new-track strip never reported a frame")
        }
        let beforeTracks = model.tracks.count
        let beforeClips = model.timeline.count

        click(center(zone))
        pump(0.3)
        check("clicking the empty canvas does not add a track",
              model.tracks.count == beforeTracks)
        check("clicking the empty canvas does not add a clip",
              model.timeline.count == beforeClips)

        dragGesture(from: CGPoint(x: zone.minX + 8, y: zone.midY),
                    to: CGPoint(x: zone.minX + 8 + 32 * 16, y: zone.midY))
        pump(0.4)
        check("dragging the new-track strip adds exactly one track",
              model.tracks.count == beforeTracks + 1)
        check("the canvas clip lands on the new track",
              model.timeline.count == beforeClips + 1
              && model.timeline.contains { $0.track == beforeTracks })
    }

    /// The lane canvas scrolls with the header, and programmatic positions move both.
    private func testCanvasScroll() {
        while model.tracks.count < 8 { model.addTrack() }
        model.laneTop = 0
        pump(0.6)
        guard let start = UITestHooks.shared.frame("lane.0"),
              let headerStart = UITestHooks.shared.frame("header.0") else {
            return fail("lane.0 or header.0 lost its frame")
        }
        model.laneTop = 5
        pump(0.8)
        guard let moved = UITestHooks.shared.frame("lane.0"),
              let headerMoved = UITestHooks.shared.frame("header.0") else {
            return fail("lane.0 or header.0 lost its frame after scrolling")
        }
        check("the arrangement canvas scrolls vertically", moved.minY < start.minY - 100)
        check("the track headers scroll with the canvas",
              headerMoved.minY < headerStart.minY - 100)
        check("the lane canvas exposes a vertical scrollbar",
              waitFor("arr.scrollbar") != nil)
    }


    /// A clip drawn on lane 2 must sit inside lane 2, and a vertical drag must move it to
    /// another track with its content intact. This is the regression the canvas rewrite fixes.
    private func testSecondLaneGeometry() {
        model.clearTimeline()
        model.showAutomation = false
        model.laneTop = 0
        model.seek(to: 0)
        pump(0.5)
        guard let lane0 = waitFor("lane.0"), let lane1 = waitFor("lane.1") else {
            return fail("the second lane never reported a frame")
        }
        let start = CGPoint(x: lane1.minX + 8, y: lane1.midY)
        let end = CGPoint(x: lane1.minX + 8 + 16 * 16, y: lane1.midY)
        dragGesture(from: start, to: end)
        pump(0.4)
        guard let clip = model.timeline.first(where: { $0.track == 1 }) else {
            return fail("a clip drawn on lane 2 did not land on track 2")
        }
        check("a clip drawn on the second lane stays on it",
              clip.start == 0 && clip.length == 16)
        check("the first lane is unaffected", !model.timeline.contains { $0.track == 0 })
        guard let frame = waitFor("clip.\(clip.id)") else {
            return fail("the second-lane clip never reported a frame")
        }
        check("the second-lane clip is drawn inside its lane",
              frame.minY >= lane1.minY - 2 && frame.maxY <= lane1.maxY + 2,
              "clip \(frame.minY)...\(frame.maxY), lane \(lane1.minY)...\(lane1.maxY)")

        dragGesture(from: center(frame), to: CGPoint(x: frame.midX, y: lane0.midY))
        pump(0.5)
        guard let moved = model.timelineClip(id: clip.id) else {
            return fail("the clip disappeared during the cross-track drag")
        }
        check("dragging a clip vertically moves it to the other track", moved.track == 0)
        check("the moved clip keeps editable content", model.clips[0][moved.scene].exists)
    }

    /// Exercise the new Arrangement commands through their real toolbar buttons.
    private func testArrangementWorkflow() {
        model.clearTimeline()
        model.showAutomation = false
        model.laneTop = 0
        model.seek(to: 0)
        model.loopEnabled = true
        model.setLoop(start: 0, length: 64)
        pump(0.5)
        guard let lane = waitFor("lane.0") else { return fail("lane.0 never reported a frame") }

        dragGesture(from: CGPoint(x: lane.minX + 16 * 16 + 8, y: lane.midY),
                    to: CGPoint(x: lane.minX + 48 * 16 + 8, y: lane.midY))
        pump(0.4)
        guard let clip = model.timeline.first else {
            return fail("could not draw the workflow clip")
        }
        check("a two-bar clip starts at the dragged bar",
              clip.start == 16 && clip.length == 32,
              "start \(clip.start), length \(clip.length)")

        guard let clipFrame = waitFor("clip.\(clip.id)"),
              let undo = waitFor("arr.undo") else {
            return fail("the workflow clip or undo button never reported a frame")
        }
        let edge = CGPoint(x: clipFrame.maxX - 3, y: clipFrame.midY)
        dragGesture(from: edge, to: CGPoint(x: edge.x + 16 * 16, y: edge.y))
        pump(0.4)
        check("dragging a clip's right edge resizes it",
              model.timeline.first?.length == 48,
              "length \(model.timeline.first?.length ?? -1)")
        click(center(undo))
        pump(0.4)

        model.selectClip(clip.id)
        model.seek(to: 32)
        pump(0.2)
        guard let split = waitFor("arr.split") else { return fail("arr.split never reported a frame") }
        click(center(split))
        pump(0.5)
        check("SPLIT cuts the selected clip at the insert marker", model.timeline.count == 2)
        let right = model.timeline.first { $0.id != clip.id }
        check("the split's second half starts at the marker",
              right?.start == 32 && right?.offset == 16,
              "start \(right?.start ?? -1), offset \(right?.offset ?? -1)")

        click(center(undo))
        pump(0.5)
        check("undo restores the split clip",
              model.timeline.count == 1 && model.timeline.first?.length == 32)

        model.timeSelection = TimeRange(start: 32, end: 48)
        pump(0.2)
        guard let deleteTime = waitFor("arr.time.delete") else {
            return fail("arr.time.delete never reported a frame")
        }
        click(center(deleteTime))
        pump(0.5)
        check("DELETE TIME removes the selected span across tracks",
              model.timeline.count == 1 && model.timeline.first?.start == 16
              && model.timeline.first?.length == 16,
              "\(model.timeline.map { "\($0.start)+\($0.length)" })")

        click(center(undo))
        pump(0.5)
        check("undo restores deleted time", model.timeline.first?.length == 32)

        model.seek(to: 32)
        guard let locator = waitFor("arr.locator") else {
            return fail("arr.locator never reported a frame")
        }
        click(center(locator))
        pump(0.23)
        check("SET LOCATOR marks the insert position",
              model.locators.contains { $0.step == 32 })

        model.loopEnabled = true
        model.setLoop(start: 32, length: 32)
        check("the loop brace drives the renderer",
              model.shared.loopStart.pointee == 32
              && model.shared.loopLength.pointee == 32
              && model.shared.loopEnabled.pointee == 1)

        guard let auto = waitFor("arr.auto") else { return fail("arr.auto never reported a frame") }
        click(center(auto))
        pump(0.5)
        guard let automationLane = waitFor("automation.0") else {
            return fail("the volume automation lane never appeared")
        }
        let trackCount = model.tracks.count
        let clipCount = model.timeline.count
        dragGesture(from: CGPoint(x: automationLane.minX + 16 * 16, y: automationLane.midY),
                    to: CGPoint(x: automationLane.minX + 16 * 16 + 2, y: automationLane.midY))
        pump(0.4)
        check("clicking the automation lane writes a volume point",
              model.shared.autoVol[16] >= 0,
              "autoVol[16] = \(model.shared.autoVol[16])")
        dragGesture(from: CGPoint(x: automationLane.minX + 16 * 20, y: automationLane.midY + 12),
                    to: CGPoint(x: automationLane.minX + 16 * 20, y: automationLane.midY - 16))
        pump(0.4)
        check("the automation lane cannot create a track or clip",
              model.tracks.count == trackCount && model.timeline.count == clipCount,
              "tracks \(model.tracks.count), clips \(model.timeline.count)")
    }

    private func testClipOverlapPrevention() {
        model.clearTimeline()
        model.showAutomation = false
        guard model.addTimelineClip(track: 0, start: 0, length: 16) != nil else {
            return fail("could not build the overlap fixture")
        }
        check("a clip cannot be stacked over another clip",
              model.addTimelineClip(track: 0, start: 8, length: 16) == nil
              && model.timeline.count == 1)
        guard model.addTimelineClip(track: 0, start: 16, length: 16) != nil else {
            return fail("could not add the adjacent clip")
        }
        let first = model.timeline.min(by: { $0.start < $1.start })!
        check("a clip cannot be moved over another clip",
              !model.moveTimelineClip(first.id, to: 16)
              && model.timelineClip(id: first.id)?.start == 0)
        model.resizeTimelineClip(first.id, length: 32)
        check("resizing stops at the next clip",
              model.timelineClip(id: first.id)?.length == 16)
        model.clearTimeline()
    }

    private func testRecordingRefusesOccupiedRange() {
        model.clearTimeline()
        model.showAutomation = false
        model.seek(to: 0)
        guard model.addTimelineClip(track: 0, start: 0, length: 16) != nil else {
            return fail("could not build the recording-overlap fixture")
        }
        model.beginRecording()
        check("recording refuses an occupied range",
              !model.isRecording && model.status.contains("cannot record"),
              model.status)
        model.clearTimeline()
    }

    private func testAudioOutputRouting() {
        check("the engine is direct AUHAL, not AVAudioEngine",
              model.audio?.engineName == AudioCore.engineName)
        if let audio = model.audio {
            check("the renderer runs at the device sample rate",
                  abs(audio.sampleRate - audio.hardwareSampleRate) < 0.5,
                  "render \(audio.sampleRate) / hardware \(audio.hardwareSampleRate)")
            check("the engine reports a real hardware buffer", audio.bufferFrames > 0)
        }
        check("the buffer size is surfaced in the transport", model.audioBufferFrames > 0)
        check("the output-device control is present", waitFor("transport.audio") != nil)
        if model.audioOutputs.isEmpty {
            skipped += 1
            print("SKIP  audio output device: none visible in this process")
        } else {
            check("CoreAudio exposes an output with a name and rate",
                  model.audioOutputs.contains {
                      !$0.name.isEmpty && $0.sampleRate > 0 && $0.channels > 0
                  })
            check("the hardware rate is visible to the UI", model.audioHardwareRate > 0)
            if let audio = model.audio,
               let id = audio.currentOutputDeviceID,
               let current = model.audioOutputs.first(where: { $0.id == id }) {
                let currentRate = AudioDevices.sampleRate(current.id)
                model.selectAudioOutput(current)
                pump(0.7)
                check("selecting a CoreAudio output restarts the engine",
                      audio.isRunning && model.status.contains("audio"),
                      model.status)

                if let alternate = model.audioOutputs.first(where: {
                    let rate = AudioDevices.sampleRate($0.id)
                    return rate > 0 && abs(rate - currentRate) > 0.5
                }) {
                    model.clearTimeline()
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("PocketUITest", isDirectory: true)
                    try? FileManager.default.createDirectory(at: directory,
                                                             withIntermediateDirectories: true)
                    let tone = directory.appendingPathComponent("rate-tone.wav")
                    if makeTone(at: tone) {
                        model.dropAudio(path: tone.path, track: 0, start: 0)
                    }
                    let rateClip = model.timeline.first
                    model.selectAudioOutput(alternate)
                    pump(1.2)
                    let alternateRate = AudioDevices.sampleRate(alternate.id)
                    check("a different-rate device rebuilds the native engine",
                          audio.isRunning && abs(audio.sampleRate - alternateRate) < 0.5,
                          "render \(audio.sampleRate), device \(alternateRate)")
                    if let rateClip {
                        let index = Shared.clipIndex(track: rateClip.track, scene: rateClip.scene)
                        check("the imported clip survives a rate rebuild",
                              model.timelineClip(id: rateClip.id) != nil
                              && model.shared.clipSample[index] >= 0
                              && model.waveform(track: rateClip.track,
                                                slot: rateClip.scene)?.isEmpty == false)
                    }
                    model.selectAudioOutput(current)
                    pump(1.2)
                    let restoredRate = AudioDevices.sampleRate(current.id)
                    check("switching back restores the original native rate",
                          audio.isRunning && abs(audio.sampleRate - restoredRate) < 0.5,
                          "render \(audio.sampleRate), device \(restoredRate)")
                    model.clearTimeline()
                } else {
                    skipped += 1
                    print("SKIP  rate change: no second output with a different rate")
                }
            } else {
                skipped += 1
                print("SKIP  output switch: current device is not in the CoreAudio list")
            }
        }
    }


    /// Clicking a clip transfers command focus out of the piano roll. This is the regression
    /// that made ⌘D add a note after the user had clicked an arrangement clip.
    private func testClipFocus() {
        model.clearTimeline()
        model.showAutomation = false
        model.laneTop = 0
        model.seek(to: 0)
        pump(0.4)
        guard let clip = model.addTimelineClip(track: 0, start: 0, length: 16),
              model.addNote(step: 0, pitch: 60) != nil else {
            return fail("could not build the focus fixture")
        }
        check("the piano roll owns focus after drawing a note", model.focus == .pianoRoll)
        guard let frame = waitFor("clip.\(clip)") else {
            return fail("the focus fixture clip never reported a frame")
        }
        click(center(frame))
        pump(0.25)
        check("clicking an arrangement clip focuses the arrangement", model.focus == .arrangement)
        check("clicking an arrangement clip clears the piano-roll note selection",
              model.selectedNote == nil)
        check("clicking an arrangement clip selects the placement",
              model.selectedClips.contains(clip))
    }

    /// A track-header selection must use ⌘D's track path, not the last note or clip.
    private func testTrackDuplicate() {
        model.clearTimeline()
        model.showAutomation = false
        model.laneTop = 0
        pump(0.3)
        guard model.addTimelineClip(track: 0, start: 0, length: 16) != nil,
              model.addNote(step: 0, pitch: 64) != nil else {
            return fail("could not build the duplicate-track fixture")
        }
        model.selectTrackHeader(0)
        let before = model.tracks.count
        let new = model.duplicateTrack(at: 0)
        check("duplicating a track appends exactly one lane",
              model.tracks.count == before + 1 && new == before)
        if let new {
            check("the duplicated track has the clip and note",
                  model.timeline.contains { $0.track == new }
                  && model.clips[new].contains { $0.notes.contains { $0.pitch == 64 } })
        }
    }

    /// Cmd-J / CONSOLIDATE combines adjacent MIDI clips into one editable clip.
    private func testConsolidate() {
        model.clearTimeline()
        model.showAutomation = false
        model.laneTop = 0
        model.seek(to: 0)
        pump(0.4)
        guard let first = model.addTimelineClip(track: 0, start: 0, length: 16),
              let second = model.addTimelineClip(track: 0, start: 16, length: 16) else {
            return fail("could not create the consolidate fixtures")
        }
        model.selectTimeline(first)
        _ = model.addNote(step: 0, pitch: 60)
        model.selectTimeline(second)
        _ = model.addNote(step: 0, pitch: 64)
        model.selectedClips = [first, second]
        model.selectedTimeline = first
        pump(0.3)
        guard let button = waitFor("arr.consolidate") else {
            return fail("arr.consolidate never reported a frame")
        }
        click(center(button))
        pump(0.4)
        check("CONSOLIDATE joins adjacent MIDI clips",
              model.timeline.count == 1 && model.timeline.first?.length == 32,
              "\(model.timeline.map { "\($0.start)+\($0.length)" })")
        if let merged = model.timeline.first {
            check("the consolidated clip keeps both notes",
                  model.clips[merged.track][merged.scene].notes.count == 2,
                  "\(model.clips[merged.track][merged.scene].notes.count) notes")
        }
    }

    /// Track deletion compacts the clip rows and tells the renderer the new count.
    private func testTrackDelete() {
        model.clearTimeline()
        model.showAutomation = false
        model.laneTop = 0
        let before = model.tracks.count
        model.addTrack()
        let last = model.tracks.count - 1
        guard let id = model.addTimelineClip(track: last, start: 0, length: 16) else {
            return fail("could not create the deletion fixture")
        }
        model.removeTrack(at: last)
        check("deleting a track removes its lane", model.tracks.count == before)
        check("deleting a track removes its clips", !model.timeline.contains { $0.id == id })
        check("the renderer receives the new track count",
              model.shared.trackCount.pointee == Int32(before))
    }

    private func testLanes() {
        check("the arrangement exposes track lanes", UITestHooks.shared.frame("lane.0") != nil)
    }

    private func testTimelineNavigation() {
        model.clearTimeline()
        model.arrLength = 128
        model.syncTimeline()
        model.scrollArrangement(toX: 0)
        pump(0.35)
        check("the arrangement exposes a horizontal scrollbar",
              waitFor("arr.timelineScrollbar") != nil)
        model.scrollArrangement(x: 300)
        check("the timeline scrolls horizontally", model.timelineScroll > 100,
              "offset \(model.timelineScroll)")
        model.zoomArrangement(by: 1.4, anchorX: 120)
        check("pointer-anchored zoom changes the scale", model.zoom > 16.1)
        model.scrollArrangement(toX: 0)
        model.zoom = 16
        model.arrLength = 64
        model.syncTimeline()
    }

    private func testMIDIGroupEditing() {
        model.clearTimeline()
        model.setSnap(.bar)
        guard model.addTimelineClip(track: 0, start: 0, length: 32) != nil else {
            return fail("could not create the group-edit fixture")
        }
        guard let a = model.addNote(step: 0, pitch: 60),
              let b = model.addNote(step: 4, pitch: 64),
              let c = model.addNote(step: 8, pitch: 67) else {
            return fail("could not create the group-edit notes")
        }
        model.focusPianoRoll()
        model.selectNotes([a, b, c])
        model.nudgeSelectedNote(steps: 4, pitch: 12)
        let notes = model.clips[0][model.selection.scene].notes
        check("multiple selected notes transpose together",
              [a, b, c].allSatisfy { id in notes.first { $0.id == id }?.pitch ?? 0 >= 72 })
        check("multiple selected notes move together",
              [a, b, c].allSatisfy { id in (notes.first { $0.id == id }?.start ?? 0) % 4 == 0 })
        model.updateNote(a, start: 5)
        model.setSnap(.beat)
        model.selectNotes([a])
        model.quantizeSelectedNotes()
        check("quantize snaps a note to the beat grid",
              notes.first { $0.id == a }?.start == 4)
        model.selectNotes([a, b, c])
        model.copySelectedNotes()
        model.pasteNotes()
        check("note copy/paste adds the selected group",
              model.clips[0][model.selection.scene].notes.count == 6,
              "\(model.clips[0][model.selection.scene].notes.count) notes")
        model.setSnap(.bar)
    }

    private func testTimeSignature() {
        model.setTimeSignature(numerator: 3, denominator: 4)
        check("3/4 uses twelve sixteenth steps per bar", model.stepsPerBar == 12)
        check("bar snapping follows the meter", model.snapSteps == 12)
        check("the transport position follows the meter",
              model.positionText(12) == "002.1.1")
        model.setTimeSignature(numerator: 4, denominator: 4)
        check("the meter can return to 4/4", model.stepsPerBar == 16)
    }

    private func testMIDIRecording() {
        model.clearTimeline()
        model.recordMode = .midi
        model.setFX(0, armed: true)
        model.seek(to: 0)
        model.beginRecording()
        pump(0.1)
        check("the transport enters MIDI record", model.isRecording && model.isPlaying)
        model.shared.playhead.pointee = 4
        model.handleRecordedMIDI(status: 0x90, note: 64, velocity: 100)
        model.shared.playhead.pointee = 8
        model.handleRecordedMIDI(status: 0x80, note: 64, velocity: 0)
        model.finishRecording()
        model.stopTransport()
        check("MIDI record creates one timeline clip", model.timeline.count == 1)
        let recorded = model.timeline.first.flatMap { clip in
            model.clips[clip.track][clip.scene].notes.first { $0.pitch == 64 }
        }
        check("MIDI record writes the played pitch", recorded != nil)
        check("MIDI record keeps the held length", (recorded?.length ?? 0) >= 2,
              "length \(recorded?.length ?? -1)")
        model.setFX(0, armed: false)
        model.clearTimeline()
    }

    private func testMIDICaptureAndCC() {
        model.clearTimeline()
        model.stopTransport()
        model.clearMIDICapture()
        model.seek(to: 0)
        model.handleMIDIEvent(status: 0x90, note: 67, velocity: 110)
        model.seek(to: 4)
        model.handleMIDIEvent(status: 0x80, note: 67, velocity: 0)
        check("MIDI capture records note events without arming the transport",
              model.midiCaptureCount == 2)
        check("captured MIDI becomes a timeline clip", model.captureMIDIToClip() != nil)
        let captured = model.timeline.first.flatMap { clip in
            model.clips[clip.track][clip.scene].notes.first
        }
        check("captured MIDI keeps the played pitch", captured?.pitch == 67)
        check("captured MIDI keeps the held length", (captured?.length ?? 0) >= 4,
              "length \(captured?.length ?? -1)")
        model.clearTimeline()

        model.beginMIDILearn(.trackVolume)
        model.handleMIDIEvent(status: 0xB0, note: 7, velocity: 64)
        check("MIDI CC learn maps a controller to track volume",
              model.midiMappings[7]?.target == .trackVolume)
        check("the learned CC changes the track volume",
              abs(model.fx[0].volume - 64.0 / 127.0) < 0.01,
              "\(model.fx[0].volume)")
        model.setFX(0, volume: 0.85)
        model.clearMIDIMappings()
    }

    private func testScaleProbabilityAndRouting() {
        model.clearTimeline()
        guard model.addTimelineClip(track: 0, start: 0, length: 16) != nil else {
            return fail("could not build the scale fixture")
        }
        model.setScale(root: 0, mode: .major)
        guard let id = model.addNote(step: 0, pitch: 61) else {
            return fail("could not draw the scale note")
        }
        let note = model.note(for: id)
        check("scale-constrained drawing snaps C♯ to C major", note?.pitch == 60,
              "pitch \(note?.pitch ?? -1)")
        model.setSelectedNoteProbability(40)
        model.setSelectedNoteGroove(0.3)
        let index = Shared.clipIndex(track: 0, scene: model.selection.scene)
        check("note probability reaches the renderer",
              model.shared.noteProb[index * Shared.maxNotes] == 40)
        check("note groove reaches the renderer",
              abs(model.shared.noteGroove[index * Shared.maxNotes] - 0.3) < 0.01)
        model.setGroup(0, group: 1)
        model.setGroupVolume(1, value: 0.5)
        check("a track routes into a group bus", model.shared.groupOf[0] == 1)
        check("group volume reaches the renderer",
              abs(model.shared.groupVolume[1] - 0.5) < 0.01)
        model.setGroup(0, group: 0)
        model.setGroupVolume(1, value: 1)
        model.setScale(root: 0, mode: .chromatic)
        model.clearTimeline()
    }

    private func testStems() {
        model.clearTimeline()
        guard model.addTimelineClip(track: 0, start: 0, length: 16) != nil,
              model.addNote(step: 0, pitch: 60, length: 4) != nil else {
            return fail("could not build the stem fixture")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketUITest-stems", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let urls = try model.bounceStems(to: directory)
            check("stem export writes one file per track", urls.count == model.tracks.count,
                  "\(urls.count) files for \(model.tracks.count) tracks")
            let data = urls.first.flatMap { try? Data(contentsOf: $0) } ?? Data()
            check("stem export writes a RIFF WAV",
                  data.count > 64 && String(data: data.prefix(4), encoding: .ascii) == "RIFF")
            check("stem export contains non-silent PCM", data.dropFirst(44).contains { $0 != 0 })
        } catch {
            fail("stem export threw: \(error.localizedDescription)")
        }
        model.clearTimeline()
    }

    private func testAutomationTargets() {
        model.clearTimeline()
        model.setAutomationTarget(.pan)
        model.addAutomationPoint(track: 0, step: 4, value: 0.25)
        check("pan automation drives the renderer",
              abs(model.shared.autoPan[4] - 0.25) < 0.01,
              "\(model.shared.autoPan[4])")
        model.clearAutomation(track: 0)
        check("clearing pan automation releases the value", model.shared.autoPan[4] < 0)
        model.setFX(0, pan: -0.4)
        check("the track pan control reaches the renderer",
              abs(Double(model.shared.basePan[0]) + 0.4) < 0.01)
        model.setFX(0, pan: 0)
        model.setAutomationTarget(.volume)
    }

    private func testAudioWarpAndReverse() {
        model.clearTimeline()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketUITest", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tone = directory.appendingPathComponent("warp-tone.wav")
        guard makeTone(at: tone) else { return fail("could not write the warp fixture") }
        model.dropAudio(path: tone.path, track: 0, start: 0)
        guard let clip = model.timeline.first(where: {
            model.clips[$0.track][$0.scene].sampleName == "warp-tone.wav"
        }) else { return fail("warp fixture did not load") }
        model.selectClip(clip.id)
        model.setSampleWarp(true, sourceBPM: 90)
        model.setSampleReverse(true)
        let index = Shared.clipIndex(track: clip.track, scene: clip.scene)
        check("warp is stored per audio clip",
              model.clips[clip.track][clip.scene].sampleWarp
              && model.shared.clipWarp[index] == 1)
        check("the warp source tempo is editable",
              abs(model.clips[clip.track][clip.scene].sampleSourceBPM - 90) < 0.01
              && abs(model.shared.clipSampleBPM[index] - 90) < 0.01)
        check("reverse is stored per audio clip",
              model.clips[clip.track][clip.scene].sampleReverse
              && model.shared.clipReverse[index] == 1)

        model.selectClip(clip.id)
        let right = model.splitClip(clip.id, at: max(clip.start + 1, 4))
        if let right {
            model.selectedClips = [clip.id, right]
            model.consolidateSelectedClips()
            check("audio consolidate replaces the selected clips",
                  model.timeline.count == 1
                  && model.clips[model.timeline[0].track][model.timeline[0].scene].sampleName != nil,
                  "\(model.timeline.count) clips")
        } else {
            fail("could not split the audio consolidate fixture")
        }
        model.clearTimeline()
    }

    private func testBrowserSearch() {
        model.browserSearch = "tone"
        check("browser search filters by name",
              model.filteredBrowserItems.allSatisfy {
                  $0.name.localizedCaseInsensitiveContains("tone")
              })
        model.browserSearch = ""
    }

    private func testNoteUndoAndRollScroll() {
        model.clearTimeline()
        guard model.addTimelineClip(track: 0, start: 0, length: 16) != nil,
              model.addNote(step: 0, pitch: 60) != nil else {
            return fail("could not build the note-undo fixture")
        }
        let before = model.clips[0][model.selection.scene].notes.count
        model.undo()
        check("undo removes a drawn note",
              model.clips[0][model.selection.scene].notes.count == before - 1)
        model.redo()
        check("redo restores a drawn note",
              model.clips[0][model.selection.scene].notes.count == before)
        model.rollFocusPitch = 60
        model.scrollPianoRoll(by: -12)
        check("the piano roll scrolls by semitones", model.rollFocusPitch == 48)
        model.scrollPianoRoll(by: 12)
        model.clearTimeline()
    }

    private func testMixdown() {
        model.clearTimeline()
        guard model.addTimelineClip(track: 0, start: 0, length: 16) != nil,
              model.addNote(step: 0, pitch: 60, length: 4) != nil else {
            return fail("could not build the mixdown fixture")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketUITest-bounce.wav")
        do {
            _ = try model.bounceMixdown(to: url, start: 0, end: 16, tail: 0.05)
        } catch {
            return fail("mixdown threw: \(error.localizedDescription)")
        }
        let data = (try? Data(contentsOf: url)) ?? Data()
        check("mixdown writes a RIFF WAV", data.count > 64 && String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        check("mixdown contains non-silent PCM", data.dropFirst(44).contains { $0 != 0 })
        model.clearTimeline()
    }

    /// Generators are listed from the system, loaded into a track and asked for their editor.
    private func testInstruments() {
        let list = model.availableInstruments()
        check("AU generators are discoverable", !list.isEmpty)
        guard let dls = list.first(where: { $0.subtype == kAudioUnitSubType_DLSSynth
                                            && $0.manufacturer == kAudioUnitManufacturer_Apple })
                ?? list.first(where: { $0.name.uppercased().contains("DLS") }) else {
            skipped += 1
            print("SKIP  AU generator load: no DLS synth on this machine")
            return
        }
        model.select(track: 0, scene: model.selection.scene)
        model.loadInstrument(track: 0, descriptor: dls)
        check("an AU generator can be loaded on a track", model.instrumentNames[0]?.isEmpty == false)
        check("the generator is enabled for the renderer",
              model.shared.instOn[0] == 1 && model.shared.instPtr[0] != nil)

        var editor: NSViewController?
        var done = false
        model.instrumentInstance(track: 0)?.requestEditor { controller in
            editor = controller
            done = true
        }
        _ = waitUntil(5) { done }
        if editor != nil {
            check("the generator hands back its AU editor", true)
        } else {
            skipped += 1
            print("SKIP  AU editor: \(dls.name) exposes no view controller on this machine")
        }
        if let state = model.instrumentInstance(track: 0)?.fullState() {
            check("an AU generator exposes serializable patch state", !state.isEmpty,
                  "\(state.count) bytes")
            check("AU patch state restores into the live instance",
                  model.instrumentInstance(track: 0)?.restoreState(state) == true)
        } else {
            skipped += 1
            print("SKIP  AU state: \(dls.name) exposed no ClassInfo state")
        }
        model.removeInstrument(track: 0)
        check("removing the generator restores the built-in synth",
              model.instrumentNames[0] == nil && model.shared.instOn[0] == 0)
    }

    /// The old importer stopped decoding at two minutes. A long song therefore looked blank
    /// after the cutoff. This fixture is longer than that boundary on purpose.
    private func testLongAudioImport() {
        model.clearTimeline()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketUITest", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("long-tone.wav")
        guard makeLongTone(at: url, seconds: 130) else {
            return fail("could not write the long audio fixture")
        }
        model.dropAudio(path: url.path, track: 0, start: 0)
        guard let clip = model.timeline.first(where: {
            model.clips[$0.track][$0.scene].sampleName == "long-tone.wav"
        }), let info = model.sampleInfo(track: clip.track, scene: clip.scene) else {
            return fail("the long file did not create a clip")
        }
        check("an import longer than two minutes keeps its full duration",
              info.seconds > 129, String(format: "%.1f s", info.seconds))
        check("a long import creates a non-empty waveform",
              model.waveform(track: clip.track, slot: clip.scene)?.isEmpty == false)
        check("a long import spans the arrangement instead of one bar",
              clip.length > 500, "\(clip.length) steps")
        model.clearTimeline()
    }

    private func testTakesWarpAndMIDIEffect() {
        model.clearTimeline()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketUITest", isDirectory: true)
        let first = directory.appendingPathComponent("take-one.wav")
        let second = directory.appendingPathComponent("take-two.wav")
        guard makeTone(at: first), makeTone(at: second) else {
            return fail("could not write the take fixtures")
        }
        model.dropAudio(path: first.path, track: 0, start: 0)
        guard let clip = model.timeline.first(where: { $0.track == 0 }),
              model.timelineClip(id: clip.id) != nil else {
            return fail("could not place the take fixture")
        }
        model.selectClip(clip.id)
        _ = model.addTake(path: second.path, name: "take-two.wav",
                          track: clip.track, scene: clip.scene)
        check("recording a second pass adds a take",
              model.clips[clip.track][clip.scene].takes.count == 2)
        model.useTake(track: clip.track, scene: clip.scene, index: 0)
        check("selecting a take changes the active comp",
              model.clips[clip.track][clip.scene].activeTake == 0
              && model.clips[clip.track][clip.scene].sampleName == "take-one.wav")
        model.addWarpMarker(at: clip.start + 8)
        check("a warp anchor is stored on the clip",
              model.clips[clip.track][clip.scene].warpMarkers.count == 1)
        check("a warp anchor reaches the renderer",
              model.shared.clipWarpCount[Shared.clipIndex(track: clip.track,
                                                          scene: clip.scene)] == 1)
        model.removeWarpMarker(at: 0)
        check("a warp anchor can be removed",
              model.clips[clip.track][clip.scene].warpMarkers.isEmpty)
        model.setMIDIEffect(.chord, track: 0)
        check("a MIDI chord effect reaches the renderer",
              model.shared.midiEffect[0] == MIDIEffect.chord.code)
        model.setMIDIEffect(.off, track: 0)
        model.clearTimeline()
    }

    private func testCrossfade() {
        model.clearTimeline()
        model.setSnap(.sixteenth)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketUITest", isDirectory: true)
        let url = directory.appendingPathComponent("crossfade-tone.wav")
        guard makeTone(at: url) else { return fail("could not write the crossfade fixture") }
        model.dropAudio(path: url.path, track: 0, start: 0)
        guard let first = model.timeline.first(where: { $0.track == 0 }) else {
            return fail("could not place the first crossfade clip")
        }
        model.dropAudio(path: url.path, track: 0, start: first.length)
        guard model.timeline.count == 2 else {
            return fail("could not place the second crossfade clip")
        }
        model.selectClip(first.id)
        let crossfaded = model.crossfadeSelectedClip(overlapSteps: 1)
        check("two touching audio clips can be crossfaded", crossfaded,
              "status=\(model.status), clips=\(model.timeline.map { "\($0.start)+\($0.length)" }.joined(separator: ","))")
        guard let left = model.timelineClip(id: first.id),
              let right = model.timeline.first(where: { $0.id != first.id }) else {
            return fail("a crossfade clip disappeared")
        }
        check("the crossfade creates a real one-step overlap",
              left.start + left.length > right.start)
        check("the crossfade writes reciprocal fades",
              model.clips[left.track][left.scene].sampleFadeOut > 0
              && model.clips[right.track][right.scene].sampleFadeIn > 0)
        model.clearTimeline()
    }

    /// Pitch-preserving warp, region comping, clip gain automation, the second return bus and
    /// the arpeggiator all have to reach the renderer, not just the toolbar.
    private func testStretchCompGainReturnsArp() {
        model.clearTimeline()
        model.setSnap(.sixteenth)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketUITest", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("feature-one.wav")
        let second = directory.appendingPathComponent("feature-two.wav")
        guard makeTone(at: first), makeTone(at: second) else {
            return fail("could not write the feature fixtures")
        }
        model.dropAudio(path: first.path, track: 0, start: 0)
        guard let clip = model.timeline.first(where: { $0.track == 0 }) else {
            return fail("the feature fixture did not place")
        }
        model.selectClip(clip.id)
        _ = model.addTake(path: second.path, name: "feature-two.wav",
                          track: clip.track, scene: clip.scene)
        model.setSampleWarp(true)
        model.setSampleWarpStretch(true)
        let index = Shared.clipIndex(track: clip.track, scene: clip.scene)
        check("stretch warp reaches the renderer",
              model.shared.clipStretch[index] == 1 && model.shared.clipWarp[index] == 1)

        model.timeSelection = TimeRange(start: clip.start + 4, end: clip.start + 8)
        model.setCompRegion(take: 1)
        check("a comp region is stored on the clip",
              model.clips[clip.track][clip.scene].compRegions.count == 1)
        check("a comp region reaches the renderer with its take slot",
              model.shared.clipRegionCount[index] == 1
              && model.shared.clipRegionSlot[index * Shared.maxCompRegions] >= 0)

        model.setAutomationTarget(.clipGain)
        model.addAutomationPoint(track: clip.track, step: clip.start + 2, value: 0.25)
        check("clip gain automation is stored locally on the clip",
              model.clips[clip.track][clip.scene].gainEnvelope.contains { $0.step == 2 })
        check("clip gain automation reaches the renderer",
              model.shared.clipGainCount[index] == 1)
        model.clearAutomation(track: clip.track)
        check("clip gain automation clears",
              model.clips[clip.track][clip.scene].gainEnvelope.isEmpty
              && model.shared.clipGainCount[index] == 0)
        model.setAutomationTarget(.volume)

        model.setFX(clip.track, sendB: 0.66)
        model.setReturnLevelB(0.55)
        check("return B and its send reach the renderer",
              abs(model.shared.sendB[clip.track] - 0.66) < 0.001
              && abs(model.shared.returnLevelB.pointee - 0.55) < 0.001)
        model.setArp(mode: .up, rate: .eighth, track: clip.track)
        check("the arpeggiator reaches the renderer",
              model.shared.arpMode[clip.track] == 1
              && model.shared.arpRate[clip.track] == 2)
        model.setArp(mode: .off, rate: .sixteenth, track: clip.track)
        model.clearTimeline()
    }

    /// AUTO XF and lane reordering are structural: they must move real clips and real
    /// renderer state, not just the labels in the header.
    private func testAutoCrossfadeAndTrackOrder() {
        model.clearTimeline()
        model.setSnap(.sixteenth)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketUITest", isDirectory: true)
        let url = directory.appendingPathComponent("auto-xf-tone.wav")
        guard makeTone(at: url) else { return fail("could not write the auto-crossfade fixture") }
        model.dropAudio(path: url.path, track: 0, start: 0)
        guard let first = model.timeline.first(where: { $0.track == 0 }) else {
            return fail("the auto-crossfade fixture did not place")
        }
        model.dropAudio(path: url.path, track: 0, start: first.length)
        guard model.timeline.count == 2 else {
            return fail("could not place the second auto-crossfade clip")
        }
        model.autoCrossfade = true
        model.endGestureEdit()
        let ordered = model.timeline.sorted { $0.start < $1.start }
        check("automatic crossfade creates a real overlap",
              ordered.count == 2 && ordered[0].start + ordered[0].length > ordered[1].start)
        model.autoCrossfade = false

        model.clearTimeline()
        guard let lower = model.addTimelineClip(track: 0, start: 0, length: 16) else {
            return fail("could not place the reorder fixture")
        }
        model.addTrack()
        guard let upper = model.addTimelineClip(track: 1, start: 0, length: 16) else {
            return fail("could not place the second reorder fixture")
        }
        model.renameTrack(0, "MOVE ME")
        model.addAutomationPoint(track: 0, step: 0, value: 0.4, target: .volume)
        model.moveTrack(0, by: 1)
        check("reordering renumbers the lanes",
              model.tracks.count >= 2 && model.tracks[1].name == "MOVE ME"
              && model.tracks[1].id == 1)
        check("reordering moves the lane's clips",
              model.timeline.first(where: { $0.id == lower })?.track == 1
              && model.timeline.first(where: { $0.id == upper })?.track == 0)
        check("reordering moves the lane's automation",
              model.automation[1]?.isEmpty == false && (model.automation[0] ?? []).isEmpty)
        if let moved = model.timeline.first(where: { $0.id == lower }) {
            check("reordering rebuilds the renderer track state",
                  model.shared.hasClip[Shared.clipIndex(track: 1, scene: moved.scene)] == 1)
        }
        model.clearTimeline()
    }

    private func testRecordingLatencyMath() {
        model.setBPM(120)
        model.setRecordingLatency(milliseconds: 250)
        check("250 ms at 120 BPM compensates exactly two sixteenth steps",
              model.recordLatencySteps == 2, "\(model.recordLatencySteps) steps")
        model.setRecordingLatency(milliseconds: 0)
        model.setBPM(112)
    }

    /// Focused text fields must own Backspace. This sends the real key event through AppKit's
    /// local monitor, so a regression in the guard deletes the selected clip and fails here.
    private func testTextEditingKeepsClipSelection() {
        model.clearTimeline()
        guard let id = model.addTimelineClip(track: 0, start: 0, length: 16) else {
            return fail("could not create the keyboard fixture")
        }
        model.selectClip(id)
        let probe = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        probe.contentView = editor
        probe.makeFirstResponder(editor)
        check("a focused text editor is recognized", isEditingText(in: probe))
        if let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: probe.windowNumber, context: nil,
            characters: String(UnicodeScalar(8)),
            charactersIgnoringModifiers: String(UnicodeScalar(8)),
            isARepeat: false, keyCode: 51
        ) {
            NSApp.sendEvent(event)
            pump(0.15)
        }
        check("Backspace while editing a field does not delete the selected clip",
              model.timeline.contains { $0.id == id })
        probe.makeFirstResponder(nil)
        probe.close()
        model.clearTimeline()
    }

    // MARK: Events

    private var contentHeight: CGFloat {
        window.contentView?.bounds.height ?? window.contentLayoutRect.height
    }

    private func windowPoint(_ root: CGPoint) -> NSPoint {
        NSPoint(x: root.x, y: contentHeight - root.y)
    }

    private func press(_ root: CGPoint, nudging: CGFloat = 0) {
        post(.leftMouseDown, root: root)
        if nudging > 0 {
            post(.leftMouseDragged, root: CGPoint(x: root.x, y: root.y + nudging))
        }
        pump(0.08)
    }

    private func release(_ root: CGPoint) {
        post(.leftMouseUp, root: root)
        pump(0.12)
    }

    private func dragGesture(from start: CGPoint, to end: CGPoint) {
        post(.leftMouseDown, root: start)
        for i in 1...8 {
            let t = CGFloat(i) / 8
            post(.leftMouseDragged,
                 root: CGPoint(x: start.x + (end.x - start.x) * t,
                               y: start.y + (end.y - start.y) * t))
        }
        pump(0.08)
        post(.leftMouseUp, root: end)
        pump(0.2)
    }

    private func click(_ root: CGPoint, nudging: CGFloat = 0) {
        press(root, nudging: nudging)
        release(root)
    }

    private func post(_ type: NSEvent.EventType, root: CGPoint) {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: windowPoint(root),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        // Route through the SwiftUI host: AppKit scroll views otherwise swallow synthetic
        // clicks aimed at content inside a scrollable SwiftUI ScrollView.
        if let host = window.contentView {
            switch type {
            case .leftMouseDown: host.mouseDown(with: event)
            case .leftMouseUp: host.mouseUp(with: event)
            case .leftMouseDragged: host.mouseDragged(with: event)
            default: window.sendEvent(event)
            }
        } else {
            window.sendEvent(event)
        }
    }

    /// Real cursor drag (only used when the process may post CGEvents).
    private func drag(from start: CGPoint, to end: CGPoint) {
        func global(_ root: CGPoint) -> CGPoint {
            let local = NSPoint(x: root.x, y: contentHeight - root.y)
            let screen = window.convertPoint(toScreen: local)
            let height = (window.screen ?? NSScreen.main)?.frame.height ?? 900
            return CGPoint(x: screen.x, y: height - screen.y)
        }

        let source = CGEventSource(stateID: .hidSystemState)
        func emit(_ type: CGEventType, _ point: CGPoint) {
            CGEvent(mouseEventSource: source, mouseType: type,
                    mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            pump(0.03)
        }

        let a = global(start)
        let b = global(end)
        emit(.mouseMoved, a)
        usleep(150_000)
        emit(.leftMouseDown, a)
        pump(0.25)                 // let SwiftUI start its dragging session
        for step in 1...30 {
            let t = CGFloat(step) / 30
            emit(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            usleep(12_000)
        }
        pump(0.2)
        emit(.leftMouseUp, b)
        pump(1.2)
    }

    // MARK: Helpers

    private func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitFor(_ id: String, timeout: Double = 5) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = UITestHooks.shared.frame(id), frame.width > 1, frame.height > 1 {
                return frame
            }
            pump(0.05)
        }
        return nil
    }

    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump(0.05)
        }
        return condition()
    }

    private func center(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
            print("PASS  \(name)")
        } else {
            failed += 1
            failures.append(name)
            print("FAIL  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
    }

    private func fail(_ message: String) {
        failed += 1
        failures.append(message)
        print("FAIL  \(message)")
    }

    private func printSummary() {
        if failed == 0 {
            print("UITEST PASS  \(passed) checks, \(skipped) skipped")
        } else {
            print("UITEST FAIL  \(passed) passed, \(failed) failed, \(skipped) skipped")
            for failure in failures { print("  - \(failure)") }
        }
    }
}

// MARK: - Fixtures

/// Writes a one-second 220 Hz mono WAV at 44.1 kHz.
private func makeTone(at url: URL) -> Bool {
    try? FileManager.default.removeItem(at: url)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
          let file = try? AVAudioFile(forWriting: url, settings: format.settings) else {
        return false
    }
    let frameCount: AVAudioFrameCount = 44_100
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
          let channel = buffer.floatChannelData?[0] else { return false }
    buffer.frameLength = frameCount
    for i in 0..<Int(frameCount) {
        channel[i] = Float(sin(2 * Double.pi * 220 * Double(i) / 44_100)) * 0.5
    }
    do { try file.write(from: buffer) } catch { return false }
    return true
}

/// Writes a long low-rate WAV so the import test stays fast while crossing the old 120 s cap.
private func makeLongTone(at url: URL, seconds: Double) -> Bool {
    try? FileManager.default.removeItem(at: url)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1),
          let file = try? AVAudioFile(forWriting: url, settings: format.settings) else {
        return false
    }
    let frameCount = AVAudioFrameCount(8_000 * seconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
          let channel = buffer.floatChannelData?[0] else { return false }
    buffer.frameLength = frameCount
    for i in 0..<Int(frameCount) {
        channel[i] = Float(sin(2 * Double.pi * 110 * Double(i) / 8_000)) * 0.2
    }
    do { try file.write(from: buffer) } catch { return false }
    return true
}

private func loadPath(from provider: NSItemProvider) -> String? {
    var path: String?
    var done = false
    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        if let data = item as? Data {
            if let text = String(data: data, encoding: .utf8), let url = URL(string: text) {
                path = url.path
            } else if let url = URL(dataRepresentation: data, relativeTo: nil) {
                path = url.path
            }
        } else if let url = item as? URL {
            path = url.path
        } else if let url = item as? NSURL {
            path = url.path
        } else if let string = item as? String {
            path = URL(string: string)?.path
        }
        done = true
    }
    let deadline = Date().addingTimeInterval(3)
    while !done && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return path
}
