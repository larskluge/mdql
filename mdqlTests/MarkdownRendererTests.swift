import XCTest
import Markdown

final class MarkdownRendererTests: XCTestCase {

    private func fixtureURL(_ name: String) -> URL {
        let bundle = Bundle(for: type(of: self))
        return bundle.url(forResource: name, withExtension: "md", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("\(name).md")
    }

    // MARK: - Basic Markdown

    func testRenderBasicMarkdown() {
        let md = """
        # Hello

        A **bold** and *italic* paragraph.

        Some `inline code` here.

        [Link](https://example.com)
        """
        let html = MarkdownRenderer.render(markdown: md)
        XCTAssertTrue(html.contains("<h1>"), "Should contain h1")
        XCTAssertTrue(html.contains("<p>"), "Should contain p")
        XCTAssertTrue(html.contains("<a href="), "Should contain link")
        XCTAssertTrue(html.contains("<em>"), "Should contain em")
        XCTAssertTrue(html.contains("<strong>"), "Should contain strong")
        XCTAssertTrue(html.contains("<code>"), "Should contain code")
    }

    // MARK: - GFM Features

    func testRenderGFMTable() {
        let md = """
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let html = MarkdownRenderer.render(markdown: md)
        XCTAssertTrue(html.contains("<table>"), "Should contain table")
        XCTAssertTrue(html.contains("<th>"), "Should contain th")
        XCTAssertTrue(html.contains("<td>"), "Should contain td")
    }

    func testRenderGFMTaskList() {
        let md = """
        - [x] Done
        - [ ] Not done
        """
        let html = MarkdownRenderer.render(markdown: md)
        XCTAssertTrue(html.contains("<input type=\"checkbox\""), "Should contain checkbox input")
    }

    func testRenderGFMStrikethrough() {
        let md = "This is ~~deleted~~ text."
        let html = MarkdownRenderer.render(markdown: md)
        XCTAssertTrue(html.contains("<del>"), "Should contain del for strikethrough")
    }

    func testRenderCodeBlock() {
        let md = """
        ```swift
        let x = 42
        ```
        """
        let html = MarkdownRenderer.render(markdown: md)
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"), "Should contain code block with language class")
    }

    // MARK: - HTML Escaping (Issue #11)

    func testCodeBlockEscapesAngleBrackets() {
        let md = """
        ```sql
        SELECT * FROM <table>;
        ```
        """
        let html = MarkdownRenderer.renderBody(markdown: md)
        XCTAssertTrue(html.contains("&lt;table&gt;"), "Angle brackets in code block must be escaped; got: \(html)")
        XCTAssertFalse(html.contains("<table>"), "Code block must not emit raw <table> tag; got: \(html)")
    }

    func testCodeBlockEscapesAmpersand() {
        let md = """
        ```
        A && B
        ```
        """
        let html = MarkdownRenderer.renderBody(markdown: md)
        XCTAssertTrue(html.contains("A &amp;&amp; B"), "Ampersands in code block must be escaped; got: \(html)")
    }

    func testInlineCodeEscapesAngleBrackets() {
        let md = "Use `<div>` for blocks."
        let html = MarkdownRenderer.renderBody(markdown: md)
        XCTAssertTrue(html.contains("<code>&lt;div&gt;</code>"), "Inline code content must be escaped; got: \(html)")
    }

    func testHeadingEscapesAngleBrackets() {
        let md = "## Using <Component>"
        let html = MarkdownRenderer.renderBody(markdown: md)
        XCTAssertTrue(html.contains("<h2>Using &lt;Component&gt;</h2>"), "Heading content must be escaped; got: \(html)")
    }

    func testLinkHrefEscapesAmpersand() {
        let md = "[q](https://a.com/?x=1&y=2)"
        let html = MarkdownRenderer.renderBody(markdown: md)
        XCTAssertTrue(html.contains("href=\"https://a.com/?x=1&amp;y=2\""), "Link href must escape ampersand; got: \(html)")
    }

    func testIssue11Repro() throws {
        let url = fixtureURL("code-with-html")
        let md = try String(contentsOf: url, encoding: .utf8)
        let html = MarkdownRenderer.renderBody(markdown: md)

        let preCount = html.components(separatedBy: "<pre><code").count - 1
        XCTAssertEqual(preCount, 2, "Expected exactly two code blocks; got \(preCount). HTML:\n\(html)")

        XCTAssertTrue(html.contains("Paragraph between blocks."), "Paragraph between code blocks must be preserved")
        XCTAssertFalse(html.contains("<table>"), "Must not emit raw <table> tag")
        XCTAssertFalse(html.contains("<pattern>"), "Must not emit raw <pattern> tag")
    }

    // MARK: - HTML Document Structure

    func testHTMLDocumentStructure() {
        let html = MarkdownRenderer.render(markdown: "# Test")
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"), "Should start with DOCTYPE")
        XCTAssertTrue(html.contains("<style>"), "Should contain style tag")
        XCTAssertTrue(html.contains("class=\"markdown-body\""), "Should contain markdown-body article")
    }

    func testTitleEscaping() {
        let html = MarkdownRenderer.render(markdown: "Hello", title: "<script>alert('xss')</script>")
        XCTAssertTrue(html.contains("&lt;script&gt;"), "Title should be HTML-escaped")
        XCTAssertFalse(html.contains("<script>alert"), "Title should not contain raw script tag")
    }

    func testEmptyFile() {
        let html = MarkdownRenderer.render(markdown: "")
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"), "Empty input should still produce valid HTML")
        XCTAssertTrue(html.contains("class=\"markdown-body\""), "Should contain article wrapper")
    }

    func testLoadingSpinner() {
        let html = MarkdownRenderer.render(markdown: "# Hello")
        XCTAssertTrue(html.contains("id=\"mdql-loading\""), "Should contain loading spinner element")
        XCTAssertTrue(html.contains("mdql-spin"), "Should contain spinner animation")
        XCTAssertTrue(html.contains("display:none"), "Content should be hidden initially")
        XCTAssertTrue(html.contains("getElementById('mdql-loading')"), "JS should remove spinner on load")
    }

    // MARK: - CSS

    func testCSSContainsDarkMode() {
        let html = MarkdownRenderer.render(markdown: "test")
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"), "CSS should contain dark mode media query")
    }

    func testCSSContainsInkpadTokens() {
        let html = MarkdownRenderer.render(markdown: "test")
        XCTAssertTrue(html.contains("#3f3b3d"), "CSS should contain inkpad text color")
        XCTAssertTrue(html.contains("#4183c4"), "CSS should contain inkpad link color")
        XCTAssertTrue(html.contains("#f9f9f9"), "CSS should contain inkpad bg color")
    }

    // MARK: - File-based rendering

    func testRenderFromURL() throws {
        let url = fixtureURL("basic")
        let html = try MarkdownRenderer.render(fileAt: url)
        XCTAssertTrue(html.contains("<h1>"), "Should render headings from file")
        XCTAssertTrue(html.contains("<strong>"), "Should render bold from file")
    }

    func testRenderFromString() {
        let html = MarkdownRenderer.render(markdown: "**hello**")
        XCTAssertTrue(html.contains("<strong>"), "Should render bold from string")
    }

    // MARK: - renderBody (body-only HTML for innerHTML updates)

    func testRenderBodyExcludesDoctype() {
        let body = MarkdownRenderer.renderBody(markdown: "# Hello")
        XCTAssertFalse(body.contains("<!DOCTYPE"), "renderBody should not include DOCTYPE")
        XCTAssertFalse(body.contains("<html"), "renderBody should not include html tag")
        XCTAssertFalse(body.contains("<head"), "renderBody should not include head tag")
        XCTAssertFalse(body.contains("<style"), "renderBody should not include style tag")
    }

    func testRenderBodyContainsMarkup() {
        let body = MarkdownRenderer.renderBody(markdown: "# Hello\n\nA **bold** word.")
        XCTAssertTrue(body.contains("<h1>"), "renderBody should contain h1")
        XCTAssertTrue(body.contains("<strong>"), "renderBody should contain strong")
    }

    func testRenderBodyMatchesRenderContent() {
        let md = "# Test\n\nSome **content**."
        let fullHTML = MarkdownRenderer.render(markdown: md)
        let body = MarkdownRenderer.renderBody(markdown: md)
        XCTAssertTrue(fullHTML.contains(body), "Full render should contain renderBody output")
    }

    func testRenderBodyEmpty() {
        let body = MarkdownRenderer.renderBody(markdown: "")
        XCTAssertFalse(body.contains("<h1>"), "Empty input should produce no headings")
    }

    // MARK: - UTF-8 handling (em-dashes, special chars)

    func testUTF8InRender() {
        let html = MarkdownRenderer.render(markdown: "Hello — world • bullet « guillemets »")
        XCTAssertTrue(html.contains("—"), "Should preserve em-dash")
        XCTAssertTrue(html.contains("•"), "Should preserve bullet")
        XCTAssertTrue(html.contains("«"), "Should preserve left guillemet")
    }

    func testUTF8InRenderBody() {
        let body = MarkdownRenderer.renderBody(markdown: "Héllo — wörld 中文")
        XCTAssertTrue(body.contains("Héllo"), "Should preserve accented chars")
        XCTAssertTrue(body.contains("—"), "Should preserve em-dash")
        XCTAssertTrue(body.contains("中文"), "Should preserve CJK chars")
    }

    func testUTF8Base64RoundTrip() {
        // Simulates the innerHTML update path: renderBody → base64 → atob+TextDecoder
        let body = MarkdownRenderer.renderBody(markdown: "Test — em-dash • bullet")
        let base64 = Data(body.utf8).base64EncodedString()
        guard let decoded = Data(base64Encoded: base64) else {
            XCTFail("Base64 decode failed")
            return
        }
        let roundTripped = String(data: decoded, encoding: .utf8)
        XCTAssertEqual(roundTripped, body, "Base64 round-trip should preserve UTF-8")
    }

    // MARK: - BundleAnchor CSS loading

    func testCSSLoadsFromBundle() {
        let html = MarkdownRenderer.render(markdown: "test")
        XCTAssertTrue(html.contains("Charter"), "CSS should contain Charter font family")
        XCTAssertTrue(html.contains("markdown-body"), "Should contain markdown-body class")
    }

    func testCSSNotEmpty() {
        let html = MarkdownRenderer.render(markdown: "test")
        // If CSS fails to load, the style tag would be nearly empty
        XCTAssertTrue(html.contains("font-family:"), "CSS should contain font-family rule")
        XCTAssertTrue(html.contains("line-height:"), "CSS should contain line-height rule")
    }

    // MARK: - Front Matter

    func testFrontMatterParsed() {
        let md = """
        ---
        title: Hello
        author: Lars
        ---

        # Body
        """
        let (pairs, body) = MarkdownRenderer.parseFrontMatter(md)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].0, "author", "Fields should be sorted alphabetically")
        XCTAssertEqual(pairs[0].1, "Lars")
        XCTAssertEqual(pairs[1].0, "title")
        XCTAssertEqual(pairs[1].1, "Hello")
        XCTAssertTrue(body.contains("# Body"), "Body should contain markdown after front matter")
        XCTAssertFalse(body.contains("---"), "Body should not contain front matter delimiters")
    }

    func testFrontMatterRenderedAsHTML() {
        let md = """
        ---
        title: My Document
        author: Lars
        date: 2026-03-18
        draft: false
        ---

        # Hello
        """
        let html = MarkdownRenderer.render(markdown: md)
        XCTAssertTrue(html.contains("class=\"front-matter\""), "Should contain front-matter div")
        XCTAssertTrue(html.contains("author:"), "Should contain author field")
        XCTAssertTrue(html.contains("·"), "Should contain separator between fields")
        // Verify alphabetical order: author, date, draft, title
        let fmRange = html.range(of: "class=\"front-matter\"")!
        let afterFM = html[fmRange.upperBound...]
        let authorPos = afterFM.range(of: "author:")!.lowerBound
        let datePos = afterFM.range(of: "date:")!.lowerBound
        let draftPos = afterFM.range(of: "draft:")!.lowerBound
        let titlePos = afterFM.range(of: "title:")!.lowerBound
        XCTAssertTrue(authorPos < datePos, "author should come before date")
        XCTAssertTrue(datePos < draftPos, "date should come before draft")
        XCTAssertTrue(draftPos < titlePos, "draft should come before title")
    }

    func testFrontMatterStrippedFromBody() {
        let md = """
        ---
        title: Test
        ---

        # Content
        """
        let html = MarkdownRenderer.render(markdown: md)
        XCTAssertTrue(html.contains("<h1>"), "Body content should still render")
        // The raw front matter text should not appear as markdown content
        let bodyHTML = MarkdownRenderer.renderBody(markdown: md)
        XCTAssertFalse(bodyHTML.contains("<hr"), "Front matter should not produce a horizontal rule")
    }

    func testNoFrontMatter() {
        let md = "# Just a heading\n\nNo front matter here."
        let (pairs, body) = MarkdownRenderer.parseFrontMatter(md)
        XCTAssertTrue(pairs.isEmpty, "No pairs when no front matter")
        XCTAssertEqual(body, md, "Body should be unchanged")
    }

    func testFrontMatterNotClosedReturnsNoPairs() {
        let md = """
        ---
        title: Broken

        # Body starts here
        """
        let (pairs, body) = MarkdownRenderer.parseFrontMatter(md)
        XCTAssertTrue(pairs.isEmpty, "Unclosed front matter should return no pairs")
        XCTAssertEqual(body, md, "Body should be unchanged for unclosed front matter")
    }

    func testFrontMatterEscapesHTML() {
        let md = """
        ---
        title: <script>alert('xss')</script>
        ---

        # Safe
        """
        let html = MarkdownRenderer.render(markdown: md)
        XCTAssertTrue(html.contains("&lt;script&gt;"), "Front matter values should be HTML-escaped")
        XCTAssertFalse(html.contains("<script>alert"), "Should not contain raw script tag in front matter")
    }

    func testRenderBodyIncludesFrontMatter() {
        let md = """
        ---
        title: Live Update
        ---

        # Content
        """
        let body = MarkdownRenderer.renderBody(markdown: md)
        XCTAssertTrue(body.contains("class=\"front-matter\""), "renderBody should include front matter")
        XCTAssertTrue(body.contains("<h1>"), "renderBody should include body content")
    }

    func testFrontMatterFromFixtureFile() throws {
        let url = fixtureURL("front-matter")
        let html = try MarkdownRenderer.render(fileAt: url)
        XCTAssertTrue(html.contains("class=\"front-matter\""), "Fixture file should render front matter")
        XCTAssertTrue(html.contains("author:"), "Should contain author from fixture")
        XCTAssertTrue(html.contains("<h1>"), "Should render body from fixture")
    }

    // MARK: - Title from file path

    func testTitleFromFilePath() throws {
        let url = fixtureURL("basic")
        let html = try MarkdownRenderer.render(fileAt: url)
        XCTAssertTrue(html.contains("<title>basic</title>"), "Title should be filename without extension")
    }

    func testSpecialCharsFilePath() throws {
        let url = fixtureURL("special-chars")
        let html = try MarkdownRenderer.render(fileAt: url)
        XCTAssertTrue(html.contains("<title>special-chars</title>"), "Title should handle hyphens")
    }
}
