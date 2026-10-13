import Cocoa

/// Builds the standalone app's main menu.
///
/// Extracted from `AppDelegate` so the menu structure can be unit-tested
/// without instantiating `NSApplication` (the test bundle does not run
/// `@main` and AppDelegate.swift is not compiled into mdqlTests).
///
/// Items with `target = nil` dispatch through the responder chain — that's
/// how Copy/Select All reach the focused `WKWebView`, which handles them
/// natively against the document's text selection.
enum MainMenu {

    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        return mainMenu
    }

    private static func makeAppMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "mdql", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "mdql")
        submenu.autoenablesItems = false

        submenu.addItem(makeAppItem("Hide mdql", #selector(NSApplication.hide(_:)), key: "h"))

        let hideOthers = makeAppItem(
            "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        submenu.addItem(hideOthers)

        submenu.addItem(
            makeAppItem("Show All", #selector(NSApplication.unhideAllApplications(_:)), key: "")
        )
        submenu.addItem(.separator())
        submenu.addItem(makeAppItem("Quit", #selector(NSApplication.terminate(_:)), key: "q"))

        item.submenu = submenu
        return item
    }

    /// An app-menu item aimed at `NSApp` itself rather than the responder chain.
    private static func makeAppItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = NSApp
        return item
    }

    private static func makeEditMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Edit")

        let copy = NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        submenu.addItem(copy)

        let selectAll = NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        submenu.addItem(selectAll)

        item.submenu = submenu
        return item
    }
}
