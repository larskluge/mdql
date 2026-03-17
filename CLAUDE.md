# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build all targets
xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' build

# Install to /Applications (ALWAYS do this after building)
# Prevents duplicate QuickLook extension registrations from DerivedData vs /Applications
rm -rf /Applications/mdql.app && cp -R "$(xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $3}')/mdql.app" /Applications/mdql.app && qlmanage -r

# Build + install + reset QuickLook (one-liner)
xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' build && rm -rf /Applications/mdql.app && cp -R "$(xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $3}')/mdql.app" /Applications/mdql.app && qlmanage -r

# Run all tests
xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' test

# Run a single test
xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' \
  -only-testing:mdqlTests/MarkdownRendererTests/testRenderBasicMarkdown test

# Manual preview test
qlmanage -p /path/to/file.md
```

**IMPORTANT:** Always install to `/Applications/mdql.app` after building, never run from DerivedData. macOS registers QuickLook extensions per-path, so having copies in both DerivedData and `/Applications` causes duplicate registrations and unpredictable behavior. The build+install one-liner above handles this correctly.

## Architecture

macOS QuickLook preview extension for Markdown files. Three Xcode targets:

- **mdql** — Host app with live Markdown preview (WKWebView + FileWatcher). Also carries the QuickLook extension.
- **mdqlPreview** — QuickLook Preview Extension (.appex). View-based preview (`QLIsDataBasedPreview=false`) using legacy WebView + FileWatcher for live updates in Finder. Registered for `net.daringfireball.markdown` UTI.
- **mdqlTests** — Unit tests. Compiles mdqlPreview and mdql sources directly (not hosted tests) since app extensions can't be imported as modules by test bundles.

**QuickLook data flow:** Finder Space → `PreviewController.preparePreviewOfFile(at:)` → `MarkdownRenderer.render(fileAt:)` → legacy `WebView.mainFrame.loadHTMLString()`. FileWatcher triggers innerHTML injection via `stringByEvaluatingJavaScript(from:)`.

**Host app data flow:** `AppDelegate` → `PreviewWindowController.loadFile()` → `MarkdownRenderer.render(fileAt:)` → WKWebView. FileWatcher triggers innerHTML injection via base64-encoded JS.

**Single external dependency:** `swift-markdown` (swiftlang/swift-markdown, branch: main) — provides GFM support (tables, strikethrough, task lists) via cmark-gfm under the hood. Added to mdql, mdqlPreview, and mdqlTests targets.

## Key Files

- `mdqlPreview/MarkdownRenderer.swift` — Core rendering. `render()` for full HTML with CSS, `renderBody()` for body-only HTML (used by innerHTML updates). Uses `BundleAnchor` class for cross-target bundle resolution.
- `mdqlPreview/Resources/preview.css` — Inkpad-derived design tokens. Uses CSS custom properties with `@media (prefers-color-scheme: dark)` for automatic dark mode. Key tokens: text `#3f3b3d`, bg `#f9f9f9`, links `#4183c4`.
- `mdqlPreview/PreviewController.swift` — View-based QLPreviewingController with legacy WebView + FileWatcher for live updates.
- `mdql/AppDelegate.swift` — Host app entry point. Programmatic menu, CLI args, File > Open, drag-and-drop.
- `mdql/PreviewWindowController.swift` — WKWebView-based preview with scroll-preserving innerHTML updates.
- `mdql/FileWatcher.swift` — DispatchSource file monitor with rename/delete recovery and 100ms coalescing.
- `mdqlTests/Fixtures/` — Test markdown files (basic, gfm, empty, special-chars).

## Project Constraints

- Xcode project (not SPM) because Quick Look extensions require `.appex` embedded in `.app`
- Deployment target: macOS 12.0
- Host app sandbox disabled (needs file access + WKWebView); extension sandboxed with read-only file access
- WKWebView does NOT work in sandboxed QuickLook extensions (XPC subprocesses blocked). Extension uses legacy WebView which renders in-process.
- CSS is loaded from the bundle at runtime via `Bundle(for: BundleAnchor.self)`
