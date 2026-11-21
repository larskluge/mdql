import XCTest
import WebKit
import OSLog

/// What WebKit makes of a rendered page. A check on the HTML string cannot
/// tell how a browser parses it, so these render a file through
/// `MarkdownWebController`, as both hosts do, into a real offscreen
/// WKWebView, and ask the DOM.
final class RenderedPageTests: XCTestCase {

    // MARK: - The page never depends on how its body parses

    func testBodyTextTitleTagLeavesTheRestOfThePageVisible() throws {
        // An owl report's `Case <n>, “<title>”, has no session yet…` left Quick
        // Look and the viewer on a spinner: <title> is RCDATA, so the browser
        // read the rest of the file, mdql's own script included, as its text.
        let page = try show("x “<title>” y\n\nAfter.").webView

        XCTAssertEqual(try evaluate("document.getElementById('mdql-loading') === null", in: page) as? Bool, true,
                       "No loading spinner may remain on the page")
        let visible = try visibleText(of: page)
        XCTAssertTrue(visible.contains("After."), "The text after <title> must show; visible: \(visible)")
        XCTAssertTrue(visible.contains("<title>"), "The tag itself must show as text; visible: \(visible)")
    }

    func testEveryRawTextTagLeavesTheRestOfThePageVisible() throws {
        for tag in tagfilterTags {
            for markdown in ["Before <\(tag)> inline.\n\nAfter.", "<\(tag)>\n\nAfter."] {
                let visible = try visibleText(of: show(markdown).webView)
                XCTAssertTrue(visible.contains("After."),
                              "\(markdown.debugDescription) hid the rest of the page; visible: \(visible)")
            }
        }
    }

    func testUnclosedCommentBlockStillShowsWhatPrecedesIt() throws {
        // An HTML block opened by `<!--` runs to the end of the file, and the
        // comment swallows everything the page puts after the body.
        let visible = try visibleText(of: show("Before.\n\n<!-- never closed\n\nAfter.").webView)
        XCTAssertTrue(visible.contains("Before."), "Content before the comment must show; visible: \(visible)")
    }

    // MARK: - Only mdql's own script runs

    func testDocumentScriptDoesNotRun() throws {
        let page = try show("<script>window.__pwned = 1</script>\n\nText.").webView
        XCTAssertEqual(try evaluate("typeof window.__pwned", in: page) as? String, "undefined")
    }

