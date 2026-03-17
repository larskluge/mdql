import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureQuickLookRegistration()
    }

    private func ensureQuickLookRegistration() {
        let bundlePath = Bundle.main.bundlePath
        let homeDir = NSHomeDirectory()
        let canonicalPath = homeDir + "/Applications/mdql.app"
        let isInApplications = bundlePath.hasPrefix("/Applications/") ||
            bundlePath.hasPrefix(homeDir + "/Applications/")

        if !isInApplications {
            NSLog("[mdql] Running from %@, not ~/Applications. Fixing QuickLook registration...", bundlePath)
        }

        // Check for duplicate registrations and clean them up
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        task.arguments = ["-m", "-v", "-A", "-i", "com.mdql.app.preview"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let registrations = output.components(separatedBy: "\n").filter { $0.contains("com.mdql.app.preview") }

        let hasDuplicates = registrations.count > 1
        let registeredFromDerivedData = registrations.contains { $0.contains("DerivedData") }
        let registeredFromApplications = registrations.contains { $0.contains("/Applications/mdql.app") }

        if hasDuplicates || (registeredFromDerivedData && !registeredFromApplications) {
            NSLog("[mdql] Cleaning up QuickLook registrations (found %d, DerivedData=%d, Applications=%d)",
                  registrations.count, registeredFromDerivedData ? 1 : 0, registeredFromApplications ? 1 : 0)

            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

            // Unregister any DerivedData paths
            for reg in registrations where reg.contains("DerivedData") {
                if let path = extractAppPath(from: reg) {
                    run(lsregister, "-u", path)
                }
            }

            // Ensure ~/Applications copy is registered
            if FileManager.default.fileExists(atPath: canonicalPath) {
                run(lsregister, "-f", "-R", canonicalPath)
                run("/usr/bin/qlmanage", "-r")
                NSLog("[mdql] QuickLook extension registered from %@", canonicalPath)
            }
        }
    }

    private func extractAppPath(from pluginkitLine: String) -> String? {
        // pluginkit output format: "+    id(ver)\tUUID\tdate\t/path/to/ext.appex"
        let components = pluginkitLine.components(separatedBy: "\t")
        guard let appexPath = components.last else { return nil }
        // Convert .../mdql.app/Contents/PlugIns/mdqlPreview.appex -> .../mdql.app
        if let range = appexPath.range(of: "/Contents/PlugIns/") {
            return String(appexPath[..<range.lowerBound])
        }
        return appexPath.trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    private func run(_ path: String, _ args: String...) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }
}
