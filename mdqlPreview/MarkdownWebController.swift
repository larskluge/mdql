import Cocoa
import WebKit
import os

/// A notice at the top of the page: something the reader asked for failed,
/// was refused, is still under way, or has come right again. Problems show
/// there, where they are seen; what is fine to miss shows in the label at the
/// bottom.
struct PageNotice: Equatable {
    enum Kind: String {
        /// A red warning triangle: what was asked for failed.
        case failed
        /// A grey circle-slash: mdql refused it on purpose.
        case refused
        /// A pulsing amber dot: waiting on something, or watching for it.
        case waiting
        /// A green check: a problem cleared. It fades after a moment.
        case cleared
    }

    /// Names the notice on the page: another with the same id replaces it.
    let id: String
    let kind: Kind
    let text: String
    /// What follows the text after a `·`, quieter: the reason, the detail.
    let detail: String?
    /// Stays until its condition clears, rather than fading after a while.
    let lasting: Bool

    init(id: String, kind: Kind, text: String, detail: String? = nil, lasting: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.lasting = lasting
    }

    fileprivate var page: [String: Any] {
        ["id": id, "kind": kind.rawValue, "text": text, "detail": detail ?? "", "lasting": lasting]
    }
}

/// Owns a WKWebView and the JS↔Swift bridge, FileWatcher, and back-stack
/// navigation used to render markdown. Hosted by both the QuickLook
/// extension (`PreviewController`) and the document-based app
/// (`DocumentWindowController`); each injects its own `openURL` /
/// `readFile` / `toggleCheckbox` closures because the extension reaches the
/// filesystem through XPC while the app reads directly.
///
/// Nothing the reader asks for fails silently: each closure answers exactly
/// once, with a reason when it fails, and the page says so in a notice.
final class MarkdownWebController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    /// Where every page this controller renders lives: `loadHTMLString` with
    /// no base URL. Nothing else may load, and nothing else reaches the bridge.
    private static let pageURL = URL(string: "about:blank")!

    private static let log = Logger(subsystem: "com.mdql.app", category: "page")

    /// The notices that belong to the file on screen, replaced as it changes.
    private static let missingNoticeID = "file-missing"
    private static let encodingNoticeID = "encoding"

    let webView: WKWebView
    private var fileWatcher: FileWatcher?
    private(set) var fileURL: URL? {
        didSet {
            guard fileURL != oldValue else { return }
            fileURLDidChange?(fileURL)
        }
    }
    private var fileHistory: [URL] = []

    /// The file the host opened, which `fileURL` leaves as links are
    /// followed. Its folder bounds every file a link may open (`AccessPolicy`).
    private(set) var documentURL: URL?

    /// How the file on screen was read. Its checkboxes are clickable only when
    /// UTF-8: their offsets count UTF-8 bytes, and a write into a guessed
    /// encoding could corrupt the file.
    private(set) var encoding: MarkdownEncoding = .utf8

    /// The element to scroll to once `navigation` finishes loading its page:
    /// the fragment of the `other.md#section` link that loaded it.
    private var pendingAnchor: (navigation: WKNavigation, id: String)?

    /// Opens a URL externally (browser, Mail), then calls back on the main
    /// queue with nil, or with why it did not open.
    var openURL: (URL, @escaping (PlainError?) -> Void) -> Void = { _, completion in
        completion(PlainError("nothing here opens links"))
    }

    /// Reads and decodes a file, then calls back on the main queue with its
    /// text, or with why it could not be read.
    var readFile: (URL, @escaping (Result<MarkdownText, PlainError>) -> Void) -> Void = { _, completion in
        completion(.failure(PlainError("nothing here reads files")))
    }

    /// Sets the task-list marker at a UTF-8 offset in the currently loaded file's
    /// text (the rendered checkbox's `data-cb-offset`) to checked or not, and
    /// calls back on the main queue with the outcome. The host app writes the
    /// file directly; the QuickLook extension goes through XPC.
    var toggleCheckbox: (Int, Bool, @escaping (CheckboxToggleResult) -> Void) -> Void = { _, _, completion in
        completion(.failed(PlainError("nothing here saves ticks")))
    }

    /// Called whenever the rendered file changes — initial load, following a
    /// link to a sibling `.md`, or going back. Hosts use it to keep window
    /// chrome in sync with what is actually on screen.
    var fileURLDidChange: ((URL?) -> Void)?

    /// When true, rendered HTML enables clickable checkboxes. Both hosts set
    /// this; it says nothing about which one is rendering.
    var interactive: Bool = false

    /// When true, the page leaves headroom under the host app's transparent
    /// titlebar and fades content into it. QuickLook draws no chrome of its
    /// own, so it stays false there.
    var appChrome: Bool = false

    /// How far the host's titlebar reaches down over the page, which the back
    /// button and the notices sit 20 px below. The viewer measures it from
    /// its window; Quick Look has none.
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue, pageReady else { return } // a page still loading gets it when it has
            applyTopInset()
        }
    }

    /// When a tick that has not saved yet says so, and when it gives up.
    var slowSaveDelay: TimeInterval = 2
    var saveTimeout: TimeInterval = 10

    /// Runs `work` on the main queue after a delay. Tests run time by hand.
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A tick asked of `toggleCheckbox` that has not answered yet.
    private struct PendingToggle {
        let offset: Int
        let checked: Bool
        /// The render that drew its checkbox: a later one drew the file afresh.
        let render: Int
        /// Whether the page says it is still saving.
        var slow = false
    }
    private var pendingToggles: [Int: PendingToggle] = [:]
    private var lastToggleID = 0

    /// Counts the renders, page loads and live updates alike.
    private var renderCount = 0

    /// The notices that stay until their condition clears. A page loaded
    /// afresh shows them again.
    private var lastingNotices: [PageNotice] = []

    /// Notice changes made while a page was loading, shown once it has.
    private var queuedNoticeChanges: [NoticeChange] = []
    private enum NoticeChange {
        case show(PageNotice)
        case dismiss(String)
    }

    /// The latest page load, and whether it has finished: until then the page
    /// has no `__mdqlNotice` to show a notice with.
    private var latestNavigation: WKNavigation?
    private var pageReady = false

    private var isTornDown = false

    /// `loadPage` calls whose navigation has not yet been let through: the
    /// only navigations `decidePolicyFor` allows.
    private var pageLoadsPending = 0

    /// Whether the page loads the Mermaid runtime (`MermaidRuntime`): what
    /// `MarkdownRenderer.renderPage` said it embedded.
    private(set) var hasLoadedMermaid: Bool = false

    override init() {
        let config = WKWebViewConfiguration()
        MermaidRuntime.install(on: config)
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
    /// `openMarkdown` go through the injected `readFile` closure. Throws only
    /// when the file cannot be read at all; one that is not UTF-8 is shown
    /// anyway, with a notice.
    @discardableResult
    func loadMarkdownFile(at url: URL) throws -> Bool {
        let text = try MarkdownText(contentsOf: url)
        loadMarkdown(text.string, encoding: text.encoding, readFrom: url)
        return true
    }

    /// Renders `markdown`, which the host has already read from `url` as
    /// `encoding`, as the initial file: the back stack starts empty and `url`
    /// is watched from here on. Lets a host that reads the file itself fail
    /// the open on a read error.
    func loadMarkdown(_ markdown: String, encoding: MarkdownEncoding = .utf8, readFrom url: URL) {
        documentURL = url
        fileHistory.removeAll()
        showMarkdown(MarkdownText(string: markdown, encoding: encoding), url: url)
    }

    /// Shows `notice` at the top of the page, replacing one with its id.
    func show(_ notice: PageNotice) {
        lastingNotices.removeAll { $0.id == notice.id }
        if notice.lasting { lastingNotices.append(notice) }
        send(.show(notice))
    }

    /// Takes the notice with `id` off the page, if it is there.
    func dismissNotice(id: String) {
        lastingNotices.removeAll { $0.id == id }
        send(.dismiss(id))
    }

    /// Handles an openURL action. Exposed for testing.
    func handleOpenURL(_ urlString: String) {
        guard !urlString.isEmpty else { return }
        do {
            guard let url = URL(string: urlString) else {
                throw AccessPolicy.Refusal(kind: .noScheme, description: "it is not a URL")
            }
            try AccessPolicy.checkOpening(url)
            openURL(url) { [weak self] error in
                guard let error else { return }
                self?.show(PageNotice(id: "open \(urlString)", kind: .failed, text: "Couldn't open the link", detail: error.reason))
            }
        } catch {
            AccessPolicy.log.error("Refused to open \(urlString, privacy: .public): \(String(describing: error), privacy: .public)")
            show(refusal(error, naming: urlString))
        }
    }

    /// Handles a toggleCheckbox action posted from JS. Exposed for testing.
    /// A fast save shows nothing. One that has not answered by
    /// `slowSaveDelay` says it is still saving, and turns green if it then
    /// saves. A failure, or no answer by `saveTimeout`, reverts the checkbox
    /// and says why. When the file has changed since the page was rendered,
    /// renders it again.
    func handleToggleCheckbox(offset: Int, checked: Bool) {
        lastToggleID += 1
        let id = lastToggleID
        pendingToggles[id] = PendingToggle(offset: offset, checked: checked, render: renderCount)
        schedule(slowSaveDelay) { [weak self] in self?.toggleIsSlow(id) }
        schedule(saveTimeout) { [weak self] in self?.finishToggle(id, with: .failed(.helperDidntAnswer)) }
        toggleCheckbox(offset, checked) { [weak self] result in
            self?.finishToggle(id, with: result)
        }
    }

    /// Handles an openMarkdown action: `href` is a link's relative `.md` or
    /// `.markdown` target, with or without a `#section`. Exposed for testing.
    func handleOpenMarkdown(_ href: String) {
        // The fragment names a place in the file, not part of its name, and each
        // half is percent-decoded on its own: `%23` is a `#` in the name.
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let decoded = parts[0].removingPercentEncoding ?? parts[0]
        let anchor = parts.count > 1 ? parts[1].removingPercentEncoding ?? parts[1] : ""
        guard let currentURL = self.fileURL, let documentURL,
              !decoded.isEmpty else { return }

        let resolved = URL(fileURLWithPath: decoded, relativeTo: currentURL.deletingLastPathComponent()).standardized
        do {
            _ = try AccessPolicy.file(resolved, previewing: documentURL)
        } catch {
            AccessPolicy.log.error("Refused to open \(resolved.path, privacy: .public) in the preview: \(String(describing: error), privacy: .public)")
            if let refusal = error as? AccessPolicy.Refusal, case .unresolvable = refusal.kind {
                // Not refused on purpose: the file is not there to read.
                showCouldNotOpen(resolved, PlainError(refusal.plainReason(naming: decoded)))
            } else {
                show(refusal(error, naming: decoded))
            }
            return
        }

        readFile(resolved) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                self.fileHistory.append(currentURL)
                self.showMarkdown(text, url: resolved, scrollingTo: anchor.isEmpty ? nil : anchor)
            case .failure(let error):
                self.showCouldNotOpen(resolved, error)
            }
        }
    }

    // MARK: - Internal navigation

    private func goBack() {
        guard let previousURL = fileHistory.popLast() else { return }
        readFile(previousURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                self.showMarkdown(text, url: previousURL)
            case .failure(let error):
                self.fileHistory.append(previousURL) // so that back still leads there
                self.showCouldNotOpen(previousURL, error)
            }
        }
    }

    private func showMarkdown(_ text: MarkdownText, url: URL, scrollingTo anchor: String? = nil) {
        fileWatcher?.stop()
        fileURL = url
        dismissNotice(id: Self.missingNoticeID)
        showEncoding(text.encoding)
        let title = url.deletingPathExtension().lastPathComponent
        let page = MarkdownRenderer.renderPage(markdown: text.string, title: title, showBackButton: !fileHistory.isEmpty,
                                               interactive: interactive, checkboxesClickable: text.encoding == .utf8,
                                               appChrome: appChrome, topInset: topInset)
        hasLoadedMermaid = page.loadsMermaid
        let navigation = loadPage(page.html)
        if let navigation, let anchor {
            pendingAnchor = (navigation, anchor)
        } else {
            pendingAnchor = nil
        }
        startWatching(url)
    }

    /// Every page goes in through here, so that `decidePolicyFor` can tell
    /// mdql's own loads from a navigation the document asks for.
    @discardableResult
    private func loadPage(_ html: String) -> WKNavigation? {
        pageLoadsPending += 1
        renderCount += 1
        pageReady = false
        latestNavigation = webView.loadHTMLString(html, baseURL: nil)
        return latestNavigation
    }

    private func startWatching(_ url: URL) {
        let watcher = FileWatcher(url: url) { [weak self] in
            self?.reloadContent()
        }
        watcher.availabilityChanged = { [weak self] present in
            self?.fileAvailabilityChanged(present, at: url)
        }
        fileWatcher = watcher
        watcher.start()
    }

    /// Re-renders the watched file after a change on disk. Exposed for testing.
    func reloadContent() {
        guard let url = fileURL else { return }
        readFile(url) { [weak self] result in
            guard let self, self.fileURL == url else { return }
            switch result {
            case .success(let text):
                self.showEncoding(text.encoding)
                let body = MarkdownRenderer.renderBodyNotingDiagrams(markdown: text.string, interactive: self.interactive && text.encoding == .utf8)
                // The first fence in a page without diagrams brings the runtime
                // into this page, which stays where the reader is.
                let bringsRuntime = body.hasMermaidFence && !self.hasLoadedMermaid && MermaidRuntime.runtimeFileURL != nil
                if bringsRuntime { self.hasLoadedMermaid = true }
                let base64 = Data(body.html.utf8).base64EncodedString()
                self.renderCount += 1
                // On a page with diagrams, __mdqlSwapBody (MermaidRuntime.glue)
                // swaps the body and puts unchanged diagrams back without
                // re-rendering them. Until the runtime has run, and on a page
                // without diagrams, the body is swapped plainly; the runtime draws
                // whatever fences are there when it starts.
                self.webView.evaluateJavaScript(
                    "(function(h) { if (window.__mdqlSwapBody) { window.__mdqlSwapBody(h); return; } var a = document.querySelector('.markdown-body'); if (a) a.innerHTML = h; })(new TextDecoder().decode(Uint8Array.from(atob('\(base64)'), c => c.charCodeAt(0))));"
                        + (bringsRuntime ? MermaidRuntime.injectionJS : "")
                ) { _, error in
                    if let error {
                        Self.log.error("A live update of \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            case .failure(let error) where error == .fileNotFound:
                break // the watcher says when it is gone, and when it is back
            case .failure(let error):
                self.showCouldNotOpen(url, error)
            }
        }
    }

    // MARK: - Notices

    /// `error`, which `AccessPolicy` threw, as the notice that says so.
    private func refusal(_ error: Error, naming name: String) -> PageNotice {
        let reason = (error as? AccessPolicy.Refusal)?.plainReason(naming: name) ?? String(describing: error)
        return PageNotice(id: "refused \(name)", kind: .refused, text: "Not opened", detail: reason)
    }

    private func showCouldNotOpen(_ url: URL, _ error: PlainError) {
        show(PageNotice(id: "open \(url.path)", kind: .failed, text: "Couldn't open \(url.lastPathComponent)", detail: error.reason))
    }

    private func showEncoding(_ encoding: MarkdownEncoding) {
        self.encoding = encoding
        switch encoding {
        case .utf8:
            dismissNotice(id: Self.encodingNoticeID)
        case .utf16:
            // Its byte-order mark says so: no character is in doubt.
            show(PageNotice(id: Self.encodingNoticeID, kind: .failed, text: "Not UTF-8", detail: "shown as \(encoding.name)", lasting: true))
        case .windowsLatin1, .isoLatin1:
            show(PageNotice(id: Self.encodingNoticeID, kind: .failed, text: "Not UTF-8",
                            detail: "shown as \(encoding.name), some characters may be off", lasting: true))
        }
    }

    private func fileAvailabilityChanged(_ present: Bool, at url: URL) {
        guard url == fileURL else { return }
        let name = url.lastPathComponent
        if present {
            show(PageNotice(id: Self.missingNoticeID, kind: .cleared, text: "\(name) is back", detail: "showing the latest"))
        } else {
            show(PageNotice(id: Self.missingNoticeID, kind: .waiting, text: "\(name) was moved or deleted",
                            detail: "updates resume when it's back", lasting: true))
        }
    }

    private func toggleIsSlow(_ id: Int) {
        guard pendingToggles[id] != nil else { return }
        pendingToggles[id]?.slow = true
        show(PageNotice(id: "tick \(id)", kind: .waiting, text: "Still saving the tick…", lasting: true))
    }

    /// The one answer a tick gets: the first of its reply and its timeout.
    private func finishToggle(_ id: Int, with result: CheckboxToggleResult) {
        guard let toggle = pendingToggles.removeValue(forKey: id) else { return }
        let noticeID = "tick \(id)"
        switch result {
        case .toggled:
            if toggle.slow {
                show(PageNotice(id: noticeID, kind: .cleared, text: "Saved", detail: "it just took a while"))
            }
        case .stale:
            if toggle.slow { dismissNotice(id: noticeID) }
            reloadContent()
        case .failed(let error):
            // A render since the click drew the file as it is: nothing to revert.
            if toggle.render == renderCount {
                runInPage("window.__mdqlRevertCheckbox && window.__mdqlRevertCheckbox(offset, checked)",
                          ["offset": toggle.offset, "checked": toggle.checked])
            }
            show(PageNotice(id: noticeID, kind: .failed, text: "Tick not saved", detail: error.reason))
        }
    }

    private func send(_ change: NoticeChange) {
        guard !isTornDown else { return }
        guard pageReady else {
            queuedNoticeChanges.append(change)
            return
        }
        apply(change)
    }

    private func apply(_ change: NoticeChange) {
        switch change {
        case .show(let notice):
            runInPage("window.__mdqlNotice(notice)", ["notice": notice.page])
        case .dismiss(let id):
            runInPage("window.__mdqlDismissNotice(id)", ["id": id])
        }
    }

    private func applyTopInset() {
        runInPage("document.documentElement.style.setProperty('--mdql-top', inset + 'px')", ["inset": Double(topInset)])
    }

    /// Runs `script` in mdql's page with `arguments` as its variables, which
    /// no document text can break out of, and logs it if it fails.
    private func runInPage(_ script: String, _ arguments: [String: Any]) {
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
            if case .failure(let error) = result {
                Self.log.error("A script in the page failed: \(error.localizedDescription, privacy: .public)")
            }
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
                handleOpenURL(urlString)
            }
        case "openMarkdown":
            if let urlString = body["url"] as? String {
                handleOpenMarkdown(urlString)
            }
        case "goBack":
            goBack()
        case "toggleCheckbox":
            if let offset = body["offset"] as? Int, let checked = body["checked"] as? Bool {
                handleToggleCheckbox(offset: offset, checked: checked)
            }
        default:
            break
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Cancel all link-activated navigations: a link opens through
        // `handleOpenURL`, which opens it or says why not. Only a jump within
        // mdql's own page (`about:blank#…`) is left alone.
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url, url.scheme?.lowercased() != "about" {
                handleOpenURL(url.absoluteString)
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

    /// Shows the notices the page is due, once it can, and scrolls to the
    /// anchor a section link named, once its file has loaded: the element with
    /// that id, else the `<a>` with that name, as a browser resolves a
    /// fragment. No such element leaves the page at the top.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if navigation === latestNavigation, !pageReady {
            pageReady = true
            applyTopInset() // it may have changed since the page was rendered
            lastingNotices.forEach { apply(.show($0)) }
            let queued = queuedNoticeChanges
            queuedNoticeChanges.removeAll()
            queued.forEach(apply)
        }
        guard let pending = pendingAnchor, pending.navigation === navigation else { return }
        pendingAnchor = nil
        webView.callAsyncJavaScript(
            """
            var target = document.getElementById(id)
                || Array.from(document.getElementsByName(id)).find(function (el) { return el.tagName === 'A'; });
            if (target) target.scrollIntoView();
            """,
            arguments: ["id": pending.id], in: nil, in: .page)
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