    func testDocumentEventHandlerAttributeDoesNotRun() throws {
        let page = try show(#"<img src="data:image/png;base64,AAAA" onerror="window.__pwned = 1">"#).webView
        try waitUntil("document.querySelector('img').complete", in: page)
        settle()
        XCTAssertEqual(try evaluate("typeof window.__pwned", in: page) as? String, "undefined")
    }

    func testJavaScriptLinkDoesNotRun() throws {
        let page = try show("[a](javascript:window.__pwned=1)").webView
        try evaluate("document.querySelector('a').click(); true", in: page)
        settle()
        XCTAssertEqual(try evaluate("typeof window.__pwned", in: page) as? String, "undefined")
    }

    func testLiveReloadDoesNotRunTheDocumentsEventHandlers() throws {
        let shown = try show("Before.")
        try Data(#"Reloaded. <img src="data:image/png;base64,AAAA" onerror="window.__pwned = 1">"#.utf8)
            .write(to: shown.file)
        try waitUntil("document.body.innerText.includes('Reloaded.')", in: shown.webView)
        try waitUntil("document.querySelector('img').complete", in: shown.webView)
        settle()
        XCTAssertEqual(try evaluate("typeof window.__pwned", in: shown.webView) as? String, "undefined")
    }

    // MARK: - The page never navigates away from mdql's own

    /// A port nothing listens on: a navigation that is let through starts,
    /// shows in `webView.url`, and fails at once, without leaving the Mac.
    private let elsewhere = "http://127.0.0.1:9/"

    func testMetaRefreshDoesNotNavigate() throws {
        try assertStaysPut("<meta http-equiv=\"refresh\" content=\"0; url=\(elsewhere)\">\n\nStill here.")
    }

    func testMetaRefreshToAnEmptyPageDoesNotReplaceTheDocument() throws {
        try assertStaysPut("<meta http-equiv=\"refresh\" content=\"0; url=about:blank\">\n\nStill here.")
    }

    func testFormSubmitDoesNotNavigate() throws {
        try assertStaysPut("<form action=\"\(elsewhere)\"><button>Go</button></form>\n\nStill here.",
                           then: "document.querySelector('button').click()")
    }

    func testScriptedNavigationDoesNotLeaveThePage() throws {
        try assertStaysPut("Still here.", then: "window.open('\(elsewhere)', '_self')")
        try assertStaysPut("Still here.", then: "window.open('\(elsewhere)')")
        try assertStaysPut("Still here.", then: "location.href = '\(elsewhere)'")
    }

    func testTheLatestOfTwoQuickLoadsShows() throws {
        let shown = try show("First.")
        let second = shown.file.deletingLastPathComponent().appendingPathComponent("second.md")
        try Data("Second.".utf8).write(to: second)
        let third = shown.file.deletingLastPathComponent().appendingPathComponent("third.md")
        try Data("Third.".utf8).write(to: third)

        try shown.controller.loadMarkdownFile(at: second)
        try shown.controller.loadMarkdownFile(at: third)

        try waitUntil("document.body.innerText.includes('Third.') && document.readyState === 'complete'", in: shown.webView)
    }

    // MARK: - Only mdql's own page reaches the bridge

    func testMessageFromASubframeIsIgnored() throws {
        var opened: [String] = []
        let page = try show("Text.") { controller in
            controller.openURL = { url, done in opened.append(url.absoluteString); done(nil) }
        }.webView

        try evaluate("""
            var frame = document.createElement('iframe');
            document.body.appendChild(frame);
            frame.contentWindow.webkit.messageHandlers.mdql.postMessage({action: 'openURL', url: 'https://example.com/framed'});
            true
            """, in: page)
        try evaluate("webkit.messageHandlers.mdql.postMessage({action: 'openURL', url: 'https://example.com/main'}); true", in: page)
        let deadline = Date().addingTimeInterval(5)
        while opened.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        settle()

        XCTAssertEqual(opened, ["https://example.com/main"], "Only the main frame's message may act")
    }

    func testMessageFromAPageOtherThanMdqlsIsIgnored() throws {
        // Were a navigation ever to get through, the page it reached must
        // find the bridge deaf. Detaching the navigation delegate lets the
        // test put such a page in the main frame.
        var opened: [String] = []
        let shown = try show("Text.") { controller in
            controller.openURL = { url, done in opened.append(url.absoluteString); done(nil) }
        }
        shown.webView.navigationDelegate = nil
        shown.webView.loadHTMLString("<p>Elsewhere.</p>", baseURL: URL(string: "https://attacker.example/"))
        try waitUntil("document.body.innerText.includes('Elsewhere.')", in: shown.webView)

        try evaluate("webkit.messageHandlers.mdql.postMessage({action: 'openURL', url: 'https://example.com/'}); true",
                     in: shown.webView)
        settle()

        XCTAssertEqual(opened, [], "A main frame showing anything but mdql's page may not use the bridge")
    }

    // MARK: - mdql's own features still work

    func testFollowingAMarkdownLinkAndGoingBackStillWork() throws {
        let shown = try show("[Two](two.md)")
        let two = shown.file.deletingLastPathComponent().appendingPathComponent("two.md")
        try Data("Second page.".utf8).write(to: two)

        let followed = expectation(description: "followed the link to two.md")
        let wentBack = expectation(description: "went back to the first file")
        shown.controller.fileURLDidChange = { url in
            if url?.lastPathComponent == "two.md" { followed.fulfill() }
            if url?.lastPathComponent == shown.file.lastPathComponent { wentBack.fulfill() }
        }

        try evaluate("document.querySelector('a').click(); true", in: shown.webView)
        wait(for: [followed], timeout: 10)
        try waitUntil("!!document.getElementById('mdql-back') && document.readyState === 'complete'", in: shown.webView)
        try evaluate("document.getElementById('mdql-back').click(); true", in: shown.webView)
        wait(for: [wentBack], timeout: 10)
    }

    func testCheckboxStillToggles() throws {
        let toggled = expectation(description: "toggleCheckbox reached Swift")
        var toggledOffset: Int?
        var toggledChecked: Bool?
        let page = try show("- [ ] task") { controller in
            controller.toggleCheckbox = { offset, checked, completion in
                toggledOffset = offset
                toggledChecked = checked
                completion(.toggled)
                toggled.fulfill()
            }
        }.webView

        try evaluate("document.querySelector('input[type=checkbox]').click(); true", in: page)
        wait(for: [toggled], timeout: 10)
        XCTAssertEqual(toggledOffset, 3)
        XCTAssertEqual(toggledChecked, true)
    }

    func testALinkToASectionOfAnotherFileOpensItThereAndBackReturns() throws {
        let shown = try show("[Section](two.md#sec)")
        let two = shown.file.deletingLastPathComponent().appendingPathComponent("two.md")
        try Data("Top.\n\n\(filler)\n\n<h2 id=\"sec\">Section</h2>\n\nSection text.\n\n\(filler)".utf8).write(to: two)

        let followed = expectation(description: "followed the link to two.md")
        let wentBack = expectation(description: "went back to the first file")
        shown.controller.fileURLDidChange = { url in
            if url?.lastPathComponent == "two.md" { followed.fulfill() }
            if url?.lastPathComponent == shown.file.lastPathComponent { wentBack.fulfill() }
        }

        try evaluate("document.querySelector('a').click(); true", in: shown.webView)
        wait(for: [followed], timeout: 10)
        try waitUntilScrolled(to: "sec", in: shown.webView)
        try evaluate("document.getElementById('mdql-back').click(); true", in: shown.webView)
        wait(for: [wentBack], timeout: 10)
    }

    func testALinkToAHeadingOfAnotherFileScrollsToIt() throws {
        let shown = try show("[Setup](two.md#setup)")
        let two = shown.file.deletingLastPathComponent().appendingPathComponent("two.md")
        try Data("Top.\n\n\(filler)\n\n## Setup\n\nSetup text.\n\n\(filler)".utf8).write(to: two)

        let followed = expectation(description: "followed the link to two.md")
        shown.controller.fileURLDidChange = { url in
            if url?.lastPathComponent == "two.md" { followed.fulfill() }
        }
        try evaluate("document.querySelector('a').click(); true", in: shown.webView)
        wait(for: [followed], timeout: 10)
        try waitUntilScrolled(to: "setup", in: shown.webView)
    }

    func testALinkToAHeadingInTheSameFileScrollsToIt() throws {
        let page = try show("[Setup](#setup)\n\n\(filler)\n\n## Setup\n\nSetup text.\n\n\(filler)").webView
        try evaluate("document.querySelector('a').click(); true", in: page)
        try waitUntilScrolled(to: "setup", in: page)
        XCTAssertEqual(page.url?.absoluteString, "about:blank", "A jump within the page stays on mdql's page")
    }

    func testAPercentEncodedSameFileLinkScrollsToItsHeading() throws {
        let page = try show("[Café](#caf%C3%A9)\n\n\(filler)\n\n## Café\n\nText.\n\n\(filler)").webView
        try evaluate("document.querySelector('a').click(); true", in: page)
        try waitUntilScrolled(to: "café", in: page)
    }

    // MARK: - A click flips that task's marker, and nothing else

    /// Each source holds the tasks `task0`, `task1`, … and decoys that look like a
    /// task to a scan of the lines but render as none. Clicking task N, through the
    /// viewer's own wiring, must flip the byte inside task N's brackets and no other.
    func testClickingATaskFlipsExactlyThatTasksMarker() throws {
        let sources: [(name: String, markdown: [UInt8])] = [
            ("an indented code block", Array("Intro.\n\n    - [ ] decoy in indented code\n\n- [ ] task0\n- [ ] task1\n".utf8)),
            ("a 1) list", Array("1) [ ] task0\n\n- [ ] task1\n".utf8)),
            ("a raw <input type=checkbox>", Array("Raw: <input type=\"checkbox\"> inline.\n\n- [ ] task0\n- [ ] task1\n".utf8)),
            ("an HTML comment", Array("<!--\n- [ ] decoy in a comment\n-->\n\n- [ ] task0\n- [ ] task1\n".utf8)),
            ("a four-backtick fence holding three", Array("````\n```\n- [ ] decoy in a fence\n```\n````\n\n- [ ] task0\n- [ ] task1\n".utf8)),
            ("a UTF-8 BOM", [0xEF, 0xBB, 0xBF] + Array("- [ ] task0\n- [ ] task1\n".utf8)),
            ("front matter", Array("---\ntitle: Plan\n---\n- [ ] task0\n- [ ] task1\n".utf8)),
            ("CRLF line endings", Array("Intro.\r\n\r\n- [ ] task0\r\n- [ ] task1\r\n".utf8)),
            ("a nested list", Array("- parent\n  - [ ] task0\n    - [ ] task1\n".utf8)),
        ]
        for source in sources {
            for task in 0..<2 {
                let shown = try showInViewer(Data(source.markdown))
                let original = try Data(contentsOf: shown.file)
                let marker = try XCTUnwrap(markerOffset(of: "task\(task)", in: original), "\(source.name): no task\(task)")
                var expected = original
                expected[marker] = UInt8(ascii: "x")

                // The innermost item holding the label is the task's own: a parent
                // item's text includes its children's.
                try evaluate("""
                    var items = Array.from(document.querySelectorAll('.markdown-body li'))
                        .filter(function (li) { return li.textContent.includes('task\(task)'); });
                    items[items.length - 1].querySelector('input[type=checkbox]').click();
                    true
                    """, in: shown.webView)
                let written = waitForChange(of: shown.file, from: original)
                XCTAssertEqual(written.map { String(decoding: $0, as: UTF8.self) },
                               String(decoding: expected, as: UTF8.self),
                               "\(source.name): clicking task\(task) must flip its marker and nothing else")
            }
        }
    }

    func testExternalLinkStillOpens() throws {
        let opened = expectation(description: "openURL reached Swift")
        var openedURL: URL?
        let page = try show("[site](https://example.com/)") { controller in
            controller.openURL = { url, done in
                openedURL = url
                done(nil)
                opened.fulfill()
            }
        }.webView

        try evaluate("document.querySelector('a').click(); true", in: page)
        wait(for: [opened], timeout: 10)
        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/")
    }

    func testDetailsAndImagesStillRenderAsHTML() throws {
        let dot = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        let page = try show("<details><summary>s</summary>b</details>\n\n<img alt=\"dot\" src=\"data:image/png;base64,\(dot)\">").webView

        XCTAssertEqual(try evaluate("!!document.querySelector('.markdown-body details > summary')", in: page) as? Bool, true,
                       "<details> must render as an element")
        XCTAssertEqual(try evaluate("document.querySelector('.markdown-body img').naturalWidth", in: page) as? Int, 1,
                       "A data: image must load")
    }

    // MARK: - Problems show on top, what is fine to miss at the bottom

    func testTheNoticeSitsOnTheBackButtonsLineBesideIt() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let page = try showSecondPage(in: appearance).webView
            try showRefusal(in: page)
            let back = try rect(of: "#mdql-back", in: page)
            let notice = try rect(of: "#mdql-notices .mdql-notice", in: page)

            XCTAssertLessThanOrEqual(back.maxX, notice.minX, "\(appearance): the notice must sit beside the back button, never under it")
            XCTAssertEqual(back.minY, notice.minY, accuracy: 0.5, "\(appearance): the notice and the back button share their top")
            XCTAssertEqual(back.height, notice.height, accuracy: 0.5, "\(appearance): the notice and the back button share their height")
            XCTAssertEqual(back.minY, 20, accuracy: 0.5, "\(appearance): 20 px from the top of a page with no titlebar")
            XCTAssertEqual(back.minX, 20, accuracy: 0.5, "\(appearance): 20 px from the left")
            XCTAssertEqual(back.width, 36, accuracy: 0.5)
            XCTAssertEqual(back.height, 36, accuracy: 0.5)
        }
    }

