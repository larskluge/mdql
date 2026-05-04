import Cocoa
import WebKit

/// Hosts the markdown viewer window. Owns a `MarkdownWebController` and
/// wires its file-read and url-open closures to direct (unsandboxed) calls —
/// no XPC needed.
final class DocumentWindowController: NSWindowController {

    private let controller = MarkdownWebController()
    private var loadedURL: URL?

    convenience init() {
        let initialFrame = NSRect(origin: .zero, size: MarkdownRenderer.previewSize)
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MarkdownDocumentWindow")
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
