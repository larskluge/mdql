import Cocoa
import WebKit

/// Owns a WKWebView and the JS↔Swift bridge, FileWatcher, and back-stack
/// navigation used to render markdown. Hosted by both the QuickLook
/// extension (`PreviewController`) and the document-based app
/// (`DocumentWindowController`); each injects its own `openURL` /
/// `readFile` closures because the extension reaches the filesystem
/// through XPC while the app reads directly.
final class MarkdownWebController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    let webView: WKWebView
    private var fileWatcher: FileWatcher?
    private(set) var fileURL: URL?
    private var fileHistory: [URL] = []

    /// Opens a URL externally (browser, Finder, etc.). Default is a no-op.
    var openURL: (URL) -> Void = { _ in }

    /// Reads file contents on the main thread and calls back with the string,
    /// or nil on failure. Default is a no-op (no callback).
    var readFile: (URL, @escaping (String?) -> Void) -> Void = { _, _ in }

    override init() {
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: NSRect(origin: .zero, size: MarkdownRenderer.previewSize), configuration: config)
        super.init()
        config.userContentController.add(self, name: "mdql")
        webView.navigationDelegate = self
    }

    deinit {
        fileWatcher?.stop()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mdql")
    }

    // MARK: - Public API

    /// Loads and renders a markdown file. Used for the initial file (the one
    /// the host has direct read access to). Sibling files reached via
    /// `openMarkdown` go through the injected `readFile` closure.
    @discardableResult
    func loadMarkdownFile(at url: URL) throws -> Bool {
        let html = try MarkdownRenderer.render(fileAt: url)
        fileWatcher?.stop()
        fileURL = url
        fileHistory.removeAll()
        webView.loadHTMLString(html, baseURL: nil)
        startWatching(url)
        return true
    }

    /// Handles an openURL action. Exposed for testing.
    func handleOpenURL(_ urlString: String, background: Bool) {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return }
        openURL(url)
    }

    /// Handles an openMarkdown action. Exposed for testing.
    func handleOpenMarkdown(_ urlString: String) {
        let decoded = urlString.removingPercentEncoding ?? urlString
        guard let currentURL = self.fileURL,
              !decoded.isEmpty else { return }

        let resolved = URL(fileURLWithPath: decoded, relativeTo: currentURL.deletingLastPathComponent()).standardized
        let ext = resolved.pathExtension.lowercased()
        guard ext == "md" || ext == "markdown" else { return }

        readFile(resolved) { [weak self] markdown in
            guard let self = self, let markdown = markdown else { return }
            self.fileHistory.append(currentURL)
            self.showMarkdown(markdown, url: resolved)
        }
    }

    // MARK: - Internal navigation

    private func goBack() {
        guard let previousURL = fileHistory.popLast() else { return }
        readFile(previousURL) { [weak self] markdown in
            guard let markdown = markdown else { return }
            self?.showMarkdown(markdown, url: previousURL)
        }
    }

    private func showMarkdown(_ markdown: String, url: URL) {
        fileWatcher?.stop()
        fileURL = url
        let title = url.deletingPathExtension().lastPathComponent
        let html = MarkdownRenderer.render(markdown: markdown, title: title, showBackButton: !fileHistory.isEmpty)
        webView.loadHTMLString(html, baseURL: nil)
        startWatching(url)
    }

    private func startWatching(_ url: URL) {
        fileWatcher = FileWatcher(url: url) { [weak self] in
            self?.reloadContent()
        }
        fileWatcher?.start()
    }

    private func reloadContent() {
        guard let url = fileURL else { return }
        readFile(url) { [weak self] markdown in
            guard let self = self, let markdown = markdown else { return }
            let bodyHTML = MarkdownRenderer.renderBody(markdown: markdown)
            let base64 = Data(bodyHTML.utf8).base64EncodedString()
            self.webView.evaluateJavaScript(
                "document.querySelector('.markdown-body').innerHTML = new TextDecoder().decode(Uint8Array.from(atob('\(base64)'), c => c.charCodeAt(0)))"
            )
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "openURL":
            if let urlString = body["url"] as? String {
                let background = body["background"] as? Bool ?? false
                handleOpenURL(urlString, background: background)
            }
        case "openMarkdown":
            if let urlString = body["url"] as? String {
                handleOpenMarkdown(urlString)
            }
        case "goBack":
            goBack()
        default:
            break
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Cancel all link-activated navigations — JS message handlers handle everything.
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url,
               let scheme = url.scheme,
               ["http", "https"].contains(scheme) {
                handleOpenURL(url.absoluteString, background: false)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
