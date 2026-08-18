import XCTest
import Cocoa

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

    func testTitleIsTheFileNameWithItsExtension() throws {
        let dir = try makeTemporaryDirectory()
        let file = try makeMarkdownFile(named: "notes.md", in: dir)

        let controller = DocumentWindowController()
        try controller.load(fileAt: file)

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
        try controller.load(fileAt: file)

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
        try controller.load(fileAt: first)
        try controller.load(fileAt: second)

        XCTAssertEqual(controller.window?.title, "two.md")
        XCTAssertEqual(controller.window?.representedURL?.resolvingSymlinksInPath(),
                       second.resolvingSymlinksInPath())
    }
}
