# Bug Report: Leaked "about:" WebContent Processes After View Dismissal

- **Date:** 2026-09-25
- **Status:** Fixed / Verified
- **Severity:** High (Resource leak / Process table exhaustion)
- **Affects:** `mdqlPreview.appex` (QuickLook extension) and `mdql.app` (Standalone viewer)

---

## 1. Summary

When previewing markdown files in QuickLook (or opening files in the standalone viewer) and subsequently dismissing the view, macOS leaves orphaned helper processes running indefinitely. In Activity Monitor and process listings, these processes are named:

```
about:
```
(or `com.apple.WebKit.WebContent (about:)`).

These processes remain in memory until the host daemon terminates or the system is rebooted. Each preview cycle spawns and leaks an additional WebContent process, steadily consuming system memory and process table entries.

---

## 2. Problem Description & Symptoms

1. **Reproduction Steps:**
   - In Finder, select a markdown file and press Space to open QuickLook.
   - Close the preview (press Space or Esc).
   - Repeat with several files.
   - Check Activity Monitor (filtered by "about:" or "WebContent") or inspect running processes via Terminal.

2. **Observed Behavior:**
   - For every previewed file, a new process titled `about:` appears.
   - When the preview window/view is dismissed, the process does **not** terminate.
   - Dismissing 20 previews results in 20 idle `about:` processes running in the background.

3. **Expected Behavior:**
   - When a preview is dismissed, all associated WebKit child processes (`com.apple.WebKit.WebContent`, `com.apple.WebKit.Networking`, `com.apple.WebKit.GPU`) should be promptly dismantled and terminated by the system.

---

## 3. Root Cause Analysis

The leak is caused by the interaction of three factors:

### A. Process Naming: `loadHTMLString(..., baseURL: nil)`
`WKWebView` delegates HTML execution and rendering to out-of-process WebKit XPC services (`com.apple.WebKit.WebContent`). WebKit titles WebContent processes according to the security origin/URL scheme of the loaded document.

