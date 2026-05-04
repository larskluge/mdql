import Cocoa

/// `NSDocument` subclass for read-only markdown viewing.
///
/// We don't keep an in-memory model — `MarkdownWebController` reads and renders
/// directly from disk, and the file watcher pulls in subsequent changes. The
/// document override exists only to retain the source URL (the default
/// `read(from:Data)` path discards it) and to declare the document is never
/// edited.
final class MarkdownDocument: NSDocument {

    override class var autosavesInPlace: Bool { false }

    override var isDocumentEdited: Bool { false }

    override func makeWindowControllers() {
        let wc = DocumentWindowController()
        addWindowController(wc)
        if let url = fileURL {
            try? wc.load(fileAt: url)
        }
    }

    /// Override `read(from url:ofType:)` rather than `read(from data:)` so we
    /// keep the URL — `MarkdownWebController` needs it to resolve relative
    /// `.md` links and to start the file watcher.
    override func read(from url: URL, ofType typeName: String) throws {
        // No work to do here — the window controller's MarkdownWebController
        // reads and renders the file once the window is created.
        // We rely on `fileURL` being set by NSDocument before this is called.
    }
}
