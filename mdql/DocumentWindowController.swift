import Cocoa
import WebKit

/// Hosts the markdown viewer window. Owns a `MarkdownWebController` and
/// wires its file-read and url-open closures to direct (unsandboxed) calls —
/// no XPC needed.
final class DocumentWindowController: NSWindowController {

    private static let frameAutosaveName = "MarkdownDocumentWindow"
    private static let zedBundleIdentifier = "dev.zed.Zed"

    private let controller = MarkdownWebController()

    convenience init() {
        let initialFrame = NSRect(origin: .zero, size: Self.defaultContentSize())
        let window = MarkdownWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.setFrame(Self.defaultWindowFrame(for: window), display: false)
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        self.init(window: window)

        controller.webView.autoresizingMask = [.width, .height]
        window.contentView = controller.webView

        controller.interactive = true
        controller.appChrome = true
        controller.fileURLDidChange = { [weak self] _ in
            self?.synchronizeWindowTitleWithDocumentName()
        }
        controller.openURL = { url in
            NSWorkspace.shared.open(url)
        }
        controller.readFile = { url, completion in
            let content = try? String(contentsOf: url, encoding: .utf8)
            completion(content)
        }
        controller.toggleCheckbox = { [weak self] index, _, completion in
            guard let url = self?.controller.fileURL else { completion(false); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = CheckboxToggle.toggle(fileAt: url, index: index)
                DispatchQueue.main.async { completion(ok) }
            }
        }

        installToolbar(on: window)
    }

    private static func defaultContentSize() -> NSSize {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return MarkdownRenderer.previewSize
        }

        let width = min(max(visibleFrame.width * 0.74, 860), 1280)
        let height = min(max(visibleFrame.height * 0.86, 700), 1180)
        return NSSize(width: width, height: height)
    }

    private static func defaultWindowFrame(for window: NSWindow) -> NSRect {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return window.frame
        }

        var frame = window.frame
        frame.origin.x = visibleFrame.midX - frame.width / 2
        frame.origin.y = visibleFrame.midY - frame.height / 2
        return frame
    }

    /// Loads a markdown file into the window's web view. The title follows via
    /// `fileURLDidChange`, which also covers the files reached later by
    /// following links inside the preview.
    func load(fileAt url: URL) throws {
        try controller.loadMarkdownFile(at: url)
    }

    /// Titles the window with the file actually on screen, which is not always
    /// the document's own URL — following a link inside the preview swaps the
    /// rendered file without opening a new document.
    ///
    /// `representedURL` is what earns the title its Finder-style path menu:
    /// right- or ⌘-clicking the file name lists every ancestor folder up to the
    /// volume, and picking one opens it in Finder. AppKit draws and drives that
    /// menu, so there is nothing else to wire up.
    override func synchronizeWindowTitleWithDocumentName() {
        guard let window else { return }
        guard let url = controller.fileURL else {
            super.synchronizeWindowTitleWithDocumentName()
            return
        }
        window.representedURL = url
        window.title = url.lastPathComponent
    }

    private func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "MarkdownDocumentToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = false
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
    }

    @objc fileprivate func showSharePicker(_ sender: NSView) {
        guard let url = controller.fileURL else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc fileprivate func openInZed(_ sender: Any?) {
        guard let url = controller.fileURL else { return }
        guard let zedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.zedBundleIdentifier) else {
            let alert = NSAlert()
            alert.messageText = "Zed isn’t installed"
            alert.informativeText = "Install Zed from https://zed.dev to open Markdown files in it."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: zedURL,
            configuration: configuration,
            completionHandler: nil
        )
    }
}

extension DocumentWindowController: NSToolbarDelegate {

    fileprivate static let shareItemID = NSToolbarItem.Identifier("net.daringfireball.markdown.share")
    fileprivate static let openInZedItemID = NSToolbarItem.Identifier("net.daringfireball.markdown.openInZed")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.shareItemID, Self.openInZedItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.shareItemID, Self.openInZedItemID]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.shareItemID:
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            let image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")?
                .withSymbolConfiguration(symbolConfig)
            let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(showSharePicker(_:)))
            button.isBordered = false
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.imagePosition = .imageOnly
            button.sizeToFit()

            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Share"
            item.paletteLabel = "Share"
            item.toolTip = "Share"
            item.view = button
            item.isBordered = false
            item.backgroundTintColor = .clear
            return item

        case Self.openInZedItemID:
            let button = PaddedPillButton(title: "Open with Zed", target: self, action: #selector(openInZed(_:)))
            button.bezelStyle = .flexiblePush
            button.controlSize = .regular
            button.horizontalPadding = 15

            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Open with Zed"
            item.paletteLabel = "Open with Zed"
            item.toolTip = "Open the current document in Zed"
            item.view = button
            item.isBordered = false
            item.backgroundTintColor = .clear
            return item

        default:
            return nil
        }
    }
}

private final class PaddedPillButton: NSButton {
    var horizontalPadding: CGFloat = 0 {
        didSet { invalidateIntrinsicContentSize() }
    }
    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += horizontalPadding * 2
        return s
    }
}

private final class MarkdownWindow: NSWindow {

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "w":
            performClose(nil)
            return true
        case "q":
            NSApp.terminate(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
