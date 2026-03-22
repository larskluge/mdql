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

        controller.handleOpenURL("https://example.com", background: false)

        waitForExpectations(timeout: 1)
        XCTAssertEqual(receivedURL?.absoluteString, "https://example.com")
    }

    func testOpenURLWithBackgroundFlag() {
        let controller = PreviewController()
        controller.loadView()

        let expectation = expectation(description: "openURL callback invoked")
        var receivedURL: URL?

        controller.openURL = { url in
            receivedURL = url
            expectation.fulfill()
        }

        controller.handleOpenURL("https://example.com/bg", background: true)

        waitForExpectations(timeout: 1)
        XCTAssertEqual(receivedURL?.absoluteString, "https://example.com/bg")
    }

    func testOpenURLIgnoresEmptyString() {
        let controller = PreviewController()
        controller.loadView()

        var callbackInvoked = false
        controller.openURL = { _ in
            callbackInvoked = true
        }

        controller.handleOpenURL("", background: false)

        XCTAssertFalse(callbackInvoked, "Should not invoke callback for empty URL")
    }

    func testOpenURLHandlesVariousSchemes() {
        let controller = PreviewController()
        controller.loadView()

        var receivedURLs: [URL] = []
        controller.openURL = { url in
            receivedURLs.append(url)
        }

        controller.handleOpenURL("https://example.com", background: false)
        controller.handleOpenURL("http://example.com", background: false)

        XCTAssertEqual(receivedURLs.count, 2, "Should handle both http and https URLs")
        XCTAssertEqual(receivedURLs[0].scheme, "https")
        XCTAssertEqual(receivedURLs[1].scheme, "http")
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

    func testRenderedHTMLContainsStatusBar() {
        let html = MarkdownRenderer.render(markdown: "test", title: "t")
        XCTAssertTrue(html.contains("id=\"mdql-status\""), "HTML must contain status bar element")
    }

    func testRenderedHTMLContainsHoverHandlers() {
        let html = MarkdownRenderer.render(markdown: "test", title: "t")
        XCTAssertTrue(html.contains("mouseover"), "HTML must contain mouseover handler")
        XCTAssertTrue(html.contains("mouseout"), "HTML must contain mouseout handler")
    }

    // MARK: - openMarkdown handler

    func testHandleOpenMarkdownLoadsExistingFile() throws {
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

        // Set current file to file1
        controller.preparePreviewOfFile(at: file1) { _ in }

        // Navigate to file2
        controller.handleOpenMarkdown("two.md")

        // fileURL should now be file2
        XCTAssertEqual(controller.fileURL?.lastPathComponent, "two.md")
    }

    func testHandleOpenMarkdownIgnoresNonExistentFile() {
        let controller = PreviewController()
        controller.loadView()

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file1 = tmpDir.appendingPathComponent("one.md")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try? "# One".write(to: file1, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        controller.preparePreviewOfFile(at: file1) { _ in }
        controller.handleOpenMarkdown("nonexistent.md")

        XCTAssertEqual(controller.fileURL?.lastPathComponent, "one.md",
                       "Should not change fileURL for nonexistent file")
    }

    func testHandleOpenMarkdownIgnoresNonMdExtension() {
        let controller = PreviewController()
        controller.loadView()

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file1 = tmpDir.appendingPathComponent("one.md")
        let txtFile = tmpDir.appendingPathComponent("notes.txt")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try? "# One".write(to: file1, atomically: true, encoding: .utf8)
        try? "hello".write(to: txtFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        controller.preparePreviewOfFile(at: file1) { _ in }
        controller.handleOpenMarkdown("notes.txt")

        XCTAssertEqual(controller.fileURL?.lastPathComponent, "one.md",
                       "Should not navigate to non-markdown files")
    }

    func testHandleOpenMarkdownIgnoresHttpUrls() {
        let controller = PreviewController()
        controller.loadView()

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file1 = tmpDir.appendingPathComponent("one.md")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try? "# One".write(to: file1, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        controller.preparePreviewOfFile(at: file1) { _ in }
        controller.handleOpenMarkdown("https://example.com/readme.md")

        XCTAssertEqual(controller.fileURL?.lastPathComponent, "one.md",
                       "Should not navigate to HTTP URLs")
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
}