In [`MarkdownWebController.swift`](file:///Users/johnfricker/Projects/mdql/mdqlPreview/MarkdownWebController.swift):
```swift
webView.loadHTMLString(html, baseURL: nil)
```
Because `baseURL` is `nil`, WebKit assigns the document the origin `about:blank`. Activity Monitor and process inspection APIs display the scheme as the process title: **`about:`**.

### B. Circular Retain Cycle via `WKScriptMessageHandler`
The primary bug is a circular retain cycle in [`MarkdownWebController.swift`](file:///Users/johnfricker/Projects/mdql/mdqlPreview/MarkdownWebController.swift#L54-L64):

```swift
override init() {
    let config = WKWebViewConfiguration()
    self.webView = WKWebView(frame: NSRect(origin: .zero, size: MarkdownRenderer.previewSize), configuration: config)
    super.init()
    config.userContentController.add(self, name: "mdql")
    webView.navigationDelegate = self
}

deinit {
    fileWatcher?.stop()
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "mdql")
}
```

- `WKUserContentController.add(_:name:)` retains `self` (`MarkdownWebController`) **strongly**.
- The resulting ownership graph is:
  $$\text{self (MarkdownWebController)} \longrightarrow \text{webView} \longrightarrow \text{configuration} \longrightarrow \text{userContentController} \longrightarrow \text{self}$$
- Because `userContentController` retains `self`, the retain count of `MarkdownWebController` never reaches zero.
- **`MarkdownWebController.deinit` is never called.**
- The call to `removeScriptMessageHandler(forName: "mdql")` inside `deinit` is **dead code**.
- Consequently, `self.webView` is **never deallocated**.

### C. QuickLook Extension Caching (`quicklookd` / `QuickLookUIService`)
- QuickLook extensions are hosted by long-lived macOS system daemons (`quicklookd` or `QuickLookUIService` managed via `pluginkit`).
- To make previews fast, macOS does not terminate the extension host daemon when a single preview is closed.
- When the preview view is dismissed, QuickLook drops its reference to [`PreviewController`](file:///Users/johnfricker/Projects/mdql/mdqlPreview/PreviewController.swift), but [`MarkdownWebController`](file:///Users/johnfricker/Projects/mdql/mdqlPreview/MarkdownWebController.swift) and its `WKWebView` remain alive in daemon memory due to the retain cycle.
- Because the `WKWebView` instance is never destroyed, WebKit's internal `WebPageProxy` remains active and keeps the child `com.apple.WebKit.WebContent (about:)` process alive.
- Each new preview creates a new controller and web view, leaking another `about:` process into the persistent host daemon.

---

## 4. Implementation Plan

To completely resolve the leak, we must break the retain cycle and introduce explicit teardown on view dismissal.

### Step 1: Break the Retain Cycle with a Weak Proxy Handler

Create a lightweight `WeakScriptMessageHandler` trampoline so `WKUserContentController` does not retain `MarkdownWebController`.

In [`mdqlPreview/MarkdownWebController.swift`](file:///Users/johnfricker/Projects/mdql/mdqlPreview/MarkdownWebController.swift):

```swift
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
```

Update `init`:
```swift
override init() {
    let config = WKWebViewConfiguration()
    self.webView = WKWebView(frame: NSRect(origin: .zero, size: MarkdownRenderer.previewSize), configuration: config)
    super.init()
    config.userContentController.add(WeakScriptMessageHandler(delegate: self), name: "mdql")
    webView.navigationDelegate = self
}
```

### Step 2: Implement Explicit Teardown on `MarkdownWebController`

Add a `teardown()` method to [`MarkdownWebController.swift`](file:///Users/johnfricker/Projects/mdql/mdqlPreview/MarkdownWebController.swift) to immediately dismantle WebKit resources rather than waiting for garbage collection:

```swift
/// Stops file watching and releases WebKit handlers and navigation delegates.
func teardown() {
    fileWatcher?.stop()
    fileWatcher = nil
    webView.navigationDelegate = nil
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "mdql")
    // Navigating to an empty string terminates in-flight JS and releases DOM resources
    webView.loadHTMLString("", baseURL: nil)
}
```

Keep `deinit` as a fallback safety net:
```swift
deinit {
    teardown()
}
```

### Step 3: Wire Dismissal in `PreviewController`

In [`mdqlPreview/PreviewController.swift`](file:///Users/johnfricker/Projects/mdql/mdqlPreview/PreviewController.swift), hook into `NSViewController`'s dismissal lifecycle:

```swift
override func viewDidDisappear() {
    super.viewDidDisappear()
    controller.teardown()
}

deinit {
    xpcConnection?.invalidate()
    controller.teardown()
}
```

### Step 4: Wire Dismissal in `DocumentWindowController`

In [`mdql/DocumentWindowController.swift`](file:///Users/johnfricker/Projects/mdql/mdql/DocumentWindowController.swift), conform to `NSWindowDelegate` and tear down when the window closes:

```swift
func windowWillClose(_ notification: Notification) {
    controller.teardown()
}
```

---

## 5. Verification & Testing

1. **Unit Test for Controller Deallocation:**
   Add a test in `mdqlTests/` verifying that `MarkdownWebController` deallocates when released:
   ```swift
   func testMarkdownWebControllerDeallocates() {
       weak var weakController: MarkdownWebController?
       autoreleasepool {
           let controller = MarkdownWebController()
           weakController = controller
           _ = try? controller.loadMarkdownFile(at: fixtureURL)
       }
       XCTAssertNil(weakController, "MarkdownWebController should deallocate without leaking")
   }
   ```

2. **Integration Verification via Terminal / Activity Monitor:**
   - Build and install: `make install`
   - Trigger QuickLook on a markdown file: `qlmanage -p path/to/file.md`
   - Close the preview window.
   - Verify that no lingering `about:` or `com.apple.WebKit.WebContent` processes remain associated with the preview host:
     ```bash
     pgrep -fl "WebContent.*about:"
     ```
