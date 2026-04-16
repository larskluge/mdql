import Cocoa
import Markdown
import WebKit

private class BundleAnchor {}

public struct MarkdownRenderer {

    /// Canonical preview size — used by QuickLook extension and screenshot tool.
    public static let previewSize = NSSize(width: 1060, height: 900)

    public static func render(fileAt url: URL) throws -> String {
        let markdown = try String(contentsOf: url, encoding: .utf8)
        let title = url.deletingPathExtension().lastPathComponent
        return render(markdown: markdown, title: title)
    }

    public static func render(markdown: String, title: String = "", showBackButton: Bool = false) -> String {
        let (frontMatter, body) = parseFrontMatter(markdown)
        let document = Document(parsing: body, options: [.parseBlockDirectives])
        let html = postProcessEscaping(HTMLFormatter.format(document))
        let frontMatterHTML = renderFrontMatter(frontMatter)
        return wrapInHTMLDocument(body: frontMatterHTML + html, title: title, showBackButton: showBackButton)
    }

    public static func renderBody(markdown: String) -> String {
        let (frontMatter, body) = parseFrontMatter(markdown)
        let document = Document(parsing: body, options: [.parseBlockDirectives])
        let frontMatterHTML = renderFrontMatter(frontMatter)
        return frontMatterHTML + postProcessEscaping(HTMLFormatter.format(document))
    }

    // MARK: - HTML Escaping
    // swift-markdown's HTMLFormatter interpolates user content raw in several places
    // (CodeBlock.code, InlineCode.code, Heading.plainText, Link.destination). We
    // post-process its output to close those holes. See docs/superpowers/specs/
    // 2026-04-17-html-escaping-fix-design.md.

    static func postProcessEscaping(_ html: String) -> String {
        var out = html
        out = replaceRegex(in: out, pattern: #"<code([^>]*)>([\s\S]*?)</code>"#) { groups in
            "<code\(groups[1])>\(escapeCodeContent(groups[2]))</code>"
        }
        out = replaceRegex(in: out, pattern: #"<h([1-6])>([\s\S]*?)</h\1>"#) { groups in
            "<h\(groups[1])>\(escapeCodeContent(groups[2]))</h\(groups[1])>"
        }
        out = replaceRegex(in: out, pattern: #"<a href="([^"]*)">"#) { groups in
            "<a href=\"\(escapeAttribute(groups[1]))\">"
        }
        return out
    }

