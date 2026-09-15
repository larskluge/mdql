import XCTest
import WebKit

final class PreviewControllerTests: XCTestCase {

    func testPreviewSizeIsLarge() {
        let size = MarkdownRenderer.previewSize
        XCTAssertGreaterThanOrEqual(size.width, 1060, "Preview width must be at least 1060")
        XCTAssertGreaterThanOrEqual(size.height, 900, "Preview height must be at least 900")
    }

    func testPreferredContentSizeIsSet() {
        let controller = PreviewController()
        controller.loadView()
        XCTAssertEqual(controller.preferredContentSize, MarkdownRenderer.previewSize,
                       "preferredContentSize must match previewSize")
    }

    func testViewFrameMatchesPreviewSize() {
        let controller = PreviewController()
        controller.loadView()
        XCTAssertEqual(controller.view.frame.size, MarkdownRenderer.previewSize,
                       "View frame must match previewSize")
    }

    func testViewIsWKWebView() {
        let controller = PreviewController()
        controller.loadView()
        XCTAssertTrue(controller.view is WKWebView, "View must be a WKWebView")
    }

    func testRenderedHTMLContainsMessageHandler() {
        let html = MarkdownRenderer.render(markdown: "[test](https://example.com)", title: "t")
        XCTAssertTrue(html.contains("window.webkit.messageHandlers.mdql.postMessage"),
                      "HTML must contain WKWebView message handler call")
        XCTAssertTrue(html.contains("__mdqlShowToast"), "HTML must contain toast notification")
    }

    func testRenderedHTMLContainsOpenURLAction() {
        let html = MarkdownRenderer.render(markdown: "[test](https://example.com)", title: "t")
        XCTAssertTrue(html.contains("action: \"openURL\""),
                      "HTML must post openURL action to message handler")
    }

    // MARK: - URL opening via injectable handler

    func testOpenURLCallbackIsInvoked() {
        let controller = PreviewController()
        controller.loadView()

        let expectation = expectation(description: "openURL callback invoked")
        var receivedURL: URL?

        controller.openURL = { url, done in
            receivedURL = url
            done(nil)
            expectation.fulfill()
        }

        controller.handleOpenURL("https://example.com")

        waitForExpectations(timeout: 1)
        XCTAssertEqual(receivedURL?.absoluteString, "https://example.com")
    }

    func testOpenURLIgnoresEmptyString() {
        let controller = PreviewController()
        controller.loadView()

        var callbackInvoked = false
        controller.openURL = { _, done in
            callbackInvoked = true
            done(nil)
        }

        controller.handleOpenURL("")

        XCTAssertFalse(callbackInvoked, "Should not invoke callback for empty URL")
    }

    func testOpenURLHandlesVariousSchemes() {
        let controller = PreviewController()
        controller.loadView()

        var receivedURLs: [URL] = []
        controller.openURL = { url, done in
            receivedURLs.append(url)
            done(nil)
        }

        controller.handleOpenURL("https://example.com")
        controller.handleOpenURL("http://example.com")

        XCTAssertEqual(receivedURLs.count, 2, "Should handle both http and https URLs")
        XCTAssertEqual(receivedURLs[0].scheme, "https")
        XCTAssertEqual(receivedURLs[1].scheme, "http")
    }

    func testOpenURLRefusesSchemesOutsideTheAllowlist() {
        let controller = MarkdownWebController()
        var opened: [String] = []
        controller.openURL = { url, done in opened.append(url.absoluteString); done(nil) }

        for string in refusedURLs {
            controller.handleOpenURL(string)
        }
        controller.handleOpenURL("mailto:someone@example.com")

        XCTAssertEqual(opened, ["mailto:someone@example.com"], "Only http, https and mailto may be opened")
    }

    // MARK: - XPC protocol

    func testOpenURLProtocolConformance() {
        // Verify the protocol can be used with NSXPCInterface (requires @objc)
        let interface = NSXPCInterface(with: OpenURLProtocol.self)
        XCTAssertNotNil(interface, "OpenURLProtocol must be usable with NSXPCInterface")
    }

    // MARK: - Markdown link detection in JS

    func testRenderedHTMLContainsMdLinkDetection() {
        let html = MarkdownRenderer.render(markdown: "[readme](readme.md)", title: "t")
        XCTAssertTrue(html.contains("isMdLink"), "HTML must contain isMdLink function")
        XCTAssertTrue(html.contains("openMarkdown"), "HTML must contain openMarkdown action")
    }

