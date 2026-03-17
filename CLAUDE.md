# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build all targets
xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' build

# Run all tests
xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' test

# Run a single test
xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' \
  -only-testing:mdqlTests/MarkdownRendererTests/testRenderBasicMarkdown test

# Install to ~/Applications (REQUIRED after every build for Finder QuickLook to work)
cp -R ~/Library/Developer/Xcode/DerivedData/mdql-*/Build/Products/Debug/mdql.app ~/Applications/mdql.app
qlmanage -r

# Manual preview test
qlmanage -p /path/to/file.md
```

**IMPORTANT:** Always install the built app to `~/Applications/` after building. Finder's QuickLook only reliably discovers extensions from apps in `/Applications` or `~/Applications`, not from DerivedData. Without this step, pressing Space in Finder will show a file icon instead of the rendered preview. Multiple copies in DerivedData can also cause duplicate extension registrations and crashes.

## Architecture

macOS QuickLook preview extension for Markdown files. Three Xcode targets:

- **mdql** — Minimal host app (required to carry the extension; does nothing itself)
- **mdqlPreview** — QuickLook Preview Extension (.appex). View-based preview (`QLIsDataBasedPreview=false`) using legacy `WebView` + FileWatcher for live updates in Finder. Registered for `net.daringfireball.markdown` UTI.
- **mdqlTests** — Unit tests. Compiles mdqlPreview and mdql sources directly (not hosted tests) since app extensions can't be imported as modules by test bundles.

**Data flow:** Finder Space → `PreviewController.preparePreviewOfFile(at:)` → `MarkdownRenderer.render(fileAt:)` → legacy `WebView.mainFrame.loadHTMLString()`. FileWatcher triggers innerHTML injection via `stringByEvaluatingJavaScript(from:)`.

**Single external dependency:** `swift-markdown` (swiftlang/swift-markdown, branch: main) — provides GFM support (tables, strikethrough, task lists) via cmark-gfm under the hood. Added to mdqlPreview and mdqlTests targets.

## Key Files

- `mdqlPreview/MarkdownRenderer.swift` — Core rendering. `render()` for full HTML with CSS, `renderBody()` for body-only HTML (used by innerHTML updates). Uses `BundleAnchor` class for cross-target bundle resolution.
- `mdqlPreview/Resources/preview.css` — Inkpad-derived design tokens. Uses CSS custom properties with `@media (prefers-color-scheme: dark)` for automatic dark mode. Key tokens: text `#3f3b3d`, bg `#f9f9f9`, links `#4183c4`.
- `mdqlPreview/PreviewController.swift` — View-based QLPreviewingController with legacy WebView + FileWatcher for live updates.
- `mdql/FileWatcher.swift` — DispatchSource file monitor with rename/delete recovery and 100ms coalescing.
- `mdqlTests/Fixtures/` — Test markdown files (basic, gfm, empty, special-chars).

## Project Constraints

- Xcode project (not SPM) because Quick Look extensions require `.appex` embedded in `.app`
- Deployment target: macOS 12.0
- App sandbox enabled on both host app and extension; extension has read-only file access
- CSS is loaded from the bundle at runtime via `Bundle(for: BundleAnchor.self)`

## Learnings

- **WKWebView does NOT work in sandboxed QuickLook extensions.** Its GPU, Networking, and WebContent XPC subprocesses get blocked. Mach-lookup entitlement exceptions don't help — they're XPC services, not mach services.
- **NSAttributedString(html:) does NOT support modern CSS.** No CSS custom properties (`var()`), no `@media` queries, no advanced selectors. Produces visually broken output with our stylesheet.
- **Legacy `WebView` (deprecated macOS 10.14) works in sandboxed extensions.** It renders HTML in-process without spawning XPC subprocesses, so the full `preview.css` with CSS variables and dark mode media queries works correctly.
- **`@main` on NSApplicationDelegate doesn't wire up the delegate.** Must use an explicit `@main enum Main` that creates `NSApplication.shared`, sets the delegate, and calls `app.run()`.
- **JavaScript `atob()` produces Latin-1, not UTF-8.** Multi-byte UTF-8 characters (em-dashes, etc.) get mangled. Fix: `new TextDecoder().decode(Uint8Array.from(atob(b64), c => c.charCodeAt(0)))`.
- **`Bundle(for: PreviewController.self)` fails cross-target.** When MarkdownRenderer is compiled into multiple targets, the class reference resolves to the wrong bundle. Fix: private `BundleAnchor` class in the same file as the bundle lookup.
- **Finder only discovers QL extensions from ~/Applications or /Applications.** DerivedData builds don't register reliably, causing "file icon only" preview. Multiple DerivedData copies cause duplicate registrations and crashes.
