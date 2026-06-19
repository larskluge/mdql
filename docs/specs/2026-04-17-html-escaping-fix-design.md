# HTML Escaping Fix (Issue #11 and related)

## Summary

Fenced code blocks containing `<` characters (e.g. SQL with `<table>` placeholders, HTML tutorials) render incorrectly: the code block visually never closes and swallows the rest of the document. Root cause is in `swift-markdown`'s `HTMLFormatter`, which does not HTML-escape content in several places. This spec covers a targeted post-process fix in `MarkdownRenderer.swift` that closes the four escaping holes currently reachable from user-authored markdown.

## Background

`swift-markdown`'s `HTMLFormatter` (at `Sources/Markdown/Walker/Walkers/HTMLFormatter.swift`) interpolates user content without escaping:

| Line | Node | Pattern |
|------|------|---------|
| 89   | `CodeBlock`    | `<pre><code…>\(codeBlock.code)</code></pre>` |
| 93   | `Heading`      | `<h\(n)>\(heading.plainText)</h\(n)>` |
| 225  | `InlineCode`   | `<code>\(inlineCode.code)</code>` |
| 265  | `Link`         | `href="\(link.destination)"` |

The library's test suite (`HTMLFormatterTests.swift`, 319 lines) contains no escape assertions. `HTMLFormatterOptions` has no escape-related flags. This is a library-level gap, not a mdql misconfiguration.

**Why issue #11 looks like "the code block doesn't close":** when output contains `<pre><code>SELECT * FROM <table>;…`, the browser treats `<table>` as a real HTML table element. `<table>` is a "special" element in the HTML parsing algorithm: text nodes appearing inside a table but outside a cell are **foster-parented** — relocated in the DOM tree. The result is a broken, open `<table>` that visually absorbs surrounding content. The markdown's closing fence is correctly parsed by swift-markdown; the HTML emitter is what breaks it.

## Scope

Fix these four escaping holes in the rendered HTML:

1. **Fenced code blocks** — `<pre><code class="language-X">…</code></pre>` inner content
2. **Inline code** — `<code>…</code>` inner content
3. **Headings** — `<h1>…</h6>` inner content (swift-markdown emits `heading.plainText`; no inline formatting is preserved to protect)
4. **Link hrefs** — `<a href="…">` attribute value

## Non-goals

- Paragraph text escaping (swift-markdown emits `text.string` raw at line 276). In practice, markdown inline HTML tokens like `<foo>` are parsed as `InlineHTML` nodes and intended to be raw — but a literal `&` or `<` in `Text` output is still unescaped. Tracked as a separate future fix; not reached by the issue #11 repro.
- Image `src` / `title` attributes (lines 240, 244). Not currently triggered in real usage in this project.
- Replacing `HTMLFormatter` with an mdql-owned walker. Considered, but ~300 LOC of copied machinery for maintenance gain we don't need today.
- Filing a PR upstream to swift-markdown. Out of scope for this ticket.

## Approach

**Post-process the string output of `HTMLFormatter.format(document)` with targeted regex replacements before it's handed to `wrapInHTMLDocument` / returned from `renderBody`.**

Reasoning:
- We own the input to `HTMLFormatter` (via `Document`), and `HTMLFormatter`'s output shape is stable and mechanical — every `CodeBlock` emits exactly one `<pre><code…>…</code></pre>`, every `InlineCode` emits `<code>…</code>`, etc. Regex-on-HTML is normally fragile; here the "HTML" is predictable output from a formatter whose source we've read, not arbitrary web input.
- Alternative considered: write a parallel `MarkupWalker` to replace `HTMLFormatter`. ~300 LOC, extra maintenance pressure each time we pick up a new swift-markdown feature (tables, tasklists, asides). Rejected as YAGNI for four narrow fixes.
- Alternative considered: AST pre-pass to mutate content. swift-markdown AST nodes are immutable value types; no clean hook.

## Implementation

### Files changed

- `mdqlPreview/MarkdownRenderer.swift` — add `postProcessEscaping(_:)`, call it from `render(markdown:title:showBackButton:)` and `renderBody(markdown:)`
- `mdqlTests/MarkdownRendererTests.swift` — add tests (listed below)
- `mdqlTests/Fixtures/code-with-html.md` — new fixture matching the issue #11 repro

### `postProcessEscaping`

Add a private static helper:

