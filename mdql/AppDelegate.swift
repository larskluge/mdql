import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundlePath = Bundle.main.bundlePath
        let isInApplications = bundlePath.hasPrefix("/Applications/") ||
            bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")

        if !isInApplications {
            NSLog("[mdql] WARNING: Running from %@. Install to ~/Applications or /Applications for Finder QuickLook to work. Running from other locations causes duplicate extension registrations and broken previews.", bundlePath)
        }
    }
}
