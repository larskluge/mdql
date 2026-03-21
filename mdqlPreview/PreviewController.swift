import Cocoa
import QuickLookUI
import Quartz
import WebKit

class PreviewController: NSViewController, QLPreviewingController, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private var fileWatcher: FileWatcher?
    private var fileURL: URL?
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

        // Set up XPC connection to unsandboxed URL opener
        let connection = NSXPCConnection(serviceName: "com.mdql.app.open-url")
        connection.remoteObjectInterface = NSXPCInterface(with: OpenURLProtocol.self)
        connection.resume()
        self.xpcConnection = connection

        self.openURL = { [weak self] url in
            guard let proxy = self?.xpcConnection?.remoteObjectProxyWithErrorHandler({ error in
                NSLog("mdql XPC error: \(error)")
            }) as? OpenURLProtocol else { return }
            proxy.open(url) { _ in }
        }
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        fileURL = url

        do {
            let html = try MarkdownRenderer.render(fileAt: url)
            webView.loadHTMLString(html, baseURL: nil)
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

    // MARK: - URL handling

    /// Handles an openURL action. Exposed for testing.
    func handleOpenURL(_ urlString: String, background: Bool) {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return }
        openURL(url)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        if action == "openURL", let urlString = body["url"] as? String {
            let background = body["background"] as? Bool ?? false
            handleOpenURL(urlString, background: background)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           let scheme = url.scheme,
           ["http", "https"].contains(scheme) {
            handleOpenURL(url.absoluteString, background: false)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func reloadContent() {
        guard let url = fileURL,
              let markdown = try? String(contentsOf: url, encoding: .utf8) else { return }

        let bodyHTML = MarkdownRenderer.renderBody(markdown: markdown)
        let base64 = Data(bodyHTML.utf8).base64EncodedString()
        webView.evaluateJavaScript(
            "document.querySelector('.markdown-body').innerHTML = new TextDecoder().decode(Uint8Array.from(atob('\(base64)'), c => c.charCodeAt(0)))"
        )
    }
}
