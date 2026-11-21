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

    /// `checkboxesClickable` false, in interactive mode, draws the body's
    /// checkboxes disabled while the page still listens for clicks: a live
    /// update may bring clickable ones. `topInset` is how far the host's
    /// titlebar reaches over the page.
    public static func render(markdown: String, title: String = "", showBackButton: Bool = false, interactive: Bool = false,
                              checkboxesClickable: Bool = true, appChrome: Bool = false, topInset: CGFloat = 0) -> String {
        renderPage(markdown: markdown, title: title, showBackButton: showBackButton, interactive: interactive,
                   checkboxesClickable: checkboxesClickable, appChrome: appChrome, topInset: topInset).html
    }

    /// The page, and whether it loads the Mermaid runtime: it does when the
    /// parse found a ```mermaid fence and this build has the runtime.
    static func renderPage(markdown: String, title: String = "", showBackButton: Bool = false, interactive: Bool = false,
                           checkboxesClickable: Bool = true, appChrome: Bool = false, topInset: CGFloat = 0) -> (html: String, loadsMermaid: Bool) {
        let body = renderBodyNotingDiagrams(markdown: markdown, interactive: interactive && checkboxesClickable)
        let loadsMermaid = body.hasMermaidFence && MermaidRuntime.runtimeFileURL != nil
        let html = wrapInHTMLDocument(body: body.html, title: title, showBackButton: showBackButton, interactive: interactive,
                                      appChrome: appChrome, topInset: topInset, loadsMermaid: loadsMermaid)
        return (html, loadsMermaid)
    }

    public static func renderBody(markdown: String, interactive: Bool = false) -> String {
        renderBodyNotingDiagrams(markdown: markdown, interactive: interactive).html
    }

    /// The body, and whether the parse found a ```mermaid fence in it.
    static func renderBodyNotingDiagrams(markdown: String, interactive: Bool = false) -> (html: String, hasMermaidFence: Bool) {
        let (frontMatter, body) = parseFrontMatter(markdown)
        let document = Document(parsing: body, options: [.parseBlockDirectives])
        var checkboxes = TaskCheckboxes(markdown: markdown, body: body, interactive: interactive)
        let html = HTMLFormatter.format(escapingAttributeValues(checkboxes.visit(document) ?? document))
        return (renderFrontMatter(frontMatter) + html, checkboxes.hasMermaidFence)
    }

    // MARK: - Task Checkboxes
    // Which list items are tasks, and where each one's marker sits in the file,
    // both come from the parse that renders them. A scan of the source lines or
    // of the HTML disagrees with it (indented code, `1)` lists, comments, raw
    // `<input>`s, a fence inside a longer fence), and a click then flipped some
    // other task's byte, or one inside code.

    /// Draws each task item's checkbox from its source. In interactive mode the
    /// checkbox carries `data-cb-offset`, the UTF-8 offset in the markdown text
    /// of the byte between its brackets, which `CheckboxToggle` flips; otherwise
    /// it is disabled. Either way it shows that byte's state, so the state a
    /// click asks for is always the other one. An item whose marker is not where
    /// the parse puts it keeps the formatter's disabled checkbox.
    ///
    /// The same walk notes whether a code block is a ```mermaid fence, so that
    /// what decides a page loads the runtime is the parse the formatter writes.
    private struct TaskCheckboxes: LinearRewriter {
        /// The whole markdown text, front matter included, which offsets count in.
        let source: [UInt8]
        /// The offset in `source` at which each line of the parsed body starts.
        let lineStarts: [Int]
        let interactive: Bool
        private(set) var hasMermaidFence = false

        init(markdown: String, body: String, interactive: Bool) {
            source = Array(markdown.utf8)
            let bodyStart = source.count - body.utf8.count // the body is what follows the front matter
            var starts = [bodyStart]
            for i in bodyStart..<source.count {
                // A line ends at \n, \r\n or a lone \r, as cmark reads it.
                if source[i] == UInt8(ascii: "\n") || (source[i] == UInt8(ascii: "\r") && (i + 1 == source.count || source[i + 1] != UInt8(ascii: "\n"))) {
                    starts.append(i + 1)
                }
            }
            lineStarts = starts
            self.interactive = interactive
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> Markup? {
            if MermaidRuntime.isDiagram(language: codeBlock.language) { hasMermaidFence = true }
            return codeBlock
        }

        mutating func visitListItem(_ listItem: ListItem) -> Markup? {
            let visited = defaultVisit(listItem)
            guard listItem.checkbox != nil,
                  let start = listItem.range?.lowerBound,
                  let marker = markerOffset(line: start.line, column: start.column),
                  let item = visited as? ListItem else { return visited }
            let checked = source[marker] != UInt8(ascii: " ")
            let input = "<input type=\"checkbox\""
                + (interactive ? "" : " disabled=\"\"")
                + (checked ? " checked=\"\"" : "")
                + (interactive ? " data-cb-offset=\"\(marker)\"" : "")
                + " /> "
            return ListItem(checkbox: nil, [HTMLBlock(input)] + Array(item.blockChildren))
        }

        /// The offset of the byte between a task item's brackets, given the line
        /// and byte column its list marker starts at: past `-`, `+` or `*`, or
        /// digits and their delimiter, then the spaces or tabs after it, as
        /// cmark-gfm's tasklist scanner reads it. Nil unless `[ ]`, `[x]` or `[X]`
        /// is there.
        private func markerOffset(line: Int, column: Int) -> Int? {
            guard line >= 1, line <= lineStarts.count, column >= 1 else { return nil }
            func byte(_ i: Int) -> UInt8? { i < source.count ? source[i] : nil }
            func isDigit(_ b: UInt8?) -> Bool { b.map { (0x30...0x39).contains($0) } ?? false }
            var i = lineStarts[line - 1] + column - 1
            if let b = byte(i), [UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "*")].contains(b) {
                i += 1
            } else if isDigit(byte(i)) {
                while isDigit(byte(i)) { i += 1 }
                i += 1 // `.` or `)`
            } else {
                return nil
            }
            let afterBullet = i
            while byte(i) == UInt8(ascii: " ") || byte(i) == UInt8(ascii: "\t") { i += 1 }
            guard i > afterBullet,
                  byte(i) == UInt8(ascii: "["), byte(i + 2) == UInt8(ascii: "]"),
                  let marker = byte(i + 1), [UInt8(ascii: " "), UInt8(ascii: "x"), UInt8(ascii: "X")].contains(marker)
            else { return nil }
            return i + 1
        }
    }

    // MARK: - HTML Escaping
    // HTMLFormatter escapes text, code blocks and inline code itself. It still
    // writes `Link.destination`, `Image.source`, `Image.title` and
    // `CodeBlock.language` (a fence's whole info string) raw into `href="…"` /
    // `src="…"` / `title="…"` / `class="language-…"`, and raw HTML verbatim,
    // so we escape those on the tree before it formats. See
    // docs/specs/2026-04-17-html-escaping-fix-design.md.

    /// Escapes the URLs, titles and code-block languages that `HTMLFormatter`
    /// drops straight into attribute values, before it does so, and runs the
    /// tagfilter over the raw HTML it would emit verbatim.
    ///
    /// Repairing the formatter's output with a regex cannot work here: once a
    /// destination containing `"` has been written out, the quote has already
    /// closed the attribute and whatever followed it is a sibling attribute
    /// indistinguishable from a real one. `[](a"onmouseover="alert(1))` is
    /// enough — and this preview runs JS with a bridge that opens URLs and
    /// writes to the file on disk. Escaping on the tree removes the hole
    /// instead of papering over it.
    static func escapingAttributeValues(_ markup: Markup) -> Markup {
        var escaper = AttributeValueEscaper()
        return escaper.visit(markup) ?? markup
    }

    private struct AttributeValueEscaper: LinearRewriter {
        typealias Result = Markup?

        /// Raw inline HTML in a heading is shown, not run. `## Using <Component>`
        /// means what it says; nobody titles a section with a live element. Turning
        /// the node into text lets the formatter escape it exactly once. Raw HTML
        /// elsewhere still renders, less the tagfilter's tags — see AGENTS.md.
        mutating func visitHeading(_ heading: Heading) -> Markup? {
            let children = heading.children.map { child -> Markup in
                guard let inlineHTML = child as? InlineHTML else { return child }
                return Text(inlineHTML.rawHTML)
            }
            return defaultVisit(heading.detached.withUncheckedChildren(children))
        }

        mutating func visitLink(_ link: Link) -> Markup? {
            var link = link.detached
            link.destination = link.destination.flatMap(MarkdownRenderer.allowedURL).map(MarkdownRenderer.escapeAttribute)
            return defaultVisit(link)
        }

        mutating func visitImage(_ image: Image) -> Markup? {
            var image = image.detached
            image.source = image.source.flatMap(MarkdownRenderer.allowedURL).map(MarkdownRenderer.escapeAttribute)
            image.title = image.title.map(MarkdownRenderer.escapeAttribute)
            return defaultVisit(image)
        }

        /// The class holds the info string's first word only, as in CommonMark's
        /// reference renderer: ```` ```swift title=main ```` is `language-swift`.
        mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> Markup? {
            var codeBlock = codeBlock.detached
            codeBlock.language = codeBlock.language?
                .split(whereSeparator: \.isWhitespace).first
                .map { MarkdownRenderer.escapeAttribute(String($0)) }
            return codeBlock
        }

        mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> Markup? {
            var inlineHTML = inlineHTML.detached
            inlineHTML.rawHTML = MarkdownRenderer.filteringRawTextTags(inlineHTML.rawHTML)
            return inlineHTML
        }

        mutating func visitHTMLBlock(_ html: HTMLBlock) -> Markup? {
            var html = html.detached
            html.rawHTML = MarkdownRenderer.filteringRawTextTags(html.rawHTML)
            return html
        }
    }

    // MARK: - Tagfilter
    // GFM's tagfilter, plus `noscript` and `template`. Each of these tags makes
    // the browser read what follows as raw text, or as inert template content,
    // up to its end tag or the end of the file: one `<title>` in a paragraph
    // swallowed the rest of the document. Escaping the `<` shows the tag as
    // text, as on GitHub; every other tag (`<details>`, `<img>`, `<kbd>`) stays
    // live.

    /// The `<` of an open or close tag of a filtered name. A browser ends a tag
    /// name at whitespace, `/`, `>` or the end of the input and ignores ASCII
    /// case, so this matches exactly the tags it would open: `<title/x>` is a
    /// <title>, `<title-card>` is not.
    private static let rawTextTag = try! NSRegularExpression(
        pattern: #"<(?=/?(?:title|textarea|style|xmp|iframe|noembed|noframes|script|plaintext|noscript|template)(?:[\t\n\f\r />]|$))"#,
        options: [.caseInsensitive]
    )

    static func filteringRawTextTags(_ html: String) -> String {
        rawTextTag.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "&lt;")
    }

    // MARK: - URL schemes
    // A link or image keeps its URL only when the URL is relative (a sibling
    // `.md`, a `#fragment`) or names one of `AccessPolicy.allowedSchemes`.
    // Any other — `file:`, `smb:`, an app's own scheme — is dropped, and the
    // formatter writes the `<a>` without an href, the `<img>` without a src.

    /// A scheme as a browser reads one: a letter, then letters, digits, `+`,
    /// `-` or `.`, up to the first `:`.
    private static let scheme = try! NSRegularExpression(pattern: "^([A-Za-z][A-Za-z0-9+.-]*):")

    static func allowedURL(_ url: String) -> String? {
        // A browser drops leading C0 controls and spaces, and every tab and
        // newline, before it reads the scheme: `java\tscript:` is `javascript:`.
        let read = String(String.UnicodeScalarView(url.unicodeScalars
            .drop { $0.value <= 0x20 }
            .filter { !["\t", "\n", "\r"].contains($0) }))
        guard let match = scheme.firstMatch(in: read, range: NSRange(read.startIndex..., in: read)),
              let range = Range(match.range(at: 1), in: read) else {
            return url
        }
        return AccessPolicy.allowedSchemes.contains(read[range].lowercased()) ? url : nil
    }

    private static func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
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

    /// `appChrome` tags `<body class="mdql-app">`, which is what scopes the
    /// titlebar headroom and top fade in preview.css to the standalone window.
    /// It is deliberately separate from `interactive` — QuickLook renders
    /// interactive too, but draws no chrome to make room for.
    ///
    /// Nothing on the page waits for the body to parse as written. mdql's
    /// script sits in `<head>`, ahead of anything the document brings, and runs
    /// on DOMContentLoaded, which fires however the body ends — under an
    /// unclosed `<!--` too. The Content-Security-Policy lets only scripts
    /// carrying this render's nonce run, so a document's own `<script>`, its
    /// `on…=` attributes and its `javascript:` links stay inert, on first load
    /// and on live reload alike. `evaluateJavaScript` from Swift is not subject
    /// to it. Images and styles load as they would without a policy.
    ///
    /// `loadsMermaid` adds the one other script, the Mermaid runtime, under the
    /// same nonce and `async`, so the text does not wait on it (`MermaidRuntime`).
    private static func wrapInHTMLDocument(body: String, title: String, showBackButton: Bool = false, interactive: Bool = false,
                                           appChrome: Bool = false, topInset: CGFloat = 0, loadsMermaid: Bool = false) -> String {
        let css = loadCSS()
        let version = loadVersion()
        let escapedTitle = escapeHTML(title)
        let nonce = makeNonce()
        // Empty on a plain page, which is then the page it always was, byte for byte.
        let mermaidScript = loadsMermaid ? "\n" + MermaidRuntime.scriptTag(nonce: nonce) : ""
        let backButtonHTML = showBackButton ? """
        <div id="mdql-back" class="mdql-glass"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"></polyline></svg></div>
        """ : ""
        return """
        <!DOCTYPE html>
        <html lang="en" style="--mdql-top: \(max(0, Double(topInset)))px">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="script-src 'nonce-\(nonce)'; object-src 'none'; base-uri 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapedTitle)</title>
        <style>
        \(css)
        </style>\(mermaidScript)
        <script nonce="\(nonce)">
        document.addEventListener('DOMContentLoaded', function() {
        \(pageScript)
        \(interactive ? checkboxScript : "")
        });
        </script>
        </head>
        <body\(appChrome ? " class=\"mdql-app\"" : "")>
        \(backButtonHTML)
        <div id="mdql-version">\(escapeHTML(version))</div>
        <article class="markdown-body">
        \(body)
        </article>
        </body>
        </html>
        """
    }

    /// The page's own behavior: links, the back button, the notices on top
    /// and the label at the bottom. Swift shows a notice with
    /// `__mdqlNotice({id, kind, text, detail, lasting})` and takes it away
    /// with `__mdqlDismissNotice(id)`; `__mdqlShowToast(text, icon)` puts
    /// `text` in the label for a moment. All of them set text, never markup.
    private static let pageScript = #"""
            var back = document.getElementById('mdql-back');
            if (back) back.addEventListener('click', function() {
                window.webkit.messageHandlers.mdql.postMessage({action: 'goBack'});
            });

            function svg(shapes) {
                return '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
                    'stroke-linecap="round" stroke-linejoin="round">' + shapes + '</svg>';
            }
            var icons = {
                failed: svg('<path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/>' +
                    '<line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>'),
                refused: svg('<circle cx="12" cy="12" r="10"/><line x1="4.93" y1="4.93" x2="19.07" y2="19.07"/>'),
                waiting: '<span class="mdql-dot"></span>',
                cleared: svg('<polyline points="20 6 9 17 4 12"/>'),
                web: svg('<line x1="7" y1="17" x2="17" y2="7"/><polyline points="7 7 17 7 17 17"/>'),
                note: svg('<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/>' +
                    '<line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/>')
            };

            // An icon, then the text and, quieter, its detail after a `·`.
            function fill(el, icon, text, detail) {
                el.textContent = '';
                if (icons[icon]) {
                    var i = document.createElement('span');
                    i.className = 'mdql-icon';
                    i.innerHTML = icons[icon];
                    el.appendChild(i);
                }
                var t = document.createElement('span');
                t.className = 'mdql-text';
                t.textContent = text;
                if (detail) {
                    var d = document.createElement('span');
                    d.className = 'mdql-detail';
                    d.textContent = ' · ' + detail;
                    t.appendChild(d);
                }
                el.appendChild(t);
            }

            // Problems, on top. Lasting ones stay until Swift takes them away
            // and come first; the others fade, unless the pointer holds them.
            var notices = document.createElement('div');
            notices.id = 'mdql-notices';
            document.body.appendChild(notices);

            // Gives the page the room the notices take, so that nothing in the
            // document is under them at scroll top.
            function makeRoom() {
                var shown = Array.prototype.filter.call(notices.children, function(el) {
                    return !el.classList.contains('mdql-leaving');
                });
                var room = 0;
                if (shown.length) {
                    room = parseFloat(getComputedStyle(notices).top) + 20 + 8 * (shown.length - 1);
                    shown.forEach(function(el) { room += el.offsetHeight; });
                }
                document.body.style.setProperty('--mdql-notice-room', room + 'px');
            }

            function noticeNamed(id) {
                return Array.prototype.find.call(notices.children, function(el) {
                    return el.mdqlId === id && !el.classList.contains('mdql-leaving');
                });
            }

            function dismiss(el) {
                if (!el || el.classList.contains('mdql-leaving')) return;
                clearTimeout(el.mdqlTimer);
                el.classList.add('mdql-leaving');
                makeRoom();
                setTimeout(function() { el.remove(); makeRoom(); }, 200);
            }

            function countDown(el) {
                clearTimeout(el.mdqlTimer);
                if (el.mdqlFadesAfter) el.mdqlTimer = setTimeout(function() { dismiss(el); }, el.mdqlFadesAfter);
            }

            window.__mdqlNotice = function(notice) {
                var el = noticeNamed(notice.id);
                if (!el) {
                    el = document.createElement('div');
                    el.mdqlId = notice.id;
                    el.setAttribute('role', 'status');
                    el.addEventListener('mouseenter', function() { clearTimeout(el.mdqlTimer); });
                    el.addEventListener('mouseleave', function() { countDown(el); });
                }
                var wasLasting = el.classList.contains('mdql-lasting');
                el.className = 'mdql-notice mdql-glass mdql-' + notice.kind + (notice.lasting ? ' mdql-lasting' : '');
                fill(el, notice.kind, notice.text, notice.detail);
                var firstFading = Array.prototype.find.call(notices.children, function(other) {
                    return other !== el && !other.classList.contains('mdql-lasting');
                });
                if (el.parentNode !== notices) {
                    // A lasting one goes after the others that last, a fading one last.
                    notices.insertBefore(el, notice.lasting ? firstFading || null : null);
                } else if (notice.lasting !== wasLasting) {
                    notices.insertBefore(el, firstFading || null);
                }
                el.mdqlFadesAfter = notice.lasting ? 0 : notice.kind === 'cleared' ? 2500 : 6000;
                if (!el.matches(':hover')) countDown(el);
                makeRoom();
            };

            window.__mdqlDismissNotice = function(id) { dismiss(noticeNamed(id)); };

            // What is fine to miss, at the bottom: where a link goes, and
            // that it is opening.
            var label = document.createElement('div');
            label.id = 'mdql-label';
            label.className = 'mdql-glass';
            document.body.appendChild(label);

            function showLabel(icon, text, detail) {
                fill(label, icon, text, detail);
                label.classList.add('visible');
            }

            window.__mdqlShowToast = function(text, icon) {
                showLabel(icon, text);
                clearTimeout(label.mdqlTimer);
                label.mdqlTimer = setTimeout(function() {
                    label.mdqlTimer = null;
                    label.classList.remove('visible');
                }, 2000);
            };

            function isMdLink(href) {
                if (!href) return false;
                if (/^https?:/i.test(href)) return false;
                return /\.(?:md|markdown)(#.*)?$/i.test(href);
            }

            function findLink(el) {
                while (el && el.tagName !== 'A') el = el.parentElement;
                return el;
            }

            // A web link's address as a reader would say it: no scheme, no
            // trailing slash.
            function address(href) {
                try {
                    var url = new URL(href);
                    return (url.host + url.pathname + url.search + url.hash).replace(/\/$/, '');
                } catch (e) {
                    return href;
                }
            }

            function noteName(href) {
                var name = href.replace(/#.*$/, '').split('/').pop();
                try { return decodeURIComponent(name); } catch (e) { return name; }
            }

            document.addEventListener('mouseover', function(e) {
                var el = findLink(e.target);
                if (!el) return;
                var href = el.getAttribute('href') || '';
                if (isMdLink(href)) {
                    showLabel('note', noteName(href), 'opens here');
                } else if (/^https?:/i.test(el.href || href)) {
                    showLabel('web', address(el.href || href));
                } else {
                    return;
                }
                clearTimeout(label.mdqlTimer);
                label.mdqlTimer = null;
            });

            document.addEventListener('mouseout', function(e) {
                var el = findLink(e.target);
                if (el && !el.contains(e.relatedTarget) && !label.mdqlTimer) label.classList.remove('visible');
            });

            // Every link goes to Swift, which opens it or says why not: a web
            // link in the browser, mailto: in Mail, a relative link in place
            // when it is Markdown. Only a jump within the page, and the
            // javascript: links the CSP keeps inert, are left alone.
            document.addEventListener('click', function(e) {
                var el = findLink(e.target);
                if (!el) return;
                var href = el.getAttribute('href') || '';
                if (!href || href.charAt(0) === '#' || /^(about|javascript):/i.test(href)) return;
                e.preventDefault();
                if (/^https?:/i.test(href)) {
                    var target = el.href || href;
                    var host;
                    try { host = new URL(target).host; } catch (err) { host = target; }
                    window.__mdqlShowToast('Opening ' + host, 'web');
                    window.webkit.messageHandlers.mdql.postMessage({action: "openURL", url: target});
                } else if (/^[a-z][a-z0-9+.-]*:/i.test(href)) {
                    window.webkit.messageHandlers.mdql.postMessage({action: "openURL", url: href});
                } else {
                    window.webkit.messageHandlers.mdql.postMessage({action: "openMarkdown", url: href});
                }
            });
    """#

    /// Interactive pages only: a click on a checkbox asks Swift to save it.
    private static let checkboxScript = #"""
            // By the time a click reaches this listener the box has already
            // flipped, so `checked` is the state asked for. Swift writes it to
            // the marker at `data-cb-offset`, or reverts the box if it cannot.
            document.addEventListener('click', function(e) {
                var el = e.target;
                if (el && el.matches && el.matches('input[type="checkbox"][data-cb-offset]')) {
                    window.webkit.messageHandlers.mdql.postMessage({
                        action: "toggleCheckbox",
                        offset: parseInt(el.getAttribute('data-cb-offset'), 10),
                        checked: el.checked
                    });
                }
            });

            // Puts the box back as it was before a click asked for `checked`.
            window.__mdqlRevertCheckbox = function(offset, checked) {
                var el = document.querySelector('input[type="checkbox"][data-cb-offset="' + offset + '"]');
                if (el) el.checked = !checked;
            };
    """#

    /// A fresh nonce for every page, so no document can know in advance the
    /// one that would let its script run.
    private static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
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

// MARK: - Rewriting in linear time
// swift-markdown's own `MarkupRewriter.defaultVisit` rebuilds each node with
// `withUncheckedChildren` while it is still attached to its parent, and so do
// the nodes' property setters. For an attached node that rebuilds every
// ancestor up to the root, copying each one's children, so every node costs
// as much as the document has top-level blocks: the two passes over a 1 MB
// file took 5 s (mdql-4hx). A detached node rebuilds only itself, and the
// rewriters keep only what a node holds, never where it hangs.

/// A `MarkupRewriter` in time linear in the size of the tree: it rebuilds a
/// node, detached from its parent, only when something under it changed.
private protocol LinearRewriter: MarkupRewriter {}

private extension LinearRewriter {
    mutating func defaultVisit(_ markup: Markup) -> Markup? {
        var changed = false
        var children: [Markup] = []
        children.reserveCapacity(markup.childCount)
        for child in markup.children {
            guard let new = visit(child) else { changed = true; continue }
            changed = changed || !new.isIdentical(to: child)
            children.append(new)
        }
        return changed ? markup.detached.withUncheckedChildren(children) : markup
    }
}

private extension Markup {
    /// This node as the root of a tree of its own, made in O(1): changing it
    /// then rebuilds it alone, not its ancestors.
    var detached: Self { detachedFromParent as! Self }
}
