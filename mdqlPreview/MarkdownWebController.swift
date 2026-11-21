import Cocoa
import WebKit

/// Owns a WKWebView and the JS↔Swift bridge, FileWatcher, and back-stack
/// navigation used to render markdown. Hosted by both the QuickLook
/// extension (`PreviewController`) and the document-based app
/// (`DocumentWindowController`); each injects its own `openURL` /
/// `readFile` closures because the extension reaches the filesystem
/// through XPC while the app reads directly.
final class MarkdownWebController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    /// Where every page this controller renders lives: `loadHTMLString` with
    /// no base URL. Nothing else may load, and nothing else reaches the bridge.
    private static let pageURL = URL(string: "about:blank")!

    let webView: WKWebView
    private var fileWatcher: FileWatcher?
    private(set) var fileURL: URL? {
        didSet {
            guard fileURL != oldValue else { return }
            fileURLDidChange(fileURL)
        }
    }
    private var fileHistory: [URL] = []

    /// The file the host opened, which `fileURL` leaves as links are
    /// followed. Its folder bounds every file a link may open (`AccessPolicy`).
    private(set) var documentURL: URL?

    /// Opens a URL externally (browser, Finder, etc.). Default is a no-op.
    var openURL: (URL) -> Void = { _ in }

    /// Reads file contents on the main thread and calls back with the string,
    /// or nil on failure. Default is a no-op (no callback).
    var readFile: (URL, @escaping (String?) -> Void) -> Void = { _, _ in }

    /// Toggles the `index`-th task-list checkbox in the currently loaded file.
    /// Calls back with `true` on success, `false` on failure. The host app
    /// writes the file directly; the QuickLook extension goes through XPC.
    var toggleCheckbox: (Int, Bool, @escaping (Bool) -> Void) -> Void = { _, _, completion in completion(false) }

    /// Called whenever the rendered file changes — initial load, following a
    /// link to a sibling `.md`, or going back. Hosts use it to keep window
    /// chrome in sync with what is actually on screen. Default is a no-op.
    var fileURLDidChange: (URL?) -> Void = { _ in }

    /// When true, rendered HTML enables clickable checkboxes. Both hosts set
    /// this; it says nothing about which one is rendering.
    var interactive: Bool = false

    /// When true, the page leaves headroom under the host app's transparent
    /// titlebar and fades content into it. QuickLook draws no chrome of its
    /// own, so it stays false there.
    var appChrome: Bool = false

    private var isTornDown = false

    /// `loadPage` calls whose navigation has not yet been let through: the
    /// only navigations `decidePolicyFor` allows.
    private var pageLoadsPending = 0

    override init() {
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: NSRect(origin: .zero, size: MarkdownRenderer.previewSize), configuration: config)
        super.init()
        config.userContentController.add(WeakScriptMessageHandler(delegate: self), name: "mdql")
        webView.navigationDelegate = self
    }

    /// Stops file watching, halts web view loading, and releases the script message handler.
    /// Final: a controller is not loaded again after it.
    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        fileWatcher?.stop()
        fileWatcher = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mdql")
    }

    deinit {
        teardown()
    }

    // MARK: - Public API

    /// Loads and renders a markdown file. Used for the initial file (the one
    /// the host has direct read access to). Sibling files reached via
    /// `openMarkdown` go through the injected `readFile` closure.
    @discardableResult
    func loadMarkdownFile(at url: URL) throws -> Bool {
        loadMarkdown(try String(contentsOf: url, encoding: .utf8), readFrom: url)
        return true
    }

    /// Renders `markdown`, which the host has already read from `url`, as the
    /// initial file: the back stack starts empty and `url` is watched from here
    /// on. Lets a host that reads the file itself fail the open on a read error.
    func loadMarkdown(_ markdown: String, readFrom url: URL) {
        let title = url.deletingPathExtension().lastPathComponent
        let html = MarkdownRenderer.render(markdown: markdown, title: title, interactive: interactive, appChrome: appChrome)
        fileWatcher?.stop()
        documentURL = url
        fileURL = url
        fileHistory.removeAll()
        loadPage(html)
        startWatching(url)
    }

    /// Handles an openURL action. Exposed for testing.
    func handleOpenURL(_ urlString: String, background: Bool) {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return }
        do {
            try AccessPolicy.checkOpening(url)
        } catch {
            AccessPolicy.log.error("Refused to open \(urlString, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
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
        guard let documentURL else { return }
        do {
            _ = try AccessPolicy.file(resolved, previewing: documentURL)
        } catch {
            AccessPolicy.log.error("Refused to open \(resolved.path, privacy: .public) in the preview: \(String(describing: error), privacy: .public)")
            return
        }

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
        loadPage(html)
        startWatching(url)
    }

    /// Every page goes in through here, so that `decidePolicyFor` can tell
    /// mdql's own loads from a navigation the document asks for.
    private func loadPage(_ html: String) {
        pageLoadsPending += 1
        webView.loadHTMLString(html, baseURL: nil)
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
        // Only mdql's own page speaks for the user: not a frame inside it,
        // nor a page that replaced it.
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url == Self.pageURL else {
            let frame = message.frameInfo.request.url?.absoluteString ?? "no URL"
            AccessPolicy.log.error("Ignored a message from \(message.frameInfo.isMainFrame ? "main frame" : "subframe", privacy: .public) \(frame, privacy: .public), which is not mdql's page")
            return
        }
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
        // mdql's own pages load; nothing a document asks for does — a meta
        // refresh, a form, `window.open`, a subframe — wherever it points.
        if pageLoadsPending > 0, navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.request.url == Self.pageURL {
            pageLoadsPending -= 1
            decisionHandler(.allow)
            return
        }
        AccessPolicy.log.error("Cancelled a navigation to \(navigationAction.request.url?.absoluteString ?? "no URL", privacy: .public): only mdql's own page loads")
        decisionHandler(.cancel)
    }
}

/// Trampoline that forwards `WKScriptMessageHandler` calls without retaining the delegate,
/// breaking the circular retain cycle between `WKUserContentController` and `MarkdownWebController`.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
