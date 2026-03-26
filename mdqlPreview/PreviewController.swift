import Cocoa
import QuickLookUI
import Quartz
import WebKit

class PreviewController: NSViewController, QLPreviewingController, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private var fileWatcher: FileWatcher?
    private(set) var fileURL: URL?
    private var fileHistory: [URL] = []
    private var xpcConnection: NSXPCConnection?

    /// Injectable URL opener. Default uses the XPC service to open in the default browser.
    var openURL: (URL) -> Void = { _ in }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "mdql")

        webView = WKWebView(frame: NSRect(origin: .zero, size: MarkdownRenderer.previewSize), configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        self.view = webView
        preferredContentSize = MarkdownRenderer.previewSize

        // Set up XPC connection to unsandboxed service (URL opening + file reading)
        let connection = NSXPCConnection(serviceName: "com.mdql.app.open-url")
        connection.remoteObjectInterface = NSXPCInterface(with: OpenURLProtocol.self)
        connection.resume()
        self.xpcConnection = connection

        self.openURL = { [weak self] url in
            guard let proxy = self?.xpcProxy else { return }
            proxy.open(url) { _ in }
        }
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            try loadMarkdownFile(at: url)
            handler(nil)
        } catch {
            handler(error)
        }
    }

    // MARK: - URL handling

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

        readFileViaXPC(at: resolved) { [weak self] markdown in
            guard let self = self else { return }
            self.fileHistory.append(currentURL)
            self.showMarkdown(markdown, url: resolved)
        }
    }

    // MARK: - Navigation

    /// Loads and renders a markdown file directly (used for the initial file the sandbox grants access to).
    @discardableResult
    func loadMarkdownFile(at url: URL) throws -> Bool {
        let html = try MarkdownRenderer.render(fileAt: url)
        fileWatcher?.stop()
        fileURL = url
        webView.loadHTMLString(html, baseURL: nil)
        startWatching(url)
        return true
    }

    private func goBack() {
        guard let previousURL = fileHistory.popLast() else { return }
        readFileViaXPC(at: previousURL) { [weak self] markdown in
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

    // MARK: - XPC helpers

    private var xpcProxy: OpenURLProtocol? {
        xpcConnection?.remoteObjectProxyWithErrorHandler({ _ in }) as? OpenURLProtocol
    }

    private func readFileViaXPC(at url: URL, completion: @escaping (String) -> Void) {
        guard let proxy = xpcProxy else { return }
        proxy.readFile(at: url.path) { content, _ in
            guard let content = content else { return }
            DispatchQueue.main.async { completion(content) }
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

    // MARK: - Live reload

    private func reloadContent() {
        guard let url = fileURL else { return }
        readFileViaXPC(at: url) { [weak self] markdown in
            let bodyHTML = MarkdownRenderer.renderBody(markdown: markdown)
            let base64 = Data(bodyHTML.utf8).base64EncodedString()
            self?.webView.evaluateJavaScript(
                "document.querySelector('.markdown-body').innerHTML = new TextDecoder().decode(Uint8Array.from(atob('\(base64)'), c => c.charCodeAt(0)))"
            )
        }
    }
}
