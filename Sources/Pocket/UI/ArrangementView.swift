import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The song's linear workspace. This is deliberately built out of real per-lane clip views:
/// selection, cross-track moves, clip-edge resizing, fades, time selection, locators, the loop
/// brace and automation all operate on the same model the renderer reads.
struct ArrangementView: View {
    @ObservedObject var model: SessionModel

    private let headerWidth: CGFloat = 188
    private let rowHeight: CGFloat = 58
    private let rulerHeight: CGFloat = 42
    private let toolbarHeight: CGFloat = 58
    private let automationHeight: CGFloat = 54
    private let newTrackHeight: CGFloat = 44
    private let runwaySteps = 256
    private let scrollbarSize: CGFloat = 9

    private var zoom: CGFloat { CGFloat(model.zoom) }

    var body: some View {
        GeometryReader { geo in
            let laneViewport = max(geo.size.height - toolbarHeight - rulerHeight - scrollbarSize,
                                   rowHeight * 3)
            let length = max(model.arrLength, model.loopEnd, model.stepsPerBar * 4) + runwaySteps
            let width = max(CGFloat(length) * zoom, 400)
            let viewportWidth = max(geo.size.width - headerWidth - scrollbarSize, 200)
            let contentHeight = totalHeight() + newTrackHeight

            VStack(spacing: 0) {
                toolbar(length: length, viewport: viewportWidth)
                HStack(spacing: 0) {
                    headerColumn(viewport: laneViewport)
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ZStack(alignment: .topLeading) {
                                ruler(length: length, width: width)
                                    .offset(x: -model.timelineScroll)
                            }
                            .frame(width: viewportWidth, height: rulerHeight, alignment: .topLeading)
                            .clipped()

                            ZStack(alignment: .topLeading) {
                                lanes(length: length, width: width)
                                    .offset(x: -model.timelineScroll, y: -model.laneScroll)
                            }
                            .frame(width: viewportWidth, height: laneViewport, alignment: .topLeading)
                            .clipped()
                            .background(Theme.bg)
                            .background(
                                GeometryReader { geometry in
                                    Color.clear
                                        .onAppear { updateMetrics(geometry, width: width,
                                                                  height: contentHeight) }
                                        .onChange(of: geometry.size) { _, _ in
                                            updateMetrics(geometry, width: width,
                                                          height: contentHeight)
                                        }
                                        .onChange(of: width) { _, _ in
                                            updateMetrics(geometry, width: width,
                                                          height: contentHeight)
                                        }
                                        .onChange(of: contentHeight) { _, _ in
                                            updateMetrics(geometry, width: width,
                                                          height: contentHeight)
                                        }
                                }
                            )
                        }

                        VStack(spacing: 0) {
                            Color.clear.frame(height: rulerHeight)
                            LaneScrollbar(model: model)
                                .frame(width: scrollbarSize, height: laneViewport)
                                .opacity(model.arrangementContentHeight > laneViewport + 1 ? 1 : 0.25)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 1)

                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            HorizontalScrollbar(model: model)
                                .frame(width: viewportWidth - 4, height: scrollbarSize)
                        }
                        .frame(height: laneViewport + rulerHeight, alignment: .bottom)
                        .padding(.bottom, 2)
                    }
                    .frame(width: viewportWidth, height: laneViewport + rulerHeight)
                }
            }
            .overlay(alignment: .topLeading) {
                followDriver(length: length, viewport: viewportWidth)
                    .padding(.leading, headerWidth)
                    .padding(.top, toolbarHeight + rulerHeight)
            }
        }
        .background(Theme.bg)
        .onChange(of: model.laneTop) { _, newTop in
            guard let newTop else { return }
            model.scrollLanes(to: CGFloat(newTop) * rowHeight)
        }
    }

    private func updateMetrics(_ geometry: GeometryProxy, width: CGFloat, height: CGFloat) {
        model.arrangementCanvasFrame = geometry.frame(in: .named("pocket"))
        model.updateArrangementViewport(width: geometry.size.width,
                                        height: geometry.size.height,
                                        contentWidth: width,
                                        contentHeight: height)
    }

    // MARK: - Toolbar

    private func toolbar(length: Int, viewport: CGFloat) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("ARRANGEMENT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Text("\(Int(ceil(Double(model.arrLength) / Double(model.stepsPerBar)))) BARS · \(model.timeSigNumerator)/\(model.timeSigDenominator)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.6))
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 16)

                FlatButton(title: "+ TRACK") { model.addTrack() }
                FlatButton(title: model.loopEnabled ? "LOOP ON" : "LOOP OFF",
                           tint: model.loopEnabled ? Theme.accent : Theme.dim) {
                    model.toggleLoop()
                }
                .background(FrameReporter(id: "arr.loop"))
                FlatButton(title: "SET LOCATOR") { model.addLocator() }
                .background(FrameReporter(id: "arr.locator"))
                FlatButton(title: "◀", width: 24) { model.jumpToLocator(forward: false) }
                FlatButton(title: "▶", width: 24) { model.jumpToLocator(forward: true) }
                FlatButton(title: "FOLLOW", tint: model.followPlayhead ? Theme.go : Theme.dim) {
                    model.followPlayhead.toggle()
                }
                FlatButton(title: "AUTO", tint: model.showAutomation ? Theme.accent : Theme.dim) {
                    model.showAutomation.toggle()
                }
                .background(FrameReporter(id: "arr.auto"))

                Menu {
                    ForEach(SnapGrid.allCases) { grid in
                        Button(grid.label) { model.setSnap(grid) }
                    }
                } label: {
                    Text("SNAP \(model.snap.label)")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Theme.panelAlt)
                        .foregroundStyle(Theme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 78)

                FlatButton(title: "−", width: 22) { model.zoomArrangement(by: 1 / 1.25) }
                FlatButton(title: "+", width: 22) { model.zoomArrangement(by: 1.25) }
                FlatButton(title: "FIT") { model.zoomToFit(contentSteps: model.arrLength) }
                Spacer(minLength: 6)
                FlatButton(title: "UNDO", tint: model.canUndo ? Theme.text : Theme.dim) {
                    model.undo()
                }
                .disabled(!model.canUndo)
                .background(FrameReporter(id: "arr.undo"))
                FlatButton(title: "REDO", tint: model.canRedo ? Theme.text : Theme.dim) {
                    model.redo()
                }
                .disabled(!model.canRedo)
            }
            .padding(.horizontal, 9)

            HStack(spacing: 6) {
                Text("CLIPS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.7))
                FlatButton(title: "SPLIT") { model.splitAtInsertMarker() }
                    .background(FrameReporter(id: "arr.split"))
                FlatButton(title: "XFADE") { _ = model.crossfadeSelectedClip() }
                    .help("Crossfade this audio clip into the next touching clip on its track")
                FlatButton(title: "AUTO XF", tint: model.autoCrossfade ? Theme.go : Theme.dim) {
                    model.autoCrossfade.toggle()
                }
                .help("Automatically crossfade adjacent audio clips after edits and drops")
                FlatButton(title: "CONSOLIDATE") { model.consolidateSelectedClips() }
                    .background(FrameReporter(id: "arr.consolidate"))
                FlatButton(title: "DUPLICATE") { model.duplicateSelectedTimelineClip() }
                FlatButton(title: "COPY") { model.copySelectedClips() }
                FlatButton(title: "PASTE") { model.pasteClips() }
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 16)
                Text("TIME")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.7))
                FlatButton(title: "INSERT") { insertTime() }
                FlatButton(title: "DUPLICATE TIME") { duplicateTime() }
                    .disabled(model.timeSelection == nil)
                FlatButton(title: "DELETE TIME") { deleteTime() }
                    .disabled(model.timeSelection == nil)
                    .background(FrameReporter(id: "arr.time.delete"))
                if model.showAutomation {
                    Menu {
                        ForEach(AutomationTarget.allCases) { target in
                            Button(target.label) { model.setAutomationTarget(target) }
                        }
                    } label: {
                        Text("ENV \(model.automationTarget.label)")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .frame(height: 22)
                            .background(Theme.panelAlt)
                            .foregroundStyle(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 76)
                    FlatButton(title: "CLEAR AUTO") {
                        model.clearAutomation(track: model.selection.track)
                    }
                }
                Spacer(minLength: 6)
                Text("drag clips · double-click empty lane adds a bar · shift-drag selects time · scroll pans · ⌘-scroll zooms")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.dim.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
        }
        .frame(height: toolbarHeight, alignment: .top)
        .padding(.top, 5)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    private func insertTime() {
        if let selection = model.timeSelection, !selection.isEmpty {
            model.insertTime(at: selection.start, length: selection.length)
        } else {
            model.insertTime(at: model.insertStep, length: model.stepsPerBar)
        }
    }

    private func duplicateTime() {
        guard let selection = model.timeSelection, !selection.isEmpty else { return }
        model.duplicateTime(start: selection.start, end: selection.end)
    }

    private func deleteTime() {
        guard let selection = model.timeSelection, !selection.isEmpty else { return }
        model.deleteTime(start: selection.start, end: selection.end)
    }

    // MARK: - Headers

    private func headerColumn(viewport: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(model.tracks) { track in
                        headerRow(track)
                            .id(track.id)
                        if isExpanded(track.id) {
                            automationHeader(track)
                        }
                    }
                    Color.clear.frame(height: 240)
                }
                .offset(y: -model.laneScroll)
            }
            .frame(height: viewport, alignment: .topLeading)
            .clipped()
        }
        .frame(width: headerWidth)
        .background(Theme.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.stroke).frame(width: 1) }
    }

    private func headerRow(_ track: TrackInfo) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(track.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(track.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(model.selection.track == track.id ? Theme.text : Theme.dim)
                        .lineLimit(1)
                        .onTapGesture(count: 2) { promptRename(track) }
                    Spacer(minLength: 0)
                    Button {
                        model.moveTrack(track.id, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Theme.dim.opacity(0.7))
                            .frame(width: 12, height: 12)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    .buttonStyle(.plain)
                    .help("Move \(track.name) up")
                    Button {
                        model.moveTrack(track.id, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Theme.dim.opacity(0.7))
                            .frame(width: 12, height: 12)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    .buttonStyle(.plain)
                    .help("Move \(track.name) down")
                    Button {
                        confirmDeleteTrack(track)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Theme.dim.opacity(0.7))
                            .frame(width: 12, height: 12)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    .buttonStyle(.plain)
                    .help("Delete \(track.name)")
                }
                HStack(spacing: 3) {
                    FlagButton(label: "M", active: (model.muteMask >> track.id) & 1 == 1,
                               tint: Theme.mute) { model.toggleMute(track.id) }
                    FlagButton(label: "S", active: (model.soloMask >> track.id) & 1 == 1,
                               tint: Theme.solo) { model.toggleSolo(track.id) }
                    FlagButton(label: "R", active: model.fx[track.id].armed,
                               tint: Theme.record) {
                        model.setFX(track.id, armed: !model.fx[track.id].armed)
                    }
                    Slider(value: Binding(get: { model.fx[track.id].volume },
                                          set: { model.setFX(track.id, volume: $0) }),
                           in: 0...1)
                        .frame(width: 48)
                        .tint(track.color)
                        .help("Track volume")
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { _ in
                        GeometryReader { geo in
                            ZStack(alignment: .bottom) {
                                Rectangle().fill(Color(white: 0.17))
                                Rectangle().fill(track.color)
                                    .frame(height: geo.size.height
                                           * CGFloat(min(max(model.shared.trackLevel[track.id], 0), 1)))
                            }
                        }
                        .frame(width: 4, height: 15)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: rowHeight)
        .background(model.selection.track == track.id ? Theme.header : Theme.panel)
        .background(FrameReporter(id: "header.\(track.id)"))
        .contentShape(Rectangle())
        .onTapGesture { model.selectTrackHeader(track.id) }
        .onHover { inside in model.hoveredTrack = inside ? track.id : nil }
        .contextMenu {
            Button("Duplicate Track") { model.duplicateTrack(at: track.id) }
            Button("Delete Track") { confirmDeleteTrack(track) }
        }
    }

    private func automationHeader(_ track: TrackInfo) -> some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(AutomationTarget.allCases) { target in
                    Button(target.label) { model.setAutomationTarget(target) }
                }
            } label: {
                Text(model.automationTarget.label)
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 44)
            Text("AUTOMATION")
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(Theme.dim.opacity(0.7))
            Spacer()
            Button { model.clearAutomation(track: track.id) } label: {
                Text("CLEAR")
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: automationHeight)
        .background(Color(white: 0.105))
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    private func isExpanded(_ track: Int) -> Bool {
        model.showAutomation && model.selection.track == track
    }

    // MARK: - Ruler

    private func ruler(length: Int, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.panelAlt))
                let loopX = CGFloat(max(model.loopStart, 0)) * zoom
                let loopW = CGFloat(max(model.loopLength, model.stepsPerBar)) * zoom
                context.fill(Path(CGRect(x: loopX, y: 0, width: min(loopW, size.width - loopX),
                                         height: size.height)),
                             with: .color(Theme.accent.opacity(model.loopEnabled ? 0.11 : 0.04)))
                let barSteps = model.stepsPerBar
                let majorEvery = max(barSteps * 4, 1)
                for bar in stride(from: 0, through: length, by: barSteps) {
                    let x = CGFloat(bar) * zoom
                    let heavy = bar % majorEvery == 0
                    context.fill(Path(CGRect(x: x, y: 14, width: 1, height: size.height - 14)),
                                 with: .color(Color.white.opacity(heavy ? 0.24 : 0.10)))
                    if x + 26 < size.width {
                        context.draw(Text("\(bar / barSteps + 1)")
                                        .font(.system(size: 8, weight: heavy ? .bold : .medium,
                                                      design: .monospaced))
                                        .foregroundStyle(heavy ? Theme.text : Theme.dim),
                                     at: CGPoint(x: x + 4, y: size.height - 9), anchor: .leading)
                    }
                }
                // The loop brace: a bracket in the scrub area with edge grips.
                let braceY: CGFloat = 27
                context.fill(Path(CGRect(x: loopX, y: braceY, width: min(loopW, size.width - loopX),
                                         height: 4)),
                             with: .color(model.loopEnabled ? Theme.accent.opacity(0.75)
                                                            : Theme.dim.opacity(0.35)))
                context.fill(Path(CGRect(x: loopX - 1, y: braceY - 3, width: 2, height: 10)),
                             with: .color(model.loopEnabled ? Theme.accent : Theme.dim))
                context.fill(Path(CGRect(x: loopX + loopW - 1, y: braceY - 3, width: 2, height: 10)),
                             with: .color(model.loopEnabled ? Theme.accent : Theme.dim))
                if size.width > loopX + 44 {
                    context.draw(Text("LOOP")
                                    .font(.system(size: 6, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Theme.accent.opacity(0.8)),
                                 at: CGPoint(x: loopX + 4, y: braceY + 10), anchor: .leading)
                }
            }
            .frame(width: width, height: rulerHeight)

            HStack(spacing: 0) {
                ForEach(0..<max(length / model.stepsPerBar + 1, 1), id: \.self) { bar in
                    Color.clear
                        .frame(width: CGFloat(model.stepsPerBar) * zoom, height: 1)
                        .id("bar-\(bar)")
                }
            }
            .frame(height: 1, alignment: .leading)

            Color.clear
                .contentShape(Rectangle())
                .gesture(rulerGesture())
                .onTapGesture(count: 2) {
                    model.zoom = 16
                    model.seek(to: 0)
                }

            ForEach(model.locators) { locator in
                locatorFlag(locator)
                    .offset(x: CGFloat(locator.step) * zoom + 2, y: 1)
            }

            insertMarker(height: rulerHeight)
                .allowsHitTesting(false)
            PlayheadLine(model: model, zoom: zoom, length: length, height: rulerHeight)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: rulerHeight, alignment: .topLeading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
        .background(FrameReporter(id: "arr.ruler"))
    }

    private func locatorFlag(_ locator: Locator) -> some View {
        Button {
            model.seek(to: locator.step)
            if model.isPlaying { model.stopTransport(); model.startTransport() }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "flag.fill").font(.system(size: 6))
                Text(locator.name).font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 3)
            .frame(height: 13)
            .background(Theme.accent.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename Locator") { promptRenameLocator(locator) }
            Button("Delete Locator") { model.deleteLocator(locator.id) }
        }
    }

    private func insertMarker(height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Theme.accent.opacity(0.9))
                .frame(width: 1, height: height)
            Path { path in
                path.move(to: CGPoint(x: -4, y: 0))
                path.addLine(to: CGPoint(x: 4, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 6))
                path.closeSubpath()
            }
            .fill(Theme.accent)
            .frame(width: 8, height: 6)
        }
        .offset(x: CGFloat(model.insertStep) * zoom)
    }

    // MARK: - Lanes

    private func lanes(length: Int, width: CGFloat) -> some View {
        let total = totalHeight() + newTrackHeight
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(model.tracks) { track in
                    laneRow(track, width: width, length: length)
                        .id(track.id)
                    if isExpanded(track.id) {
                        AutomationLaneView(model: model, track: track.id,
                                           width: width, height: automationHeight, zoom: zoom)
                            .id("auto-\(track.id)")
                    }
                }
                addTrackZone(width: width)
            }
            .scrollTargetLayout()

            if let selection = model.timeSelection, !selection.isEmpty {
                TimeSelectionOverlay(selection: selection, zoom: zoom, height: total)
                    .allowsHitTesting(false)
            }

            insertMarker(height: total)
                .allowsHitTesting(false)
            PlayheadLine(model: model, zoom: zoom, length: length, height: total)
                .allowsHitTesting(false)

            if let ghost = model.ghost {
                Rectangle()
                    .fill((model.ghostBlocked ? Theme.record : Theme.accent).opacity(0.20))
                    .overlay(Rectangle().strokeBorder(
                        (model.ghostBlocked ? Theme.record : Theme.accent).opacity(0.9),
                        lineWidth: 1))
                    .frame(width: ghost.width, height: ghost.height)
                    .offset(x: ghost.minX, y: ghost.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: total, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in updateHover(phase) }
        .simultaneousGesture(backgroundGesture(length: length))
        .onAppear { model.arrangementContentHeight = total }
        .onChange(of: total) { _, newHeight in
            model.arrangementContentHeight = newHeight
            model.scrollLanes(to: model.laneScroll)
        }
        .onDrop(of: [UTType.fileURL, UTType.url],
                delegate: LaneDropDelegate(model: model, zoom: zoom,
                                           trackAt: { y in
                                               trackIndex(atY: y)?.track ?? automationTrack(atY: y)
                                           }))
    }

    private func laneRow(_ track: TrackInfo, width: CGFloat, length: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                drawLaneBackground(&context, size: size, track: track.id,
                                   length: length, selected: model.selection.track == track.id)
            }
            .frame(width: width, height: rowHeight)
            // Double-click belongs to the empty lane surface, not to the lane container. The
            // old gesture sat above the clip views and created a second clip when a clip was
            // double-clicked in place.
            .onTapGesture(count: 2) { model.createClipOnLane(track: track.id) }

            ForEach(model.timeline.filter { $0.track == track.id }) { clip in
                ArrangementClipView(model: model, clip: clip, zoom: zoom,
                                    rowHeight: rowHeight, length: length)
            }

            if !model.timeline.contains(where: { $0.track == track.id }) {
                Text("EMPTY LANE · DRAG TO DRAW")
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.28))
                    .padding(.leading, 9)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: rowHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.hoveredTrack = track.id }
            else if model.hoveredTrack == track.id { model.hoveredTrack = nil }
        }
        .background(FrameReporter(id: "lane.\(track.id)"))
    }

    /// One explicit strip, not a stack of fake lanes. A plain click only moves the insert marker;
    /// a real horizontal drag creates exactly one track and its clip.
    private func addTrackZone(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
            Rectangle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .foregroundStyle(Theme.dim.opacity(0.28))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            Text("DRAG HERE TO ADD A TRACK")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.dim.opacity(0.5))
                .padding(.leading, 16)
        }
        .frame(width: width, height: newTrackHeight)
        .contentShape(Rectangle())
        .background(FrameReporter(id: "arr.newTrack"))
    }

    private func drawLaneBackground(_ context: inout GraphicsContext, size: CGSize,
                                    track: Int, length: Int, selected: Bool) {
        let shade: Double = track % 2 == 0 ? 0.125 : 0.112
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(selected ? Color(white: shade + 0.02) : Color(white: shade)))
        context.fill(Path(CGRect(x: 0, y: rowHeight - 1, width: size.width, height: 1)),
                     with: .color(Color.white.opacity(0.055)))

        for beat in stride(from: 0, through: length, by: 4) {
            let x = CGFloat(beat) * zoom
            context.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)),
                         with: .color(Color.white.opacity(0.03)))
        }
        let barSteps = model.stepsPerBar
        let majorEvery = max(barSteps * 4, 1)
        for bar in stride(from: 0, through: length, by: barSteps) {
            let x = CGFloat(bar) * zoom
            let heavy = bar % majorEvery == 0
            context.fill(Path(CGRect(x: x, y: 0, width: heavy ? 1.2 : 0.7, height: size.height)),
                         with: .color(Color.white.opacity(heavy ? 0.18 : 0.07)))
        }
        if model.loopEnabled {
            let start = CGFloat(max(model.loopStart, 0)) * zoom
            let end = CGFloat(max(model.loopEnd, model.loopStart + model.stepsPerBar)) * zoom
            context.fill(Path(CGRect(x: start, y: 0, width: max(0, end - start), height: 2)),
                         with: .color(Theme.accent.opacity(0.35)))
        }
    }

    private func totalHeight() -> CGFloat {
        var height = CGFloat(model.tracks.count) * rowHeight
        if model.showAutomation,
           model.selection.track >= 0, model.selection.track < model.tracks.count {
            height += automationHeight
        }
        return height
    }

    private func trackIndex(atY y: CGFloat) -> (track: Int?, row: Int)? {
        var top: CGFloat = 0
        for track in model.tracks {
            if y >= top && y < top + rowHeight { return (track.id, track.id) }
            top += rowHeight
            if isExpanded(track.id) {
                if y >= top && y < top + automationHeight { return (nil, -1) }
                top += automationHeight
            }
        }
        return (nil, model.tracks.count)
    }

    // MARK: - Background editing

    private var backgroundMode: ArrangementBackgroundMode {
        get { model.interaction.backgroundMode }
        nonmutating set { model.interaction.backgroundMode = newValue }
    }

    private func backgroundGesture(length: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if case .none = backgroundMode, model.interaction.dragClipID == nil {
                    beginBackground(at: value.startLocation, length: length)
                }
                if abs(value.translation.width) > 2 || abs(value.translation.height) > 2 {
                    autoScroll(at: value.location)
                }
                if model.interaction.fadeClipID != nil {
                    NSCursor.resizeLeftRight.set()
                    updateFade(value)
                } else if model.interaction.resizeClipID != nil {
                    NSCursor.resizeLeftRight.set()
                    updateClipResize(value)
                } else if model.interaction.dragClipID != nil {
                    if model.interaction.dragClipBegan { NSCursor.closedHand.set() }
                    updateClipDrag(value)
                } else {
                    updateBackground(at: value.location)
                }
            }
            .onEnded { value in
                if model.interaction.fadeClipID != nil {
                    model.interaction.fadeClipID = nil
                    model.interaction.fadeBegan = false
                    model.endGestureEdit()
                    return
                }
                if model.interaction.resizeClipID != nil {
                    model.ghost = nil
                    model.interaction.resizeClipID = nil
                    model.interaction.resizeBegan = false
                    model.endGestureEdit()
                    return
                }
                if let id = model.interaction.dragClipID {
                    if model.interaction.dragClipBegan {
                        _ = model.moveTimelineClip(id,
                                                   to: model.interaction.dragClipTargetStart,
                                                   track: model.interaction.dragClipTargetTrack)
                    }
                    model.ghost = nil
                    model.ghostBlocked = false
                    model.interaction.dragClipID = nil
                    model.interaction.dragClipBegan = false
                    model.endGestureEdit()
                    return
                }
                switch backgroundMode {
                case .create(let track, let start):
                    let distance = abs(value.translation.width)
                    let end = max(start + model.stepsPerBar,
                                  model.snappedStep(Int(value.location.x / zoom)))
                    if distance > 3 {
                        model.pushUndo()
                        model.addTimelineClip(track: track, scene: -1, start: min(start, end),
                                              length: max(model.stepsPerBar, abs(end - start)))
                    }
                case .newTrack(let start):
                    let distance = max(abs(value.translation.width), abs(value.translation.height))
                    let end = max(start + model.stepsPerBar,
                                  model.snappedStep(Int(value.location.x / zoom)))
                    if distance > 3, let track = model.appendTrackForCanvas() {
                        model.addTimelineClip(track: track, scene: -1, start: min(start, end),
                                              length: max(model.stepsPerBar, abs(end - start)))
                    }
                case .time:
                    if let selection = model.timeSelection,
                       selection.length < max(model.snap.steps, 4) {
                        model.timeSelection = nil
                    }
                case .none:
                    break
                }
                model.ghost = nil
                model.ghostBlocked = false
                backgroundMode = .none
            }
    }

    private func updateBackground(at point: CGPoint) {
        switch backgroundMode {
        case .create(let track, let start):
            let end = max(start + model.stepsPerBar,
                          model.snappedStep(Int(point.x / zoom)))
            let y = trackTop(track) + 4
            let low = min(start, end)
            let span = max(model.stepsPerBar, abs(end - start))
            model.ghostBlocked = !model.isRangeFree(track: track, start: low, length: span)
            model.ghost = CGRect(x: CGFloat(low) * zoom,
                                 y: y,
                                 width: CGFloat(span) * zoom,
                                 height: rowHeight - 8)
        case .newTrack(let start):
            let end = max(start + model.stepsPerBar,
                          model.snappedStep(Int(point.x / zoom)))
            model.ghost = CGRect(x: CGFloat(min(start, end)) * zoom,
                                 y: totalHeight() + 4,
                                 width: CGFloat(abs(end - start)) * zoom,
                                 height: rowHeight - 8)
        case .time(let start):
            let other = model.snappedStep(Int(point.x / zoom))
            let lower = min(start, other)
            let upper = max(start, other)
            model.timeSelection = upper > lower ? TimeRange(start: lower, end: upper) : nil
        case .none:
            break
        }
    }

    private func beginBackground(at point: CGPoint, length: Int) {
        // The automation row is not empty canvas. Without this guard the parent lane gesture
        // interpreted a click there as the new-track strip and painted a clip ghost.
        if let autoTrack = automationTrack(atY: point.y) {
            model.selection = Selection(track: autoTrack, scene: model.selection.scene)
            model.focusArrangement()
            model.ghost = nil
            model.ghostBlocked = false
            backgroundMode = .none
            return
        }
        let step = model.snappedStep(Int(point.x / zoom))
        if let hit = clipHit(at: point) {
            let left = CGFloat(hit.start) * zoom
            let right = left + CGFloat(hit.length) * zoom
            let info = model.clips[hit.track][hit.scene]
            let localY = point.y - trackTop(hit.track)
            if info.samplePath != nil, localY < 14,
               (point.x <= left + 12 || point.x >= right - 12) {
                model.selectClip(hit.id)
                model.interaction.fadeClipID = hit.id
                model.interaction.fadeIsOut = point.x >= right - 12
                model.interaction.fadeOrigin = model.interaction.fadeIsOut
                    ? info.sampleFadeOut : info.sampleFadeIn
                model.interaction.fadeBegan = false
                return
            }
            // Edges are resize zones. Handling them here (rather than in a clip subview)
            // keeps the drag reliable inside the scroll view.
            if point.x <= left + 8 || point.x >= right - 8 {
                model.selectClip(hit.id)
                model.interaction.resizeClipID = hit.id
                model.interaction.resizeLeftEdge = point.x <= left + 8
                model.interaction.resizeOriginStart = hit.start
                model.interaction.resizeOriginLength = hit.length
                model.interaction.resizeBegan = false
                return
            }
            let additive = NSEvent.modifierFlags.contains(.shift)
            model.selectClip(hit.id, additive: additive)
            model.interaction.dragClipID = hit.id
            model.interaction.dragClipOriginStart = hit.start
            model.interaction.dragClipOriginTrack = hit.track
            model.interaction.dragClipTargetStart = hit.start
            model.interaction.dragClipTargetTrack = hit.track
            model.interaction.dragClipBegan = false
            return
        }
        if NSEvent.modifierFlags.contains(.shift) {
            model.focusArrangement()
            backgroundMode = .time(start: step)
            model.clearClipSelection()
            model.timeSelection = TimeRange(start: step, end: step)
            return
        }

        // Shift-clicking empty lane space must not draw a time selection by accident when the
        // user only wanted additive selection. A real drag arms time selection; a click just
        // selects the lane and leaves the marker there.


        guard let row = trackIndex(atY: point.y) else { return }
        if let track = row.track {
            // Clicking empty lane space only focuses, selects the lane and moves the marker.
            // No track or clip is materialized here; the drag distance is checked on mouse-up.
            model.prepareLaneClick(track: track)
            backgroundMode = .create(track: track, start: step)
            model.seek(to: step)
        } else {
            model.focusArrangement()
            model.clearClipSelection()
            backgroundMode = .newTrack(start: step)
            model.seek(to: step)
        }
    }

    private func clipHit(at point: CGPoint) -> TimelineClip? {
        guard let row = trackIndex(atY: point.y), let track = row.track else { return nil }
        let x = point.x
        return model.timeline
            .filter { $0.track == track }
            .reversed()
            .first { clip in
                let left = CGFloat(clip.start) * zoom
                let right = left + CGFloat(clip.length) * zoom
                return x >= left && x < right
            }
    }

    private func autoScroll(at point: CGPoint) {
        let viewportLeft = model.timelineScroll
        let viewportRight = viewportLeft + max(model.arrangementViewportWidth, 1)
        if point.x > viewportRight - 24 {
            model.scrollArrangement(toX: viewportLeft + 18)
        } else if point.x < viewportLeft + 24 {
            model.scrollArrangement(toX: viewportLeft - 18)
        }
        let viewportTop = model.laneScroll
        let viewportBottom = viewportTop + max(model.arrangementViewportHeight, 1)
        if point.y > viewportBottom - 20 {
            model.scrollLanes(to: viewportTop + 14)
        } else if point.y < viewportTop + 20 {
            model.scrollLanes(to: viewportTop - 14)
        }
    }

    private func trackForDrag(y: CGFloat, fallback: Int) -> Int {
        guard !model.tracks.isEmpty else { return 0 }
        if let track = trackIndex(atY: y)?.track { return track }
        if let track = automationTrack(atY: y) { return track }
        if y < 0 { return 0 }
        return model.tracks.count - 1
    }

    private func updateHover(_ phase: HoverPhase) {
        switch phase {
        case .active(let point):
            if let track = automationTrack(atY: point.y) {
                model.hoveredTrack = track
                model.hoveredClipID = nil
                NSCursor.crosshair.set()
                return
            }
            if point.y >= totalHeight() {
                model.hoveredClipID = nil
                NSCursor.resizeUpDown.set()
                return
            }
            guard let hit = clipHit(at: point) else {
                model.hoveredClipID = nil
                NSCursor.crosshair.set()
                return
            }
            model.hoveredTrack = hit.track
            model.hoveredClipID = hit.id
            let left = CGFloat(hit.start) * zoom
            let right = left + CGFloat(hit.length) * zoom
            let info = model.clips[hit.track][hit.scene]
            let localY = point.y - trackTop(hit.track)
            let edge = point.x <= left + 8 || point.x >= right - 8
            let fade = info.samplePath != nil && localY < 14
                && (point.x <= left + 12 || point.x >= right - 12)
            if edge || fade {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.openHand.set()
            }
        case .ended:
            model.hoveredClipID = nil
            NSCursor.arrow.set()
        }
    }

    private func automationTrack(atY y: CGFloat) -> Int? {
        var top: CGFloat = 0
        for track in model.tracks {
            top += rowHeight
            if isExpanded(track.id) {
                if y >= top && y < top + automationHeight { return track.id }
                top += automationHeight
            }
        }
        return nil
    }

    private func trackTop(_ track: Int) -> CGFloat {
        var top: CGFloat = 0
        for item in model.tracks {
            if item.id == track { return top }
            top += rowHeight
            if isExpanded(item.id) { top += automationHeight }
        }
        return top
    }

    private func updateFade(_ value: DragGesture.Value) {
        guard let id = model.interaction.fadeClipID else { return }
        if !model.interaction.fadeBegan {
            guard abs(value.translation.width) > 1 else { return }
            model.interaction.fadeBegan = true
            model.beginGestureEdit()
        }
        let steps = Double(value.translation.width / zoom)
        var seconds = steps * 60.0 / model.bpm / 4.0
        if model.interaction.fadeIsOut { seconds = -seconds }
        let target = model.interaction.fadeOrigin + seconds
        if model.interaction.fadeIsOut {
            model.setClipFade(id, fadeOut: target)
        } else {
            model.setClipFade(id, fadeIn: target)
        }
    }

    private func updateClipResize(_ value: DragGesture.Value) {
        guard let id = model.interaction.resizeClipID,
              model.timelineClip(id: id) != nil else { return }
        if !model.interaction.resizeBegan {
            guard abs(value.translation.width) > 1 else { return }
            model.interaction.resizeBegan = true
            model.beginGestureEdit()
        }
        let delta = Int((value.translation.width / zoom).rounded())
        if model.interaction.resizeLeftEdge {
            model.resizeTimelineClipLeft(id, to: model.interaction.resizeOriginStart + delta)
        } else {
            model.resizeTimelineClip(id,
                                     length: model.interaction.resizeOriginLength + delta)
        }
        if let updated = model.timelineClip(id: id) {
            model.ghost = CGRect(x: CGFloat(updated.start) * zoom,
                                 y: trackTop(updated.track) + 4,
                                 width: CGFloat(updated.length) * zoom,
                                 height: rowHeight - 8)
        }
    }

    private func updateClipDrag(_ value: DragGesture.Value) {
        guard let id = model.interaction.dragClipID,
              let clip = model.timelineClip(id: id) else { return }
        if !model.interaction.dragClipBegan {
            guard abs(value.translation.width) > 2 || abs(value.translation.height) > 2 else {
                return
            }
            model.interaction.dragClipBegan = true
            model.beginGestureEdit()
        }
        let steps = Int((value.translation.width / zoom).rounded())
        let start = model.snappedStep(model.interaction.dragClipOriginStart + steps)
        // Use the pointer's actual lane, not translation / rowHeight. Once an automation row is
        // open, row heights are no longer uniform and the old arithmetic targeted the wrong track.
        let track = trackForDrag(y: value.location.y,
                                 fallback: model.interaction.dragClipOriginTrack)
        model.interaction.dragClipTargetStart = start
        model.interaction.dragClipTargetTrack = track
        model.ghostBlocked = !model.isRangeFree(track: track, start: start,
                                                length: clip.length, excluding: clip.id)
        model.ghost = CGRect(x: CGFloat(start) * zoom,
                             y: trackTop(track) + 4,
                             width: CGFloat(clip.length) * zoom,
                             height: rowHeight - 8)
    }

    private var rulerMode: ArrangementRulerMode {
        get { model.interaction.rulerMode }
        nonmutating set { model.interaction.rulerMode = newValue }
    }

    private var rulerOriginStep: Int {
        get { model.interaction.rulerOriginStep }
        nonmutating set { model.interaction.rulerOriginStep = newValue }
    }

    private func rulerGesture() -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let step = model.snappedStep(Int(value.location.x / zoom))
                if case .none = rulerMode {
                    rulerOriginStep = step
                    let startX = CGFloat(model.loopStart) * zoom
                    let endX = CGFloat(model.loopEnd) * zoom
                    if value.startLocation.y < 38, abs(value.startLocation.x - startX) < 7 {
                        rulerMode = .loopStart
                    } else if value.startLocation.y < 38, abs(value.startLocation.x - endX) < 7 {
                        rulerMode = .loopEnd
                    } else if value.startLocation.y < 38,
                              value.startLocation.x > startX, value.startLocation.x < endX {
                        rulerMode = .loopMove(origin: model.loopStart)
                    } else {
                        rulerMode = .seek
                    }
                }
                switch rulerMode {
                case .seek:
                    model.seek(to: step)
                case .loopStart:
                    model.setLoopStart(step)
                case .loopEnd:
                    model.setLoopEnd(step)
                case .loopMove(let origin):
                    let delta = step - model.snappedStep(Int(value.startLocation.x / zoom))
                    model.setLoop(start: origin + delta, length: model.loopLength)
                case .none:
                    break
                }
            }
            .onEnded { _ in rulerMode = .none }
    }

    // MARK: - Follow

    private func followDriver(length: Int, viewport: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 0.4)) { _ in
            let bar = min(max(Int(model.shared.playhead.pointee) / model.stepsPerBar, 0),
                          max(length / model.stepsPerBar, 0))
            Color.clear
                .frame(width: 1, height: 1)
                .onChange(of: bar) { _, newBar in
                    guard model.followPlayhead else { return }
                    let x = CGFloat(newBar * model.stepsPerBar) * zoom
                    let target = max(0, x - viewport * 0.18)
                    withAnimation(.linear(duration: 0.22)) {
                        model.scrollArrangement(toX: target)
                    }
                }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Dialogs

    private func promptRename(_ track: TrackInfo) {
        let alert = NSAlert()
        alert.messageText = "Rename Track"
        alert.informativeText = "Track name"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = track.name
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            model.renameTrack(track.id, field.stringValue)
        }
    }

    private func promptRenameLocator(_ locator: Locator) {
        let alert = NSAlert()
        alert.messageText = "Rename Locator"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = locator.name
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            model.renameLocator(locator.id, name: field.stringValue)
        }
    }

    private func confirmDeleteTrack(_ track: TrackInfo) {
        guard model.tracks.count > 1 else {
            model.status = "the last track cannot be deleted"
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete \(track.name)?"
        alert.informativeText = "Its clips and instrument assignment will be removed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.removeTrack(at: track.id)
        }
    }
}


