import XCTest

final class FileWatcherTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileWatcherTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func tempFile(_ name: String = "test.md", content: String = "# Hello") -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testCallbackOnFileWrite() {
        let url = tempFile()
        let expectation = self.expectation(description: "callback fires")

        let watcher = FileWatcher(url: url) {
            expectation.fulfill()
        }
        watcher.start()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            try! "# Updated".write(to: url, atomically: false, encoding: .utf8)
        }

        waitForExpectations(timeout: 2)
        watcher.stop()
    }

    func testCoalescing() {
        let url = tempFile()
        var callCount = 0
        let expectation = self.expectation(description: "coalesced callback")

        let watcher = FileWatcher(url: url) {
            callCount += 1
            if callCount == 1 {
                expectation.fulfill()
            }
        }
        watcher.start()

        // Rapid-fire writes
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            for i in 0..<10 {
                try! "# Write \(i)".write(to: url, atomically: false, encoding: .utf8)
                usleep(5000) // 5ms between writes
            }
        }

        waitForExpectations(timeout: 2)
        // Wait a bit more to ensure no extra callbacks
        let extra = self.expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { extra.fulfill() }
        waitForExpectations(timeout: 1)

        // Should have fired very few times due to coalescing (not 10)
        XCTAssertLessThanOrEqual(callCount, 3, "Coalescing should batch rapid writes")
        watcher.stop()
    }

    func testAtomicSave() {
        let url = tempFile()
        let expectation = self.expectation(description: "atomic save detected")

        let watcher = FileWatcher(url: url) {
            expectation.fulfill()
        }
        watcher.start()

        // Simulate atomic save: write to temp file, then rename over original
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            let tmpURL = self.tempDir.appendingPathComponent("tmp-atomic")
            try! "# Atomic".write(to: tmpURL, atomically: false, encoding: .utf8)
            try! FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
        }

        waitForExpectations(timeout: 2)
        watcher.stop()
    }

    func testStop() {
        let url = tempFile()
        var callbackFired = false

        let watcher = FileWatcher(url: url) {
            callbackFired = true
        }
        watcher.start()
        watcher.stop()

        XCTAssertFalse(watcher.isWatching)

        // Write after stop
        try! "# After stop".write(to: url, atomically: false, encoding: .utf8)

        let settle = self.expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        waitForExpectations(timeout: 1)

        XCTAssertFalse(callbackFired, "Callback should not fire after stop")
    }

    func testDeinit() {
        let url = tempFile()
        var watcher: FileWatcher? = FileWatcher(url: url) {}
        watcher?.start()
        XCTAssertTrue(watcher!.isWatching)
        watcher = nil
        // No crash = pass
    }

    func testDoubleStart() {
        let url = tempFile()
        var callCount = 0
        let expectation = self.expectation(description: "callback fires")

        let watcher = FileWatcher(url: url) {
            callCount += 1
            if callCount == 1 { expectation.fulfill() }
        }
        watcher.start()
        watcher.start() // Should be no-op

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            try! "# Updated".write(to: url, atomically: false, encoding: .utf8)
        }

        waitForExpectations(timeout: 2)
        let settle = self.expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        waitForExpectations(timeout: 1)

        // Double start should not cause double callbacks
        XCTAssertEqual(callCount, 1, "Double start should not cause duplicate callbacks")
        watcher.stop()
    }

    func testStopThenRestart() {
        let url = tempFile()
        let expectation = self.expectation(description: "callback after restart")

        let watcher = FileWatcher(url: url) {
            expectation.fulfill()
        }
        watcher.start()
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)

        watcher.start()
        XCTAssertTrue(watcher.isWatching)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            try! "# Restarted".write(to: url, atomically: false, encoding: .utf8)
        }

        waitForExpectations(timeout: 2)
        watcher.stop()
    }

    func testRapidStopStartDoesNotLoseEvents() {
        let url = tempFile()
        let expectation = self.expectation(description: "callback after rapid stop/start")

        let watcher = FileWatcher(url: url) {
            expectation.fulfill()
        }

        // Rapid stop/start cycles — the old cancel handler must not close
        // the new file descriptor (race condition fixed in df22604)
        for _ in 0..<5 {
            watcher.start()
            watcher.stop()
        }
        watcher.start()
        XCTAssertTrue(watcher.isWatching)

        // Give the async cancel handlers from previous cycles time to fire
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            try! "# After rapid cycles".write(to: url, atomically: false, encoding: .utf8)
        }

        waitForExpectations(timeout: 2)
        watcher.stop()
    }

    func testStoppingAndStartingWhileTheFileChanges() {
        // Events arrive while the owner stops and restarts the watcher, as
        // following links does. Run under Thread Sanitizer, this is the check that
        // the watcher's state is only touched from one thread.
        let url = tempFile()
        let watcher = FileWatcher(url: url) {}
        let written = expectation(description: "writes finished")
        DispatchQueue.global().async {
            for i in 0..<200 {
                try? "# Write \(i)".write(to: url, atomically: i % 2 == 0, encoding: .utf8)
                usleep(1000)
            }
            written.fulfill()
        }
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            watcher.start()
            RunLoop.current.run(until: Date().addingTimeInterval(0.003))
            watcher.stop()
        }
        wait(for: [written], timeout: 10)
        XCTAssertFalse(watcher.isWatching)
    }

    func testCallbackOnMainThread() {
        let url = tempFile()
        let expectation = self.expectation(description: "callback on main")
        var wasMainThread = false

        let watcher = FileWatcher(url: url) {
            wasMainThread = Thread.isMainThread
            expectation.fulfill()
        }
        watcher.start()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            try! "# Thread test".write(to: url, atomically: false, encoding: .utf8)
        }

        waitForExpectations(timeout: 2)
        XCTAssertTrue(wasMainThread, "Callback should fire on main thread")
        watcher.stop()
    }

    func testNonexistentFile() {
        let url = tempDir.appendingPathComponent("nonexistent.md")
        let watcher = FileWatcher(url: url) {}
        watcher.start()
        // Should not crash, just silently fail to monitor
        XCTAssertTrue(watcher.isWatching, "isWatching should be true even if file doesn't exist")
        watcher.stop()
    }
}
