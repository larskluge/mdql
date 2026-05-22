import XCTest

final class CheckboxToggleTests: XCTestCase {

    private var tempURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
        tempURL = dir.appendingPathComponent("checkbox-toggle-\(UUID().uuidString).md")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    private func write(_ contents: String) throws {
        try contents.write(to: tempURL, atomically: true, encoding: .utf8)
    }

    private func read() throws -> String {
        try String(contentsOf: tempURL, encoding: .utf8)
    }

    // MARK: - Tests

    func testToggleUncheckedBecomesChecked() throws {
        try write("- [ ] task\n")
        let ok = CheckboxToggle.toggle(fileAt: tempURL, index: 0)
        XCTAssertTrue(ok)
        XCTAssertEqual(try read(), "- [x] task\n")
    }

    func testToggleCheckedBecomesUnchecked() throws {
        try write("- [x] task\n")
        XCTAssertTrue(CheckboxToggle.toggle(fileAt: tempURL, index: 0))
        XCTAssertEqual(try read(), "- [ ] task\n")
    }

    func testToggleCapitalCheckedBecomesUnchecked() throws {
        try write("- [X] task\n")
        XCTAssertTrue(CheckboxToggle.toggle(fileAt: tempURL, index: 0))
        XCTAssertEqual(try read(), "- [ ] task\n")
    }

    func testToggleSecondCheckboxLeavesFirstUntouched() throws {
        try write("- [ ] a\n- [ ] b\n")
        XCTAssertTrue(CheckboxToggle.toggle(fileAt: tempURL, index: 1))
        XCTAssertEqual(try read(), "- [ ] a\n- [x] b\n")
    }

    func testOnlyOneByteDiffers() throws {
        let original = "Some text.\n- [ ] task one\nmore text\n- [ ] task two\nfinal\n"
        try write(original)
        XCTAssertTrue(CheckboxToggle.toggle(fileAt: tempURL, index: 1))
        let after = try read()
        let originalBytes = Array(original.utf8)
        let afterBytes = Array(after.utf8)
        XCTAssertEqual(originalBytes.count, afterBytes.count)
        var diffs = 0
        for i in 0..<originalBytes.count where originalBytes[i] != afterBytes[i] {
            diffs += 1
        }
        XCTAssertEqual(diffs, 1, "Exactly one byte should differ")
    }

    func testOutOfRangeIndexReturnsFalseAndDoesNotModify() throws {
        let original = "- [ ] only\n"
        try write(original)
        XCTAssertFalse(CheckboxToggle.toggle(fileAt: tempURL, index: 5))
        XCTAssertEqual(try read(), original)
    }

    func testNonexistentFileReturnsFalse() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).md")
        XCTAssertFalse(CheckboxToggle.toggle(fileAt: missing, index: 0))
    }

    func testReadOnlyFileReturnsFalseAndDoesNotModify() throws {
        let original = "- [ ] task\n"
        try write(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: tempURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tempURL.path)
        }
        XCTAssertFalse(CheckboxToggle.toggle(fileAt: tempURL, index: 0))
        XCTAssertEqual(try read(), original)
    }

    func testMultiByteContentBeforeCheckboxToggleWritesAtCorrectByteOffset() throws {
        // Multi-byte chars before the checkbox — ensure we don't write at a char index.
        let original = "中文 header\n- [ ] task\n"
        try write(original)
        XCTAssertTrue(CheckboxToggle.toggle(fileAt: tempURL, index: 0))
        XCTAssertEqual(try read(), "中文 header\n- [x] task\n")
    }
}
