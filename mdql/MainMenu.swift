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

        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        submenu.addItem(quit)

        item.submenu = submenu
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
