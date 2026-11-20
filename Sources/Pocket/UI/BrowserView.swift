import SwiftUI
import UniformTypeIdentifiers

/// Sample browser: file system folders on the left of the window.
/// A folder click navigates. An audio-file click only selects it; placement happens on drag.
struct BrowserView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(model.filteredBrowserItems) { item in
                        row(item)
                    }
                    if model.filteredBrowserItems.isEmpty {
                        Text(model.browserSearch.isEmpty ? "no audio files here" : "no matches")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.dim.opacity(0.7))
                            .padding(.top, 14)
                    }
                }
            }
            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 196)
        .background(Theme.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.stroke).frame(width: 1) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("BROWSER")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            Text((model.browserPath as NSString).lastPathComponent)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.head)
            Text("click to audition · drag to place")
                .font(.system(size: 8))
                .foregroundStyle(Theme.dim.opacity(0.7))
            TextField("search", text: Binding(
                get: { model.browserSearch },
                set: { model.browserSearch = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 9, design: .monospaced))
                .frame(height: 20)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func row(_ item: BrowserItem) -> some View {
        if item.isFolder {
            Button(action: { model.openBrowserItem(item) }) { label(item) }
                .buttonStyle(.plain)
                .help("Open folder")
        } else {
            // Not a Button: the button gesture claims the press and the drag never starts.
            label(item)
                .contentShape(Rectangle())
                .onTapGesture { model.selectBrowserItem(item) }
                .onDrag {
                    model.stopBrowserPreview()
                    return FileDrag.makeProvider(url: URL(fileURLWithPath: item.id), name: item.name)
                }
                .help("Click to audition; drag onto a lane to place a one-shot clip")
        }
    }

    private func label(_ item: BrowserItem) -> some View {
        HStack(spacing: 5) {
            Image(systemName: item.isFolder ? "folder" : "waveform")
                .font(.system(size: 9))
                .frame(width: 11)
            Text(item.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(item.isFolder || model.browserSelection == item.id
                         ? Theme.text : Theme.dim)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .contentShape(Rectangle())
        .background(model.browserSelection == item.id
                    ? Theme.accent.opacity(0.16) : Color.clear)
        .background(FrameReporter(id: "browser.\(item.name)"))
    }

    private var footer: some View {
        HStack(spacing: 4) {
            FlatButton(title: "UP", width: 30) { model.browserUp() }
            FlatButton(title: "…", width: 24) { model.chooseBrowserFolder() }
            Spacer(minLength: 0)
        }
        .padding(5)
    }
}

/// Builds the drag provider used by the browser. Kept separate so the UI test can assert the
/// exact registration the drop targets rely on.
enum FileDrag {
    static func makeProvider(url: URL, name: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerItem(forTypeIdentifier: UTType.fileURL.identifier) { completion, _, _ in
            completion?(url.dataRepresentation as NSData, nil)
        }
        provider.registerItem(forTypeIdentifier: UTType.url.identifier) { completion, _, _ in
            completion?(url.absoluteString as NSString, nil)
        }
        return provider
    }
}
