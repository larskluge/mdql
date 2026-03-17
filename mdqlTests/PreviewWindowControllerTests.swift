import XCTest

final class PreviewWindowControllerTests: XCTestCase {

    func testWindowCreation() {
        let controller = PreviewWindowController()
        XCTAssertNotNil(controller.window)
        XCTAssertEqual(controller.window?.title, "mdql")
        let contentRect = controller.window!.contentRect(forFrameRect: controller.window!.frame)
        XCTAssertEqual(contentRect.size.width, 900)
        XCTAssertEqual(contentRect.size.height, 700)
    }

    func testLoadFile() {
        let url = Bundle(for: type(of: self)).url(forResource: "basic", withExtension: "md", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("basic.md")

        let controller = PreviewWindowController()
        controller.loadFile(url)

        XCTAssertEqual(controller.window?.title, "basic.md")
        XCTAssertEqual(controller.currentURL, url)
    }

    func testFileWatcherStarted() {
        let url = Bundle(for: type(of: self)).url(forResource: "basic", withExtension: "md", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("basic.md")

        let controller = PreviewWindowController()
        controller.loadFile(url)

        XCTAssertTrue(controller.isWatching)
    }
}
