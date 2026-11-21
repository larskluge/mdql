import XCTest
import WebKit

/// What WebKit makes of a rendered page. A check on the HTML string cannot
/// tell how a browser parses it, so these render a file through
/// `MarkdownWebController`, as both hosts do, into a real offscreen
/// WKWebView, and ask the DOM.
final class RenderedPageTests: XCTestCase {

    // MARK: - The page never depends on how its body parses

    func testBodyTextTitleTagLeavesTheRestOfThePageVisible() throws {
        // An owl report's `Case <n>, “<title>”, has no session yet…` left Quick
        // Look and the viewer on a spinner: <title> is RCDATA, so the browser
        // read the rest of the file, mdql's own script included, as its text.
        let page = try show("x “<title>” y\n\nAfter.").webView

        XCTAssertEqual(try evaluate("document.getElementById('mdql-loading') === null", in: page) as? Bool, true,
                       "No loading spinner may remain on the page")
        let visible = try visibleText(of: page)
        XCTAssertTrue(visible.contains("After."), "The text after <title> must show; visible: \(visible)")
        XCTAssertTrue(visible.contains("<title>"), "The tag itself must show as text; visible: \(visible)")
    }

    func testEveryRawTextTagLeavesTheRestOfThePageVisible() throws {
        for tag in tagfilterTags {
            for markdown in ["Before <\(tag)> inline.\n\nAfter.", "<\(tag)>\n\nAfter."] {
                let visible = try visibleText(of: show(markdown).webView)
                XCTAssertTrue(visible.contains("After."),
                              "\(markdown.debugDescription) hid the rest of the page; visible: \(visible)")
            }
        }
    }

    func testUnclosedCommentBlockStillShowsWhatPrecedesIt() throws {
        // An HTML block opened by `<!--` runs to the end of the file, and the
        // comment swallows everything the page puts after the body.
        let visible = try visibleText(of: show("Before.\n\n<!-- never closed\n\nAfter.").webView)
        XCTAssertTrue(visible.contains("Before."), "Content before the comment must show; visible: \(visible)")
    }

    // MARK: - Only mdql's own script runs

    func testDocumentScriptDoesNotRun() throws {
        let page = try show("<script>window.__pwned = 1</script>\n\nText.").webView
        XCTAssertEqual(try evaluate("typeof window.__pwned", in: page) as? String, "undefined")
    }