/// A slim, always-visible lane scrollbar. The canvas itself is offset manually so vertical
/// clip drags can never be stolen by a nested ScrollView.
private struct LaneScrollbar: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let content = max(model.arrangementContentHeight, height)
            let knob = max(28, height * height / max(content, 1))
            let track = max(height - knob, 1)
            let maxScroll = max(content - height, 1)
            let position = track * min(max(model.laneScroll / maxScroll, 0), 1)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 5, height: height)
                Capsule()
                    .fill(Theme.dim.opacity(0.65))
                    .frame(width: 5, height: knob)
                    .offset(y: position)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if model.interaction.scrollbarStart == nil {
                            model.interaction.scrollbarStart = model.laneScroll
                        }
                        let start = model.interaction.scrollbarStart ?? 0
                        model.scrollLanes(to: start + value.translation.height / track * maxScroll)
                    }
                    .onEnded { _ in model.interaction.scrollbarStart = nil }
            )
            .help("Scroll tracks")
        }
        .background(FrameReporter(id: "arr.scrollbar"))
    }
}

/// Persistent horizontal overview. Native auto-hiding scroll indicators made the arrangement
/// feel like it had no timeline navigation; this bar is always visible and draggable.
private struct HorizontalScrollbar: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let content = max(model.arrangementContentWidth, width)
            let knob = max(36, width * width / max(content, 1))
            let travel = max(width - knob, 1)
            let maxScroll = max(content - width, 1)
            let position = travel * min(max(model.timelineScroll / maxScroll, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.055))
                    .frame(width: width, height: 5)
                Capsule()
                    .fill(Theme.dim.opacity(0.62))
                    .frame(width: knob, height: 5)
                    .offset(x: position)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if model.interaction.timelineScrollbarStart == nil {
                            model.interaction.timelineScrollbarStart = model.timelineScroll
                        }
                        let start = model.interaction.timelineScrollbarStart ?? 0
                        model.scrollArrangement(toX: start + value.translation.width / travel * maxScroll)
                    }
                    .onEnded { _ in model.interaction.timelineScrollbarStart = nil }
            )
            .help("Drag to scroll the timeline")
        }
        .background(FrameReporter(id: "arr.timelineScrollbar"))
    }
}

