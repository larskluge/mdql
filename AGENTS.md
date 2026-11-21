# AGENTS.md

mdql is a macOS Quick Look extension that renders Markdown files, live as they change, plus a standalone viewer app that renders them the same way. [README.md](README.md) is the user's view.

## Build & Test Commands

```bash
# Build, install to /Applications, register extension, and verify
make install

# Run all tests — the scripts' Python suites first, then the Xcode ones
# (in the tart-ci VM: on this Mac its build phase replaces /Applications/mdql.app)
make test

# Run a single test; CI=true keeps the build phase from replacing /Applications/mdql.app
CI=true xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' \
  -only-testing:mdqlTests/MarkdownRendererTests/testRenderBasicMarkdown test

# Manual preview test
qlmanage -p /path/to/file.md
```

`make install` is the primary build command. It builds a Release binary, calls `scripts/install.sh` to copy to `/Applications/` and clean up stale registrations, then verifies pluginkit and lsregister have exactly one entry. A viewer that is running is quit and relaunched on the new build with the documents it was showing; if one does not quit, `make install` fails and names its pid rather than leave it on the old build unannounced. The Xcode post-build phase also calls `scripts/install.sh` (with `SKIP_LAUNCH=1` since apps can't be launched during builds), where a running viewer is left alone and reported as a build warning.

## Releases

[docs/releases.md](docs/releases.md) is the whole process — four make targets, with the push between them, which is not optional:

```bash
make version-dry                      # what the bump would do, written nowhere
make version                          # bump + CHANGELOG.md + commit + tag; pushes nothing
git push origin main --follow-tags    # main, and the annotated tag it carries
make dist                             # Release build → Developer ID sign → notarize → staple → zip
make release                          # gh release create: the CHANGELOG section + an Install stanza as the body
```

Skipping the push does not fail late: `make release` refuses until the tag is on `origin`. Every refusal on that path, and why each exists, is in docs/releases.md.

The version lives in `mdql.xcodeproj/project.pbxproj` as project-level `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, inherited by all five targets. **Never edit them by hand, and never add a target-level override**: macOS refuses to load an appex whose `CFBundleVersion` disagrees with its containing app's, and `scripts/version.py` refuses any other shape (docs/releases.md → "Where the number lives").

## Architecture

macOS QuickLook preview extension for Markdown files. Five Xcode targets:

- **mdql** — Host app, and a standalone Markdown viewer: `DocumentWindowController` hosts the same `MarkdownWebController` the extension does, in a window with a transparent titlebar and Share / Open-in-Zed toolbar items, so a file renders in the app exactly as it does in Quick Look. Deliberately **unsandboxed** (`mdql/mdql.entitlements` is an empty `<dict/>`), which is what lets it read and write the file directly rather than through the XPC service. Registration is `scripts/install.sh`'s job rather than the AppDelegate's; the post-build phase calls it to copy the build to `/Applications/`.
- **mdqlPreview** — QuickLook Preview Extension (.appex). View-based preview (`QLIsDataBasedPreview=false`) using `WKWebView` + `WKScriptMessageHandler` + FileWatcher for live updates in Finder. Registered for `net.daringfireball.markdown` UTI.
- **mdql-open-url** — Unsandboxed XPC service (`com.apple.product-type.xpc-service`). Embedded **inside the appex**, not beside it: a Release build puts it at `mdql.app/Contents/PlugIns/mdqlPreview.appex/Contents/XPCServices/com.mdql.app.open-url.xpc`. Exposes `OpenURLProtocol` with `open(_:withReply:)` (opens URLs in the default browser via `NSWorkspace`), `readFile(at:withReply:)` (reads sibling files the extension sandbox can't access directly, e.g. when navigating to a linked `.md` file) and `toggleCheckbox(at:index:withReply:)` (flips one task-list marker in the previewed file — a write the read-only extension sandbox has no way to make). No entitlements = no sandbox.
- **mdqlTests** — Unit tests. Compiles mdqlPreview and mdql sources directly (not hosted tests) since app extensions can't be imported as modules by test bundles.
- **mdql-screenshot** — CLI tool for taking PNG screenshots of rendered markdown. Uses WKWebView (unsandboxed).

**Data flow:** Finder Space → `PreviewController.preparePreviewOfFile(at:)` → `MarkdownWebController` → `MarkdownRenderer.render(fileAt:)` → `WKWebView.loadHTMLString()`. Link clicks are intercepted in JS and posted via `window.webkit.messageHandlers.mdql.postMessage()` to Swift's `WKScriptMessageHandler`. Four JS actions: `openURL` (http/https → XPC open in browser), `openMarkdown` (relative `.md`/`.markdown` href → `loadMarkdownFile` in-place, pushing the current URL onto `fileHistory`), `goBack` (pops the history stack), and `toggleCheckbox` (flips a task-list marker in the file, reverting the rendered checkbox and showing a toast if the write fails). Hovering a link shows a bottom status bar. FileWatcher triggers innerHTML injection via `evaluateJavaScript()`.

**Why reading linked `.md` files needs XPC:** The extension sandbox only grants read access to the file QuickLook initially passed in. Sibling `.md` files referenced by relative links must be read through `OpenURLProtocol.readFile(at:withReply:)` on the unsandboxed XPC service. `loadMarkdownFile` handles the initial file (uses `String(contentsOf:)` directly); navigation uses `readFileViaXPC`.

**Single external dependency:** `swift-markdown` (swiftlang/swift-markdown, pinned to an exact revision) — provides GFM support (tables, strikethrough, task lists) via cmark-gfm under the hood. Linked by every target but mdql-open-url.

## Key Files

- `scripts/install.sh` — Single source of truth for install + registration. Copies to /Applications, unregisters every other `mdql.app` LaunchServices knows of, registers the extension, then launches the app for pluginkit finalization: running viewers are quit by pid and their documents reopened in the new build, and with none running the app is launched once and quit again. `scripts/test_install.py` runs it against a scratch directory and stubs (`MDQL_INSTALL_DIR`, `MDQL_LSREGISTER`), as part of `make version-test`.
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
- **Never `.allow` a link-activated navigation.** `decidePolicyFor` cancels every `.linkActivated` action and the JS message handlers dispatch `openURL` and `openMarkdown`, since WKWebView's own navigation races `loadHTMLString`.
- **Escape link and image attribute values on the markup tree, before formatting** (`escapingAttributeValues()`), never by repairing `HTMLFormatter`'s output.
- **swift-markdown stays pinned** to an exact revision, with `Package.resolved` committed: bump the pin deliberately and run the tests; never float it.
- Raw inline HTML in body text renders; headings show it as text. Narrowing that is a product decision, not a bug fix.
- Registration (lsregister, pluginkit) lives only in `scripts/install.sh`, which quits viewers by pid, never by name: there can always be more than one `mdql` process.
- Re-sign the installed app with `--sign -`, never `--deep`, which breaks the extension's identity.

## Docs

- [docs/releases.md](docs/releases.md) — cutting a release: the bump, signing, notarization, publishing, and why there is no release CI.
- [docs/live-updates.md](docs/live-updates.md) — how live previews work inside the Quick Look sandbox, and what fails there.
- [docs/learnings.md](docs/learnings.md) — the platform gotchas behind the constraints above, each with what goes wrong and the fix. New ones go there, not here.
- `docs/specs/` — design specs, `<date>-<topic>-design.md`.

<!-- BEGIN OWL -->
## Testing (owl tier: local)

- Before landing: the tests your change touches, plus `make version-test` (smoke). Never the full suite in-session.
- One test: `CI=true xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' -only-testing:mdqlTests/<Class>/<test> test`.
- Full suite: `make test` (tart-ci VM only, through `ci.yml`). owl runs it on main while u26 is locked and quiet; `owl run mdql` runs it now.
- After pushing: nothing to watch. owl reports a red suite.
<!-- END OWL -->

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:46cd31e7 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
