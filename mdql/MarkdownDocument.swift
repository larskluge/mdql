import Cocoa

/// `NSDocument` subclass for read-only markdown viewing.
///
/// The document reads the file once, so a file that cannot be read fails the
/// open with the real error, which `NSDocumentController` presents, instead of
/// opening a blank window. One that is not UTF-8 opens anyway, decoded as
/// `MarkdownText` decodes it, with a notice that says so.
/// `MarkdownWebController` renders what it read and its file watcher pulls in
/// later changes from disk. The document is never edited.
final class MarkdownDocument: NSDocument {

    override class var autosavesInPlace: Bool { false }

    override var isDocumentEdited: Bool { false }

    /// The file's contents as `read(from:ofType:)` found them.
    private var text: MarkdownText?

    override func makeWindowControllers() {
        let wc = DocumentWindowController()
        addWindowController(wc)
        if let url = fileURL, let text {
            wc.load(text.string, encoding: text.encoding, readFrom: url)
        }
    }

    /// Override `read(from url:ofType:)` rather than `read(from data:)` so we
    /// keep the URL — `MarkdownWebController` needs it to resolve relative
    /// `.md` links and to start the file watcher.
    override func read(from url: URL, ofType typeName: String) throws {
        text = try MarkdownText(contentsOf: url)
    }
}