// MARK: - Clip view

/// A real clip: its frame is the placement, not a painted rectangle over the whole canvas.
private struct ArrangementClipView: View {
    @ObservedObject var model: SessionModel
    let clip: TimelineClip
    let zoom: CGFloat
    let rowHeight: CGFloat
    let length: Int

    private var moveOrigin: (start: Int, track: Int)? {
        get { model.interaction.moveOrigin }
        nonmutating set { model.interaction.moveOrigin = newValue }
    }
    private var resizeOrigin: Int? {
        get { model.interaction.resizeOrigin }
        nonmutating set { model.interaction.resizeOrigin = newValue }
    }
    private var resizeStartOrigin: Int? {
        get { model.interaction.resizeStartOrigin }
        nonmutating set { model.interaction.resizeStartOrigin = newValue }
    }
    private var fadeInOrigin: Double? {
        get { model.interaction.fadeInOrigin }
        nonmutating set { model.interaction.fadeInOrigin = newValue }
    }
    private var fadeOutOrigin: Double? {
        get { model.interaction.fadeOutOrigin }
        nonmutating set { model.interaction.fadeOutOrigin = newValue }
    }

    private var info: ClipInfo { model.clips[clip.track][clip.scene] }
    private var trackColor: Color {
        model.tracks[min(max(clip.track, 0), model.tracks.count - 1)].color
    }
    private var selected: Bool { model.isClipSelected(clip.id) }
    private var width: CGFloat { max(CGFloat(clip.length) * zoom, 10) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                draw(&context, size: size)
            }
            .frame(width: width, height: rowHeight - 8)

