import XCTest
import Cocoa
import WebKit

final class DocumentWindowControllerTests: XCTestCase {

    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeMarkdownFile(named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Loads `file` the way `MarkdownDocument` does: read, then handed over.
    private func load(_ file: URL, into controller: DocumentWindowController) throws {
        controller.load(try String(contentsOf: file, encoding: .utf8), readFrom: file)
    }

    func testTitleIsTheFileNameWithItsExtension() throws {
        let dir = try makeTemporaryDirectory()
        let file = try makeMarkdownFile(named: "notes.md", in: dir)

        let controller = DocumentWindowController()
        try load(file, into: controller)

        XCTAssertEqual(controller.window?.title, "notes.md")
    }

    func testRepresentedURLPointsAtTheLoadedFile() throws {
        // The titlebar's Finder-style path menu — right- or ⌘-click the file
        // name to walk the folders up to the volume — is drawn by AppKit and
        // exists only while representedURL is set. Clearing it, as the window
        // used to, silently removes the menu.
        let dir = try makeTemporaryDirectory()
        let file = try makeMarkdownFile(named: "notes.md", in: dir)

        let controller = DocumentWindowController()
        try load(file, into: controller)

        XCTAssertEqual(controller.window?.representedURL?.resolvingSymlinksInPath(),
                       file.resolvingSymlinksInPath(),
                       "Without representedURL the title has no path menu to show")
    }

    func testTitleAndPathMenuFollowTheFileOnScreen() throws {
        // Regression: the window used to title itself once, at load, so any
        // later change of file left the name — and now the path menu — naming
        // a file that is no longer on screen.
        let dir = try makeTemporaryDirectory()
        let first = try makeMarkdownFile(named: "one.md", in: dir)
        let second = try makeMarkdownFile(named: "two.md", in: dir)

        let controller = DocumentWindowController()
        try load(first, into: controller)
        try load(second, into: controller)

        XCTAssertEqual(controller.window?.title, "two.md")
        XCTAssertEqual(controller.window?.representedURL?.resolvingSymlinksInPath(),
                       second.resolvingSymlinksInPath())
    }

    func testTheBackButtonAndNoticesSitBelowTheTitlebar() throws {
        // The back button sat at 12 px from the top, under the traffic lights.
        let dir = try makeTemporaryDirectory()
        let file = try makeMarkdownFile(named: "one.md", in: dir)
        try "# Two\n".write(to: dir.appendingPathComponent("two.md"), atomically: true, encoding: .utf8)
        try "[Two](two.md)\n".write(to: file, atomically: true, encoding: .utf8)
        let controller = DocumentWindowController()
        addTeardownBlock { controller.controller.teardown() }
        try load(file, into: controller)
        let window = try XCTUnwrap(controller.window)
        let page = controller.controller.webView
        try waitUntilLoaded(page)

        let titlebar = DocumentWindowController.titlebarHeight(of: window)
        XCTAssertGreaterThan(titlebar, 0, "The window's titlebar reaches over its full-size content")
        XCTAssertEqual(controller.controller.topInset, titlebar)

        try evaluate("document.querySelector('a').click(); true", in: page)
        try waitUntil("!!document.getElementById('mdql-back') && document.readyState === 'complete'", in: page)
        let backTop = try XCTUnwrap(evaluate("document.getElementById('mdql-back').getBoundingClientRect().top", in: page) as? Double)
        XCTAssertEqual(backTop, Double(titlebar) + 20, accuracy: 0.5, "20 px below the titlebar's bottom edge")

        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let closeInWindow = close.convert(close.bounds, to: nil)
        XCTAssertGreaterThan(backTop, Double(window.frame.height - closeInWindow.minY),
                             "The back button must sit below the traffic lights, not under them")
    }

    func testDocumentWindowControllerDeallocatesCleanly() {
        weak var weakWindowController: DocumentWindowController?
        weak var weakWebController: MarkdownWebController?
        autoreleasepool {
            let controller = DocumentWindowController()
            weakWindowController = controller
            weakWebController = controller.controller
            XCTAssertNotNil(weakWindowController)
            XCTAssertNotNil(weakWebController)
        }
        XCTAssertNil(weakWindowController, "DocumentWindowController should deallocate")
        XCTAssertNil(weakWebController, "MarkdownWebController should deallocate when DocumentWindowController deallocates")
    }
}
