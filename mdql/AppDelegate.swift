import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Registration is handled by scripts/install.sh (the install path is
        // unsandboxed regardless of host-app sandboxing). Nothing to do here.
    }

    /// When the app is launched without any documents, present an open panel.
    /// Matches Preview / TextEdit behavior on macOS.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }
}