            if selected {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white.opacity(0.92), lineWidth: 1)
                    .frame(width: width, height: rowHeight - 8)
            }


            if info.samplePath != nil {
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 5, height: 5)
                    .offset(x: 3, y: 3)
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 5, height: 5)
                    .offset(x: max(width - 8, 1), y: 3)
            }
        }
        .frame(width: width, height: rowHeight - 8)
        .offset(x: CGFloat(clip.start) * zoom, y: 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Split at Marker") { model.splitClip(clip.id, at: model.insertStep) }
            Button("Crossfade Next") {
                model.selectClip(clip.id)
                _ = model.crossfadeSelectedClip()
            }
            Button("Duplicate") {
                model.selectClip(clip.id)
                model.duplicateSelectedTimelineClip()
            }
            Button(model.isClipActive(clip.id) ? "Deactivate" : "Enable") {
                model.toggleClipActive(clip.id)
            }
            Divider()
            Button("Delete") { model.deleteTimelineClip(clip.id) }
        }
        .background(FrameReporter(id: "clip.\(clip.id)",
                                 offset: CGSize(width: CGFloat(clip.start) * zoom, height: 4)))
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let active = model.isClipActive(clip.id)
        let base = active ? trackColor : Color(white: 0.28)
        let path = Path(roundedRect: rect, cornerRadius: 3)
        context.fill(path, with: .color(base.opacity(selected ? 0.95 : 0.78)))
        context.stroke(path, with: .color(Color.black.opacity(0.45)), lineWidth: 1)

        // Header strip.
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 14)),
                     with: .color(Color.black.opacity(0.20)))
        let label = info.sampleName ?? "\(info.notes.count) note\(info.notes.count == 1 ? "" : "s")"
        context.draw(Text(label)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.black.opacity(0.72)),
                     at: CGPoint(x: 4, y: 7), anchor: .leading)

        if let peaks = model.waveform(track: clip.track, slot: clip.scene),
           let sampleSteps = model.sampleDurationSteps(track: clip.track, scene: clip.scene) {
            let sourceStep = Double(clip.offset) + info.sampleStart * sampleSteps
            drawWaveform(&context, peaks: peaks, durationSteps: sampleSteps,
                         sourceStep: sourceStep, visibleSteps: Double(clip.length),
                         in: rect.insetBy(dx: 2, dy: 14))
        } else {
            let notes = info.notes
            for note in notes {
                let x = CGFloat(note.start - clip.offset) * zoom
                guard x < size.width else { continue }
                let noteWidth = max(CGFloat(note.length) * zoom - 1, 1)
                let normalized = min(max(CGFloat(note.pitch - 36) / 48, 0), 1)
                let y = size.height - 6 - normalized * (size.height - 18)
                let bar = CGRect(x: max(x, 0), y: y, width: min(noteWidth, size.width - max(x, 0)),
                                 height: 3)
                context.fill(Path(bar), with: .color(.black.opacity(0.38)))
            }
        }

        if info.samplePath != nil {
            let secondsToSteps = 60.0 / model.bpm * 4
            let fadeIn = CGFloat(info.sampleFadeIn * secondsToSteps) * zoom
            let fadeOut = CGFloat(info.sampleFadeOut * secondsToSteps) * zoom
            if fadeIn > 1 {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: 0))
                line.addLine(to: CGPoint(x: min(fadeIn, size.width), y: 0))
                line.addLine(to: CGPoint(x: 0, y: size.height))
                line.closeSubpath()
                context.fill(line, with: .color(.black.opacity(0.30)))
            }
            if fadeOut > 1 {
                var line = Path()
                line.move(to: CGPoint(x: size.width, y: 0))
                line.addLine(to: CGPoint(x: max(0, size.width - fadeOut), y: 0))
                line.addLine(to: CGPoint(x: size.width, y: size.height))
                line.closeSubpath()
                context.fill(line, with: .color(.black.opacity(0.30)))
            }
        }

        if !active {
            var hatch = Path()
            for x in stride(from: CGFloat(0), through: size.width, by: 7) {
                hatch.move(to: CGPoint(x: x, y: 0))
                hatch.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(hatch, with: .color(.black.opacity(0.22)), lineWidth: 1)
            context.draw(Text("OFF")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.black.opacity(0.55)),
                         at: CGPoint(x: size.width - 12, y: 7), anchor: .trailing)
        }

        if selected || model.hoveredClipID == clip.id {
            // Edge grips advertise the 8 px resize zones instead of making them a secret.
            let grip = Color.white.opacity(0.62)
            context.fill(Path(CGRect(x: 1, y: 3, width: 2, height: size.height - 6)),
                         with: .color(grip))
            context.fill(Path(CGRect(x: size.width - 3, y: 3, width: 2,
                                     height: size.height - 6)),
                         with: .color(grip))
        }
    }

    /// Draws the part of the file that this placement actually plays. `sourceStep` includes the
    /// clip's split offset and its START knob; `visibleSteps` is the trimmed timeline length.
    private func drawWaveform(_ context: inout GraphicsContext, peaks: [Float],
                              durationSteps: Double, sourceStep: Double,
                              visibleSteps: Double, in rect: CGRect) {
        guard peaks.count > 1, rect.width > 4, rect.height > 8, durationSteps > 0 else { return }
        let columns = max(Int(rect.width / 2), 1)
        var path = Path()
        for column in 0..<columns {
            let step = sourceStep + (Double(column) + 0.5) / Double(columns) * visibleSteps
            guard step >= 0, step < durationSteps else { continue }
            let index = min(Int(step / durationSteps * Double(peaks.count)), peaks.count - 1)
            let amplitude = CGFloat(peaks[index]) * rect.height * 0.42
            let x = rect.minX + CGFloat(column) * 2 + 1
            path.move(to: CGPoint(x: x, y: rect.midY - amplitude))
            path.addLine(to: CGPoint(x: x, y: rect.midY + amplitude))
        }
        context.stroke(path, with: .color(.black.opacity(0.40)), lineWidth: 1)
    }
}