    func testTheNoticeAndTheLabelAreOneSizeAndClipNoDescender() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let page = try show("Text.", appearance: appearance).webView
            try showRefusal(in: page)
            try evaluate("window.__mdqlShowToast('Opening example.org — typography', 'web'); true", in: page)

            let style = "['paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft', 'borderTopLeftRadius', 'borderBottomRightRadius', 'lineHeight', 'fontSize']"
            let notice = try XCTUnwrap(evaluate("var s = getComputedStyle(document.querySelector('#mdql-notices .mdql-notice')); \(style).map(function (k) { return s[k]; })", in: page) as? [String])
            let label = try XCTUnwrap(evaluate("var s = getComputedStyle(document.getElementById('mdql-label')); \(style).map(function (k) { return s[k]; })", in: page) as? [String])
            XCTAssertEqual(notice, label, "\(appearance): the notice and the label share padding, radius and type")
            XCTAssertEqual(notice, ["9px", "14px", "9px", "14px", "10px", "10px", "17.5px", "12.5px"], "\(appearance)")

            let noticeRect = try rect(of: "#mdql-notices .mdql-notice", in: page)
            let labelRect = try rect(of: "#mdql-label", in: page)
            let height = try XCTUnwrap(evaluate("window.innerHeight", in: page) as? Double)
            XCTAssertEqual(noticeRect.minY, 20, accuracy: 0.5, "\(appearance): the notice's gap from the top edge")
            XCTAssertEqual(height - labelRect.maxY, 20, accuracy: 0.5, "\(appearance): the label's gap from the bottom edge")
            XCTAssertEqual(noticeRect.height, labelRect.height, accuracy: 0.5, "\(appearance): one size top and bottom")

