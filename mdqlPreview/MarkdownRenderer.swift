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

    public static func render(markdown: String, title: String = "", showBackButton: Bool = false, interactive: Bool = false, appChrome: Bool = false) -> String {
        let (frontMatter, body) = parseFrontMatter(markdown)
        let document = Document(parsing: body, options: [.parseBlockDirectives])
        let html = postProcessCheckboxes(HTMLFormatter.format(escapingAttributeValues(document)), interactive: interactive)
        let frontMatterHTML = renderFrontMatter(frontMatter)
        return wrapInHTMLDocument(body: frontMatterHTML + html, title: title, showBackButton: showBackButton, interactive: interactive, appChrome: appChrome)
    }

    public static func renderBody(markdown: String, interactive: Bool = false) -> String {
        let (frontMatter, body) = parseFrontMatter(markdown)
        let document = Document(parsing: body, options: [.parseBlockDirectives])
        let frontMatterHTML = renderFrontMatter(frontMatter)
        return frontMatterHTML + postProcessCheckboxes(HTMLFormatter.format(escapingAttributeValues(document)), interactive: interactive)
    }

    // MARK: - Interactive Checkboxes
    // When `interactive` is true, strip `disabled` from task-list
    // checkboxes and assign each one a sequential `data-cb-index` attribute so
    // JS can identify them and Swift can map clicks back to the source file.

    static func postProcessCheckboxes(_ html: String, interactive: Bool) -> String {
        guard interactive else { return html }
        var index = 0
        return replaceRegex(in: html, pattern: #"<input([^>]*?type="checkbox"[^>]*?)\s*/?>"#) { groups in
            var attrs = groups[1]
            attrs = attrs.replacingOccurrences(of: #" disabled="""#, with: "")
            attrs = attrs.replacingOccurrences(of: " disabled=''", with: "")
            attrs = attrs.replacingOccurrences(of: " disabled", with: "")
            let result = "<input\(attrs) data-cb-index=\"\(index)\">"
            index += 1
            return result
        }
    }

    // MARK: - HTML Escaping
    // HTMLFormatter escapes text, code blocks and inline code itself. It still
    // writes `Link.destination`, `Image.source` and `Image.title` raw into
    // `href="…"` / `src="…"` / `title="…"`, so we escape those on the tree
    // before it formats. See docs/specs/2026-04-17-html-escaping-fix-design.md.

    /// Escapes the URLs and titles that `HTMLFormatter` drops straight into
    /// attribute values, before it does so.
    ///
    /// Repairing the formatter's output with a regex cannot work here: once a
    /// destination containing `"` has been written out, the quote has already
    /// closed the attribute and whatever followed it is a sibling attribute
    /// indistinguishable from a real one. `[](a"onmouseover="alert(1))` is
    /// enough — and this preview runs JS with a bridge that opens URLs and
    /// writes to the file on disk. Escaping on the tree removes the hole
    /// instead of papering over it.
    static func escapingAttributeValues(_ document: Document) -> Markup {
        var escaper = AttributeValueEscaper()
        return escaper.visit(document) ?? document
    }

    private struct AttributeValueEscaper: MarkupRewriter {
        typealias Result = Markup?

        /// Raw inline HTML in a heading is shown, not run. `## Using <Component>`
        /// means what it says; nobody titles a section with a live element. Turning
        /// the node into text lets the formatter escape it exactly once. Inline HTML
        /// elsewhere still renders — see AGENTS.md.
        mutating func visitHeading(_ heading: Heading) -> Markup? {
            let children = heading.children.map { child -> Markup in
                guard let inlineHTML = child as? InlineHTML else { return child }
                return Text(inlineHTML.rawHTML)
            }
            return defaultVisit(heading.withUncheckedChildren(children))
        }

        mutating func visitLink(_ link: Link) -> Markup? {
            var link = link
            link.destination = link.destination.map(MarkdownRenderer.escapeAttribute)
            return defaultVisit(link)
        }

        mutating func visitImage(_ image: Image) -> Markup? {
            var image = image
            image.source = image.source.map(MarkdownRenderer.escapeAttribute)
            image.title = image.title.map(MarkdownRenderer.escapeAttribute)
            return defaultVisit(image)
        }
    }

    private static func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replaceRegex(
        in input: String,
        pattern: String,
        with transform: ([String]) -> String
    ) -> String {
        // Patterns here are hard-coded literals; a compile failure is a programmer error,
        // not a runtime condition to recover from silently.
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
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

    /// `appChrome` tags `<body class="mdql-app">`, which is what scopes the
    /// titlebar headroom and top fade in preview.css to the standalone window.
    /// It is deliberately separate from `interactive` — QuickLook renders
    /// interactive too, but draws no chrome to make room for.
    private static func wrapInHTMLDocument(body: String, title: String, showBackButton: Bool = false, interactive: Bool = false, appChrome: Bool = false) -> String {
        let css = loadCSS()
        let version = loadVersion()
        let mermaidScript = mermaidScriptTag(for: body)
        let escapedTitle = escapeHTML(title)
        let backButtonHTML = showBackButton ? """
        <div id="mdql-back" onclick="window.webkit.messageHandlers.mdql.postMessage({action:'goBack'})"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"></polyline></svg></div>
        """ : ""
        let interactiveCheckboxJS = interactive ? """

            // Optimistic toggle: own the visual flip in JS on click, BEFORE
            // anything else. preventDefault stops the native toggle so the
            // visible state changes exactly when we set it — no waiting on
            // the browser's default-action + change-event chain.
            document.addEventListener('click', function(e) {
                var el = e.target;
                if (el && el.matches && el.matches('input[type="checkbox"][data-cb-index]')) {
                    var idx = parseInt(el.getAttribute('data-cb-index'), 10);
                    window.webkit.messageHandlers.mdql.postMessage({
                        action: "toggleCheckbox",
                        index: idx,
                        checked: el.checked
                    });
                }
            });

            window.__mdqlRevertCheckbox = function(index) {
                var el = document.querySelector('input[type="checkbox"][data-cb-index="' + index + '"]');
                if (el) el.checked = !el.checked;
            };
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
        <body\(appChrome ? " class=\"mdql-app\"" : "")>
        \(backButtonHTML)
        <div id="mdql-version" style="position:fixed;top:6px;right:12px;font-size:10px;opacity:0.3;font-family:monospace;z-index:9998;pointer-events:none;">\(escapeHTML(version))</div>
        <div id="mdql-loading"></div>
        <div id="mdql-status"></div>
        <article class="markdown-body" style="display:none;">
        \(body)
        </article>
        \(mermaidScript)
        <script>
        (function() {
            var loader = document.getElementById('mdql-loading');
            var article = document.querySelector('.markdown-body');
            if (loader) loader.remove();
            if (article) article.style.display = '';

            // Mermaid diagrams: the runtime is only embedded when the document
            // has a ```mermaid fence (see mermaidScriptTag(for:)). The hook is
            // also re-invoked after live-update swaps (__mdqlSwapBody) —
            // rendered blocks are marked with data-mdql-mermaid, so it is
            // idempotent. seq lives at this scope so the initial render,
            // live-update re-renders, and theme re-renders never reuse an SVG id.
            var seq = 0;
            // mermaidTheme is the theme mermaid is initialized with; themeGen
            // bumps on every change so a render queued before the change can
            // tell its SVG may be stale.
            var mermaidTheme = null;
            var themeGen = 0;
            function initMermaid(dark) {
                var theme = dark ? 'dark' : 'default';
                if (theme === mermaidTheme) return;
                mermaidTheme = theme;
                themeGen++;
                mermaid.initialize({
                    startOnLoad: false,
                    securityLevel: 'strict',
                    suppressErrorRendering: true,
                    theme: theme
                });
            }
            // Brings mermaid in line with the page's current color scheme. The
            // media query can flip before its change event fires, so swaps
            // check it directly rather than waiting on the listener.
            function syncMermaidTheme() {
                initMermaid(window.matchMedia('(prefers-color-scheme: dark)').matches);
            }
            // Renders sourceText and swaps the result in for target (the raw
            // <pre> on first render, the previous wrapper on theme change).
            // The source and theme ride along on the wrapper so it can be
            // re-rendered, and so a live-update swap only reuses wrappers
            // drawn in the current theme. mermaid queues renders, so one
            // requested before a theme change may run after it: re-render
            // when the theme moved while this one was in flight.
            function renderMermaid(target, sourceText) {
                var gen = themeGen;
                var theme = mermaidTheme;
                return mermaid.render('mdql-mermaid-svg-' + (seq++), sourceText).then(function(result) {
                    var div = document.createElement('div');
                    div.className = 'mdql-mermaid';
                    div.setAttribute('data-mdql-source', sourceText);
                    div.setAttribute('data-mdql-theme', theme);
                    div.innerHTML = typeof result === 'string' ? result : (result && result.svg || '');
                    if (result && typeof result.bindFunctions === 'function') {
                        result.bindFunctions(div);
                    }
                    target.replaceWith(div);
                    if (gen !== themeGen && div.isConnected) {
                        renderMermaid(div, sourceText).catch(function() {});
                    }
                });
            }

            // cache (optional) maps fence source to a queue of rendered
            // wrappers from before a live-update swap; a fence whose source
            // is unchanged takes its old wrapper back instead of re-rendering.
            // Moving the node keeps its SVG ids and bindFunctions listeners.
            window.__mdqlRenderDiagrams = function(cache) {
                var blocks = document.querySelectorAll('.markdown-body pre code.language-mermaid');
                if (!blocks.length || typeof mermaid === 'undefined') return;
                syncMermaidTheme();
                blocks.forEach(function(code) {
                    var pre = code.parentElement;
                    if (pre.getAttribute('data-mdql-mermaid')) return;
                    // textContent is entity-decoded by the browser, so mermaid
                    // gets the raw fence source.
                    var sourceText = code.textContent;
                    var reusable = cache && cache.get(sourceText);
                    if (reusable && reusable.length) {
                        pre.replaceWith(reusable.shift());
                        return;
                    }
                    pre.setAttribute('data-mdql-mermaid', '1');
                    renderMermaid(pre, sourceText).catch(function(err) {
                        pre.classList.add('mdql-mermaid-error');
                        var note = document.createElement('div');
                        note.className = 'mdql-mermaid-error-msg';
                        note.textContent = 'Diagram error: ' + (err && err.message || err);
                        pre.after(note);
                    });
                });
            };

            // Live-update swap. Harvesting the rendered wrappers, replacing the
            // body, and putting unchanged diagrams back all happen in this one
            // task, so no frame shows raw fence source in between. Wrappers
            // left in the cache are dropped; error blocks are never harvested,
            // so a fixed fence re-renders.
            window.__mdqlSwapBody = function(html) {
                var article = document.querySelector('.markdown-body');
                if (!article) return;
                var cache = new Map();
                if (typeof mermaid !== 'undefined') {
                    syncMermaidTheme();
                    article.querySelectorAll('.mdql-mermaid[data-mdql-source]').forEach(function(div) {
                        if (div.getAttribute('data-mdql-theme') !== mermaidTheme) return;
                        var sourceText = div.getAttribute('data-mdql-source');
                        if (!cache.has(sourceText)) cache.set(sourceText, []);
                        cache.get(sourceText).push(div);
                    });
                }
                article.innerHTML = html;
                window.__mdqlRenderDiagrams(cache);
            };

            if (!window.__mdqlMermaidThemeListener && window.matchMedia) {
                window.__mdqlMermaidThemeListener = true;
                window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function(e) {
                    if (typeof mermaid === 'undefined') return;
                    initMermaid(e.matches);
                    // A swap may already have synced the theme and rendered
                    // some wrappers in it; only the stale ones need redrawing.
                    document.querySelectorAll('.markdown-body .mdql-mermaid[data-mdql-source]').forEach(function(div) {
                        var sourceText = div.getAttribute('data-mdql-source');
                        if (!sourceText || div.getAttribute('data-mdql-theme') === mermaidTheme) return;
                        renderMermaid(div, sourceText).catch(function() {});
                    });
                });
            }
            window.__mdqlRenderDiagrams();

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
        \(interactiveCheckboxJS)
        })();
        </script>
        </body>
        </html>
        """
    }

    /// mermaid.min.js, loaded once and made safe to embed inside a <script>
    /// tag: `</script` inside JS string literals would close the tag early,
    /// and `<\/script` is the identical string value inside those literals.
    private static let mermaidRuntime: String? = {
        guard let url = Bundle(for: BundleAnchor.self).url(forResource: "mermaid.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return js
            .replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
            .replacingOccurrences(of: "<!--", with: "<\\!--")
            .replacingOccurrences(of: "<![CDATA[", with: "<\\![CDATA[")
    }()

    /// True when `html` holds a rendered ```mermaid fence. Matches the exact
    /// opening tag HTMLFormatter emits rather than the bare class name: text
    /// content is escaped, so prose, inline code, or URLs that merely mention
    /// `language-mermaid` never produce the literal tag.
    internal static func containsMermaidFence(_ html: String) -> Bool {
        html.contains("<code class=\"language-mermaid\">")
    }

    /// The Mermaid runtime is embedded only when the body has a mermaid fence —
    /// diagram-free files must render exactly the HTML they always did. The
    /// in-page `__mdqlRenderDiagrams` hook does the actual rendering.
    internal static func mermaidScriptTag(for body: String) -> String {
        guard containsMermaidFence(body), let js = mermaidRuntime else { return "" }
        return "\n<script id=\"mdql-mermaid\">\n\(js)\n</script>\n"
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