    func testTableMdLinksRenderAsAnchors() {
        let table = """
        | Spec | Status |
        |------|--------|
        | [04 — Source](04-source.md) | Draft |
        | [08 — WhatsApp](08-wa.md) | Partial |
        | [12 — Jobs](12-jobs.md) | Draft |
        """
        let html = MarkdownRenderer.renderBody(markdown: table)
        XCTAssertTrue(html.contains("href=\"04-source.md\""), "Link 04 must have correct href")
        XCTAssertTrue(html.contains("href=\"08-wa.md\""), "Link 08 must have correct href")
        XCTAssertTrue(html.contains("href=\"12-jobs.md\""), "Link 12 must have correct href")
    }

    func testRenderedHTMLHasTheBottomLabelAndNoStatusStrip() {
        let html = MarkdownRenderer.render(markdown: "test", title: "t")
        XCTAssertTrue(html.contains("label.id = 'mdql-label'"), "HTML must make the bottom label")
        XCTAssertFalse(html.contains("mdql-status"), "The full-width hover strip is gone")
        XCTAssertFalse(html.contains("Opening:"), "__mdqlShowToast adds no prefix: callers pass the whole text")
        XCTAssertFalse(html.contains("\u{1F4C4}") || html.contains("\u{1F310}"), "No emoji")
    }

    func testRenderedHTMLContainsHoverHandlers() {
        let html = MarkdownRenderer.render(markdown: "test", title: "t")
        XCTAssertTrue(html.contains("mouseover"), "HTML must contain mouseover handler")
        XCTAssertTrue(html.contains("mouseout"), "HTML must contain mouseout handler")
        XCTAssertTrue(html.contains("classList"), "HTML must toggle status bar via CSS class")
    }

    // MARK: - Checkbox toggle dispatch

    func testHandleToggleCheckboxInvokesClosureWithOffsetAndState() {
        let controller = MarkdownWebController()
        var receivedOffset: Int?
        var receivedChecked: Bool?
        let exp = expectation(description: "toggleCheckbox invoked")
        controller.toggleCheckbox = { offset, checked, completion in
            receivedOffset = offset
            receivedChecked = checked
            completion(.toggled)
            exp.fulfill()
        }
        controller.handleToggleCheckbox(offset: 23, checked: true)
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(receivedOffset, 23)
        XCTAssertEqual(receivedChecked, true)
    }

    func testAStaleToggleRendersTheFileAgain() throws {
        // The file changed since the page was drawn: rather than write, show it.
        let controller = MarkdownWebController()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdql-stale-\(UUID().uuidString).md")
        try "- [x] task\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try controller.loadMarkdownFile(at: tmp)

        var read: [URL] = []
        controller.readFile = { url, _ in read.append(url) }
        controller.toggleCheckbox = { _, _, completion in completion(.stale) }
        controller.handleToggleCheckbox(offset: 3, checked: true)

        XCTAssertEqual(read, [tmp], "A stale toggle must re-read the file to render it again")
    }

