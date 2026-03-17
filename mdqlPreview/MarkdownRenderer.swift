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
        let document = Document(parsing: markdown, options: [.parseBlockDirectives])
        let html = HTMLFormatter.format(document)
        return wrapInHTMLDocument(body: html, title: title)
    }

    public static func renderBody(markdown: String) -> String {
        let document = Document(parsing: markdown, options: [.parseBlockDirectives])
        return HTMLFormatter.format(document)
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

    public static func renderForNativeText(fileAt url: URL) throws -> String {
        let markdown = try String(contentsOf: url, encoding: .utf8)
        let title = url.deletingPathExtension().lastPathComponent
        return renderForNativeText(markdown: markdown, title: title)
    }

    public static func renderForNativeText(markdown: String, title: String = "", darkMode: Bool = false) -> String {
        let document = Document(parsing: markdown, options: [.parseBlockDirectives])
        let body = HTMLFormatter.format(document)
        let escapedTitle = escapeHTML(title)

        let textColor = darkMode ? "#d4d0d2" : "#3f3b3d"
        let bgColor = darkMode ? "#1a1a1a" : "#f9f9f9"
        let linkColor = darkMode ? "#6cb0e0" : "#4183c4"
        let codeBg = darkMode ? "#2a2a2a" : "#f0f0f0"
        let borderColor = darkMode ? "#444" : "#ddd"
        let quoteColor = darkMode ? "#999" : "#666"

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>\(escapedTitle)</title>
        <style>
        body {
            font-family: -apple-system, Helvetica Neue, Helvetica, sans-serif;
            font-size: 15px;
            line-height: 1.6;
            color: \(textColor);
            background-color: \(bgColor);
            padding: 10px 20px;
        }
        h1 { font-size: 28px; font-weight: 700; margin: 0.8em 0 0.4em; }
        h2 { font-size: 22px; font-weight: 700; margin: 1.2em 0 0.4em; }
        h3 { font-size: 18px; font-weight: 700; margin: 1em 0 0.4em; }
        h4 { font-size: 16px; font-weight: 700; margin: 1em 0 0.4em; }
        p { margin: 0 0 0.8em; }
        a { color: \(linkColor); }
        strong { font-weight: 600; }
        code {
            font-family: Menlo, Consolas, monospace;
            font-size: 0.9em;
            background-color: \(codeBg);
            padding: 2px 5px;
        }
        pre {
            background-color: \(codeBg);
            padding: 12px;
            overflow-x: auto;
        }
        pre code { background: none; padding: 0; font-size: 0.85em; }
        blockquote {
            border-left: 3px solid \(borderColor);
            padding-left: 16px;
            margin-left: 0;
            color: \(quoteColor);
            font-style: italic;
        }
        ul, ol { padding-left: 1.8em; }
        li { margin-bottom: 0.2em; }
        table { border-collapse: collapse; width: 100%; margin: 0 0 1em; }
        th, td { border: 1px solid \(borderColor); padding: 6px 10px; text-align: left; }
        th { font-weight: 600; }
        hr { border: none; border-top: 1px solid \(borderColor); margin: 1.5em 0; }
        del { text-decoration: line-through; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
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
