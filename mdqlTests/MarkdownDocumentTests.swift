import XCTest
import Cocoa
import WebKit

final class MarkdownDocumentTests: XCTestCase {

    private static let markdownType = "net.daringfireball.markdown"

    private func makeFile(named name: String, contents: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    func testOpeningAFileThatCannotBeReadFailsWithTheReadError() throws {
        // Regression: the window controller's load error was dropped with
        // `try?`, so a file it could not read opened as a blank window and
        // said nothing.
        let file = try makeFile(named: "locked.md", contents: Data("# Locked\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        var readError: NSError?
        XCTAssertThrowsError(try Data(contentsOf: file)) { readError = $0 as NSError }

        XCTAssertThrowsError(try MarkdownDocument(contentsOf: file, ofType: Self.markdownType)) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, readError?.domain, "The open must fail with the read error; got \(error)")
            XCTAssertEqual(error.code, readError?.code, "The open must fail with the read error; got \(error)")
        }
    }

    func testAWindowsLatin1FileOpensWithTheRightCharacters() throws {
        let file = try makeFile(named: "menu.md", contents: try Data(contentsOf: fixtureURL("windows-1252")))

        let document = try MarkdownDocument(contentsOf: file, ofType: Self.markdownType)
        document.makeWindowControllers()
        let windowController = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        addTeardownBlock { windowController.controller.teardown() }
        let page = windowController.controller.webView
        try waitUntilLoaded(page)

        XCTAssertEqual(windowController.controller.encoding, .windowsLatin1)
        let visible = try visibleText(of: page)
        XCTAssertTrue(visible.contains("Café du Marché"), visible)
        XCTAssertTrue(visible.contains("The crème brûlée costs 5 € and the müesli is über good."), visible)
        try waitForNotice(.failed, "Not UTF-8 · shown as Windows Latin-1, some characters may be off", in: page)
        XCTAssertEqual(try evaluate("document.querySelectorAll('input[type=checkbox][data-cb-offset]').length", in: page) as? Int, 0,
                       "Its checkboxes aren't clickable")
    }

    // MARK: - How every reader in mdql decodes a file

    func testDecodingPrefersUTF8ThenWindowsLatin1() throws {
        XCTAssertEqual(MarkdownText(data: Data("Café €".utf8)).encoding, .utf8)
        XCTAssertEqual(MarkdownText(data: Data("Café €".utf8)).string, "Café €")

        let windows = MarkdownText(data: try Data(contentsOf: fixtureURL("windows-1252")))
        XCTAssertEqual(windows.encoding, .windowsLatin1)
        XCTAssertTrue(windows.string.contains("The crème brûlée costs 5 € and the müesli is über good."), windows.string)
    }

    func testDecodingHonorsAByteOrderMark() throws {
        let utf16 = MarkdownText(data: try Data(contentsOf: fixtureURL("utf16-bom")))
        XCTAssertEqual(utf16.encoding, .utf16)
        XCTAssertTrue(utf16.string.hasPrefix("# Grüße aus Köln\n"), utf16.string)

        let utf8 = MarkdownText(data: Data([0xEF, 0xBB, 0xBF] + Array("# Grüße".utf8)))
        XCTAssertEqual(utf8.encoding, .utf8)
        XCTAssertEqual(utf8.string, "# Grüße", "The mark is dropped, as CheckboxToggle expects")
    }

    func testDecodingFallsBackToISOLatin1ForAnyBytes() {
        // 0x81 is not a character in Windows Latin-1.
        let text = MarkdownText(data: Data([0x43, 0x61, 0x66, 0xE9, 0x81]))
        XCTAssertEqual(text.encoding, .isoLatin1)
        XCTAssertEqual(text.string, "Caf\u{E9}\u{81}")
    }

    func testOpenedDocumentShowsTheFileItRead() throws {
        let file = try makeFile(named: "notes.md", contents: Data("# Notes\n".utf8))

        let document = try MarkdownDocument(contentsOf: file, ofType: Self.markdownType)
        document.makeWindowControllers()
        let windowController = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        addTeardownBlock { windowController.controller.teardown() }

        XCTAssertEqual(windowController.controller.fileURL?.resolvingSymlinksInPath(),
                       file.resolvingSymlinksInPath(),
                       "The window must render the file the document read")
    }
}
