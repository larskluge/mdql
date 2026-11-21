import Foundation
import os

/// What a previewed document may make mdql do: which URLs it may open, and
/// which files it may read or write. A document is untrusted (a downloaded
/// `.md` previewed in Finder), so the renderer drops the link and image URLs
/// it may not carry, `MarkdownWebController` and the viewer refuse what it may
/// not open or read, and the unsandboxed XPC service checks every request
/// again, as the boundary.
///
/// A refused action does nothing but say so: a grey notice on the page, in
/// `Refusal.plainReason(naming:)`'s words, and a line in this log:
/// `log show --predicate 'subsystem == "com.mdql.app" && category == "access"'`.
enum AccessPolicy {

    static let log = Logger(subsystem: "com.mdql.app", category: "access")

    /// The only schemes a link may open, and the only ones a link or an
    /// image may carry into the page. Relative URLs carry none.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    struct Refusal: Error, CustomStringConvertible {
        enum Kind: Equatable {
            case noScheme
            case scheme(String)
            case outsideFolder
            case notMarkdown
            case notRegularFile
            /// The path does not resolve: the file is missing, or mdql may not
            /// look at it. Not a refusal on purpose, but a file it cannot read.
            case unresolvable(errno: Int32)
        }

        let kind: Kind
        /// Why, for the log: the real paths involved.
        let description: String

        /// Why, in plain words for a notice, naming the link or file `name`
        /// as the document wrote it.
        func plainReason(naming name: String) -> String {
            switch kind {
            case .noScheme: return "\(name) isn't a web address"
            case .scheme(let scheme): return "\(scheme): links are off in mdql"
            case .outsideFolder: return "\(name) is outside this folder"
            case .notMarkdown: return "\(name) isn't a Markdown file"
            case .notRegularFile: return "\(name) isn't a regular file"
            case .unresolvable(let code): return PlainError(errno: code, reading: true).reason
            }
        }
    }

    /// Throws why `url` may not be opened, if it may not.
    static func checkOpening(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased() else {
            throw Refusal(kind: .noScheme, description: "it has no scheme")
        }
        guard allowedSchemes.contains(scheme) else {
            throw Refusal(kind: .scheme(scheme), description: "\(scheme): is not one of http, https, mailto")
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
            throw Refusal(kind: .outsideFolder, description: "\(path) is outside \(folder), the previewed document's folder")
        }
        guard ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()) else {
            throw Refusal(kind: .notMarkdown, description: "\(path) is not a .md or .markdown file")
        }
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw Refusal(kind: .notRegularFile, description: "\(path) is not a regular file")
        }
        return URL(fileURLWithPath: path)
    }

    private static func realPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            let code = errno
            throw Refusal(kind: .unresolvable(errno: code), description: "\(path): \(String(cString: strerror(code)))")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
