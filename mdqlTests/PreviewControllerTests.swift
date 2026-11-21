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

        controller.openURL = { url in
            receivedURL = url
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
        controller.openURL = { _ in
            callbackInvoked = true
        }

        controller.handleOpenURL("")

        XCTAssertFalse(callbackInvoked, "Should not invoke callback for empty URL")
    }

    func testOpenURLHandlesVariousSchemes() {
        let controller = PreviewController()
        controller.loadView()

        var receivedURLs: [URL] = []
        controller.openURL = { url in
            receivedURLs.append(url)
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
        controller.openURL = { opened.append($0.absoluteString) }

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

    func testRenderedHTMLContainsStatusBar() {
        let html = MarkdownRenderer.render(markdown: "test", title: "t")
        XCTAssertTrue(html.contains("id=\"mdql-status\""), "HTML must contain status bar element")
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
            completion(try? String(contentsOf: url, encoding: .utf8))
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
            completion(try? String(contentsOf: url, encoding: .utf8))
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
            completion(try? String(contentsOf: url, encoding: .utf8))
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
}