```swift
private static func postProcessEscaping(_ html: String) -> String {
    var out = html
    out = replaceRegex(in: out, pattern: #"<code([^>]*)>([\s\S]*?)</code>"#) { match in
        // Group 1 is the attributes (e.g. ' class="language-sql"'), group 2 is the inner content.
        // Covers both inline <code>…</code> and block <pre><code…>…</code></pre> in one pass —
        // the <pre> wrapper is untouched because this regex only matches the <code> boundary.
        "<code\(match[1])>\(escapeCodeContent(match[2]))</code>"
    }
    out = replaceRegex(in: out, pattern: #"<h([1-6])>([\s\S]*?)</h\1>"#) { match in
        "<h\(match[1])>\(escapeCodeContent(match[2]))</h\(match[1])>"
    }
    out = replaceRegex(in: out, pattern: #"<a href="([^"]*)">"#) { match in
        #"<a href="\#(escapeAttribute(match[1]))">"#
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
```

`replaceRegex` is a small adapter over `NSRegularExpression` that accepts a closure producing the replacement per match (so we can escape per-group). Implement it inline in `MarkdownRenderer.swift` — do not introduce a new file.

### Order of operations

1. Code (`<code>…</code>`) first. This pass escapes `&`, `<`, `>` inside every `<code>`, whether wrapped in `<pre>` or not. Crucially, after this pass, literal `&amp;` sequences we produce inside code will not be double-escaped by subsequent passes because subsequent patterns don't overlap.
2. Headings (`<h1>…</h6>`) second. Heading inner content from swift-markdown is `plainText` — a plain string with no nested tags — so escaping the whole captured group is safe.
3. Link hrefs third. Only touches the attribute value inside `<a href="…">`.

### Call sites

```swift
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
```

## Testing

Follow the project bug-fix protocol (`CLAUDE.md`):
1. Write the failing test(s).
2. Run and confirm they fail.
3. Implement `postProcessEscaping` and wire it into `render` / `renderBody`.
4. Confirm tests pass.
5. Temporarily remove the two call sites (leaving the helper in place) and confirm tests fail again — this proves the tests actually exercise the fix.
6. Re-apply.

### Test cases (`mdqlTests/MarkdownRendererTests.swift`)

- `testCodeBlockEscapesAngleBrackets` — fenced SQL block with `SELECT * FROM <table>;` renders `&lt;table&gt;`; the closing `</code></pre>` appears before any subsequent paragraph content.
- `testCodeBlockEscapesAmpersand` — block containing `A && B` renders as `A &amp;&amp; B`.
- `testInlineCodeEscapesAngleBrackets` — markdown `` `<div>` `` renders as `<code>&lt;div&gt;</code>`.
- `testHeadingEscapesAngleBrackets` — `## <table>` renders as `<h2>&lt;table&gt;</h2>`.
- `testLinkHrefEscapesAmpersand` — `[q](https://a.com/?x=1&y=2)` renders with `href="https://a.com/?x=1&amp;y=2"`.
- `testIssue11Repro` — loads `Fixtures/code-with-html.md` (the full 60-line issue #11 repro), asserts exactly two `<pre><code` substrings, and that the paragraph text `Then restart the app.` appears outside any `<pre>` block.

### Fixture

`mdqlTests/Fixtures/code-with-html.md` — verbatim contents of the repro block from issue #11 (two SQL code blocks with `<table>`, `<migrator_name>`, `<pattern>` placeholders, with prose between them).

## Risks & limitations

- **`</code>` literal inside a code block** — if a user authors a code block whose content contains the exact substring `</code>`, the non-greedy regex stops at the first `</code>`. This is a pre-existing bug (swift-markdown's raw emission already closes the tag early in the same case); our fix does not make it worse, but also does not fix it. Rare in practice; documented as a known limitation.
- **Swift-markdown output-shape changes on upgrade** — the regex patterns are anchored to current output. Our tests will fail loudly if the shapes change (e.g. if `visitCodeBlock` adds attributes). That's acceptable failure mode.
- **Paragraph text with `<`, `&`** — still broken after this fix. Out of scope; file as follow-up if encountered in real files.

## Verification

Before claiming done:
- Run `xcodebuild … test` — all new tests pass, all existing tests still pass.
- Run `make install`, open the issue #11 repro file (or the new fixture) in Finder, press Space — verify two distinct code blocks render, with prose and a heading between them.