            let clipped = try XCTUnwrap(evaluate("""
                Array.from(document.querySelectorAll('#mdql-notices .mdql-text, #mdql-label .mdql-text'))
                    .filter(function (el) { return el.scrollHeight > el.clientHeight; }).length
                """, in: page) as? Int)
            XCTAssertEqual(clipped, 0, "\(appearance): no text in the notice or the label may be clipped")
        }
    }

    func testContentMovesDownBelowTheNoticesAtScrollTop() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let shown = try show("# Heading\n\nText.", appearance: appearance)
            try showRefusal(in: shown.webView)
            shown.controller.show(PageNotice(id: "second", kind: .failed, text: "Couldn't open the link", detail: "a second problem"))
            try waitForNotice(.failed, "Couldn't open the link · a second problem", in: shown.webView)
            try waitUntil("""
                (function () {
                    var notices = document.querySelectorAll('#mdql-notices .mdql-notice');
                    var last = notices[notices.length - 1].getBoundingClientRect();
                    return document.querySelector('.markdown-body > :first-child').getBoundingClientRect().top >= last.bottom;
                })()
                """, in: shown.webView)
            let tops = try XCTUnwrap(evaluate("Array.from(document.querySelectorAll('#mdql-notices .mdql-notice')).map(function (el) { return el.getBoundingClientRect().top; })", in: shown.webView) as? [Double])
            XCTAssertEqual(tops.count, 2, "\(appearance): two problems stack")
            XCTAssertEqual(tops[1] - tops[0], 36 + 8, accuracy: 0.5, "\(appearance): stacked 8 px apart")
        }
    }

    func testALastingNoticeStacksFirst() throws {
        let shown = try show("Text.")
        try showRefusal(in: shown.webView)
        shown.controller.show(PageNotice(id: "lasting", kind: .waiting, text: "page.md was moved or deleted", lasting: true))
        try waitForNotice(.waiting, "page.md was moved or deleted", in: shown.webView)
        XCTAssertEqual(try notices(in: shown.webView),
                       ["waiting: page.md was moved or deleted", "refused: Not opened · smb: links are off in mdql"])
    }

    func testTheVersionSitsFaintAtTheBottomRight() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let page = try show("Text.", appearance: appearance).webView
            let version = try rect(of: "#mdql-version", in: page)
            let width = try XCTUnwrap(evaluate("window.innerWidth", in: page) as? Double)
            let height = try XCTUnwrap(evaluate("window.innerHeight", in: page) as? Double)
            XCTAssertEqual(width - version.maxX, 12, accuracy: 0.5, "\(appearance)")
            XCTAssertEqual(height - version.maxY, 8, accuracy: 0.5, "\(appearance)")
        }
    }

    func testTheGlassFollowsTheAppearance() throws {
        let expected: [NSAppearance.Name: String] = [.aqua: "rgba(255, 255, 255, 0.74)", .darkAqua: "rgba(44, 44, 46, 0.72)"]
        for (appearance, background) in expected {
            let page = try show("Text.", appearance: appearance).webView
            try showRefusal(in: page)
            XCTAssertEqual(try evaluate("matchMedia('(prefers-color-scheme: dark)').matches", in: page) as? Bool, appearance == .darkAqua)
            XCTAssertEqual(try evaluate("getComputedStyle(document.querySelector('#mdql-notices .mdql-notice')).backgroundColor", in: page) as? String,
                           background, "\(appearance)")
            XCTAssertEqual(try evaluate("getComputedStyle(document.getElementById('mdql-label')).backgroundColor", in: page) as? String,
                           background, "\(appearance)")
        }
    }

    func testHoveringALinkShowsWhereItGoesInTheLabel() throws {
        let page = try show("[site](https://example.com/projects/timeline) and [notes](notes.md)").webView
        try evaluate("document.querySelector('a[href^=\"https\"]').dispatchEvent(new MouseEvent('mouseover', {bubbles: true})); true", in: page)
        XCTAssertEqual(try evaluate("document.getElementById('mdql-label').textContent", in: page) as? String, "example.com/projects/timeline")
        XCTAssertEqual(try evaluate("document.getElementById('mdql-label').classList.contains('visible')", in: page) as? Bool, true)

        try evaluate("document.querySelector('a[href=\"notes.md\"]').dispatchEvent(new MouseEvent('mouseover', {bubbles: true})); true", in: page)
        XCTAssertEqual(try evaluate("document.getElementById('mdql-label').textContent", in: page) as? String, "notes.md · opens here")

        try evaluate("document.querySelector('a[href=\"notes.md\"]').dispatchEvent(new MouseEvent('mouseout', {bubbles: true})); true", in: page)
        XCTAssertEqual(try evaluate("document.getElementById('mdql-label').classList.contains('visible')", in: page) as? Bool, false)
        XCTAssertEqual(try evaluate("document.getElementById('mdql-status') === null", in: page) as? Bool, true,
                       "The full-width hover strip is gone")
    }

    func testClickingAWebLinkSaysItIsOpening() throws {
        let page = try show("[site](https://example.com/projects/timeline)").webView
        try evaluate("document.querySelector('a').click(); true", in: page)
        XCTAssertEqual(try evaluate("document.getElementById('mdql-label').textContent", in: page) as? String, "Opening example.com")
    }

    // MARK: - A tick: nothing when fast, a notice when slow, and back when it fails

    func testATickSavedAtOnceShowsNothing() throws {
        let tick = try clickTask { $0(.toggled) }
        tick.clock.run(through: 10)
        settle()
        XCTAssertEqual(try notices(in: tick.page), [])
        XCTAssertEqual(try checked(in: tick.page), true)
    }

    func testATickNotSavedAfterTwoSecondsSaysItIsStillSaving() throws {
        let tick = try clickTask { _ in }
        settle()
        XCTAssertEqual(try notices(in: tick.page), [], "Nothing shows before 2 s")
        tick.clock.run(through: 2)
        try waitForNotice(.waiting, "Still saving the tick…", in: tick.page)
    }

    func testATickSavedLateTurnsTheNoticeGreen() throws {
        var answer: ((CheckboxToggleResult) -> Void)?
        let tick = try clickTask { answer = $0 }
        tick.clock.run(through: 2)
        try waitForNotice(.waiting, "Still saving the tick…", in: tick.page)
        try XCTUnwrap(answer)(.toggled)
        try waitForNotice(.cleared, "Saved · it just took a while", in: tick.page)
        XCTAssertEqual(try notices(in: tick.page), ["cleared: Saved · it just took a while"])
        XCTAssertEqual(try checked(in: tick.page), true)
    }

    func testAFailedTickGoesBackAndSaysWhy() throws {
        let tick = try clickTask { $0(.failed(PlainError("the file is read-only"))) }
        try waitForNotice(.failed, "Tick not saved · the file is read-only", in: tick.page)
        try waitUntil("document.querySelector('input[type=checkbox]').checked === false", in: tick.page)
    }

    func testATickWithNoAnswerByTenSecondsGivesUp() throws {
        var answer: ((CheckboxToggleResult) -> Void)?
        let tick = try clickTask { answer = $0 }
        tick.clock.run(through: 2)
        try waitForNotice(.waiting, "Still saving the tick…", in: tick.page)
        tick.clock.run(through: 10)
        try waitForNotice(.failed, "Tick not saved · mdql's helper didn't answer", in: tick.page)
        try waitUntil("document.querySelector('input[type=checkbox]').checked === false", in: tick.page)
        XCTAssertEqual(try notices(in: tick.page), ["failed: Tick not saved · mdql's helper didn't answer"])

        try XCTUnwrap(answer)(.toggled) // too late: it is the live update that shows it
        settle()
        XCTAssertEqual(try notices(in: tick.page), ["failed: Tick not saved · mdql's helper didn't answer"])
    }

    // MARK: - A link mdql won't open, or can't

    func testEachRefusalSaysWhyInGreyAndIsLogged() throws {
        let root = try makeFolder()
        let document = try write("Text.", to: root.appendingPathComponent("docs/page.md"))
        try write("secret", to: root.appendingPathComponent("private.md"))
        try write("plain", to: root.appendingPathComponent("docs/notes.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs/chapter.md"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("docs/link.md"),
                                                   withDestinationURL: root.appendingPathComponent("private.md"))
        let controller = try load(document)
        let since = Date()

        let refusals: [(href: String, open: (String) -> Void, reason: String)] = [
            ("smb://server/share", controller.handleOpenURL, "smb: links are off in mdql"),
            ("../private.md", controller.handleOpenMarkdown, "../private.md is outside this folder"),
            ("link.md", controller.handleOpenMarkdown, "link.md is outside this folder"),
            ("notes.txt", controller.handleOpenMarkdown, "notes.txt isn't a Markdown file"),
            ("chapter.md", controller.handleOpenMarkdown, "chapter.md isn't a regular file"),
        ]
        for refusal in refusals {
            refusal.open(refusal.href)
            try waitForNotice(.refused, "Not opened · \(refusal.reason)", in: controller.webView)
        }
        XCTAssertEqual(controller.fileURL, document, "Nothing refused may open")

        let logged = try accessLog(since: since)
        for refusal in refusals {
            XCTAssertTrue(logged.contains { $0.contains(refusal.href.replacingOccurrences(of: "../", with: "")) },
                          "\(refusal.href) must still be logged; logged: \(logged)")
        }
    }

    func testARefusedSchemeInRawHTMLSaysSoWhenClicked() throws {
        var opened: [URL] = []
        let page = try show("<a href=\"smb://server/share\">share</a> and <a href=\"mailto:someone@example.com\">mail</a>") { controller in
            controller.openURL = { url, done in opened.append(url); done(nil) }
        }.webView
        try evaluate("document.querySelector('a[href^=smb]').click(); true", in: page)
        try waitForNotice(.refused, "Not opened · smb: links are off in mdql", in: page)
        try evaluate("document.querySelector('a[href^=mailto]').click(); true", in: page)
        let deadline = Date().addingTimeInterval(5)
        while opened.isEmpty && Date() < deadline { settle(0.05) }
        XCTAssertEqual(opened.map(\.absoluteString), ["mailto:someone@example.com"], "A mailto: link opens")
    }

    func testARelativeLinkToAFileThatIsNotMarkdownSaysWhy() throws {
        let shown = try show("[plain](notes.txt)")
        try write("plain", to: shown.file.deletingLastPathComponent().appendingPathComponent("notes.txt"))
        try evaluate("document.querySelector('a').click(); true", in: shown.webView)
        try waitForNotice(.refused, "Not opened · notes.txt isn't a Markdown file", in: shown.webView)
    }

    func testALinkThatDidNotOpenSaysWhy() throws {
        let page = try show("[site](https://example.com/)") { controller in
            controller.openURL = { _, done in done(PlainError("macOS couldn't open it")) }
        }.webView
        try evaluate("document.querySelector('a').click(); true", in: page)
        try waitForNotice(.failed, "Couldn't open the link · macOS couldn't open it", in: page)
    }

    func testALinkedNoteTheViewerCannotReadSaysWhy() throws {
        let shown = try showInViewer(Data("[Notes](notes.md) and [Gone](gone.md)".utf8))
        let notes = try write("# Notes", to: shown.file.deletingLastPathComponent().appendingPathComponent("notes.md"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: notes.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notes.path) }

        try evaluate("document.querySelector('a[href=\"notes.md\"]').click(); true", in: shown.webView)
        try waitForNotice(.failed, "Couldn't open notes.md · no permission to read it", in: shown.webView)
        try evaluate("document.querySelector('a[href=\"gone.md\"]').click(); true", in: shown.webView)
        try waitForNotice(.failed, "Couldn't open gone.md · file not found", in: shown.webView)
        XCTAssertEqual(shown.controller.fileURL, shown.file, "The page stays on the file it showed")
    }

    // MARK: - A file that is not UTF-8 shows anyway

    func testAWindowsLatin1FileShowsWithALastingNoticeAndNoClickableTicks() throws {
        let file = try scratchFile(Data(contentsOf: fixtureURL("windows-1252")))
        let controller = try load(file)
        let page = controller.webView

        let visible = try visibleText(of: page)
        XCTAssertTrue(visible.contains("The crème brûlée costs 5 € and the müesli is über good."), visible)
        try waitForNotice(.failed, "Not UTF-8 · shown as Windows Latin-1, some characters may be off", in: page)
        XCTAssertEqual(try evaluate("document.querySelectorAll('input[type=checkbox]').length", in: page) as? Int, 2)
        XCTAssertEqual(try evaluate("document.querySelectorAll('input[type=checkbox][data-cb-offset]').length", in: page) as? Int, 0,
                       "A file not read as UTF-8 has no clickable checkbox")
        XCTAssertEqual(try evaluate("Array.from(document.querySelectorAll('input[type=checkbox]')).every(function (el) { return el.disabled; })", in: page) as? Bool, true)

        // A live update keeps the notice, as it keeps the encoding.
        var bytes = try Data(contentsOf: file)
        bytes.append(contentsOf: Array("\nMore.\n".utf8))
        try bytes.write(to: file)
        try waitUntil("document.body.innerText.includes('More.')", in: page)
        settle()
        XCTAssertEqual(try notices(in: page), ["failed: Not UTF-8 · shown as Windows Latin-1, some characters may be off"])
        XCTAssertEqual(try evaluate("document.querySelectorAll('input[type=checkbox][data-cb-offset]').length", in: page) as? Int, 0)

        // Saved as UTF-8, it is an ordinary file again.
        try Data("- [ ] Order the crème brûlée\n".utf8).write(to: file)
        try waitUntil("document.querySelectorAll('input[type=checkbox][data-cb-offset]').length === 1", in: page)
        try waitUntil("document.querySelectorAll('#mdql-notices .mdql-notice:not(.mdql-leaving)').length === 0", in: page)
    }

    func testAUTF8FilesTicksAreClickable() throws {
        let page = try show("- [ ] Order the crème brûlée\n").webView
        XCTAssertEqual(try evaluate("document.querySelectorAll('input[type=checkbox][data-cb-offset]').length", in: page) as? Int, 1)
        settle()
        XCTAssertEqual(try notices(in: page), [])
    }

    func testAUTF16FileWithAByteOrderMarkShows() throws {
        let page = try load(try scratchFile(Data(contentsOf: fixtureURL("utf16-bom")))).webView
        let visible = try visibleText(of: page)
        XCTAssertTrue(visible.contains("Übung macht den Meister: 5 €."), visible)
        try waitForNotice(.failed, "Not UTF-8 · shown as UTF-16", in: page)
    }

    // MARK: - Helpers

    private struct Shown {
        let controller: MarkdownWebController
        let file: URL
        /// Whatever hosts `controller` and must outlive the test, if not the test itself.
        var host: AnyObject? = nil
        var webView: WKWebView { controller.webView }
    }

    /// Writes `markdown` to a file of its own, loads it the way both hosts do,
    /// and waits until the page has finished loading.
    private func show(_ markdown: String, configure: (MarkdownWebController) -> Void = { _ in }) throws -> Shown {
        let file = try scratchFile(Data(markdown.utf8))
        let controller = MarkdownWebController()
        addTeardownBlock { controller.teardown() }
        controller.interactive = true
        controller.readFile = { url, completion in
            completion(MarkdownText.read(url))
        }
        configure(controller)
        try controller.loadMarkdownFile(at: file)
        try waitUntilLoaded(controller.webView)
        return Shown(controller: controller, file: file)
    }

    /// Writes `contents` to a file of its own and opens it as the viewer does: read
    /// as `MarkdownDocument` reads it, shown by a `DocumentWindowController`, whose
    /// checkbox toggles write to the file on disk.
    private func showInViewer(_ contents: Data) throws -> Shown {
        let file = try scratchFile(contents)
        let viewer = DocumentWindowController()
        addTeardownBlock { viewer.controller.teardown() }
        let text = try MarkdownText(contentsOf: file)
        viewer.load(text.string, encoding: text.encoding, readFrom: file)
        try waitUntilLoaded(viewer.controller.webView)
        return Shown(controller: viewer.controller, file: file, host: viewer)
    }

    /// `show`, in `appearance`.
    private func show(_ markdown: String, appearance: NSAppearance.Name) throws -> Shown {
        try show(markdown) { $0.webView.appearance = NSAppearance(named: appearance) }
    }

    /// A page reached by following a link, which has a back button.
    private func showSecondPage(in appearance: NSAppearance.Name) throws -> Shown {
        let shown = try show("[Two](two.md)", appearance: appearance)
        try Data("Second page.".utf8).write(to: shown.file.deletingLastPathComponent().appendingPathComponent("two.md"))
        try evaluate("document.querySelector('a').click(); true", in: shown.webView)
        try waitUntil("!!document.getElementById('mdql-back') && document.readyState === 'complete'", in: shown.webView)
        return shown
    }

    /// Loads `file` as both hosts do, reading through `MarkdownText`.
    private func load(_ file: URL) throws -> MarkdownWebController {
        let controller = MarkdownWebController()
        addTeardownBlock { controller.teardown() }
        controller.interactive = true
        controller.readFile = { url, completion in completion(MarkdownText.read(url)) }
        try controller.loadMarkdownFile(at: file)
        try waitUntilLoaded(controller.webView)
        return controller
    }

    /// Shows the grey notice a refused `smb:` link gets, at rest.
    private func showRefusal(in page: WKWebView, file: StaticString = #filePath, line: UInt = #line) throws {
        try stopMotion(in: page)
        try evaluate("window.webkit.messageHandlers.mdql.postMessage({action: 'openURL', url: 'smb://server/share'}); true", in: page)
        try waitForNotice(.refused, "Not opened · smb: links are off in mdql", in: page, file: file, line: line)
    }

    /// An offscreen web view never advances its animations and transitions,
    /// so a notice would stay where it enters from: this measures the page at
    /// rest instead.
    private func stopMotion(in page: WKWebView) throws {
        try evaluate("""
            var still = document.createElement('style');
            still.textContent = '*, *::before, *::after { animation: none !important; transition: none !important; }';
            document.head.appendChild(still);
            true
            """, in: page)
    }

    private func rect(of selector: String, in page: WKWebView) throws -> CGRect {
        let r = try XCTUnwrap(evaluate("""
            var r = document.querySelector('\(selector)').getBoundingClientRect(); [r.left, r.top, r.width, r.height]
            """, in: page) as? [Double])
        return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
    }

    /// Enough paragraphs that what follows them starts below the fold.
    private let filler = (1...200).map { "Line \($0)." }.joined(separator: "\n\n")

    /// Waits until the page has scrolled the element with `id` to its top.
    private func waitUntilScrolled(to id: String, in page: WKWebView, file: StaticString = #filePath, line: UInt = #line) throws {
        let target = "document.getElementById(\(String(reflecting: id)))"
        try waitUntil("document.readyState === 'complete' && !!\(target) && window.scrollY > 0"
                      + " && Math.abs(\(target).getBoundingClientRect().top) < 2",
                      in: page, file: file, line: line)
    }

    /// Clicks `- [ ] task` on a page whose saves `answer` replies to, with the
    /// controller's time run by hand.
    private func clickTask(answer: @escaping (@escaping (CheckboxToggleResult) -> Void) -> Void) throws -> (page: WKWebView, clock: ManualClock) {
        let clock = ManualClock()
        let asked = expectation(description: "the tick reached Swift")
        let page = try show("- [ ] task") { controller in
            controller.schedule = clock.schedule
            controller.toggleCheckbox = { _, _, completion in
                asked.fulfill()
                answer(completion)
            }
        }.webView
        try evaluate("document.querySelector('input[type=checkbox]').click(); true", in: page)
        wait(for: [asked], timeout: 10)
        return (page, clock)
    }

    private func checked(in page: WKWebView) throws -> Bool? {
        try evaluate("document.querySelector('input[type=checkbox]').checked", in: page) as? Bool
    }

    /// What mdql logged to `com.mdql.app` / `access` since `date`.
    private func accessLog(since date: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        return try store.getEntries(at: store.position(date: date.addingTimeInterval(-1)))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "com.mdql.app" && $0.category == "access" }
            .map(\.composedMessage)
    }

    private func scratchFile(_ contents: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("page.md")
        try contents.write(to: file)
        return file
    }

    /// The offset in `data` of the marker byte inside `[ ] <label>`'s brackets.
    private func markerOffset(of label: String, in data: Data) -> Int? {
        let needle = Array("[ ] \(label)".utf8)
        let bytes = Array(data)
        guard bytes.count >= needle.count else { return nil }
        return (0...(bytes.count - needle.count)).first { Array(bytes[$0..<($0 + needle.count)]) == needle }.map { $0 + 1 }
    }

    /// The contents of `file` once they differ from `original`, or nil if they do
    /// not within `timeout`. Runs the main run loop meanwhile, where the page's
    /// message and the write's completion arrive.
    private func waitForChange(of file: URL, from original: Data, timeout: TimeInterval = 5) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? Data(contentsOf: file), contents != original { return contents }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    /// Shows `markdown`, runs `script` in the page if given, and checks that
    /// the web view never left mdql's page: `webView.url` names a navigation
    /// as soon as it starts, even one that then fails.
    private func assertStaysPut(_ markdown: String, then script: String? = nil,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        var visited: [String] = []
        var observation: NSKeyValueObservation?
        let shown = try show(markdown) { controller in
            observation = controller.webView.observe(\.url) { webView, _ in
                visited.append(webView.url?.absoluteString ?? "nil")
            }
        }
        if let script { try evaluate(script + "; true", in: shown.webView) }
        settle(1)
        observation?.invalidate()

        XCTAssertEqual(visited.filter { $0 != "about:blank" }, [], "The page navigated away", file: file, line: line)
        XCTAssertEqual(shown.webView.url?.absoluteString, "about:blank", file: file, line: line)
        let visible = try visibleText(of: shown.webView)
        XCTAssertTrue(visible.contains("Still here."), "The document must still show; visible: \(visible)",
                      file: file, line: line)
    }
}

