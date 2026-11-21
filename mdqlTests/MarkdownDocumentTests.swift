import XCTest
import Cocoa

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

    func testOpeningAFileThatIsNotUTF8FailsWithTheReadError() throws {
        // Regression: the window controller's load error was dropped with
        // `try?`, so a Latin-1 file opened as a blank window and said nothing.
        let file = try makeFile(named: "latin1.md", contents: try XCTUnwrap("# Café\n".data(using: .isoLatin1)))
        var readError: NSError?
        XCTAssertThrowsError(try String(contentsOf: file, encoding: .utf8)) { readError = $0 as NSError }

        XCTAssertThrowsError(try MarkdownDocument(contentsOf: file, ofType: Self.markdownType)) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, readError?.domain, "The open must fail with the read error; got \(error)")
            XCTAssertEqual(error.code, readError?.code, "The open must fail with the read error; got \(error)")
        }
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