// MARK: - Automation lane

private struct AutomationLaneView: View {
    @ObservedObject var model: SessionModel
    let track: Int
    let width: CGFloat
    let height: CGFloat
    let zoom: CGFloat

    private var dragIndex: Int? {
        get { model.interaction.automationDragIndex }
        nonmutating set { model.interaction.automationDragIndex = newValue }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(Color(white: 0.095)))
                for bar in stride(from: 0, through: Int(size.width / zoom) + 1,
                                  by: max(model.stepsPerBar, 1)) {
                    let x = CGFloat(bar) * zoom
                    context.fill(Path(CGRect(x: x, y: 0, width: 0.7, height: size.height)),
                                 with: .color(Color.white.opacity(0.05)))
                }
                let points = model.automationPoints(track: track)
                guard !points.isEmpty else {
                    context.draw(Text("CLICK TO DRAW \(model.automationTarget.label) AUTOMATION")
                                    .font(.system(size: 7, design: .monospaced))
                                    .foregroundStyle(Theme.dim.opacity(0.45)),
                                 at: CGPoint(x: 8, y: size.height / 2), anchor: .leading)
                    return
                }
                var fill = Path()
                fill.move(to: CGPoint(x: 0, y: height))
                for point in points {
                    fill.addLine(to: CGPoint(x: CGFloat(point.step) * zoom,
                                             y: (1 - CGFloat(point.value)) * height))
                }
                fill.addLine(to: CGPoint(x: CGFloat(points.last!.step) * zoom, y: height))
                fill.closeSubpath()
                context.fill(fill, with: .color(Theme.accent.opacity(0.16)))
                var line = Path()
                line.move(to: CGPoint(x: 0, y: (1 - CGFloat(points.first!.value)) * height))
                for point in points {
                    line.addLine(to: CGPoint(x: CGFloat(point.step) * zoom,
                                             y: (1 - CGFloat(point.value)) * height))
                }
                line.addLine(to: CGPoint(x: width, y: (1 - CGFloat(points.last!.value)) * height))
                context.stroke(line, with: .color(Theme.accent.opacity(0.9)), lineWidth: 1.2)
                for point in points {
                    let dot = CGRect(x: CGFloat(point.step) * zoom - 2.5,
                                     y: (1 - CGFloat(point.value)) * height - 2.5,
                                     width: 5, height: 5)
                    context.fill(Path(ellipseIn: dot), with: .color(Theme.accent))
                }
            }
            .frame(width: width, height: height)

            Text(model.automationTarget.label)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.accent.opacity(0.8))
                .padding(.leading, 4)
                .padding(.top, 3)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let step = max(0, Int(value.location.x / zoom))
                    let level = 1 - min(max(value.location.y / height, 0), 1)
                    if dragIndex == nil {
                        model.beginGestureEdit()
                        model.addAutomationPoint(track: track, step: step, value: Double(level))
                        let points = model.automationPoints(track: track)
                        dragIndex = points.firstIndex { abs($0.step - step) <= 1 }
                    } else if let index = dragIndex {
                        model.moveAutomationPoint(track: track, index: index,
                                                  step: step, value: Double(level))
                    }
                }
                .onEnded { _ in
                    dragIndex = nil
                    model.endGestureEdit()
                }
        )
        .contextMenu {
            Button("Clear Automation") { model.clearAutomation(track: track) }
        }
        .help("Click to add \(model.automationTarget.label) automation · drag points · right-click to clear")
        .background(FrameReporter(id: "automation.\(track)"))
    }
}

