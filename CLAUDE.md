# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build, install to ~/Applications, register extension, and verify
make install

# Run all tests
xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' test

# Run a single test
xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' \
  -only-testing:mdqlTests/MarkdownRendererTests/testRenderBasicMarkdown test

# Manual preview test
qlmanage -p /path/to/file.md
```

`make install` is the primary build command. It builds a Release binary, calls `scripts/install.sh` to copy to `~/Applications/` and clean up stale registrations, then verifies pluginkit and lsregister have exactly one entry. The Xcode post-build phase also calls `scripts/install.sh` (with `SKIP_LAUNCH=1` since apps can't be launched during builds).

## Architecture

macOS QuickLook preview extension for Markdown files. Five Xcode targets:

- **mdql** — Host app. Minimal AppDelegate (registration is handled by `scripts/install.sh` since the app is sandboxed). Post-build script calls `install.sh` to copy to `~/Applications/`.
- **mdqlPreview** — QuickLook Preview Extension (.appex). View-based preview (`QLIsDataBasedPreview=false`) using `WKWebView` + `WKScriptMessageHandler` + FileWatcher for live updates in Finder. Registered for `net.daringfireball.markdown` UTI.
- **mdql-open-url** — Unsandboxed XPC service (`com.apple.product-type.xpc-service`). Embedded in mdql.app at `Contents/XPCServices/`. Exposes `OpenURLProtocol` with a single `open(_:withReply:)` method so the sandboxed extension can open URLs in the default browser via `NSWorkspace`. No entitlements = no sandbox.
- **mdqlTests** — Unit tests. Compiles mdqlPreview and mdql sources directly (not hosted tests) since app extensions can't be imported as modules by test bundles.
- **mdql-screenshot** — CLI tool for taking PNG screenshots of rendered markdown. Uses WKWebView (unsandboxed).

**Data flow:** Finder Space → `PreviewController.preparePreviewOfFile(at:)` → `MarkdownRenderer.render(fileAt:)` → `WKWebView.loadHTMLString()`. Link clicks are intercepted in JS and posted via `window.webkit.messageHandlers.mdql.postMessage()` to Swift's `WKScriptMessageHandler`, which delegates to the XPC service for browser opening. FileWatcher triggers innerHTML injection via `evaluateJavaScript()`.

**Single external dependency:** `swift-markdown` (swiftlang/swift-markdown, branch: main) — provides GFM support (tables, strikethrough, task lists) via cmark-gfm under the hood. Added to mdqlPreview and mdqlTests targets.

## Key Files

- `scripts/install.sh` — Single source of truth for install + registration. Copies to ~/Applications, cleans stale lsregister/pluginkit entries, registers extension, launches app for pluginkit finalization.
- `Makefile` — `make install` builds Release, calls `install.sh`, verifies no duplicates. `make clean` cleans build artifacts.
- `mdqlPreview/MarkdownRenderer.swift` — Core rendering. `render()` for full HTML with CSS, `renderBody()` for body-only HTML (used by innerHTML updates). Uses `BundleAnchor` class for cross-target bundle resolution.
- `mdqlPreview/Resources/preview.css` — Inkpad-derived design tokens. Uses CSS custom properties with `@media (prefers-color-scheme: dark)` for automatic dark mode. Key tokens: text `#3f3b3d`, bg `#f9f9f9`, links `#4183c4`.
- `mdqlPreview/PreviewController.swift` — View-based QLPreviewingController with WKWebView + WKScriptMessageHandler for native JS↔Swift messaging + FileWatcher for live updates. Opens URLs via XPC service.
- `mdql-open-url/` — Unsandboxed XPC service: `OpenURLProtocol.swift` (shared @objc protocol), `OpenURLService.swift` (NSWorkspace.open), `OpenURLDelegate.swift` (NSXPCListenerDelegate), `main.swift`.
- `mdql/FileWatcher.swift` — DispatchSource file monitor with rename/delete recovery and 100ms coalescing.
- `mdqlTests/Fixtures/` — Test markdown files (basic, gfm, empty, special-chars).

## Project Constraints

- Xcode project (not SPM) because Quick Look extensions require `.appex` embedded in `.app`
- Deployment target: macOS 12.0
- App sandbox enabled on both host app and extension; extension has read-only file access
- CSS is loaded from the bundle at runtime via `Bundle(for: BundleAnchor.self)`
- **WKWebView only. Never use legacy `WebView`.** The entire project uses `WKWebView` exclusively (mdqlPreview extension, mdql-screenshot CLI, and any future targets). The deprecated `WebView` class must never be introduced — it was fully removed and replaced by `WKWebView` with the `com.apple.security.network.client` entitlement.

## Learnings

- **WKWebView requires `com.apple.security.network.client` entitlement in sandboxed QuickLook extensions.** Its out-of-process architecture (GPU, Networking, WebContent XPC subprocesses) needs this entitlement even for local HTML. Without it, the view renders blank. This was a known WebKit bug on macOS Big Sur (fixed in macOS 12 via WebKit Changeset 271895).
- **NSAttributedString(html:) does NOT support modern CSS.** No CSS custom properties (`var()`), no `@media` queries, no advanced selectors. Produces visually broken output with our stylesheet.
- **Never use legacy `WebView` (deprecated macOS 10.14).** It was previously used as a workaround for sandbox issues but has been fully removed. WKWebView with `network.client` entitlement is the correct and only approach for macOS 12+.
- **`@main` on NSApplicationDelegate doesn't wire up the delegate.** Must use an explicit `@main enum Main` that creates `NSApplication.shared`, sets the delegate, and calls `app.run()`.
- **JavaScript `atob()` produces Latin-1, not UTF-8.** Multi-byte UTF-8 characters (em-dashes, etc.) get mangled. Fix: `new TextDecoder().decode(Uint8Array.from(atob(b64), c => c.charCodeAt(0)))`.
- **`Bundle(for: PreviewController.self)` fails cross-target.** When MarkdownRenderer is compiled into multiple targets, the class reference resolves to the wrong bundle. Fix: private `BundleAnchor` class in the same file as the bundle lookup.
- **Finder only discovers QL extensions from ~/Applications or /Applications.** DerivedData builds don't register reliably, causing "file icon only" preview. Multiple DerivedData copies cause duplicate registrations and crashes. Automated via `scripts/install.sh`.
- **Xcode's RegisterWithLaunchServices re-registers from DerivedData after build scripts run.** The post-build script alone is not sufficient — `make install` runs `install.sh` again after xcodebuild completes to clean up re-registered DerivedData entries.
- **The app sandbox prevents AppDelegate from running lsregister/qlmanage.** All registration logic must live in `scripts/install.sh` (unsandboxed). The AppDelegate is a no-op.
- **pluginkit only discovers extensions when the host app is launched.** `lsregister -f -R` alone is not enough — `install.sh` must `open` the app and then quit it to finalize registration.
- **`codesign --force --deep` breaks extension identity.** When re-signing the host app after copying to ~/Applications, use `--sign -` without `--deep` to preserve the extension's original signature.
- **Sandboxed QuickLook extensions cannot call `NSWorkspace.shared.open()`.** The extension sandbox profile is missing `(allow lsopen)`. Fix: unsandboxed XPC service embedded in `Contents/XPCServices/` that calls `NSWorkspace.shared.open()` on behalf of the extension via `NSXPCConnection(serviceName:)`.
