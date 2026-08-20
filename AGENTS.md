# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## Build & Test Commands

```bash
# Build, install to /Applications, register extension, and verify
make install

# Run all tests — the bump tool's Python suite first, then the Xcode ones
make test

# Run a single test
xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' \
  -only-testing:mdqlTests/MarkdownRendererTests/testRenderBasicMarkdown test

# Manual preview test
qlmanage -p /path/to/file.md
```

`make install` is the primary build command. It builds a Release binary, calls `scripts/install.sh` to copy to `/Applications/` and clean up stale registrations, then verifies pluginkit and lsregister have exactly one entry. The Xcode post-build phase also calls `scripts/install.sh` (with `SKIP_LAUNCH=1` since apps can't be launched during builds).

## Releases

[docs/releases.md](docs/releases.md) is the whole process — four make targets, with the push between them, which is not optional:

```bash
make version-dry                      # what the bump would do, written nowhere
make version                          # bump + CHANGELOG.md + commit + tag; pushes nothing
git push origin main --follow-tags    # main, and the annotated tag it carries
make dist                             # Release build → Developer ID sign → notarize → staple → zip
make release                          # gh release create: the CHANGELOG section + an Install stanza as the body
```

Skipping the push does not fail late: `make release` refuses until the tag is on `origin`, because `gh release create` creates a tag it cannot find there — on the remote default branch's HEAD — and would publish that instead. The tag `make version` writes is annotated (`git tag -a`), which is what `--follow-tags` carries; a lightweight one would be silently skipped by a push that still exits 0. `make dist` refuses a dirty tree, since the version-stamp build phase bakes `-dirty` into the badge drawn in every preview's corner. `make release` unpacks the zip and checks it holds one `mdql.app` of this version, stapled and Gatekeeper-accepted — and, by reading the `version.txt` that build phase stamps into the appex, that it was built from the tagged commit and over a clean tree; every other check there reads the tree rather than the artifact, so nothing else would notice. It also refuses unless `origin` is `larskluge/mdql`, since that is the repository `gh` is pointed at while the tag check asks `origin`. The body it publishes is the CHANGELOG section plus a fixed **Install** stanza appended by the Makefile — boilerplate for a download page, which is why it is not in `CHANGELOG.md`.

The version lives in `mdql.xcodeproj/project.pbxproj` as project-level `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` — one pair, inherited by all five targets, and referenced as `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` from the three `Info.plist`s that ship inside `mdql.app` (app, appex, XPC service). **Never edit them by hand, and never add a target-level override**: macOS refuses to load an appex whose `CFBundleVersion` disagrees with its containing app's, and `scripts/version.py` refuses to run when the pbxproj has anything other than exactly those two declarations of each.

## Architecture

macOS QuickLook preview extension for Markdown files. Five Xcode targets:

- **mdql** — Host app, and a standalone Markdown viewer: `DocumentWindowController` hosts the same `MarkdownWebController` the extension does, in a window with a transparent titlebar and Share / Open-in-Zed toolbar items, so a file renders in the app exactly as it does in Quick Look. Deliberately **unsandboxed** (`mdql/mdql.entitlements` is an empty `<dict/>`), which is what lets it read and write the file directly rather than through the XPC service. Registration is `scripts/install.sh`'s job rather than the AppDelegate's; the post-build phase calls it to copy the build to `/Applications/`.
- **mdqlPreview** — QuickLook Preview Extension (.appex). View-based preview (`QLIsDataBasedPreview=false`) using `WKWebView` + `WKScriptMessageHandler` + FileWatcher for live updates in Finder. Registered for `net.daringfireball.markdown` UTI.
- **mdql-open-url** — Unsandboxed XPC service (`com.apple.product-type.xpc-service`). Embedded **inside the appex**, not beside it: a Release build puts it at `mdql.app/Contents/PlugIns/mdqlPreview.appex/Contents/XPCServices/com.mdql.app.open-url.xpc`. Exposes `OpenURLProtocol` with `open(_:withReply:)` (opens URLs in the default browser via `NSWorkspace`), `readFile(at:withReply:)` (reads sibling files the extension sandbox can't access directly, e.g. when navigating to a linked `.md` file) and `toggleCheckbox(at:index:withReply:)` (flips one task-list marker in the previewed file — a write the read-only extension sandbox has no way to make). No entitlements = no sandbox.
- **mdqlTests** — Unit tests. Compiles mdqlPreview and mdql sources directly (not hosted tests) since app extensions can't be imported as modules by test bundles.
- **mdql-screenshot** — CLI tool for taking PNG screenshots of rendered markdown. Uses WKWebView (unsandboxed).

**Data flow:** Finder Space → `PreviewController.preparePreviewOfFile(at:)` → `MarkdownWebController` → `MarkdownRenderer.render(fileAt:)` → `WKWebView.loadHTMLString()`. Link clicks are intercepted in JS and posted via `window.webkit.messageHandlers.mdql.postMessage()` to Swift's `WKScriptMessageHandler`. Four JS actions: `openURL` (http/https → XPC open in browser), `openMarkdown` (relative `.md`/`.markdown` href → `loadMarkdownFile` in-place, pushing the current URL onto `fileHistory`), `goBack` (pops the history stack), and `toggleCheckbox` (flips a task-list marker in the file, reverting the rendered checkbox and showing a toast if the write fails). Hovering a link shows a bottom status bar. FileWatcher triggers innerHTML injection via `evaluateJavaScript()`.

**Why reading linked `.md` files needs XPC:** The extension sandbox only grants read access to the file QuickLook initially passed in. Sibling `.md` files referenced by relative links must be read through `OpenURLProtocol.readFile(at:withReply:)` on the unsandboxed XPC service. `loadMarkdownFile` handles the initial file (uses `String(contentsOf:)` directly); navigation uses `readFileViaXPC`.

**Single external dependency:** `swift-markdown` (swiftlang/swift-markdown, branch: main) — provides GFM support (tables, strikethrough, task lists) via cmark-gfm under the hood. Added to mdqlPreview and mdqlTests targets.

## Key Files

- `scripts/install.sh` — Single source of truth for install + registration. Copies to /Applications, cleans stale lsregister/pluginkit entries, registers extension, launches app for pluginkit finalization.
- `Makefile` — `make install` builds Release, calls `install.sh`, verifies no duplicates. `make clean` cleans build artifacts. The release path (`version`, `dist`, `release`, and the guards they depend on) lives at the bottom; [docs/releases.md](docs/releases.md) explains it.
- `scripts/version.py`, `scripts/changelog-section.py` — The bump tool (pbxproj + CHANGELOG.md + commit + annotated tag) and the reader that hands one CHANGELOG section to `gh release create`. `make version-test` is their suite and runs first in `make test` and in CI.
- `mdqlPreview/MarkdownRenderer.swift` — Core rendering. `render(markdown:title:showBackButton:interactive:appChrome:)` for full HTML with CSS (renders back chevron + hover status bar when `showBackButton` is true, headroom under the host app's titlebar when `appChrome` is), `renderBody()` for body-only HTML (used by innerHTML updates). `escapingAttributeValues()` escapes link/image URLs on the markup tree before formatting; `postProcessCheckboxes()` makes task-list checkboxes clickable when `interactive`. Uses `BundleAnchor` class for cross-target bundle resolution, and draws the build's `version.txt` badge in the corner.
- `mdqlPreview/Resources/preview.css` — Inkpad-derived design tokens. Uses CSS custom properties with `@media (prefers-color-scheme: dark)` for automatic dark mode. Key tokens: text `#3f3b3d`, bg `#f9f9f9`, links `#4183c4`. Also styles the hover link status bar and back button chrome.
- `mdqlPreview/MarkdownWebController.swift` — The shared engine both hosts embed: WKWebView + WKScriptMessageHandler for native JS↔Swift messaging + FileWatcher for live updates. Handles `openURL` / `openMarkdown` / `goBack` / `toggleCheckbox`, maintains the `fileHistory` stack. Its `openURL` / `readFile` / `toggleCheckbox` closures are what differ between hosts.
- `mdqlPreview/PreviewController.swift` — View-based QLPreviewingController. Owns the XPC connection and points the controller's `openURL` / `readFile` / `toggleCheckbox` closures at it, since the extension sandbox can open no URLs, read no sibling files, and write nothing.
- `mdql/DocumentWindowController.swift` — The standalone viewer's window: same controller, closures wired to direct (unsandboxed) calls, plus the transparent titlebar and the Share / Open-in-Zed toolbar.
- `mdql-open-url/` — Unsandboxed XPC service: `OpenURLProtocol.swift` (shared @objc protocol with `open`, `readFile` and `toggleCheckbox`), `OpenURLService.swift` (NSWorkspace.open + file reading + checkbox writes), `OpenURLDelegate.swift` (NSXPCListenerDelegate), `main.swift`.
- `mdql/CheckboxToggle.swift`, `mdql/MarkdownCheckboxScanner.swift` — Locate GFM task-list markers (skipping fenced code) and flip one of them with a single-byte write, so toggling a checkbox does not rewrite the file.
- `mdql/FileWatcher.swift` — DispatchSource file monitor with rename/delete recovery and 100ms coalescing.
- `mdqlTests/Fixtures/` — Test markdown files (basic, gfm, empty, special-chars, front-matter, code-with-html for HTML-escape regression coverage).
- `mdqlTests/PreviewControllerTests.swift` — Covers `handleOpenURL` / `handleOpenMarkdown` behavior and relative-path resolution.

## Project Constraints

- Xcode project (not SPM) because Quick Look extensions require `.appex` embedded in `.app`
- Deployment target: macOS 26.0
- App sandbox on the extension only — read-only file access, plus `com.apple.security.network.client`. The host app is deliberately unsandboxed (empty `<dict/>` entitlements), and the XPC service has no entitlements at all; `scripts/codesign-app.sh` reads all three back out of the finished signature.
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
- **`codesign --force --deep` breaks extension identity.** When re-signing the host app after copying to /Applications, use `--sign -` without `--deep` to preserve the extension's original signature.
- **Sandboxed QuickLook extensions cannot call `NSWorkspace.shared.open()`.** The extension sandbox profile is missing `(allow lsopen)`. Fix: unsandboxed XPC service embedded in `Contents/XPCServices/` that calls `NSWorkspace.shared.open()` on behalf of the extension via `NSXPCConnection(serviceName:)`.
- **The QuickLook extension sandbox only grants read access to the initially-previewed file.** Following a relative `.md` link cannot use `String(contentsOf:)` on the sibling path — it fails with "don't have permission to view it." Fix: extend the unsandboxed XPC service with a `readFile(at:withReply:)` method and read sibling files through it.
- **`WKNavigationDelegate` races with `loadHTMLString` on link-activated navigations.** When a user clicks a link, WKWebView's default navigation can clobber an in-flight `loadHTMLString` call. In `decidePolicyFor`, cancel all `.linkActivated` actions and let JS message handlers dispatch to Swift for both `openURL` (http/https) and `openMarkdown` (relative `.md`) — never `.allow` a link-activated navigation.
- **swift-markdown's `HTMLFormatter` interpolates URLs into attribute values raw.** `Link.destination`, `Image.source` and `Image.title` go straight into `href="…"` / `src="…"` / `title="…"`, so a destination containing `"` closes the attribute and injects its own — `[x](a"onmouseover="alert(1))` is enough. Fix: `MarkdownRenderer.escapingAttributeValues()` escapes those values **on the markup tree, before formatting**. Do not try to repair the formatter's output with a regex: once the quote is written the injected attribute is indistinguishable from a real one, which is why the older `postProcessEscaping()` never actually closed this hole. See `docs/specs/2026-04-17-html-escaping-fix-design.md` for the original analysis (its `CodeBlock.code` / `InlineCode.code` / `Heading.plainText` findings are now fixed upstream).
- **swift-markdown is pinned to an exact revision, and `Package.resolved` is committed.** It used to track `branch = main` while `.gitignore` excluded the whole `project.xcworkspace/`, so every fresh checkout silently resolved a different library. Upstream then added escaping to `CodeBlock.code` and `InlineCode.code` and made `visitHeading` descend into its children — which turned the old post-processing pass into a *double*-escape, rendering `&amp;` and literal `<code>` tags. Bump the pin deliberately and run the tests; never float it.
- **Raw inline HTML in body text is rendered, not escaped.** `visitInlineHTML` / `visitHTMLBlock` emit `rawHTML` verbatim, so a `.md` file can put live markup — including `<script>` — into the preview, which runs JS with a bridge that opens URLs and writes to the file. Headings are the exception: `AttributeValueEscaper.visitHeading` turns inline HTML into text, so `## Using <Component>` shows the tag. Narrowing this further is a product decision, not a bug fix — it would stop `<details>` and `<img>` working in READMEs.
