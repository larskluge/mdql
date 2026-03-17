import Cocoa
import WebKit

class PreviewWindowController: NSWindowController {
    private var webView: WKWebView!
    private var fileWatcher: FileWatcher?
    private(set) var currentURL: URL?
    var isWatching: Bool { fileWatcher?.isWatching ?? false }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.setFrameAutosaveName("PreviewWindow")
        window.title = "mdql"
        window.center()

        self.init(window: window)

        webView = WKWebView(frame: window.contentView!.bounds)
        webView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(webView)
    }

    func loadFile(_ url: URL) {
        currentURL = url
        window?.title = url.lastPathComponent

        // Full initial render with CSS
        guard let html = try? MarkdownRenderer.render(fileAt: url) else { return }
        webView.loadHTMLString(html, baseURL: nil)

        // Start watching for changes
        fileWatcher?.stop()
        fileWatcher = FileWatcher(url: url) { [weak self] in
            self?.reloadContent()
        }
        fileWatcher?.start()
    }

    private func reloadContent() {
        guard let url = currentURL,
              let markdown = try? String(contentsOf: url, encoding: .utf8) else { return }

        let bodyHTML = MarkdownRenderer.renderBody(markdown: markdown)
        let base64 = Data(bodyHTML.utf8).base64EncodedString()
        webView.evaluateJavaScript(
            "document.querySelector('.markdown-body').innerHTML = new TextDecoder().decode(Uint8Array.from(atob('\(base64)'), c => c.charCodeAt(0)))"
        )
    }
}
