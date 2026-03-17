import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Registration is handled by scripts/install.sh (unsandboxed).
        // This sandboxed app cannot run lsregister or qlmanage.
    }
}
