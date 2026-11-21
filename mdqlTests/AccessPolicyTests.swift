import XCTest

/// The rules every host and the XPC service apply to what a previewed
/// document asks for.
final class AccessPolicyTests: XCTestCase {

    // MARK: - Opening URLs

    func testAllowedSchemesOpen() throws {
        for string in ["http://example.com/", "https://example.com/a?b=c", "mailto:someone@example.com", "HTTPS://example.com/"] {
            XCTAssertNoThrow(try AccessPolicy.checkOpening(XCTUnwrap(URL(string: string))), string)
        }
    }

    func testOtherSchemesAreRefused() throws {
        for string in refusedURLs {
            XCTAssertThrowsError(try AccessPolicy.checkOpening(XCTUnwrap(URL(string: string))), string)
        }
    }

    func testOpenCallsTheOpenerOnlyForAllowedSchemes() throws {
        var opened: [String] = []
        let opener: (URL) -> Bool = { opened.append($0.absoluteString); return true }

        for string in refusedURLs {
            XCTAssertFalse(AccessPolicy.open(try XCTUnwrap(URL(string: string)), with: opener), string)
        }
        XCTAssertTrue(AccessPolicy.open(try XCTUnwrap(URL(string: "https://example.com/")), with: opener))
        XCTAssertEqual(opened, ["https://example.com/"])
    }

    // MARK: - Files a preview may read or write

    func testTheDocumentItselfIsAllowedWhateverItsExtension() throws {
        let folder = try makeFolder()
        let document = try write("# Notes", to: folder.appendingPathComponent("notes.mdown"))
        XCTAssertEqual(try AccessPolicy.file(document, previewing: document).path, try realPath(document))
    }

    func testSiblingAndSubfolderMarkdownFilesAreAllowed() throws {
        let folder = try makeFolder()
        let document = try write("# One", to: folder.appendingPathComponent("one.md"))
        let sibling = try write("# Two", to: folder.appendingPathComponent("two.markdown"))
        let nested = try write("# Deep", to: folder.appendingPathComponent("sub/deep.md"))

        XCTAssertEqual(try AccessPolicy.file(sibling, previewing: document).path, try realPath(sibling))
        XCTAssertEqual(try AccessPolicy.file(nested, previewing: document).path, try realPath(nested))
    }

    func testAMarkdownFileOutsideTheFolderIsRefused() throws {
        let root = try makeFolder()
        let document = try write("# One", to: root.appendingPathComponent("docs/one.md"))
        let outside = try write("secret", to: root.appendingPathComponent("private.md"))

        XCTAssertThrowsError(try AccessPolicy.file(outside, previewing: document))
        XCTAssertThrowsError(try AccessPolicy.file(URL(fileURLWithPath: outside.path), previewing: document),
                             "An absolute path outside the folder")
    }

    func testADotDotEscapeIsRefused() throws {
        let root = try makeFolder()
        let document = try write("# One", to: root.appendingPathComponent("docs/one.md"))
        _ = try write("secret", to: root.appendingPathComponent("private.md"))
        let escape = URL(fileURLWithPath: root.path + "/docs/../private.md")

        XCTAssertThrowsError(try AccessPolicy.file(escape, previewing: document))
    }

    func testAFolderWhoseNameStartsLikeTheDocumentsFolderIsRefused() throws {
        let root = try makeFolder()
        let document = try write("# One", to: root.appendingPathComponent("docs/one.md"))
        let lookalike = try write("secret", to: root.appendingPathComponent("docs-private/two.md"))

        XCTAssertThrowsError(try AccessPolicy.file(lookalike, previewing: document))
    }

    func testASymlinkPointingOutsideIsRefused() throws {
        let root = try makeFolder()
        let document = try write("# One", to: root.appendingPathComponent("docs/one.md"))
        let outside = try write("secret", to: root.appendingPathComponent("private.md"))
        let link = root.appendingPathComponent("docs/link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try AccessPolicy.file(link, previewing: document))
    }

    func testANonMarkdownFileIsRefused() throws {
        let folder = try makeFolder()
        let document = try write("# One", to: folder.appendingPathComponent("one.md"))
        let text = try write("plain", to: folder.appendingPathComponent("notes.txt"))
        let disguised = folder.appendingPathComponent("disguised.md")
        try FileManager.default.createSymbolicLink(at: disguised, withDestinationURL: text)

        XCTAssertThrowsError(try AccessPolicy.file(text, previewing: document))
        XCTAssertThrowsError(try AccessPolicy.file(disguised, previewing: document),
                             "A .md symlink to a .txt reads the .txt")
    }

    func testAFolderNamedLikeMarkdownIsRefused() throws {
        let folder = try makeFolder()
        let document = try write("# One", to: folder.appendingPathComponent("one.md"))
        let directory = folder.appendingPathComponent("chapter.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try AccessPolicy.file(directory, previewing: document))
    }

    func testAMissingFileIsRefused() throws {
        let folder = try makeFolder()
        let document = try write("# One", to: folder.appendingPathComponent("one.md"))
        XCTAssertThrowsError(try AccessPolicy.file(folder.appendingPathComponent("gone.md"), previewing: document))
    }
}

/// URLs a document's link may not open.
let refusedURLs = [
    "file:///System/Applications/Calculator.app",
    "smb://server/share",
    "javascript:alert(1)",
    "x-custom-app://do/something",
    "ftp://example.com/file",
]

// MARK: - Shared file helpers

extension XCTestCase {
    /// A fresh folder of the test's own, removed when it ends.
    func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Writes `contents` to `url`, creating its folder, and returns `url`.
    @discardableResult
    func write(_ contents: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// `Fixtures/<name>.md`: from the test bundle when it carries it, else
    /// beside this source file.
    func fixtureURL(_ name: String) -> URL {
        let bundle = Bundle(for: type(of: self))
        return bundle.url(forResource: name, withExtension: "md", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("\(name).md")
    }

    func realPath(_ url: URL) throws -> String {
        let resolved = try XCTUnwrap(realpath(url.path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
