# mdql

A macOS Quick Look extension for previewing Markdown files. Press Space on any `.md` file in Finder to see a rendered preview — with **live updates** as the file changes.

![mdql preview](assets/preview.png)

## Features

- **Live preview** — edit a Markdown file and watch the QuickLook preview update in real-time
- **GitHub Flavored Markdown** — tables, task lists, strikethrough, fenced code blocks with language hints
- **Follow `.md` links** — click a relative `.md`/`.markdown` link to navigate to that file inside the same preview, with a back button and hover status bar showing where each link goes
- **Light & dark mode** — automatically follows system appearance
- **Inkpad-inspired styling** — clean typography with thoughtful spacing and color tokens. Big shout out to Mariusz and Matt for the epic work together on Inkpad nearly a decade ago
- **Fast** — uses Apple's [swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm) for native-speed parsing

## Requirements

- macOS 12.0+
- Xcode 15.0+

## Todo

- [ ] **Faithful Inkpad styling** — Audit the current CSS against the original Inkpad design and bring any missing or divergent styles closer to the source. Some elements (blockquotes, nested lists, code blocks) may need refinement to fully match Inkpad's look and feel.
- [ ] **Incremental DOM updates** — Currently, every file change replaces the entire `.markdown-body` innerHTML. This works but is wasteful: a single-character edit re-renders and re-injects the full document HTML. Instead, diff the old and new rendered HTML and patch only the changed DOM nodes. This would reduce flicker on large documents, preserve any in-page state (e.g., text selection), and improve performance for files with hundreds of sections. Changed elements should briefly highlight (e.g., a subtle flash or background pulse) so the user can instantly see what updated in the preview.

## Install

```bash
make install
```

This builds a Release binary, copies it to `~/Applications/`, cleans up all stale DerivedData and duplicate registrations, registers the QuickLook extension, and verifies everything is correct. Press Space on any `.md` file in Finder to preview.

## Test

```bash
xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' test
```

## How Live Updates Work

Getting live-updating QuickLook previews on macOS is surprisingly difficult. QuickLook extensions run in a strict sandbox, and the obvious approaches all fail. Here's what we learned and how we solved it.

### The problem

By default, QuickLook extensions use **data-based previews** (`QLIsDataBasedPreview=true`): the extension returns an HTML blob once, QuickLook renders it, and that's it. The preview is a static snapshot — if the file changes, nothing happens until the user closes and re-opens the preview.

### What doesn't work

We tried every approach we could find. None of them work inside the QuickLook extension sandbox:

- **JavaScript polling** — Embedding `fetch()`, `XMLHttpRequest`, or `EventSource` in the HTML to poll for changes. The sandbox blocks all network access from the WebView, including `file://` URLs and `http://127.0.0.1`.

- **NSAttributedString(html:)** — Renders HTML in-process (no sandbox issues), but its CSS engine is extremely limited. No CSS custom properties (`var()`), no `@media` queries, no advanced selectors. Our stylesheet renders with broken fonts, colors, and layout.

- **Embedded HTTP server** — Running an `NWListener` inside the extension to serve updated content. The sandbox denies `networkd.plist` access and the port stays at 0.

- **localStorage / WebSocket / SSE** — All blocked by the sandbox.

### What works: WKWebView + WKScriptMessageHandler + DispatchSource FileWatcher

The solution uses four components working together:

**1. View-based preview (`QLIsDataBasedPreview=false`)**

Instead of returning data, the extension provides an `NSView` that stays alive for the lifetime of the QuickLook panel. This is the key enabler — it gives us a persistent view we can update.

```swift
func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
    let html = try MarkdownRenderer.render(fileAt: url)
    webView.loadHTMLString(html, baseURL: nil)
    handler(nil)
    // Start watching for changes...
}
```

**2. WKWebView with `network.client` entitlement**

WKWebView spawns out-of-process XPC subprocesses (WebContent, GPU, Networking) that the sandbox blocks by default. The fix is adding the `com.apple.security.network.client` entitlement to the extension — WKWebView requires this even for local HTML because it communicates with its subprocesses via XPC. This was a known WebKit bug on macOS Big Sur (fixed in macOS 12 via WebKit Changeset 271895).

Link clicks are intercepted in JavaScript and dispatched to Swift via `WKScriptMessageHandler`, where they're opened in the default browser.

**3. FileWatcher (DispatchSource with `O_EVTONLY`)**

A `DispatchSource.makeFileSystemObjectSource` monitors the file for `.write`, `.rename`, `.delete`, and `.attrib` events. This works inside the sandbox because the extension has read access to the previewed file.

Key details:
- **Atomic save recovery** — Editors like vim and `sed -i` delete the original file and rename a temp file in its place. The watcher detects `.rename`/`.delete` events, closes the old file descriptor, waits 50ms for the new file to settle, then re-opens at the same path.
- **100ms coalescing** — Rapid writes (e.g., `echo` in a loop) are batched via a `DispatchWorkItem` that resets on each event. Only the final state triggers a callback.
- **Main thread callback** — The callback dispatches to the main thread so it's safe to update the WebView.

**4. innerHTML injection (no flicker, no scroll loss)**

On file change, instead of reloading the entire page (which would flicker and reset scroll position), we:
1. Re-read the file and render body-only HTML via `MarkdownRenderer.renderBody()`
2. Base64-encode the HTML
3. Inject it via JavaScript: `document.querySelector('.markdown-body').innerHTML = ...`

The page frame (CSS, `<head>`, etc.) stays loaded — only the content inside `<article class="markdown-body">` swaps.

The base64 + `TextDecoder` dance is necessary because JavaScript's `atob()` produces a Latin-1 string, not UTF-8. Multi-byte characters like em-dashes (`—`) would get mangled without it:
```javascript
// This breaks UTF-8: atob(base64)
// This works: decode bytes as UTF-8
new TextDecoder().decode(Uint8Array.from(atob(base64), c => c.charCodeAt(0)))
```

### Installation matters

Finder's QuickLook **only reliably discovers extensions** from apps installed in `/Applications` or `~/Applications`. Running from Xcode's DerivedData directory causes:
- Finder shows a file icon instead of the rendered preview
- Multiple DerivedData copies create duplicate extension registrations
- Duplicate registrations cause `key cannot be nil` crashes in `ExtensionFoundation`

This is handled by `scripts/install.sh`, the single source of truth for installation and registration. It copies the app to `~/Applications/`, unregisters all stale DerivedData and sandbox container entries from `lsregister`, registers the canonical copy, and launches the app to finalize `pluginkit` registration. Both the Xcode post-build phase and `make install` call this script. The AppDelegate itself is a no-op — the app sandbox prevents it from running `lsregister` or `qlmanage`.

### Cross-target bundle resolution

`MarkdownRenderer.swift` is compiled into multiple targets (mdqlPreview, mdqlTests). Using `Bundle(for: PreviewController.self)` to load `preview.css` fails in the test target because `PreviewController` resolves to the test bundle, which doesn't contain the CSS. The fix is a private `BundleAnchor` class in the same file:

```swift
private class BundleAnchor {}
// ...
Bundle(for: BundleAnchor.self).url(forResource: "preview", withExtension: "css")
```

`BundleAnchor` always resolves to the bundle that contains `MarkdownRenderer.swift`, regardless of which target is running.
