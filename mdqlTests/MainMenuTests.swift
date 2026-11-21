import XCTest
import Cocoa

final class MainMenuTests: XCTestCase {

    // MARK: - App menu

    private func appSubmenu(in menu: NSMenu) -> NSMenu? {
        return menu.items.first?.submenu
    }

    func testAppMenuExistsWithQuit() {
        let app = appSubmenu(in: MainMenu.make())
        XCTAssertNotNil(app, "First item must have an app submenu")

        let quit = app?.items.first { $0.title == "Quit" }
        XCTAssertNotNil(quit, "App menu must have a Quit item")
        XCTAssertEqual(quit?.keyEquivalent, "q")
        XCTAssertEqual(quit?.action, #selector(NSApplication.terminate(_:)))
    }

    func testAppMenuHasHideItem() {
        let app = appSubmenu(in: MainMenu.make())
        let hide = app?.items.first { $0.action == #selector(NSApplication.hide(_:)) }

        XCTAssertNotNil(hide, "App menu must have a Hide item wired to hide:")
        XCTAssertEqual(hide?.title, "Hide mdql")
        XCTAssertEqual(hide?.keyEquivalent, "h", "Hide must use ⌘H")
        XCTAssertEqual(hide?.keyEquivalentModifierMask, .command,
                       "Hide must use the plain ⌘ modifier (no shift/option)")
    }

    func testAppMenuHasHideOthersItem() {
        let app = appSubmenu(in: MainMenu.make())
        let hideOthers = app?.items.first {
            $0.action == #selector(NSApplication.hideOtherApplications(_:))
        }

        XCTAssertNotNil(hideOthers, "App menu must have a Hide Others item wired to hideOtherApplications:")
        XCTAssertEqual(hideOthers?.title, "Hide Others")
        XCTAssertEqual(hideOthers?.keyEquivalent, "h")
        XCTAssertEqual(hideOthers?.keyEquivalentModifierMask, [.command, .option],
                       "Hide Others must use ⌥⌘H, so it cannot shadow Hide's ⌘H")
    }

    func testAppMenuHasShowAllItem() {
        let app = appSubmenu(in: MainMenu.make())
        let showAll = app?.items.first {
            $0.action == #selector(NSApplication.unhideAllApplications(_:))
        }

        XCTAssertNotNil(showAll, "App menu must have a Show All item wired to unhideAllApplications:")
        XCTAssertEqual(showAll?.title, "Show All")
        XCTAssertEqual(showAll?.keyEquivalent, "", "Show All has no shortcut on macOS")
    }

    func testAppMenuSeparatesHideGroupFromQuit() {
        let items = appSubmenu(in: MainMenu.make())?.items ?? []

        XCTAssertEqual(items.last?.action, #selector(NSApplication.terminate(_:)),
                       "Quit must stay the last item of the app menu")
        XCTAssertEqual(items.dropLast().last?.isSeparatorItem, true,
                       "A separator must sit between the hide group and Quit")
    }

    // MARK: - Edit menu

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
