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
