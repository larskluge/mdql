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

    /// Toggles the `index`-th task-list checkbox in the currently loaded file.
    /// Calls back with `true` on success, `false` on failure. The host app
    /// writes the file directly; the QuickLook extension goes through XPC.
    var toggleCheckbox: (Int, Bool, @escaping (Bool) -> Void) -> Void = { _, _, completion in completion(false) }

    /// When true, rendered HTML enables clickable checkboxes. Both hosts set
    /// this; it says nothing about which one is rendering.
    var interactive: Bool = false

    /// When true, the page leaves headroom under the host app's transparent
    /// titlebar and fades content into it. QuickLook draws no chrome of its
    /// own, so it stays false there.
    var appChrome: Bool = false

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
        let markdown = try String(contentsOf: url, encoding: .utf8)
        let title = url.deletingPathExtension().lastPathComponent
        let html = MarkdownRenderer.render(markdown: markdown, title: title, interactive: interactive, appChrome: appChrome)
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

    /// Handles a toggleCheckbox action posted from JS. Exposed for testing.
    /// On failure, reverts the checkbox in the rendered page and shows a toast.
    func handleToggleCheckbox(index: Int, checked: Bool) {
        toggleCheckbox(index, checked) { [weak self] success in
            guard !success, let self = self else { return }
            DispatchQueue.main.async {
                self.webView.evaluateJavaScript(
                    "window.__mdqlRevertCheckbox && window.__mdqlRevertCheckbox(\(index)); window.__mdqlShowToast && window.__mdqlShowToast('Couldn\\'t save change');"
                )
            }
        }
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
        let html = MarkdownRenderer.render(markdown: markdown, title: title, showBackButton: !fileHistory.isEmpty, interactive: interactive, appChrome: appChrome)
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
            let bodyHTML = MarkdownRenderer.renderBody(markdown: markdown, interactive: self.interactive)
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
        case "toggleCheckbox":
            if let index = body["index"] as? Int {
                let checked = body["checked"] as? Bool ?? false
                handleToggleCheckbox(index: index, checked: checked)
            }
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