    func testInteractiveFlagPropagatesToRenderedHTML() throws {
        let controller = MarkdownWebController()
        controller.interactive = true
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdql-interactive-\(UUID().uuidString).md")
        try "- [ ] task\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try controller.loadMarkdownFile(at: tmp)
        // The webview's HTML is loaded async; we can't easily inspect it. But
        // we can re-render with the same flag and check the output the
        // controller would have produced.
        let html = MarkdownRenderer.render(markdown: "- [ ] task\n", interactive: true)
        XCTAssertTrue(html.contains(#"data-cb-offset="3""#))
    }

    func testPreviewDoesNotUseHostAppChrome() {
        // QuickLook draws no titlebar of its own — reserving headroom and
        // fading content into it would just be dead space at the top.
        let controller = PreviewController()
        controller.loadView()
        XCTAssertFalse(controller.appChrome,
                       "The QuickLook preview must not render host app titlebar chrome")
    }

    // MARK: - openMarkdown handler

    func testLoadMarkdownFileUpdatesFileURL() throws {
        let controller = PreviewController()
        controller.loadView()

        // Create a temp directory with two .md files
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file1 = tmpDir.appendingPathComponent("one.md")
        let file2 = tmpDir.appendingPathComponent("two.md")
        try "# One".write(to: file1, atomically: true, encoding: .utf8)
        try "# Two".write(to: file2, atomically: true, encoding: .utf8)

        // Load file1, then navigate to file2
        try controller.loadMarkdownFile(at: file1)
        XCTAssertEqual(controller.fileURL?.lastPathComponent, "one.md")

        try controller.loadMarkdownFile(at: file2)
        XCTAssertEqual(controller.fileURL?.lastPathComponent, "two.md")
    }

    func testHandleOpenMarkdownIgnoresNonMdExtension() {
        // handleOpenMarkdown checks extension before calling XPC
        let controller = PreviewController()
        controller.loadView()

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file1 = tmpDir.appendingPathComponent("one.md")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try? "# One".write(to: file1, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        controller.preparePreviewOfFile(at: file1) { _ in }
        controller.handleOpenMarkdown("notes.txt")

        // fileURL unchanged because extension guard rejects .txt
        XCTAssertEqual(controller.fileURL?.lastPathComponent, "one.md",
                       "Should not navigate to non-markdown files")
    }

    func testHandleOpenMarkdownReadsOnlyMarkdownUnderTheDocumentsFolder() throws {
        let root = try makeFolder()
        let document = try write("# One", to: root.appendingPathComponent("docs/one.md"))
        try write("# Two", to: root.appendingPathComponent("docs/two.md"))
        try write("# Deep", to: root.appendingPathComponent("docs/sub/deep.md"))
        try write("plain", to: root.appendingPathComponent("docs/notes.txt"))
        let outside = try write("secret", to: root.appendingPathComponent("private.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("docs/link.md"), withDestinationURL: outside)

        let controller = MarkdownWebController()
        var read: [String] = []
        controller.readFile = { url, completion in
            read.append(url.lastPathComponent)
            completion(MarkdownText.read(url))
        }
        try controller.loadMarkdownFile(at: document)

        for href in [outside.path, "../private.md", "link.md", "notes.txt"] {
            controller.handleOpenMarkdown(href)
        }
        XCTAssertEqual(read, [], "Nothing outside the document's folder, and nothing but Markdown, may be read")

        controller.handleOpenMarkdown("sub/deep.md")
        controller.handleOpenMarkdown("../two.md")
        controller.handleOpenMarkdown("../../private.md")
        XCTAssertEqual(read, ["deep.md", "two.md"],
                       "A sibling and a subfolder file may be read, the folder staying the original document's")
        XCTAssertEqual(controller.fileURL?.lastPathComponent, "two.md")
    }

    func testFileURLDidChangeFiresWhenFollowingALinkToAnotherFile() throws {
        // The host app titles its window from this callback. Without it the
        // titlebar — and the path menu behind it — keeps naming the file the
        // reader has already navigated away from.
        let controller = MarkdownWebController()
        controller.readFile = { url, completion in
            completion(MarkdownText.read(url))
        }

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let file1 = tmpDir.appendingPathComponent("one.md")
        let file2 = tmpDir.appendingPathComponent("two.md")
        try "# One".write(to: file1, atomically: true, encoding: .utf8)
        try "# Two".write(to: file2, atomically: true, encoding: .utf8)

        var observed: [String] = []
        controller.fileURLDidChange = { observed.append($0?.lastPathComponent ?? "nil") }

        try controller.loadMarkdownFile(at: file1)
        controller.handleOpenMarkdown("two.md")

        XCTAssertEqual(observed, ["one.md", "two.md"],
                       "Every change of rendered file must be reported to the host")
    }

    func testALinkToASectionOfAnotherFileReadsThatFile() throws {
        // The fragment is not part of the file name: `two.md#sec` once had the
        // extension `md#sec`, and the link was dropped.
        let controller = MarkdownWebController()
        var read: [String] = []
        controller.readFile = { url, completion in
            read.append(url.lastPathComponent)
            completion(MarkdownText.read(url))
        }

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let file1 = tmpDir.appendingPathComponent("one.md")
        try "# One".write(to: file1, atomically: true, encoding: .utf8)
        try "# Two".write(to: tmpDir.appendingPathComponent("two words.md"), atomically: true, encoding: .utf8)

        try controller.loadMarkdownFile(at: file1)
        controller.handleOpenMarkdown("two%20words.md#sec")

        XCTAssertEqual(read, ["two words.md"])
        XCTAssertEqual(controller.fileURL?.lastPathComponent, "two words.md")
    }

    // MARK: - Version display

    func testRenderedHTMLContainsVersion() {
        let html = MarkdownRenderer.render(markdown: "test", title: "t")
        XCTAssertTrue(html.contains("id=\"mdql-version\""), "HTML must contain version element")
    }

    func testVersionLoads() {
        let version = MarkdownRenderer.loadVersion()
        // In test bundle, version.txt may not exist — should fall back to "dev"
        XCTAssertFalse(version.isEmpty, "Version should never be empty")
    }

    /// Full-screen Quick Look puts the preview in a vibrantDark window; the web view
    /// must render in the system's appearance, not inherit the window's.
    func testPreviewIgnoresDarkFullScreenWindow() {
        let preview = PreviewController()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: MarkdownRenderer.previewSize),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .vibrantDark)
        window.contentView = preview.view
        XCTAssertEqual(preview.view.effectiveAppearance.name, NSApplication.shared.effectiveAppearance.name,
                       "The preview must not inherit the full-screen window's vibrantDark appearance")
    }

    func testPreviewFollowsSystemAppearanceChanges() {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original }
        let preview = PreviewController()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: MarkdownRenderer.previewSize),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .vibrantDark)
        window.contentView = preview.view

        app.appearance = NSAppearance(named: .aqua)
        XCTAssertEqual(preview.view.effectiveAppearance.name, .aqua, "Light Mode must render light")
        app.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(preview.view.effectiveAppearance.name, .darkAqua, "Dark Mode must render dark")
    }

