import Foundation
import Markdown

private class BundleAnchor {}

public struct MarkdownRenderer {

    public static func render(fileAt url: URL) throws -> String {
        let markdown = try String(contentsOf: url, encoding: .utf8)
        let title = url.deletingPathExtension().lastPathComponent
        return render(markdown: markdown, title: title)
    }

    public static func render(markdown: String, title: String = "") -> String {
        let (frontMatter, body) = parseFrontMatter(markdown)
        let document = Document(parsing: body, options: [.parseBlockDirectives])
        let html = HTMLFormatter.format(document)
        let frontMatterHTML = renderFrontMatter(frontMatter)
        return wrapInHTMLDocument(body: frontMatterHTML + html, title: title)
    }

    public static func renderBody(markdown: String) -> String {
        let (frontMatter, body) = parseFrontMatter(markdown)
        let document = Document(parsing: body, options: [.parseBlockDirectives])
        let frontMatterHTML = renderFrontMatter(frontMatter)
        return frontMatterHTML + HTMLFormatter.format(document)
    }

    // MARK: - Front Matter

    /// Parses YAML front matter from markdown. Returns (key-value pairs, remaining body).
    static func parseFrontMatter(_ markdown: String) -> ([(String, String)], String) {
        let trimmed = markdown.trimmingCharacters(in: .init(charactersIn: "\n"))
        guard trimmed.hasPrefix("---") else { return ([], markdown) }

        let lines = markdown.components(separatedBy: "\n")

        // Find the opening --- (allow leading blank lines)
        var openIndex: Int?
        for (i, line) in lines.enumerated() {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }
            if stripped == "---" {
                openIndex = i
                break
            } else {
                return ([], markdown)
            }
        }

        guard let open = openIndex else { return ([], markdown) }

        // Find the closing ---
        var closeIndex: Int?
        for i in (open + 1)..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closeIndex = i
                break
            }
        }

        guard let close = closeIndex else { return ([], markdown) }

        // Parse key: value pairs from between the delimiters
        var pairs: [(String, String)] = []
        for i in (open + 1)..<close {
            let line = lines[i]
            guard let colonRange = line.range(of: ":") else { continue }
            let key = line[line.startIndex..<colonRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[colonRange.upperBound...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                pairs.append((key, value))
            }
        }

        // Sort alphabetically by key
        pairs.sort { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

        // Body is everything after the closing ---
        let bodyLines = Array(lines[(close + 1)...])
        let body = bodyLines.joined(separator: "\n")

        return (pairs, body)
    }

    /// Renders front matter pairs as a single horizontal line of HTML.
    static func renderFrontMatter(_ pairs: [(String, String)]) -> String {
        guard !pairs.isEmpty else { return "" }
        let items = pairs.map { key, value in
            "<span class=\"fm-key\">\(escapeHTML(key)):</span> \(escapeHTML(value))"
        }
        return "<div class=\"front-matter\">\(items.joined(separator: " <span class=\"fm-sep\">·</span> "))</div>\n"
    }

    private static func wrapInHTMLDocument(body: String, title: String) -> String {
        let css = loadCSS()
        let escapedTitle = escapeHTML(title)
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapedTitle)</title>
        <style>
        \(css)
        </style>
        </head>
        <body>
        <article class="markdown-body">
        \(body)
        </article>
        </body>
        </html>
        """
    }

    private static func loadCSS() -> String {
        guard let url = Bundle(for: BundleAnchor.self).url(forResource: "preview", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return css
    }

    static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
