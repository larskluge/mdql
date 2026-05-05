import XCTest
import Cocoa

final class MainMenuTests: XCTestCase {

    // MARK: - App menu (existing behavior, locked in by these tests)

    func testAppMenuExistsWithQuit() {
        let menu = MainMenu.make()
        let appItem = menu.items.first
        XCTAssertNotNil(appItem?.submenu, "First item must have an app submenu")

        let quit = appItem?.submenu?.items.first { $0.title == "Quit" }
        XCTAssertNotNil(quit, "App menu must have a Quit item")
        XCTAssertEqual(quit?.keyEquivalent, "q")
        XCTAssertEqual(quit?.action, #selector(NSApplication.terminate(_:)))
    }

    // MARK: - Edit menu (new feature: copy + select all)

    private func editSubmenu(in menu: NSMenu) -> NSMenu? {
        return menu.items.first { $0.title == "Edit" }?.submenu
    }

    func testEditMenuExists() {
        let menu = MainMenu.make()
        XCTAssertNotNil(editSubmenu(in: menu), "Main menu must contain an Edit submenu")
    }

    func testEditMenuHasCopyItem() {
        let menu = MainMenu.make()
        let edit = editSubmenu(in: menu)
        let copy = edit?.items.first { $0.action == #selector(NSText.copy(_:)) }

        XCTAssertNotNil(copy, "Edit menu must have a Copy item wired to copy:")
        XCTAssertEqual(copy?.keyEquivalent, "c", "Copy must use ⌘C")
        XCTAssertEqual(copy?.keyEquivalentModifierMask, .command,
                       "Copy must use the plain ⌘ modifier (no shift/option)")
        XCTAssertNil(copy?.target,
                     "Copy must dispatch to the first responder (target = nil)")
    }

    func testEditMenuHasSelectAllItem() {
        let menu = MainMenu.make()
        let edit = editSubmenu(in: menu)
        let selectAll = edit?.items.first { $0.action == #selector(NSText.selectAll(_:)) }

        XCTAssertNotNil(selectAll, "Edit menu must have a Select All item wired to selectAll:")
        XCTAssertEqual(selectAll?.keyEquivalent, "a", "Select All must use ⌘A")
        XCTAssertEqual(selectAll?.keyEquivalentModifierMask, .command)
        XCTAssertNil(selectAll?.target,
                     "Select All must dispatch to the first responder (target = nil)")
    }
}
