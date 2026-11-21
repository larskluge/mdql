import XCTest

/// The unsandboxed XPC service is the boundary: whatever the extension asks
/// for, it opens, reads and writes only what `AccessPolicy` allows.
final class OpenURLServiceTests: XCTestCase {

    // MARK: - open

    func testOpenRefusesSchemesOutsideTheAllowlist() throws {
        var opened: [URL] = []
        let service = OpenURLService(opener: { opened.append($0); return true })

        for string in refusedURLs {
            XCTAssertFalse(try reply { service.open(try XCTUnwrap(URL(string: string)), withReply: $0) }, string)
        }
        XCTAssertEqual(opened, [], "Nothing outside http, https and mailto may reach NSWorkspace")
    }

    func testOpenPassesAllowedSchemes() throws {
        var opened: [String] = []
        let service = OpenURLService(opener: { opened.append($0.absoluteString); return true })

        for string in ["https://example.com/", "http://example.com/", "mailto:someone@example.com"] {
            XCTAssertTrue(try reply { service.open(try XCTUnwrap(URL(string: string)), withReply: $0) }, string)
        }
        XCTAssertEqual(opened, ["https://example.com/", "http://example.com/", "mailto:someone@example.com"])
    }

    // MARK: - readFile

    func testReadFileReadsASiblingMarkdownFile() throws {
        let folder = try makeFolder()
        let document = try write("# One", to: folder.appendingPathComponent("one.md"))
        let sibling = try write("# Two", to: folder.appendingPathComponent("two.md"))

        let (content, error) = read(sibling, previewing: document)
        XCTAssertEqual(content, "# Two")
        XCTAssertNil(error)
    }

    func testReadFileRefusesWhatThePreviewMayNotRead() throws {
        let root = try makeFolder()
        let document = try write("# One", to: root.appendingPathComponent("docs/one.md"))
        let outside = try write("secret", to: root.appendingPathComponent("private.md"))
        let text = try write("plain", to: root.appendingPathComponent("docs/notes.txt"))
        let link = root.appendingPathComponent("docs/link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        for refused in [outside, URL(fileURLWithPath: root.path + "/docs/../private.md"), link, text] {
            let (content, error) = read(refused, previewing: document)
            XCTAssertNil(content, refused.path)
            XCTAssertNotNil(error, "A refusal says why: \(refused.path)")
        }
    }

    // MARK: - toggleCheckbox

    func testToggleCheckboxWritesThePreviewedDocument() throws {
        let folder = try makeFolder()
        let document = try write("- [ ] task\n", to: folder.appendingPathComponent("one.md"))

        XCTAssertTrue(try toggle(document, previewing: document))
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "- [x] task\n")
    }

    func testToggleCheckboxRefusesAnotherFile() throws {
        let root = try makeFolder()
        let document = try write("- [ ] task\n", to: root.appendingPathComponent("docs/one.md"))
        let outside = try write("- [ ] task\n", to: root.appendingPathComponent("private.md"))
        let text = try write("- [ ] task\n", to: root.appendingPathComponent("docs/notes.txt"))
        let link = root.appendingPathComponent("docs/link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        for refused in [outside, link, text] {
            XCTAssertFalse(try toggle(refused, previewing: document), refused.path)
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "- [ ] task\n")
        XCTAssertEqual(try String(contentsOf: text, encoding: .utf8), "- [ ] task\n")
    }

    // MARK: - Helpers

    private func read(_ url: URL, previewing document: URL) -> (String?, String?) {
        var result: (String?, String?) = (nil, nil)
        let done = expectation(description: "readFile replied")
        OpenURLService().readFile(at: url.path, previewing: document.path) { content, error in
            result = (content, error)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result
    }

    private func toggle(_ url: URL, previewing document: URL) throws -> Bool {
        try reply { OpenURLService().toggleCheckbox(at: url.path, index: 0, previewing: document.path, withReply: $0) }
    }

    private func reply(_ call: (@escaping (Bool) -> Void) throws -> Void) throws -> Bool {
        var result: Bool?
        let done = expectation(description: "replied")
        try call { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(result)
    }
}
