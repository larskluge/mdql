import Cocoa

@main
enum Main {
    private static let appDelegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = appDelegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Registration is handled by scripts/install.sh (the install path is
        // unsandboxed regardless of host-app sandboxing). Nothing to do here.
    }

    /// True from the moment the launch-time open panel appears until the
    /// documents it selects have opened. AppKit runs the "last window closed"
    /// check when that panel is dismissed — before the chosen document's window
    /// exists — so without this guard the app would quit mid-open.
    private var isOpeningDocument = false

    /// A viewer with no window has nothing left to show, so closing the last
    /// one (⌘W) quits the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !isOpeningDocument
    }

    /// When the app is launched without any documents, present an open panel.
    /// Matches Preview / TextEdit behavior on macOS.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return true
    }

    /// Drives the open panel directly (rather than `openDocument(_:)`) so the
    /// outcome is known: a cancelled panel leaves no window to close, so the
    /// app quits itself instead of lingering with nothing on screen.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        let controller = NSDocumentController.shared
        isOpeningDocument = true
        controller.beginOpenPanel { [weak self] urls in
            guard let urls, !urls.isEmpty else {
                NSApp.terminate(nil)
                return
            }
            self?.openDocuments(at: urls, using: controller)
        }
        return true
    }

    private func openDocuments(at urls: [URL], using controller: NSDocumentController) {
        let group = DispatchGroup()
        var failures: [Error] = []

        for url in urls {
            group.enter()
            controller.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { failures.append(error) }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.isOpeningDocument = false
            for failure in failures {
                NSApp.presentError(failure)
            }
            if !NSApp.windows.contains(where: { $0.isVisible }) {
                // Every document failed to open — nothing left to show.
                NSApp.terminate(nil)
            }
        }
    }
}
