import Foundation
import os

/// What a previewed document may make mdql do: which URLs it may open, and
/// which files it may read or write. A document is untrusted (a downloaded
/// `.md` previewed in Finder), so the renderer drops the link and image URLs
/// it may not carry, `MarkdownWebController` and the viewer refuse what it may
/// not open or read, and the unsandboxed XPC service checks every request
/// again, as the boundary.
///
/// A refused action does nothing beyond a line in this log:
/// `log show --predicate 'subsystem == "com.mdql.app" && category == "access"'`.
enum AccessPolicy {

    static let log = Logger(subsystem: "com.mdql.app", category: "access")

    /// The only schemes a link may open, and the only ones a link or an
    /// image may carry into the page. Relative URLs carry none.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    struct Refusal: Error, CustomStringConvertible {
        let description: String
    }

    /// Throws why `url` may not be opened, if it may not.
    static func checkOpening(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased() else {
            throw Refusal(description: "it has no scheme")
        }
        guard allowedSchemes.contains(scheme) else {
            throw Refusal(description: "\(scheme): is not one of http, https, mailto")
        }
    }

    /// Opens `url` with `opener` if it may be opened, else logs why not.
    /// Returns whether it opened.
    static func open(_ url: URL, with opener: (URL) -> Bool) -> Bool {
        do {
            try checkOpening(url)
        } catch {
            log.error("Refused to open \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
        return opener(url)
    }

    /// The file at `url`, symlinks resolved, if the preview of `document` may
    /// read or write it: `document` itself, or a regular `.md` / `.markdown`
    /// file whose real path lies under `document`'s folder. Throws why not
    /// otherwise.
    static func file(_ url: URL, previewing document: URL) throws -> URL {
        let documentPath = try realPath(document.path)
        let path = try realPath(url.path)
        if path == documentPath { return URL(fileURLWithPath: path) }

        let folder = try realPath(document.deletingLastPathComponent().path)
        guard path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") else {
            throw Refusal(description: "\(path) is outside \(folder), the previewed document's folder")
        }
        guard ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()) else {
            throw Refusal(description: "\(path) is not a .md or .markdown file")
        }
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw Refusal(description: "\(path) is not a regular file")
        }
        return URL(fileURLWithPath: path)
    }

    private static func realPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw Refusal(description: "\(path): \(String(cString: strerror(errno)))")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
