import Cocoa
import QuickLookUI
import Quartz

class PreviewController: NSViewController, QLPreviewingController {
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var fileWatcher: FileWatcher?
    private var fileURL: URL?

    override func loadView() {
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1060, height: 900))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false

        scrollView.documentView = textView
        self.view = scrollView
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        fileURL = url

        do {
            try renderFile(url)
        } catch {
            handler(error)
            return
        }

        handler(nil)

        // Watch for file changes
        fileWatcher = FileWatcher(url: url) { [weak self] in
            self?.reloadContent()
        }
        fileWatcher?.start()
    }

    private var isDarkMode: Bool {
        if #available(macOS 10.14, *) {
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return false
    }

    private func renderFile(_ url: URL) throws {
        let markdown = try String(contentsOf: url, encoding: .utf8)
        let title = url.deletingPathExtension().lastPathComponent
        let html = MarkdownRenderer.renderForNativeText(markdown: markdown, title: title, darkMode: isDarkMode)
        guard let data = html.data(using: .utf8),
              let attrStr = NSAttributedString(html: data, documentAttributes: nil) else { return }
        textView.textStorage?.setAttributedString(attrStr)
    }

    private func reloadContent() {
        guard let url = fileURL else { return }
        try? renderFile(url)
    }
}
