import AppKit

/// Owns the floating windows that show Audio Unit editors, keyed by track/slot so reopening the
/// same editor brings back the existing window instead of piling up duplicates.
///
/// One instance per window: AUv2 effects use their Cocoa view factory, instruments and AUv3
/// plugins hand back a view controller for the AUAudioUnit instance the renderer is using.
final class AUWindowManager {
    static let shared = AUWindowManager()

    private var controllers: [String: NSWindowController] = [:]

    private init() {}

    func show(key: String, title: String,
              request: (@escaping (NSViewController?) -> Void) -> Void,
              onFailure: @escaping () -> Void) {
        if let existing = controllers[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        request { controller in
            DispatchQueue.main.async {
                guard let controller else {
                    onFailure()
                    return
                }
                var size = controller.preferredContentSize
                if size.width < 200 || size.height < 120 {
                    size = NSSize(width: 760, height: 520)
                }
                controller.view.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentViewController: controller)
                window.title = title
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                window.isReleasedWhenClosed = false
                window.setContentSize(size)
                window.minSize = NSSize(width: 320, height: 200)
                window.center()
                let windowController = NSWindowController(window: window)
                self.controllers[key] = windowController
                windowController.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func close(key: String) {
        controllers[key]?.close()
        controllers[key] = nil
    }

    func closeAll() {
        for (_, controller) in controllers { controller.close() }
        controllers.removeAll()
    }
}