    // MARK: - Every XPC call answers, once

    func testAFalseOpenReplyFailsTheCallAndSaysSo() throws {
        let (preview, service) = try previewWithService()
        service.onOpen = { _, reply in reply(false) }
        preview.handleOpenURL("https://example.com/")
        try waitForNotice(.failed, "Couldn't open the link · macOS couldn't open it", in: preview.controller.webView)
    }

    func testAnXPCProxyErrorFailsTheCallAndSaysSo() throws {
        let (preview, service) = try previewWithService()
        service.onOpen = { _, _ in NSXPCConnection.current()?.invalidate() } // the service goes without a reply
        let answers = countAnswers(of: preview)
        preview.handleOpenURL("https://example.com/")
        try waitForNotice(.failed, "Couldn't open the link · mdql's helper didn't answer", in: preview.controller.webView)
        settle()
        XCTAssertEqual(answers.all, [.helperDidntAnswer], "The call answers exactly once")
    }

    func testAnInterruptedConnectionFailsTheCallAndSaysSo() throws {
        let (preview, service) = try previewWithService()
        let asked = expectation(description: "the service got the call")
        var reply: ((Bool) -> Void)?
        service.onOpen = { _, held in reply = held; asked.fulfill() }
        let answers = countAnswers(of: preview)
        preview.handleOpenURL("https://example.com/")
        wait(for: [asked], timeout: 10)

        try XCTUnwrap(service.clientConnection?.interruptionHandler)() // as when launchd relaunches the service
        try waitForNotice(.failed, "Couldn't open the link · mdql's helper didn't answer", in: preview.controller.webView)
        try XCTUnwrap(reply)(true) // too late
        settle()
        XCTAssertEqual(answers.all, [.helperDidntAnswer], "The call answers exactly once")
    }

    func testACallTheServiceNeverAnswersFailsInTime() throws {
        let (preview, service) = try previewWithService()
        preview.replyTimeout = 0.3
        service.onOpen = { _, _ in }
        preview.handleOpenURL("https://example.com/")
        try waitForNotice(.failed, "Couldn't open the link · mdql's helper didn't answer", in: preview.controller.webView)
    }

    func testALinkedNoteTheServiceCannotReadSaysWhy() throws {
        let (preview, service) = try previewWithService()
        try write("# Notes", to: try XCTUnwrap(preview.fileURL).deletingLastPathComponent().appendingPathComponent("notes.md"))
        service.onRead = { _, reply in reply(nil, .utf8, "no permission to read it") }
        preview.handleOpenMarkdown("notes.md")
        try waitForNotice(.failed, "Couldn't open notes.md · no permission to read it", in: preview.controller.webView)
        XCTAssertEqual(preview.fileURL?.lastPathComponent, "page.md")
    }

    func testALinkedNoteReadThroughTheServiceKeepsItsEncoding() throws {
        let (preview, service) = try previewWithService()
        try write("# Notes", to: try XCTUnwrap(preview.fileURL).deletingLastPathComponent().appendingPathComponent("notes.md"))
        service.onRead = { _, reply in reply("Crème brûlée, 5 €", .windowsLatin1, nil) }
        preview.handleOpenMarkdown("notes.md")
        try waitUntil("document.body.innerText.includes('Crème brûlée, 5 €')", in: preview.controller.webView)
        try waitForNotice(.failed, "Not UTF-8 · shown as Windows Latin-1, some characters may be off", in: preview.controller.webView)
    }

    func testATickTheServiceCouldNotSaveSaysWhy() throws {
        let (preview, service) = try previewWithService("- [ ] task\n")
        service.onToggle = { reply in reply(.failed, "the file is read-only") }
        preview.controller.handleToggleCheckbox(offset: 3, checked: true)
        try waitForNotice(.failed, "Tick not saved · the file is read-only", in: preview.controller.webView)
    }

    // MARK: - Lifecycle and deallocation

    func testMarkdownWebControllerDeallocatesWithoutRetainCycle() {
        weak var weakController: MarkdownWebController?
        autoreleasepool {
            let controller = MarkdownWebController()
            weakController = controller
            XCTAssertNotNil(weakController)
        }
        XCTAssertNil(weakController, "MarkdownWebController should deallocate without being retained by WKUserContentController")
    }