    func testDocumentEventHandlerAttributeDoesNotRun() throws {
        let page = try show(#"<img src="data:image/png;base64,AAAA" onerror="window.__pwned = 1">"#).webView
        try waitUntil("document.querySelector('img').complete", in: page)
        settle()
        XCTAssertEqual(try evaluate("typeof window.__pwned", in: page) as? String, "undefined")
    }

    func testJavaScriptLinkDoesNotRun() throws {
        let page = try show("[a](javascript:window.__pwned=1)").webView
        try evaluate("document.querySelector('a').click(); true", in: page)
        settle()
        XCTAssertEqual(try evaluate("typeof window.__pwned", in: page) as? String, "undefined")
    }

    func testLiveReloadDoesNotRunTheDocumentsEventHandlers() throws {
        let shown = try show("Before.")
        try Data(#"Reloaded. <img src="data:image/png;base64,AAAA" onerror="window.__pwned = 1">"#.utf8)
            .write(to: shown.file)
        try waitUntil("document.body.innerText.includes('Reloaded.')", in: shown.webView)
        try waitUntil("document.querySelector('img').complete", in: shown.webView)
        settle()
        XCTAssertEqual(try evaluate("typeof window.__pwned", in: shown.webView) as? String, "undefined")
    }

    // MARK: - The page never navigates away from mdql's own

    /// A port nothing listens on: a navigation that is let through starts,
    /// shows in `webView.url`, and fails at once, without leaving the Mac.
    private let elsewhere = "http://127.0.0.1:9/"

    func testMetaRefreshDoesNotNavigate() throws {
        try assertStaysPut("<meta http-equiv=\"refresh\" content=\"0; url=\(elsewhere)\">\n\nStill here.")
    }

    func testMetaRefreshToAnEmptyPageDoesNotReplaceTheDocument() throws {
        try assertStaysPut("<meta http-equiv=\"refresh\" content=\"0; url=about:blank\">\n\nStill here.")
    }

    func testFormSubmitDoesNotNavigate() throws {
        try assertStaysPut("<form action=\"\(elsewhere)\"><button>Go</button></form>\n\nStill here.",
                           then: "document.querySelector('button').click()")
    }

    func testScriptedNavigationDoesNotLeaveThePage() throws {
        try assertStaysPut("Still here.", then: "window.open('\(elsewhere)', '_self')")
        try assertStaysPut("Still here.", then: "window.open('\(elsewhere)')")
        try assertStaysPut("Still here.", then: "location.href = '\(elsewhere)'")
    }

    func testTheLatestOfTwoQuickLoadsShows() throws {
        let shown = try show("First.")
        let second = shown.file.deletingLastPathComponent().appendingPathComponent("second.md")
        try Data("Second.".utf8).write(to: second)
        let third = shown.file.deletingLastPathComponent().appendingPathComponent("third.md")
        try Data("Third.".utf8).write(to: third)

        try shown.controller.loadMarkdownFile(at: second)
        try shown.controller.loadMarkdownFile(at: third)

        try waitUntil("document.body.innerText.includes('Third.') && document.readyState === 'complete'", in: shown.webView)
    }

    // MARK: - Only mdql's own page reaches the bridge

    func testMessageFromASubframeIsIgnored() throws {
        var opened: [String] = []
        let page = try show("Text.") { controller in
            controller.openURL = { opened.append($0.absoluteString) }
        }.webView

        try evaluate("""
            var frame = document.createElement('iframe');
            document.body.appendChild(frame);
            frame.contentWindow.webkit.messageHandlers.mdql.postMessage({action: 'openURL', url: 'https://example.com/framed'});
            true
            """, in: page)
        try evaluate("webkit.messageHandlers.mdql.postMessage({action: 'openURL', url: 'https://example.com/main'}); true", in: page)
        let deadline = Date().addingTimeInterval(5)
        while opened.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        settle()

        XCTAssertEqual(opened, ["https://example.com/main"], "Only the main frame's message may act")
    }

    func testMessageFromAPageOtherThanMdqlsIsIgnored() throws {
        // Were a navigation ever to get through, the page it reached must
        // find the bridge deaf. Detaching the navigation delegate lets the
        // test put such a page in the main frame.
        var opened: [String] = []
        let shown = try show("Text.") { controller in
            controller.openURL = { opened.append($0.absoluteString) }
        }
        shown.webView.navigationDelegate = nil
        shown.webView.loadHTMLString("<p>Elsewhere.</p>", baseURL: URL(string: "https://attacker.example/"))
        try waitUntil("document.body.innerText.includes('Elsewhere.')", in: shown.webView)

        try evaluate("webkit.messageHandlers.mdql.postMessage({action: 'openURL', url: 'https://example.com/'}); true",
                     in: shown.webView)
        settle()

        XCTAssertEqual(opened, [], "A main frame showing anything but mdql's page may not use the bridge")
    }

    // MARK: - mdql's own features still work

    func testFollowingAMarkdownLinkAndGoingBackStillWork() throws {
        let shown = try show("[Two](two.md)")
        let two = shown.file.deletingLastPathComponent().appendingPathComponent("two.md")
        try Data("Second page.".utf8).write(to: two)

        let followed = expectation(description: "followed the link to two.md")
        let wentBack = expectation(description: "went back to the first file")
        shown.controller.fileURLDidChange = { url in
            if url?.lastPathComponent == "two.md" { followed.fulfill() }
            if url?.lastPathComponent == shown.file.lastPathComponent { wentBack.fulfill() }
        }

        try evaluate("document.querySelector('a').click(); true", in: shown.webView)
        wait(for: [followed], timeout: 10)
        try waitUntil("!!document.getElementById('mdql-back') && document.readyState === 'complete'", in: shown.webView)
        try evaluate("document.getElementById('mdql-back').click(); true", in: shown.webView)
        wait(for: [wentBack], timeout: 10)
    }

    func testCheckboxStillToggles() throws {
        let toggled = expectation(description: "toggleCheckbox reached Swift")
        var toggledIndex: Int?
        let page = try show("- [ ] task") { controller in
            controller.toggleCheckbox = { index, _, completion in
                toggledIndex = index
                completion(true)
                toggled.fulfill()
            }
        }.webView

        try evaluate("document.querySelector('input[type=checkbox]').click(); true", in: page)
        wait(for: [toggled], timeout: 10)
        XCTAssertEqual(toggledIndex, 0)
    }

    func testExternalLinkStillOpens() throws {
        let opened = expectation(description: "openURL reached Swift")
        var openedURL: URL?
        let page = try show("[site](https://example.com/)") { controller in
            controller.openURL = { url in
                openedURL = url
                opened.fulfill()
            }
        }.webView

        try evaluate("document.querySelector('a').click(); true", in: page)
        wait(for: [opened], timeout: 10)
        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/")
    }

    func testDetailsAndImagesStillRenderAsHTML() throws {
        let dot = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        let page = try show("<details><summary>s</summary>b</details>\n\n<img alt=\"dot\" src=\"data:image/png;base64,\(dot)\">").webView

        XCTAssertEqual(try evaluate("!!document.querySelector('.markdown-body details > summary')", in: page) as? Bool, true,
                       "<details> must render as an element")
        XCTAssertEqual(try evaluate("document.querySelector('.markdown-body img').naturalWidth", in: page) as? Int, 1,
                       "A data: image must load")
    }

    // MARK: - Helpers

    private struct Shown {
        let controller: MarkdownWebController
        let file: URL
        var webView: WKWebView { controller.webView }
    }

    /// Writes `markdown` to a file of its own, loads it the way both hosts do,
    /// and waits until the page has finished loading.
    private func show(_ markdown: String, configure: (MarkdownWebController) -> Void = { _ in }) throws -> Shown {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("page.md")
        try Data(markdown.utf8).write(to: file)

        let controller = MarkdownWebController()
        addTeardownBlock { controller.teardown() }
        controller.interactive = true
        controller.readFile = { url, completion in
            completion(try? String(contentsOf: url, encoding: .utf8))
        }
        configure(controller)
        try controller.loadMarkdownFile(at: file)
        try waitUntil("!!document.querySelector('.markdown-body') && document.readyState === 'complete'",
                      in: controller.webView)
        return Shown(controller: controller, file: file)
    }

    /// The text a reader sees: `innerText` leaves out whatever is not rendered.
    private func visibleText(of webView: WKWebView) throws -> String {
        try XCTUnwrap(evaluate("document.body.innerText", in: webView) as? String)
    }

    @discardableResult
    private func evaluate(_ script: String, in webView: WKWebView) throws -> Any? {
        let done = expectation(description: "evaluated \(script)")
        var result: Result<Any?, Error> = .success(nil)
        webView.evaluateJavaScript(script) { value, error in
            result = error.map { .failure($0) } ?? .success(value)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return try result.get()
    }

    private func waitUntil(_ condition: String, in webView: WKWebView, timeout: TimeInterval = 10,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Result<Any?, Error> = .success(nil)
        while Date() < deadline {
            last = Result { try evaluate(condition, in: webView) }
            if case .success(let value) = last, value as? Bool == true { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Timed out waiting for \(condition); last result: \(last)", file: file, line: line)
    }

    /// Lets anything the page queued (an error event, a navigation) run.
    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Shows `markdown`, runs `script` in the page if given, and checks that
    /// the web view never left mdql's page: `webView.url` names a navigation
    /// as soon as it starts, even one that then fails.
    private func assertStaysPut(_ markdown: String, then script: String? = nil,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        var visited: [String] = []
        var observation: NSKeyValueObservation?
        let shown = try show(markdown) { controller in
            observation = controller.webView.observe(\.url) { webView, _ in
                visited.append(webView.url?.absoluteString ?? "nil")
            }
        }
        if let script { try evaluate(script + "; true", in: shown.webView) }
        settle(1)
        observation?.invalidate()

        XCTAssertEqual(visited.filter { $0 != "about:blank" }, [], "The page navigated away", file: file, line: line)
        XCTAssertEqual(shown.webView.url?.absoluteString, "about:blank", file: file, line: line)
        let visible = try visibleText(of: shown.webView)
        XCTAssertTrue(visible.contains("Still here."), "The document must still show; visible: \(visible)",
                      file: file, line: line)
    }
}
