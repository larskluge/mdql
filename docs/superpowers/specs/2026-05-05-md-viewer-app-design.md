# Markdown Viewer App — Design

## Goal

Promote the existing `mdql` host app from a no-op shell into a real document-based viewer that opens `.md` files in their own window with the same rendering, styling, and link/live-reload behavior as the QuickLook preview that appears when the user presses Space in Finder.

## Scope

In:
- Document-based macOS app target (reuses the existing `mdql` target / bundle / installer).
- Open `.md` / `.markdown` files via Finder double-click, `open foo.md`, drag-and-drop on icon/Dock, and File → Open.
- One window per file. Standard macOS `NSDocument` lifecycle.
- Identical visual output and interaction model to `mdqlPreview` (renderer, CSS, link interception, in-place `.md` navigation with back stack, hover status bar, live reload).
- Borderless / unified window chrome (transparent title bar, content extends under it). Filename in the title bar.
- Registered as *a* handler for `.md` (so it appears in Get Info → "Open With"). Default-handler choice stays with the user.
- Empty launch state: standard `NSDocumentController` open panel.

Out:
- Tabbed windows.
- Editing. This is read-only.
- Toolbar items (back/forward/Reveal in Finder).
- Auto-claiming the default `.md` handler.
- A separate Xcode target or app bundle.
- Welcome / Recents window.

## Approach

`mdql` becomes an `NSDocument`-based app. The existing `mdqlPreview` extension is unchanged; both targets share `MarkdownRenderer.swift`, `preview.css`, and `FileWatcher.swift` via "Compile Sources" / "Copy Bundle Resources" membership (the same pattern `mdqlTests` already uses to compile mdqlPreview sources directly).

The app is **unsandboxed**: the `mdql.entitlements` `App Sandbox` key is removed. This eliminates the need for the `mdql-open-url` XPC service from the app's perspective — `NSWorkspace.shared.open()` and `String(contentsOf:)` work directly. The XPC service stays in place for the QuickLook extension, which remains sandboxed and still needs it.

Because the sandbox model differs between the two targets, the rendering view is factored out of `PreviewController` into a reusable `MarkdownWebView` `NSView` subclass that owns the `WKWebView`, the `FileWatcher`, the in-page back stack, and the JS message handler. `PreviewController` (extension) and `DocumentWindowController` (app) both host this view but inject different file-read and URL-open closures: the extension's closures call XPC, the app's closures call `String(contentsOf:)` and `NSWorkspace.shared.open()` directly.

## Components

### `MarkdownWebView` (new, shared)

`mdqlPreview/MarkdownWebView.swift`. An `NSView` containing a `WKWebView` plus the JS↔Swift bridge, the back-stack navigation, the file watcher, and the rendering pipeline.

Public surface:
```swift
final class MarkdownWebView: NSView {
    var openURL: (URL) -> Void                     // injected
    var readFile: (URL, @escaping (String?) -> Void) -> Void  // injected

    func load(fileAt url: URL) throws              // initial load
    var currentFileURL: URL? { get }
}
```

Internals (moved verbatim from `PreviewController`):
- `WKWebView` configuration with `WKScriptMessageHandler` named `"mdql"`.
- `WKNavigationDelegate.decidePolicyFor` cancels `.linkActivated`.
- Message actions `openURL`, `openMarkdown`, `goBack` — same dispatch as today.
- `fileHistory: [URL]` back stack.
- `FileWatcher` lifecycle, `reloadContent()` innerHTML injection.
- Calls `MarkdownRenderer.render(...)` / `renderBody(...)` — unchanged.

### `PreviewController` (existing, refactored)

`mdqlPreview/PreviewController.swift`. Becomes a thin `QLPreviewingController` shell that owns a `MarkdownWebView` and wires its `openURL` / `readFile` closures to the XPC service. All rendering and navigation logic moves into `MarkdownWebView`.

### `DocumentWindowController` (new)

`mdql/DocumentWindowController.swift`. Owns the borderless window plus a `MarkdownWebView`. Wires:
- `openURL = { NSWorkspace.shared.open($0) }`
- `readFile = { url, cb in cb(try? String(contentsOf: url, encoding: .utf8)) }`

Window configuration:
- `styleMask`: `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`
- `titlebarAppearsTransparent = true`
- `titleVisibility = .visible` (filename appears via `NSDocument.displayName`)
- `isMovableByWindowBackground = false`
- `setFrameAutosaveName("MarkdownDocumentWindow")` for size/position persistence
- The `MarkdownWebView` is set as the content view; its top edge sits under the transparent title bar (matches mockup C).

### `MarkdownDocument` (new)

`mdql/MarkdownDocument.swift`. `NSDocument` subclass.

```swift
final class MarkdownDocument: NSDocument {
    override func makeWindowControllers() {
        let wc = DocumentWindowController()
        addWindowController(wc)
        if let url = fileURL { try? wc.load(fileAt: url) }
    }

    override func read(from url: URL, ofType typeName: String) throws {
        // No in-memory model — MarkdownWebView reads & renders directly.
        // We override read(from:ofType:) instead of read(from:Data) so we
        // get the URL (NSDocument's default reads Data and discards the URL).
    }

    override class var autosavesInPlace: Bool { false }
    override var isDocumentEdited: Bool { false }
}
```

Override `read(from url:ofType:)` rather than `read(from data:)` so the document keeps the source URL — `MarkdownWebView` needs the URL (not just the bytes) to resolve relative `.md` links and to start the `FileWatcher`.

### `AppDelegate` (existing, expanded)