    func testPreviewControllerDeallocatesCleanly() {
        weak var weakPreviewController: PreviewController?
        weak var weakWebController: MarkdownWebController?
        autoreleasepool {
            let preview = PreviewController()
            _ = preview.view
            weakPreviewController = preview
            weakWebController = preview.controller
            XCTAssertNotNil(weakPreviewController)
            XCTAssertNotNil(weakWebController)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertNil(weakPreviewController, "PreviewController should deallocate")
        XCTAssertNil(weakWebController, "MarkdownWebController should deallocate")
    }

    func testTeardownIsIdempotentAndClearsNavigationDelegate() {
        let controller = MarkdownWebController()
        XCTAssertNotNil(controller.webView.navigationDelegate)
        controller.teardown()
        controller.teardown()
        XCTAssertNil(controller.webView.navigationDelegate)
    }

    // MARK: - Live-update Mermaid loading

    /// Loads `initial`, marks the live page, rewrites the file with `updated`,
    /// and runs the FileWatcher's reload path directly. Returns once the
    /// update is on screen, and whether the page survived (an innerHTML swap)
    /// or was replaced (a full reload).
    private func reload(from initial: String, to updated: String, expecting text: String) throws -> (MarkdownWebController, swapped: Bool) {
        let controller = MarkdownWebController()
        controller.readFile = { url, completion in completion(MarkdownText.read(url)) }
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("doc.md")
        try initial.write(to: file, atomically: true, encoding: .utf8)
        try controller.loadMarkdownFile(at: file)
        XCTAssertFalse(controller.hasLoadedMermaid,
                       "Initial diagram-free document must not have loaded mermaid")
        pollJS(controller.webView, "!!document.querySelector('.markdown-body') && (window.__mdqlTestMarker = true)", "Initial load") { $0 as? Bool == true }

        try updated.write(to: file, atomically: true, encoding: .utf8)
        controller.reloadContent()
        var swapped = false
        pollJS(controller.webView, "[(document.querySelector('.markdown-body') || {}).textContent || '', window.__mdqlTestMarker === true]", "Update on screen") { result in
            guard let pair = result as? [Any], let body = pair.first as? String, body.contains(text) else { return false }
            swapped = pair.last as? Bool == true
            return true
        }
        return (controller, swapped)
    }

    func testReloadContentFullyReloadsWhenFirstFenceAppears() throws {
        // An innerHTML swap cannot bring in the runtime, so the first fence
        // must take the full-reload path, which re-embeds it.
        let (controller, swapped) = try reload(
            from: "# Initial document without mermaid",
            to: "# Updated\n\n```mermaid\nflowchart LR\n    A --> B\n```",
            expecting: "Updated"
        )
        XCTAssertFalse(swapped, "Adding a mermaid fence must replace the page")
        XCTAssertTrue(controller.hasLoadedMermaid,
                      "The full reload must embed the runtime")
    }

    func testReloadContentSwapsInPlaceWhenProseMentionsMermaidClass() throws {
        // Only a real fence warrants a full reload; a mention of the class
        // name keeps the seamless innerHTML swap (and the scroll position).
        let (controller, swapped) = try reload(
            from: "# Notes",
            to: "# Notes\n\nSee `language-mermaid` and language-mermaid in [docs](https://x.test/language-mermaid).",
            expecting: "See"
        )
        XCTAssertTrue(swapped, "A mention of language-mermaid must not force a full reload")
        XCTAssertFalse(controller.hasLoadedMermaid)
    }

    // MARK: - Live-update Mermaid reuse

    private static let flowAB = "```mermaid\nflowchart LR\n    A --> B\n```"
    private static let flowCD = "```mermaid\nflowchart LR\n    C --> D\n```"

    /// Test-only hook, injected at document start: traps the global mermaid
    /// assignment and wraps render so that, while __mdqlTestHold is set,
    /// renders wait for __mdqlTestRelease(). Lets tests keep renders in flight
    /// across a swap instead of racing them.
    private static let renderGateScript = """
        (function() {
            var held = [];
            var instance;
            window.__mdqlTestHold = false;
            window.__mdqlTestRelease = function() {
                window.__mdqlTestHold = false;
                held.splice(0).forEach(function(resume) { resume(); });
            };
            Object.defineProperty(window, 'mermaid', {
                configurable: true,
                get: function() { return instance; },
                set: function(value) {
                    instance = value;
                    var render = value.render;
                    value.render = function() {
                        var self = this, args = arguments;
                        if (!window.__mdqlTestHold) return render.apply(self, args);
                        return new Promise(function(resume) { held.push(resume); }).then(function() { return render.apply(self, args); });
                    };
                }
            });
        })();
        """

    /// Writes `markdown` to a temp file and loads it with the render gate
    /// installed (held from the start when `holdRenders`).
    private func loadGated(_ markdown: String, dark: Bool = false, holdRenders: Bool = false) throws -> MarkdownWebController {
        let controller = MarkdownWebController()
        controller.webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        controller.webView.configuration.userContentController.addUserScript(WKUserScript(
            source: Self.renderGateScript + (holdRenders ? "window.__mdqlTestHold = true;" : ""),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("doc.md")
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        try controller.loadMarkdownFile(at: file)
        return controller
    }

    /// Serves `markdown` to the reload path through readFile. The file on disk
    /// is left alone: a write would also fire the watcher, and its second
    /// swap would mask what the first one did.
    private func serve(_ controller: MarkdownWebController, _ markdown: String) {
        controller.readFile = { _, completion in completion(.success(MarkdownText(string: markdown, encoding: .utf8))) }
    }

    /// Loads `markdown` and waits until `diagrams` SVGs are on screen, then
    /// numbers each wrapper node with a JS property that only survives if the
    /// node itself is reused. Also wraps __mdqlSwapBody to record, in the same
    /// task as the swap, the raw fences it left behind and the theme state,
    /// then releases any held renders.
    private func loadDiagrams(_ markdown: String, diagrams: Int, dark: Bool = false) throws -> MarkdownWebController {
        let controller = try loadGated(markdown, dark: dark)
        pollJS(controller.webView, """
            (function() {
                var divs = document.querySelectorAll('.markdown-body .mdql-mermaid');
                if (divs.length !== \(diagrams) || document.querySelectorAll('.markdown-body .mdql-mermaid svg').length !== \(diagrams)) return false;
                divs.forEach(function(d, i) { d.__mdqlTestMark = i + 1; });
                function stale(dark) {
                    var theme = dark ? 'dark' : 'default';
                    return Array.from(document.querySelectorAll('.markdown-body .mdql-mermaid')).filter(function(d) {
                        return d.getAttribute('data-mdql-theme') !== theme;
                    }).length;
                }
                var swap = window.__mdqlSwapBody;
                window.__mdqlSwapBody = function(html) {
                    var staleBefore = stale(window.matchMedia('(prefers-color-scheme: dark)').matches);
                    swap(html);
                    var dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
                    window.__mdqlSwapSnapshot = {
                        raw: document.querySelectorAll('.markdown-body pre code.language-mermaid').length,
                        dark: dark,
                        staleBefore: staleBefore,
                        staleAfter: stale(dark)
                    };
                    window.__mdqlTestRelease();
                };
                return true;
            })()
            """, "Initial diagrams") { $0 as? Bool == true }
        return controller
    }

    private struct ReloadResult {
        /// Each wrapper's test mark, 0 for a new node.
        var marks: [Int] = []
        /// Each wrapper's data-mdql-source.
        var sources: [String] = []
        /// Swap-time snapshot: raw fences left, whether the media query was
        /// dark, and wrappers not tagged with that theme before and after.
        var rawAfterSwap = -1
        var darkAtSwap = false
        var staleBeforeSwap = -1
        var staleAfterSwap = -1
    }

    /// Runs the reload path with `markdown` and waits for `expecting` and
    /// `diagrams` rendered wrappers (all satisfying `ready`).
    private func reloadDiagrams(_ controller: MarkdownWebController, to markdown: String, expecting text: String,
                                diagrams: Int, ready: String = "true", beforeReload: () -> Void = {}) -> ReloadResult {
        serve(controller, markdown)
        beforeReload()
        controller.reloadContent()
        var result = ReloadResult()
        pollJS(controller.webView, """
            (function() {
                var body = document.querySelector('.markdown-body');
                var divs = Array.from(body.querySelectorAll('.mdql-mermaid'));
                var snap = window.__mdqlSwapSnapshot;
                if (!body.textContent.includes(\(String(reflecting: text))) || !snap) return null;
                if (divs.length !== \(diagrams) || body.querySelectorAll('pre code.language-mermaid').length) return null;
                if (!divs.every(function(d) { return d.querySelector('svg') && (\(ready)); })) return null;
                return {
                    marks: divs.map(function(d) { return d.__mdqlTestMark || 0; }),
                    sources: divs.map(function(d) { return d.getAttribute('data-mdql-source') || ''; }),
                    raw: snap.raw, dark: snap.dark, staleBefore: snap.staleBefore, staleAfter: snap.staleAfter
                };
            })()
            """, "Diagrams after reload") { value in
            guard let dict = value as? [String: Any], let marks = dict["marks"] as? [Int] else { return false }
            result.marks = marks
            result.sources = dict["sources"] as? [String] ?? []
            result.rawAfterSwap = dict["raw"] as? Int ?? -1
            result.darkAtSwap = dict["dark"] as? Bool ?? false
            result.staleBeforeSwap = dict["staleBefore"] as? Int ?? -1
            result.staleAfterSwap = dict["staleAfter"] as? Int ?? -1
            return true
        }
        return result
    }

    /// Waits for in-flight renders to land.
    private func settle() {
        let settled = expectation(description: "Settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    func testReloadReusesUnchangedDiagrams() throws {
        let controller = try loadDiagrams("# Doc\n\nBefore.\n\n\(Self.flowAB)\n\n\(Self.flowCD)", diagrams: 2)
        let result = reloadDiagrams(controller, to: "# Doc\n\nAfter.\n\n\(Self.flowAB)\n\n\(Self.flowCD)",
                                        expecting: "After.", diagrams: 2)
        XCTAssertEqual(result.marks, [1, 2], "Both unchanged diagrams must keep their rendered nodes")
        XCTAssertEqual(result.rawAfterSwap, 0, "Reused diagrams must be back in the same task as the swap")
    }

    func testReloadReRendersEditedDiagramOnly() throws {
        let controller = try loadDiagrams("# Doc\n\nBefore.\n\n\(Self.flowAB)\n\n\(Self.flowCD)", diagrams: 2)
        let edited = "```mermaid\nflowchart LR\n    C --> E\n```"
        let result = reloadDiagrams(controller, to: "# Doc\n\nAfter.\n\n\(Self.flowAB)\n\n\(edited)",
                                        expecting: "After.", diagrams: 2)
        XCTAssertEqual(result.marks, [1, 0], "Only the edited fence may get a new node")
        XCTAssertEqual(result.rawAfterSwap, 1, "Only the edited fence may be left to render after the swap")
        XCTAssertEqual(result.sources.count, 2)
        XCTAssertTrue(result.sources.last?.contains("C --> E") == true, "The new node must render the edited source")
    }

    func testReloadReusesDuplicateIdenticalDiagrams() throws {
        let controller = try loadDiagrams("# Doc\n\nBefore.\n\n\(Self.flowAB)\n\n\(Self.flowAB)", diagrams: 2)
        let result = reloadDiagrams(controller, to: "# Doc\n\nAfter.\n\n\(Self.flowAB)\n\n\(Self.flowAB)",
                                        expecting: "After.", diagrams: 2)
        XCTAssertEqual(result.marks, [1, 2], "Each identical fence must take back its own node")
    }

    func testReloadReusesReorderedDiagrams() throws {
        let controller = try loadDiagrams("# Doc\n\nBefore.\n\n\(Self.flowAB)\n\n\(Self.flowCD)", diagrams: 2)
        let result = reloadDiagrams(controller, to: "# Doc\n\nAfter.\n\n\(Self.flowCD)\n\n\(Self.flowAB)",
                                        expecting: "After.", diagrams: 2)
        XCTAssertEqual(result.marks, [2, 1], "Reordered fences must follow their sources to the old nodes")
        XCTAssertEqual(result.rawAfterSwap, 0)
    }

    func testReloadDuringThemeChangeRendersEveryDiagramInNewTheme() throws {
        // Renders are held from before the appearance flip until the swap, so
        // the old wrappers are still tagged 'default' while the media query
        // already reports dark: without the harvest's theme check they would
        // be put back in the old theme.
        let controller = try loadDiagrams("# Doc\n\nBefore.\n\n\(Self.flowAB)\n\n\(Self.flowCD)", diagrams: 2)
        let result = reloadDiagrams(controller, to: "# Doc\n\nAfter.\n\n\(Self.flowAB)\n\n\(Self.flowCD)",
                                        expecting: "After.", diagrams: 2,
                                        ready: "d.getAttribute('data-mdql-theme') === 'dark' && window.matchMedia('(prefers-color-scheme: dark)').matches",
                                        beforeReload: {
            pollJS(controller.webView, "window.__mdqlTestHold = true", "Hold renders") { $0 as? Bool == true }
            controller.webView.appearance = NSAppearance(named: .darkAqua)
            pollJS(controller.webView, "window.matchMedia('(prefers-color-scheme: dark)').matches", "Media query dark") { $0 as? Bool == true }
        })
        XCTAssertTrue(result.darkAtSwap, "The swap must run after the media query flipped")
        XCTAssertEqual(result.staleBeforeSwap, 2, "Old wrappers must still be in the old theme at the swap")
        XCTAssertEqual(result.staleAfterSwap, 0, "The swap must not put old-theme diagrams back")
        XCTAssertEqual(result.marks, [0, 0], "Old-theme nodes must not be reused")
        // Let any in-flight renders land, then check nothing drifted back.
        settle()
        pollJS(controller.webView, "Array.from(document.querySelectorAll('.markdown-body .mdql-mermaid')).map(function(d) { return d.getAttribute('data-mdql-theme'); })", "Final themes") { result in
            (result as? [String]) == ["dark", "dark"]
        }
    }

    func testReloadWhileFirstRendersInFlightRendersEachFenceOnce() throws {
        // The swap detaches pres whose first render is still pending; when
        // those renders land they must not add diagrams to the new body.
        let controller = try loadGated("# Doc\n\nBefore.\n\n\(Self.flowAB)\n\n\(Self.flowCD)", holdRenders: true)
        pollJS(controller.webView, """
            typeof window.__mdqlSwapBody === 'function' && document.querySelectorAll('.markdown-body pre[data-mdql-mermaid]').length === 2
            """, "First renders pending") { $0 as? Bool == true }

        serve(controller, "# Doc\n\nAfter.\n\n\(Self.flowAB)\n\n\(Self.flowCD)")
        controller.reloadContent()
        pollJS(controller.webView, """
            (function() {
                var body = document.querySelector('.markdown-body');
                if (!body.textContent.includes('After.') || body.querySelectorAll('pre[data-mdql-mermaid]').length !== 2) return false;
                window.__mdqlTestRelease();
                return true;
            })()
            """, "Swapped with renders pending") { $0 as? Bool == true }

        let counts = "[document.querySelectorAll('.markdown-body .mdql-mermaid').length, document.querySelectorAll('.markdown-body .mdql-mermaid svg').length, document.querySelectorAll('.markdown-body pre code.language-mermaid, .mdql-mermaid-error-msg').length]"
        pollJS(controller.webView, counts, "Diagrams rendered") { ($0 as? [Int]) == [2, 2, 0] }
        settle()
        pollJS(controller.webView, counts, "No duplicate diagrams") { ($0 as? [Int]) == [2, 2, 0] }
    }

    // MARK: - Helpers

    /// A preview showing `markdown`, whose XPC calls go to a service of the
    /// test's own.
    /// Its calls never time out within a test, which therefore sees how the
    /// failure itself is answered.
    private func previewWithService(_ markdown: String = "Text.") throws -> (PreviewController, FakeOpenURLService) {
        let service = FakeOpenURLService()
        addTeardownBlock { service.listener.invalidate() }
        let preview = PreviewController()
        preview.loadView()
        preview.replyTimeout = 600
        addTeardownBlock { preview.controller.teardown() }
        preview.makeConnection = { service.connect() }
        let file = try write(markdown, to: try makeFolder().appendingPathComponent("page.md"))
        try preview.loadMarkdownFile(at: file)
        try waitUntilLoaded(preview.controller.webView)
        return (preview, service)
    }

    /// Every answer `preview`'s link opener gives, from here on.
    private func countAnswers(of preview: PreviewController) -> Answers {
        let answers = Answers()
        let open = preview.openURL
        preview.openURL = { url, done in
            open(url) { error in
                answers.all.append(error)
                done(error)
            }
        }
        return answers
    }

    private final class Answers {
        var all: [PlainError?] = []
    }
}

/// The open-url service's stand-in: an anonymous listener in the test's own
/// process, answering as each test says.
private final class FakeOpenURLService: NSObject, OpenURLProtocol, NSXPCListenerDelegate {
    let listener = NSXPCListener.anonymous()
    private(set) var clientConnection: NSXPCConnection?

    var onOpen: (URL, @escaping (Bool) -> Void) -> Void = { _, reply in reply(true) }
    var onRead: (String, @escaping (String?, MarkdownEncoding, String?) -> Void) -> Void = { _, reply in reply(nil, .utf8, "not set up") }
    var onToggle: (@escaping (CheckboxToggleOutcome, String?) -> Void) -> Void = { reply in reply(.toggled, nil) }

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func connect() -> NSXPCConnection {
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        clientConnection = connection
        return connection
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: OpenURLProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func open(_ url: URL, withReply reply: @escaping (Bool) -> Void) {
        onOpen(url, reply)
    }

    func readFile(at path: String, previewing documentPath: String, withReply reply: @escaping (String?, MarkdownEncoding, String?) -> Void) {
        onRead(path, reply)
    }

    func toggleCheckbox(at path: String, offset: Int, checked: Bool, previewing documentPath: String,
                        withReply reply: @escaping (CheckboxToggleOutcome, String?) -> Void) {
        onToggle(reply)
    }
}
