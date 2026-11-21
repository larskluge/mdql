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
        try write(Data(contents.utf8))
    }

    private func write(_ contents: Data) throws {
        try contents.write(to: tempURL)
    }

    private func read() throws -> String {
        try String(decoding: Data(contentsOf: tempURL), as: UTF8.self)
    }

    // MARK: - Setting a marker

    func testCheckingAnUncheckedTask() throws {
        try write("- [ ] task\n")
        XCTAssertEqual(CheckboxToggle.toggle(fileAt: tempURL, offset: 3, checked: true), .toggled)
        XCTAssertEqual(try read(), "- [x] task\n")
    }

    func testUncheckingACheckedTask() throws {
        try write("- [x] task\n")
        XCTAssertEqual(CheckboxToggle.toggle(fileAt: tempURL, offset: 3, checked: false), .toggled)
        XCTAssertEqual(try read(), "- [ ] task\n")
    }

    func testUncheckingACapitalX() throws {
        try write("- [X] task\n")
        XCTAssertEqual(CheckboxToggle.toggle(fileAt: tempURL, offset: 3, checked: false), .toggled)
        XCTAssertEqual(try read(), "- [ ] task\n")
    }

    func testOnlyOneByteDiffers() throws {
        let original = "Some text.\n- [ ] task one\nmore text\n- [ ] task two\nfinal\n"
        try write(original)
        XCTAssertEqual(CheckboxToggle.toggle(fileAt: tempURL, offset: 39, checked: true), .toggled)
        XCTAssertEqual(try read(), "Some text.\n- [ ] task one\nmore text\n- [x] task two\nfinal\n")
    }

    func testMultiByteContentBeforeTheTaskCountsInBytes() throws {
        try write("中文 header\n- [ ] task\n")
        XCTAssertEqual(CheckboxToggle.toggle(fileAt: tempURL, offset: 17, checked: true), .toggled)
        XCTAssertEqual(try read(), "中文 header\n- [x] task\n")
    }

    func testAByteOrderMarkIsKeptAndNotCounted() throws {
        // Foundation drops the mark when it decodes the file, so the offset the
        // renderer emits counts from after it.
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        try write(Data(bom + Array("- [ ] a\n- [ ] b\n".utf8)))
        XCTAssertEqual(CheckboxToggle.toggle(fileAt: tempURL, offset: 11, checked: true), .toggled)
        XCTAssertEqual(try Data(contentsOf: tempURL), Data(bom + Array("- [ ] a\n- [x] b\n".utf8)))
    }

    // MARK: - A file that is not what the page showed

    func testCheckingATaskTheFileAlreadyHasCheckedIsRefused() throws {
        let original = "- [x] task\n"
        try write(original)
        XCTAssertEqual(CheckboxToggle.toggle(fileAt: tempURL, offset: 3, checked: true), .stale)
        XCTAssertEqual(try read(), original)
    }

    func testUncheckingATaskTheFileHasUncheckedIsRefused() throws {
        let original = "- [ ] task\n"
        try write(original)
        XCTAssertEqual(CheckboxToggle.toggle(fileAt: tempURL, offset: 3, checked: false), .stale)
        XCTAssertEqual(try read(), original)
    }

    func testAnOffsetThatIsNotBetweenBracketsIsRefused() throws {
        // A line was added above the task since the page was rendered.
        let original = "New line.\n- [ ] task\n"
        try write(original)
        XCTAssertEqual(CheckboxToggle.toggle(fileAt: tempURL, offset: 3, checked: true), .stale)
        XCTAssertEqual(try read(), original)
    }

    func testAnOffsetPastTheEndIsRefused() throws {
        let original = "- [ ] only\n"
        try write(original)
        XCTAssertEqual(CheckboxToggle.toggle(fileAt: tempURL, offset: 50, checked: true), .stale)
        XCTAssertEqual(CheckboxToggle.toggle(fileAt: tempURL, offset: -1, checked: true), .stale)
        XCTAssertEqual(try read(), original)
    }

    // MARK: - A file that cannot be written

    func testNonexistentFileFails() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).md")
        XCTAssertEqual(CheckboxToggle.toggle(fileAt: missing, offset: 3, checked: true), .failed)
    }

    func testReadOnlyFileFailsAndIsNotModified() throws {
        let original = "- [ ] task\n"
        try write(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: tempURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tempURL.path)
        }
        XCTAssertEqual(CheckboxToggle.toggle(fileAt: tempURL, offset: 3, checked: true), .failed)
        XCTAssertEqual(try read(), original)
    }
}