// MARK: - Overlays

private struct TimeSelectionOverlay: View {
    let selection: TimeRange
    let zoom: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.accent.opacity(0.13))
                .frame(width: CGFloat(selection.length) * zoom, height: height)
            Rectangle()
                .fill(Theme.accent.opacity(0.7))
                .frame(width: 1, height: height)
            Rectangle()
                .fill(Theme.accent.opacity(0.7))
                .frame(width: 1, height: height)
                .offset(x: CGFloat(selection.length) * zoom)
        }
        .offset(x: CGFloat(selection.start) * zoom)
        .frame(width: CGFloat(selection.length) * zoom, height: height, alignment: .topLeading)
    }
}

/// The playhead is its own tiny layer, so the arrangement does not redraw every frame.
private struct PlayheadLine: View {
    @ObservedObject var model: SessionModel
    let zoom: CGFloat
    let length: Int
    let height: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Theme.playhead.opacity(0.9))
                    .frame(width: 1.5, height: height)
                Rectangle()
                    .fill(Theme.playhead)
                    .frame(width: 5, height: 5)
                    .offset(x: -1.75)
            }
            .offset(x: x)
        }
    }

    private var x: CGFloat {
        let step = Double(max(Int(model.shared.playhead.pointee), 0))
            + Double(model.shared.playheadFrac.pointee)
        return CGFloat(min(step, Double(max(length - 1, 1)))) * zoom
    }
}

// MARK: - Drop

private struct LaneDropDelegate: DropDelegate {
    let model: SessionModel
    let zoom: CGFloat
    let trackAt: (CGFloat) -> Int?

    func performDrop(info: DropInfo) -> Bool {
        guard !model.tracks.isEmpty else { return false }
        // Dropping onto the explicit new-track strip creates one lane. Dropping onto an existing
        // lane uses that lane; it never clamps to track 1 or fills invisible gaps.
        let track: Int
        if let existing = trackAt(info.location.y) {
            track = existing
        } else if let created = model.appendTrackForCanvas() {
            track = created
        } else {
            return false
        }
        let step = model.snappedStep(Int(info.location.x / max(zoom, 1)))
        return model.acceptAudioDrop(info.itemProviders(for: [UTType.fileURL, UTType.url]),
                                     track: track, startStep: step)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL, UTType.url])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }
}