`mdql/AppDelegate.swift` no longer just no-ops. It becomes:
```swift
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    // Other behavior comes from NSDocumentController defaults.
}
```
- Returning `false` from `applicationShouldOpenUntitledFile` lets `NSDocumentController` show its default open panel when the app is launched without a document — that satisfies Q8(a) without custom code.
- Last-window-close behavior: keep `NSApplication`'s default (app stays running). Re-launching from Finder reuses the running process.

## Info.plist / entitlements changes

`mdql/Info.plist`:
- Add `CFBundleDocumentTypes` declaring `.md` / `.markdown` with `LSHandlerRank = Alternate` (polite — don't claim default).
  ```xml
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Markdown Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>net.daringfireball.markdown</string></array>
    </dict>
  </array>
  ```
- `LSHandlerRank = Alternate` is what makes the registration polite: the app appears in "Open With" but isn't claimed as the default for the UTI.

`mdql/mdql.entitlements`:
- Remove `com.apple.security.app-sandbox` (and any sandbox-only keys). The host app becomes unsandboxed. The extension's entitlements are untouched.

## File changes summary

| File | Change |
|------|--------|
| `mdqlPreview/MarkdownWebView.swift` | **new** — extracted view + bridge |
| `mdqlPreview/PreviewController.swift` | refactor to host `MarkdownWebView`, keep XPC wiring |
| `mdql/AppDelegate.swift` | add `applicationShouldOpenUntitledFile` returning `false` |
| `mdql/MarkdownDocument.swift` | **new** — `NSDocument` subclass |
| `mdql/DocumentWindowController.swift` | **new** — borderless window + `MarkdownWebView` host |
| `mdql/Info.plist` | add `CFBundleDocumentTypes` for `.md` (rank Alternate) |
| `mdql/mdql.entitlements` | remove sandbox |
| `mdql.xcodeproj` | add `MarkdownWebView.swift` / `MarkdownRenderer.swift` / `FileWatcher.swift` / `preview.css` to mdql target's Compile Sources & Copy Bundle Resources phases; add new mdql Swift files |
| `mdqlTests` | add target membership for `MarkdownWebView.swift`, new `MarkdownDocumentTests.swift` |

## Data flow

**Open from Finder / `open foo.md` / drag-drop / File→Open:**
```
Launch Services → NSDocumentController
  → MarkdownDocument(contentsOf: url, ofType: "net.daringfireball.markdown")
  → makeWindowControllers()
  → DocumentWindowController.load(fileAt: url)
  → MarkdownWebView.load(fileAt: url)
  → MarkdownRenderer.render(fileAt: url)
  → WKWebView.loadHTMLString(...)
  → FileWatcher.start(url)
```

**Click `<a href="https://…">`:**
```
JS → window.webkit.messageHandlers.mdql.postMessage({action:"openURL", url})
  → MarkdownWebView dispatches to injected openURL closure
  → DocumentWindowController: NSWorkspace.shared.open(url)
```

**Click `<a href="./other.md">`:**
```
JS → action:"openMarkdown"
  → MarkdownWebView resolves relative URL, calls injected readFile closure
  → DocumentWindowController: String(contentsOf: resolved)
  → push current URL onto fileHistory, render new content, restart FileWatcher
```

**File saved on disk:**
```
DispatchSource (FileWatcher) fires → MarkdownWebView.reloadContent()
  → readFile closure → MarkdownRenderer.renderBody(...)
  → evaluateJavaScript('document.querySelector(".markdown-body").innerHTML = ...')
```

## Testing

- New `mdqlTests/MarkdownDocumentTests.swift`:
  - Loading a fixture `.md` populates the document's `fileURL` and the window controller's `MarkdownWebView` reports the same `currentFileURL`.
  - `MarkdownDocument.autosavesInPlace == false`, `isDocumentEdited == false`.
  - `read(from:ofType:)` does not throw on valid fixtures.
- Existing `PreviewControllerTests` continue to pass against the refactored controller (the public test surface — `handleOpenURL` / `handleOpenMarkdown` — is preserved by re-exposing them on `MarkdownWebView` and forwarding from `PreviewController` for backward compatibility, or the tests are moved to target `MarkdownWebView` directly if the forwarding is judged dead weight).

## Install / make changes

- `Makefile` `make install` flow is unchanged — it already builds Release, copies `mdql.app` to `~/Applications`, and registers via `scripts/install.sh`.
- `scripts/install.sh`: `lsregister -f -R` already re-scans the bundle; the new `CFBundleDocumentTypes` entry will be picked up automatically. No script changes required.
- After `make install`, double-clicking a `.md` in Finder will *not* open in mdql by default (rank Alternate). The user opts in via Get Info → "Open With" → mdql → "Change All…". This is intentional (Q7a).

## Risks & open mitigations

- **Sandbox change to host app.** Removing the sandbox is a real entitlement change. The extension stays sandboxed (its entitlement file is separate). Verify `make install` still produces a single, working pluginkit registration after the change.
- **Code-signing.** `scripts/install.sh` re-signs with `--sign -` (ad-hoc) without `--deep` to preserve the extension's signature. This still works for an unsandboxed host app; no script change needed.
- **`NSDocument.read(from:Data)` vs `read(from:URL)`.** Default `NSDocument` reads `Data` and discards the URL. Overriding `read(from url:ofType:)` is the documented way to keep the URL — required because the renderer and watcher are URL-driven, not content-driven.
- **Live reload on rapidly-changing files.** Existing `FileWatcher` already coalesces at 100 ms; behavior carries over unchanged.

## Non-goals (explicit)

- No window restoration of *which files were open* across launches (macOS document-app default state restoration is acceptable; nothing custom).
- No menu items for back/forward — the in-content chevron remains the only back affordance, matching the QuickLook preview.
- No print menu support, no export, no find-in-page.
- No syncing scroll position across live reloads (the existing `innerHTML` injection preserves scroll because only the body content is replaced).