    private static func escapeCodeContent(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replaceRegex(
        in input: String,
        pattern: String,
        with transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return input
        }
        let nsInput = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: nsInput.length))
        var out = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            if range.location > cursor {
                out += nsInput.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                let r = match.range(at: i)
                groups.append(r.location == NSNotFound ? "" : nsInput.substring(with: r))
            }
            out += transform(groups)
            cursor = range.location + range.length
        }
        if cursor < nsInput.length {
            out += nsInput.substring(with: NSRange(location: cursor, length: nsInput.length - cursor))
        }
        return out
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

    private static func wrapInHTMLDocument(body: String, title: String, showBackButton: Bool = false) -> String {
        let css = loadCSS()
        let version = loadVersion()
        let escapedTitle = escapeHTML(title)
        let backButtonHTML = showBackButton ? """
        <div id="mdql-back" onclick="window.webkit.messageHandlers.mdql.postMessage({action:'goBack'})"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"></polyline></svg></div>
        """ : ""
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapedTitle)</title>
        <style>
        \(css)
        @keyframes mdql-spin { to { transform: rotate(360deg); } }
        #mdql-loading {
            position: fixed; top: 50%; left: 50%;
            transform: translate(-50%, -50%);
            width: 24px; height: 24px;
            border: 2px solid var(--border-color, #ddd);
            border-top-color: var(--link-color, #4183c4);
            border-radius: 50%;
            animation: mdql-spin 0.6s linear infinite;
        }
        #mdql-back {
            position: fixed; top: 12px; left: 12px;
            width: 28px; height: 28px;
            display: flex; align-items: center; justify-content: center;
            border-radius: 6px;
            background: rgba(0,0,0,0.06);
            color: #555;
            cursor: pointer;
            z-index: 9999;
            transition: background 0.15s;
        }
        #mdql-back:hover { background: rgba(0,0,0,0.12); }
        @media (prefers-color-scheme: dark) {
            #mdql-back { background: rgba(255,255,255,0.1); color: #ccc; }
            #mdql-back:hover { background: rgba(255,255,255,0.2); }
        }
        #mdql-status {
            position: fixed; bottom: 0; left: 0; right: 0;
            padding: 4px 12px;
            font: 12px/1.4 -apple-system, sans-serif;
            background: rgba(0,0,0,0.08);
            color: #444;
            display: none;
            z-index: 9999;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        #mdql-status.visible { display: block; }
        @media (prefers-color-scheme: dark) {
            #mdql-status { background: rgba(0,0,0,0.65); color: #ddd; }
        }
        </style>
        </head>
        <body>
        \(backButtonHTML)
        <div id="mdql-version" style="position:fixed;top:6px;right:12px;font-size:10px;opacity:0.3;font-family:monospace;z-index:9998;pointer-events:none;">\(escapeHTML(version))</div>
        <div id="mdql-loading"></div>
        <div id="mdql-status"></div>
        <article class="markdown-body" style="display:none;">
        \(body)
        </article>
        <script>
        (function() {
            var loader = document.getElementById('mdql-loading');
            var article = document.querySelector('.markdown-body');
            if (loader) loader.remove();
            if (article) article.style.display = '';

            var toast = document.createElement('div');
            toast.id = 'mdql-toast';
            toast.style.cssText = 'position:fixed;bottom:20px;left:50%;transform:translateX(-50%) translateY(20px);' +
                'background:rgba(0,0,0,0.8);color:#fff;padding:8px 16px;border-radius:6px;font-size:13px;' +
                'opacity:0;transition:opacity 0.2s,transform 0.2s;pointer-events:none;z-index:9999;' +
                'max-width:80%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
            document.body.appendChild(toast);

            window.__mdqlShowToast = function(url) {
                toast.textContent = 'Opening: ' + url;
                toast.style.opacity = '1';
                toast.style.transform = 'translateX(-50%) translateY(0)';
                clearTimeout(toast._t);
                toast._t = setTimeout(function() {
                    toast.style.opacity = '0';
                    toast.style.transform = 'translateX(-50%) translateY(20px)';
                }, 2000);
            };

            var statusBar = document.getElementById('mdql-status');

            function isMdLink(href) {
                if (!href) return false;
                if (/^https?:/i.test(href)) return false;
                return /\\.(?:md|markdown)(#.*)?$/i.test(href);
            }

            function findLink(el) {
                while (el && el.tagName !== 'A') el = el.parentElement;
                return el;
            }

            document.addEventListener('mouseover', function(e) {
                var el = findLink(e.target);
                if (!el) return;
                var href = el.getAttribute('href') || '';
                if (isMdLink(href)) {
                    statusBar.textContent = '\u{1F4C4}  Open [' + href.split('/').pop().replace(/#.*$/, '') + '] in preview';
                } else if (/^https?:/i.test(el.href || href)) {
                    statusBar.textContent = '\u{1F310}  Opens in browser';
                } else {
                    return;
                }
                statusBar.classList.add('visible');
            });

            document.addEventListener('mouseout', function(e) {
                var el = findLink(e.target);
                if (el && !el.contains(e.relatedTarget)) statusBar.classList.remove('visible');
            });

            document.addEventListener('click', function(e) {
                var el = findLink(e.target);
                if (!el) return;
                var href = el.getAttribute('href') || '';
                if (isMdLink(href)) {
                    e.preventDefault();
                    window.webkit.messageHandlers.mdql.postMessage({
                        action: "openMarkdown",
                        url: href
                    });
                    return;
                }
                if (/^https?:/.test(el.href)) {
                    e.preventDefault();
                    window.__mdqlShowToast(el.href);
                    window.webkit.messageHandlers.mdql.postMessage({
                        action: "openURL",
                        url: el.href,
                        background: e.metaKey
                    });
                }
            });
        })();
        </script>
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

    static func loadVersion() -> String {
        guard let url = Bundle(for: BundleAnchor.self).url(forResource: "version", withExtension: "txt"),
              let version = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return "dev"
        }
        return version
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