/// Time run by hand: what a controller schedules runs when the test says.
final class ManualClock {
    private var now: TimeInterval = 0
    private var pending: [(at: TimeInterval, work: () -> Void)] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        pending.append((now + delay, work))
    }

    /// Runs, in order, all that is due by `time` seconds after the start.
    func run(through time: TimeInterval) {
        now = time
        let due = pending.filter { $0.at <= time }.sorted { $0.at < $1.at }
        pending.removeAll { $0.at <= time }
        due.forEach { $0.work() }
    }
}

// MARK: - Shared page helpers

extension XCTestCase {

    func waitUntilLoaded(_ webView: WKWebView, file: StaticString = #filePath, line: UInt = #line) throws {
        try waitUntil("!!document.querySelector('.markdown-body') && document.readyState === 'complete'", in: webView,
                      file: file, line: line)
    }

    /// The text a reader sees: `innerText` leaves out whatever is not rendered.
    func visibleText(of webView: WKWebView) throws -> String {
        try XCTUnwrap(evaluate("document.body.innerText", in: webView) as? String)
    }

    @discardableResult
    func evaluate(_ script: String, in webView: WKWebView) throws -> Any? {
        let done = expectation(description: "evaluated \(script)")
        var result: Result<Any?, Error> = .success(nil)
        webView.evaluateJavaScript(script) { value, error in
            result = error.map { .failure($0) } ?? .success(value)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return try result.get()
    }

    func waitUntil(_ condition: String, in webView: WKWebView, timeout: TimeInterval = 10,
                   file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Result<Any?, Error> = .success(nil)
        while Date() < deadline {
            last = Result { try evaluate(condition, in: webView) }
            if case .success(let value) = last, value as? Bool == true { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Timed out waiting for \(condition); last result: \(last)", file: file, line: line)
    }

    /// Lets anything the page queued (an error event, a navigation) run.
    func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The notices on the page, each as its kind and the text it shows.
    func notices(in webView: WKWebView) throws -> [String] {
        try XCTUnwrap(evaluate("""
            Array.from(document.querySelectorAll('#mdql-notices .mdql-notice:not(.mdql-leaving)'))
                .map(function (el) { return el.className.match(/mdql-(failed|refused|waiting|cleared)/)[1] + ': ' + el.textContent; })
            """, in: webView) as? [String])
    }

    /// Waits until the page shows a notice of `kind` reading `text`.
    func waitForNotice(_ kind: PageNotice.Kind, _ text: String, in webView: WKWebView, timeout: TimeInterval = 10,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let wanted = "\(kind.rawValue): \(text)"
        let deadline = Date().addingTimeInterval(timeout)
        var shown: [String] = []
        while Date() < deadline {
            shown = (try? notices(in: webView)) ?? shown
            if shown.contains(wanted) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("No notice \(wanted.debugDescription); the page shows \(shown)", file: file, line: line)
    }
}
