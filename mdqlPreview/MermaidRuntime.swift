import Foundation
import WebKit
import os

private class BundleAnchor {}

/// The vendored Mermaid runtime, which a page with a ```mermaid fence loads
/// after its text.
///
/// Such a page names one script, `scriptURL`, `async` and under the page's
/// nonce, which `SchemeHandler` serves from the bundle: mermaid.min.js, then
/// `glue`, the code that draws the page's fences. A page without a fence names
/// nothing and carries none of it. `async` keeps the parser and
/// DOMContentLoaded, so the text, from waiting on megabytes of script; the load
/// event (`didFinish`) does wait for it.
enum MermaidRuntime {

    static let scheme = "mdql-asset"
    static let scriptURL = URL(string: "mdql-asset:///mermaid.js")!

    private static let log = Logger(subsystem: "com.mdql.app", category: "mermaid")

    /// mermaid.min.js, or nil when this build has none, and pages then draw no
    /// diagrams and load nothing. The app ships no copy of its own: it reads the
    /// one in the Quick Look extension it embeds. The extension, the tests and
    /// mdql-screenshot each carry theirs.
    static let runtimeFileURL: URL? = {
        let url = locate(in: Bundle(for: BundleAnchor.self))
        if url == nil { log.error("No mermaid.min.js in this build: diagrams stay as code") }
        return url
    }()

    static func locate(in bundle: Bundle) -> URL? {
        if let url = bundle.url(forResource: "mermaid.min", withExtension: "js") { return url }
        guard let plugIns = bundle.builtInPlugInsURL else { return nil }
        let url = plugIns.appendingPathComponent("mdqlPreview.appex/Contents/Resources/mermaid.min.js")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether a code block's info string makes it a diagram: its first word is
    /// `mermaid`, so its class attribute holds the `language-mermaid` token that
    /// `glue` looks for.
    static func isDiagram(language: String?) -> Bool {
        language?.split(whereSeparator: \.isWhitespace).first == "mermaid"
    }

    /// The runtime's `<script>`, for a page's `<head>`.
    static func scriptTag(nonce: String) -> String {
        "<script id=\"mdql-mermaid\" nonce=\"\(nonce)\" async src=\"\(scriptURL.absoluteString)\"></script>"
    }

    /// Run in a page that has none: loads the runtime under the nonce of mdql's
    /// own script, which Swift does not know but the page does.
    static let injectionJS = """
        (function() {
            if (document.getElementById('mdql-mermaid')) return;
            var own = document.querySelector('script[nonce]');
            if (!own) return;
            var s = document.createElement('script');
            s.id = 'mdql-mermaid';
            s.nonce = own.nonce;
            s.async = true;
            s.src = '\(scriptURL.absoluteString)';
            document.head.appendChild(s);
        })();
        """

    /// Serves `scriptURL` to every WKWebView a configuration makes.
    static func install(on configuration: WKWebViewConfiguration) {
        configuration.setURLSchemeHandler(SchemeHandler(), forURLScheme: scheme)
    }

    final class SchemeHandler: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            let requested = urlSchemeTask.request.url
            guard requested == MermaidRuntime.scriptURL else {
                MermaidRuntime.log.error("Refused \(requested?.absoluteString ?? "no URL", privacy: .public): mdql serves only its Mermaid runtime")
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let runtime: Data
            do {
                guard let file = MermaidRuntime.runtimeFileURL else { throw URLError(.fileDoesNotExist) }
                runtime = try Data(contentsOf: file, options: .alwaysMapped)
            } catch {
                MermaidRuntime.log.error("Could not read mermaid.min.js: \(String(describing: error), privacy: .public)")
                urlSchemeTask.didFailWithError(error)
                return
            }
            let glue = Data(MermaidRuntime.glue.utf8)
            urlSchemeTask.didReceive(URLResponse(url: MermaidRuntime.scriptURL, mimeType: "text/javascript",
                                                 expectedContentLength: runtime.count + glue.count, textEncodingName: "utf-8"))
            urlSchemeTask.didReceive(runtime)
            urlSchemeTask.didReceive(glue)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }

    /// Runs right after mermaid.min.js, in the same script, and draws the
    /// page's fences once the DOM is there: on DOMContentLoaded, or at once
    /// when the script arrives after it. Defines `__mdqlSwapBody`, which live
    /// updates go through, and `__mdqlDiagramsSettled`, a promise that settles
    /// once the first diagrams are drawn (mdql-screenshot waits on it).
    static let glue = #"""

        ;(function() {
            // seq lives at this scope so the initial render, live-update
            // re-renders, and theme re-renders never reuse an SVG id.
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

            // Draws every fence not yet drawn. cache (optional) maps fence
            // source to a queue of rendered wrappers from before a live-update
            // swap; a fence whose source is unchanged takes its old wrapper back
            // instead of re-rendering. Moving the node keeps its SVG ids and
            // bindFunctions listeners. Settles once every render has.
            function renderDiagrams(cache) {
                var blocks = document.querySelectorAll('.markdown-body pre code.language-mermaid');
                if (!blocks.length) return Promise.resolve();
                syncMermaidTheme();
                var renders = [];
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
                    renders.push(renderMermaid(pre, sourceText).catch(function(err) {
                        pre.classList.add('mdql-mermaid-error');
                        var note = document.createElement('div');
                        note.className = 'mdql-mermaid-error-msg';
                        note.textContent = 'Diagram error: ' + (err && err.message || err);
                        pre.after(note);
                    }));
                });
                return Promise.all(renders);
            }

            // Live-update swap. Harvesting the rendered wrappers, replacing the
            // body, and putting unchanged diagrams back all happen in this one
            // task, so no frame shows raw fence source in between. Wrappers
            // left in the cache are dropped; error blocks are never harvested,
            // so a fixed fence re-renders.
            function swapBody(html) {
                var article = document.querySelector('.markdown-body');
                if (!article) return;
                var cache = new Map();
                syncMermaidTheme();
                article.querySelectorAll('.mdql-mermaid[data-mdql-source]').forEach(function(div) {
                    if (div.getAttribute('data-mdql-theme') !== mermaidTheme) return;
                    var sourceText = div.getAttribute('data-mdql-source');
                    if (!cache.has(sourceText)) cache.set(sourceText, []);
                    cache.get(sourceText).push(div);
                });
                article.innerHTML = html;
                renderDiagrams(cache);
            }

            function start() {
                window.__mdqlSwapBody = swapBody;
                window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function(e) {
                    initMermaid(e.matches);
                    // A swap may already have synced the theme and rendered
                    // some wrappers in it; only the stale ones need redrawing.
                    document.querySelectorAll('.markdown-body .mdql-mermaid[data-mdql-source]').forEach(function(div) {
                        if (div.getAttribute('data-mdql-theme') === mermaidTheme) return;
                        renderMermaid(div, div.getAttribute('data-mdql-source')).catch(function() {});
                    });
                });
                window.__mdqlDiagramsSettled = renderDiagrams();
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', start);
            } else {
                start();
            }
        })();
        """#
}
