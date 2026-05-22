import XCTest

final class MarkdownCheckboxScannerTests: XCTestCase {

    func testSingleUncheckedReturnsOneOffset() {
        let md = "- [ ] task one\n"
        let offsets = MarkdownCheckboxScanner.scan(md)
        XCTAssertEqual(offsets, [3])
    }

    func testCheckedLowercase() {
        let md = "- [x] done\n"
        let offsets = MarkdownCheckboxScanner.scan(md)
        XCTAssertEqual(offsets, [3])
        XCTAssertEqual(Array(md.utf8)[3], 0x78) // 'x'
    }

    func testCheckedCapital() {
        let md = "- [X] done\n"
        let offsets = MarkdownCheckboxScanner.scan(md)
        XCTAssertEqual(offsets, [3])
        XCTAssertEqual(Array(md.utf8)[3], 0x58) // 'X'
    }

    func testMultipleCheckboxes() {
        let md = "- [ ] a\n- [x] b\n"
        let offsets = MarkdownCheckboxScanner.scan(md)
        XCTAssertEqual(offsets, [3, 11])
    }

    func testIndentedNestedCheckbox() {
        let md = "  - [ ] sub\n"
        let offsets = MarkdownCheckboxScanner.scan(md)
        XCTAssertEqual(offsets, [5])
    }

    func testStarAndPlusBullets() {
        let md = "* [ ] a\n+ [x] b\n"
        let offsets = MarkdownCheckboxScanner.scan(md)
        XCTAssertEqual(offsets, [3, 11])
    }

    func testOrderedListBullet() {
        let md = "1. [ ] first\n"
        let offsets = MarkdownCheckboxScanner.scan(md)
        XCTAssertEqual(offsets, [4])
    }

    func testTextWithBracketsNotACheckbox() {
        // No bullet marker — not a task list item.
        let md = "this is just [ ] in a sentence\n"
        XCTAssertEqual(MarkdownCheckboxScanner.scan(md), [])
    }

    func testEmptyInput() {
        XCTAssertEqual(MarkdownCheckboxScanner.scan(""), [])
    }

    func testFencedCodeBlockIsSkipped() {
        let md = """
        - [ ] outer
        ```
        - [ ] inside fenced
        ```
        - [x] outer2
        """
        let offsets = MarkdownCheckboxScanner.scan(md)
        XCTAssertEqual(offsets.count, 2, "Should skip checkbox inside fenced code block")
        // First checkbox at line 0, char inside [...] is at byte 3
        XCTAssertEqual(offsets[0], 3)
    }

    func testTildeFencedCodeBlockIsSkipped() {
        let md = """
        - [ ] outer
        ~~~
        - [ ] inside tilde fence
        ~~~
        - [x] outer2
        """
        let offsets = MarkdownCheckboxScanner.scan(md)
        XCTAssertEqual(offsets.count, 2)
    }

    func testMultiByteUTF8BeforeCheckboxKeepsByteOffsetCorrect() {
        // "# 中文\n" is 1 + 1 + 3 + 3 + 1 = 9 bytes (# space, 中, 文, \n)
        let md = "# 中文\n- [ ] task\n"
        let offsets = MarkdownCheckboxScanner.scan(md)
        XCTAssertEqual(offsets, [12]) // 9 (header line) + 3 (- [ )
        XCTAssertEqual(Array(md.utf8)[12], 0x20) // ' '
    }

    func testRealisticMixedDocument() {
        let md = """
        # Checkbox test

        - [ ] task one
        - [x] task two
        - [ ] task three
          - [ ] sub-task
        - [X] capital X done

        ## In code (should not be interactive)
        ```
        - [ ] inside code
        ```

        """
        let offsets = MarkdownCheckboxScanner.scan(md)
        XCTAssertEqual(offsets, [20, 35, 50, 69, 84])
        let bytes = Array(md.utf8)
        XCTAssertEqual(bytes[offsets[0]], 0x20)  // ' '
        XCTAssertEqual(bytes[offsets[1]], 0x78)  // 'x'
        XCTAssertEqual(bytes[offsets[4]], 0x58)  // 'X'
    }

    func testCountMatchesRendererCheckboxCount() {
        // Whatever the scanner finds should match what swift-markdown renders
        // as <input type="checkbox">. This is the load-bearing invariant for
        // index-based toggling.
        let md = """
        # Heading
        - [ ] a
        - [x] b
          - [ ] nested
        * [X] c
        1. [ ] numbered
        2. ordinary item
        Text with [ ] not in a list.
        ```
        - [ ] in code
        ```
        - [ ] last
        """
        let scannerCount = MarkdownCheckboxScanner.scan(md).count
        let html = MarkdownRenderer.renderBody(markdown: md)
        let rendererCount = html.components(separatedBy: "type=\"checkbox\"").count - 1
        XCTAssertEqual(scannerCount, rendererCount,
                       "Scanner count must match number of <input type=\"checkbox\"> in rendered HTML")
    }
}
