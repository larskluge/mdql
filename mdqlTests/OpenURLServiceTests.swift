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

    func testReadFileDecodesAFileThatIsNotUTF8() throws {
        let folder = try makeFolder()
        let document = try write("# One", to: folder.appendingPathComponent("one.md"))
        let sibling = folder.appendingPathComponent("menu.md")
        try Data(contentsOf: fixtureURL("windows-1252")).write(to: sibling)

        var reply: (String?, MarkdownEncoding)?
        let done = expectation(description: "readFile replied")
        OpenURLService().readFile(at: sibling.path, previewing: document.path) { text, encoding, _ in
            reply = (text, encoding)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(reply?.1, .windowsLatin1)
        XCTAssertTrue(reply?.0?.contains("crème brûlée costs 5 €") == true, reply?.0 ?? "nil")
    }

    func testReadFileRefusalsSayWhyInPlainWords() throws {
        let root = try makeFolder()
        let document = try write("# One", to: root.appendingPathComponent("docs/one.md"))
        let outside = try write("secret", to: root.appendingPathComponent("private.md"))
        XCTAssertEqual(read(outside, previewing: document).1, "private.md is outside this folder")
        XCTAssertEqual(read(root.appendingPathComponent("docs/gone.md"), previewing: document).1, "file not found")
    }

    // MARK: - toggleCheckbox

    func testToggleCheckboxWritesThePreviewedDocument() throws {
        let folder = try makeFolder()
        let document = try write("- [ ] task\n", to: folder.appendingPathComponent("one.md"))

        XCTAssertTrue(try toggle(document, previewing: document))
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "- [x] task\n")
    }

    func testAToggleThatFailsSaysWhy() throws {
        let folder = try makeFolder()
        let document = try write("- [ ] task\n", to: folder.appendingPathComponent("one.md"))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: document.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: document.path) }

        var reply: (CheckboxToggleOutcome, String?)?
        let done = expectation(description: "toggleCheckbox replied")
        OpenURLService().toggleCheckbox(at: document.path, offset: 3, checked: true, previewing: document.path) { outcome, reason in
            reply = (outcome, reason)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(reply?.0, .failed)
        XCTAssertEqual(reply?.1, "the file is read-only")
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
        OpenURLService().readFile(at: url.path, previewing: document.path) { content, _, error in
            result = (content, error)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result
    }

    /// Checks the task `url` starts with, `- [ ] task`, whose marker is byte 3.
    private func toggle(_ url: URL, previewing document: URL) throws -> Bool {
        try reply { done in
            OpenURLService().toggleCheckbox(at: url.path, offset: 3, checked: true, previewing: document.path) { outcome, _ in done(outcome == .toggled) }
        }
    }

    private func reply(_ call: (@escaping (Bool) -> Void) throws -> Void) throws -> Bool {
        var result: Bool?
        let done = expectation(description: "replied")
        try call { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(result)
    }
}
