import Cocoa
import WebKit

/// Hosts the markdown viewer window. Owns a `MarkdownWebController` and
/// wires its file-read and url-open closures to direct (unsandboxed) calls —
/// no XPC needed.
final class DocumentWindowController: NSWindowController {

    private static let frameAutosaveName = "MarkdownDocumentWindow"

    private let controller = MarkdownWebController()
    private var loadedURL: URL?

    convenience init() {
        let initialFrame = NSRect(origin: .zero, size: Self.defaultContentSize())
        let window = MarkdownWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.setFrame(Self.defaultWindowFrame(for: window), display: false)
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        self.init(window: window)

        controller.webView.autoresizingMask = [.width, .height]
        window.contentView = controller.webView

        controller.openURL = { url in
            NSWorkspace.shared.open(url)
        }
        controller.readFile = { url, completion in
            let content = try? String(contentsOf: url, encoding: .utf8)
            completion(content)
        }
    }

    private static func defaultContentSize() -> NSSize {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return MarkdownRenderer.previewSize
        }

        let width = min(max(visibleFrame.width * 0.74, 860), 1280)
        let height = min(max(visibleFrame.height * 0.86, 700), 1180)
        return NSSize(width: width, height: height)
    }

    private static func defaultWindowFrame(for window: NSWindow) -> NSRect {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return window.frame
        }

        var frame = window.frame
        frame.origin.x = visibleFrame.midX - frame.width / 2
        frame.origin.y = visibleFrame.midY - frame.height / 2
        return frame
    }

    /// Loads a markdown file into the window's web view.
    func load(fileAt url: URL) throws {
        try controller.loadMarkdownFile(at: url)
        loadedURL = url
        synchronizeWindowTitleWithDocumentName()
    }

    override func synchronizeWindowTitleWithDocumentName() {
        if let loadedURL, let window {
            window.title = loadedURL.lastPathComponent
            window.representedURL = nil
            window.representedFilename = ""
        } else {
            super.synchronizeWindowTitleWithDocumentName()
            window?.representedURL = nil
            window?.representedFilename = ""
        }
    }
}

private final class MarkdownWindow: NSWindow {

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "w":
            performClose(nil)
            return true
        case "q":
            NSApp.terminate(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
