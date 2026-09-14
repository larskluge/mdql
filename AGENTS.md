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

## Versions and releases

**Every build computes the version from git history; nothing stores or bumps it** (`python3 scripts/version.py`, `--explain` for how history reads; docs/releases.md → "The version"). The `mdql-version` target computes it once per build and each bundle's `Stamp version` phase writes it in. **Never add `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` or an `Info.plist` version, and never let a bundle compute its own**: macOS refuses to load an appex whose `CFBundleVersion` disagrees with its app's. The major moves only on Lars's word ("make it 1.0" → `git tag -a v1.0.0 -m 1.0.0` on main's HEAD, pushed); never infer one.

**Every commit subject starts with a conventional prefix**, since the version is read from them: `feat:` only for a user-visible feature big enough to move the minor version; `fix:` or `perf:` for a bug fix or a small user-visible change (a patch); `chore:`, `docs:`, `ci:`, `test:`, `build:` or `refactor:` for what users never see (no bump). A `!` or `BREAKING CHANGE:` infers nothing.

A release, a notarized zip on GitHub, only when Lars asks; [docs/releases.md](docs/releases.md) is the process, with the push between, which is not optional:

```bash
make release-tag-dry                  # the CHANGELOG section and tag it would write
make release-tag                      # CHANGELOG.md section + commit + annotated tag; pushes nothing
git push origin main --follow-tags    # main, and the annotated tag it carries
make dist                             # Release build → Developer ID sign → notarize → staple → zip
make release                          # gh release create: the CHANGELOG section + an Install stanza as the body
```

Skipping the push does not fail late: `make release` refuses until the tag is on `origin`. Every refusal on that path, and why each exists, is in docs/releases.md.

## Architecture

macOS QuickLook preview extension for Markdown files. Six Xcode targets:

- **mdql** — Host app, and a standalone Markdown viewer: `DocumentWindowController` hosts the same `MarkdownWebController` the extension does, in a window with a transparent titlebar and Share / Open-in-Zed toolbar items, so a file renders in the app exactly as it does in Quick Look. Deliberately **unsandboxed** (`mdql/mdql.entitlements` is an empty `<dict/>`), which is what lets it read and write the file directly rather than through the XPC service. Registration is `scripts/install.sh`'s job rather than the AppDelegate's; the post-build phase calls it to copy the build to `/Applications/`.
- **mdqlPreview** — QuickLook Preview Extension (.appex). View-based preview (`QLIsDataBasedPreview=false`) using `WKWebView` + `WKScriptMessageHandler` + FileWatcher for live updates in Finder. Registered for `net.daringfireball.markdown` UTI.
- **mdql-open-url** — Unsandboxed XPC service (`com.apple.product-type.xpc-service`). Embedded **inside the appex**, not beside it: a Release build puts it at `mdql.app/Contents/PlugIns/mdqlPreview.appex/Contents/XPCServices/com.mdql.app.open-url.xpc`. Exposes `OpenURLProtocol` with `open(_:withReply:)` (opens URLs in the default browser via `NSWorkspace`), `readFile(at:previewing:withReply:)` (reads sibling files the extension sandbox can't access directly, e.g. when navigating to a linked `.md` file) and `toggleCheckbox(at:offset:checked:previewing:withReply:)` (sets one task-list marker in the previewed file — a write the read-only extension sandbox has no way to make). No entitlements = no sandbox, so it checks every request against `AccessPolicy` itself.
- **mdqlTests** — Unit tests. Compiles mdqlPreview and mdql sources directly (not hosted tests) since app extensions can't be imported as modules by test bundles.
- **mdql-screenshot** — CLI tool for taking PNG screenshots of rendered markdown. Uses WKWebView (unsandboxed).
- **mdql-version** — Aggregate target, no product: computes the version once per build for the three bundle targets, which depend on it.

**Data flow:** Finder Space → `PreviewController.preparePreviewOfFile(at:)` → `MarkdownWebController` → `MarkdownRenderer.render(fileAt:)` → `WKWebView.loadHTMLString()`. Link clicks are intercepted in JS and posted via `window.webkit.messageHandlers.mdql.postMessage()` to Swift's `WKScriptMessageHandler`. Four JS actions: `openURL` (a link with a scheme → XPC open in browser or Mail, or refused), `openMarkdown` (relative `.md`/`.markdown` href, `#section` optional → that file in-place, scrolled to the section, pushing the current URL onto `fileHistory`), `goBack` (pops the history stack), and `toggleCheckbox` (sets the task-list marker at the checkbox's `data-cb-offset`, rendering the file again if it changed since). FileWatcher triggers innerHTML injection via `evaluateJavaScript()`.

**Nothing fails silently.** Every host closure answers exactly once, a failure with a plain reason (`PlainError`: "file not found", not an error dump), and the controller says so in a frosted-glass notice on top (`MarkdownWebController.show(_:)` → `__mdqlNotice`): red failed, grey refused, amber waiting, green cleared; lasting ones stay until their condition clears, the rest fade. Only what is fine to miss goes in the label at the bottom (link hover, "Opening …"). A tick saves silently when fast, says "Still saving" at 2 s and gives up at 10 s (`slowSaveDelay` / `saveTimeout`, with `schedule` for tests). `PreviewController.call` completes each XPC request on reply, proxy error, interruption, invalidation or timeout. A file moved or deleted is watched for until it is back; one that is not UTF-8 shows anyway, decoded by `MarkdownText`, with its checkboxes disabled.

**Why reading linked `.md` files needs XPC:** The extension sandbox only grants read access to the file QuickLook initially passed in. Sibling `.md` files referenced by relative links must be read through `OpenURLProtocol.readFile(at:previewing:withReply:)` on the unsandboxed XPC service. `loadMarkdownFile` handles the initial file (reads it directly through `MarkdownText`); navigation uses the controller's `readFile` closure.

**Single external dependency:** `swift-markdown` (swiftlang/swift-markdown, pinned to an exact revision) — provides GFM support (tables, strikethrough, task lists) via cmark-gfm under the hood. Linked by every target but mdql-open-url and mdql-version.

## Key Files

- `scripts/install.sh` — Single source of truth for install + registration. Copies to /Applications, unregisters every other `mdql.app` LaunchServices knows of, registers the extension, then launches the app for pluginkit finalization: running viewers are quit by pid and their documents reopened in the new build, and with none running the app is launched once and quit again. `scripts/test_install.py` runs it against a scratch directory and stubs (`MDQL_INSTALL_DIR`, `MDQL_LSREGISTER`), as part of `make version-test`.
- `Makefile` — `make install` builds Release, calls `install.sh`, checks the installed bundles carry the computed version, verifies no duplicates. `make clean` cleans build artifacts. The release path (`release-tag`, `dist`, `release`, and the guards they depend on) lives at the bottom; [docs/releases.md](docs/releases.md) explains it.
- `scripts/version.py`, `scripts/stamp-version.sh` — The calculator (`--write` for the build, `--check` on a built app; it never commits, tags or writes the project) and the `Stamp version` phases' script. `scripts/release-tag.py`, `scripts/changelog-section.py` — the release path's CHANGELOG section + commit + tag, and the reader handing one section to `gh release create`. `make version-test` is their suite and runs first in `make test` and in CI.
- `mdqlPreview/MarkdownRenderer.swift` — Core rendering. `render(markdown:title:showBackButton:interactive:checkboxesClickable:appChrome:topInset:)` for full HTML with CSS and the page script that draws the notices and the bottom label (renders the back chevron when `showBackButton` is true, headroom under the host app's titlebar when `appChrome` is), `renderBody()` for body-only HTML (used by innerHTML updates). `escapingAttributeValues()` escapes link/image URLs and runs the tagfilter over raw HTML on the markup tree before formatting; `TaskCheckboxes` draws task-list checkboxes from that same parse, each carrying its marker's source offset (`data-cb-offset`) when `interactive`: never number them from the HTML or a line scan, which disagree with the parse (docs/learnings.md). Uses `BundleAnchor` class for cross-target bundle resolution, and draws the build's `version.txt` badge at the bottom right.
- `mdqlPreview/Resources/preview.css` — Inkpad-derived design tokens. Uses CSS custom properties with `@media (prefers-color-scheme: dark)` for automatic dark mode. Key tokens: text `#3f3b3d`, bg `#f9f9f9`, links `#4183c4`. Also styles mdql's glass chrome over the page: back button, notices, bottom label, version.
- `mdqlPreview/Resources/mermaid.min.js` — Vendored Mermaid runtime (pinned version + sha256, upgraded only via `scripts/fetch-mermaid.sh`; never loaded from a CDN — the preview must stay offline-deterministic for the screenshot/pr-preview path). `MarkdownRenderer.mermaidScriptTag(for:nonce:)` inlines it into the page's `<head>`, under the render's CSP nonce, only when the body has a `language-mermaid` fence, with `</script` escaped so it can't break out of its tag. The in-page `__mdqlRenderDiagrams` hook (defined in `wrapInHTMLDocument`, re-invoked after FileWatcher innerHTML swaps) renders fences as SVG; failed diagrams keep their source visible with an error note.
- `mdqlPreview/MarkdownWebController.swift` — The shared engine both hosts embed: WKWebView + WKScriptMessageHandler for native JS↔Swift messaging + FileWatcher for live updates. Handles `openURL` / `openMarkdown` / `goBack` / `toggleCheckbox`, maintains the `fileHistory` stack. Its `openURL` / `readFile` / `toggleCheckbox` closures are what differ between hosts.
- `mdqlPreview/PreviewController.swift` — View-based QLPreviewingController. Owns the XPC connection and points the controller's `openURL` / `readFile` / `toggleCheckbox` closures at it, since the extension sandbox can open no URLs, read no sibling files, and write nothing.
- `mdql/DocumentWindowController.swift` — The standalone viewer's window: same controller, closures wired to direct (unsandboxed) calls, plus the transparent titlebar (its height, from `contentLayoutRect`, is the page's `topInset`) and the Share / Open-in-Zed toolbar.
- `mdql/MarkdownText.swift` — The one decoder every reader uses (the extension, the viewer, the XPC service): a BOM decides, else UTF-8, else Windows Latin-1, else ISO Latin-1. Also `PlainError`, a failure's reason in plain words. Compiled into every target.
- `mdql-open-url/AccessPolicy.swift` — What a document may make mdql do: the scheme allowlist and the folder rule. Compiled into every target; refusals log to `com.mdql.app` / `access`.
- `mdql-open-url/` — Unsandboxed XPC service: `OpenURLProtocol.swift` (shared @objc protocol with `open`, `readFile` and `toggleCheckbox`), `OpenURLService.swift` (NSWorkspace.open + file reading + checkbox writes), `OpenURLDelegate.swift` (NSXPCListenerDelegate), `main.swift`.
- `mdql/CheckboxToggle.swift` — Sets the marker at a rendered offset with a single-byte write through one descriptor, so toggling a checkbox does not rewrite the file; refuses (`.stale`) when the byte there is not the state the page showed, and says why when it fails.
- `mdql/FileWatcher.swift` — DispatchSource file monitor with rename/delete recovery and 100ms coalescing, main-queue only. A file gone from its path is reported missing, its folder watched (once a second where it can't be) until it is back.
- `mdqlTests/Fixtures/` — Test markdown files (basic, gfm, empty, special-chars, front-matter, code-with-html for HTML-escape regression coverage, windows-1252 and utf16-bom for decoding).
- `mdqlTests/PreviewControllerTests.swift` — Covers `handleOpenURL` / `handleOpenMarkdown` behavior and relative-path resolution, and every XPC failure path against a stand-in service on an anonymous listener.
- `mdqlTests/RenderedPageTests.swift` — Loads rendered files into a real offscreen WKWebView and asks the DOM: raw-text tags and unclosed comments, the CSP, the link, checkbox and back features under it, and the notices (layout, light and dark, the tick timeline). Its shared helpers (`evaluate`, `waitUntil`, `waitForNotice`) serve the other classes.

## Project Constraints

- Xcode project (not SPM) because Quick Look extensions require `.appex` embedded in `.app`
- Deployment target: macOS 26.0
- App sandbox on the extension only — it reads the file Quick Look hands it and nothing else, plus `com.apple.security.network.client`. The host app is deliberately unsandboxed (empty `<dict/>` entitlements), and the XPC service has no entitlements at all; `scripts/codesign-app.sh` reads all three back out of the finished signature.
- CSS is loaded from the bundle at runtime via `Bundle(for: BundleAnchor.self)`
- **WKWebView only. Never use legacy `WebView`.** The entire project uses `WKWebView` exclusively (mdqlPreview extension, mdql-screenshot CLI, and any future targets). The deprecated `WebView` class must never be introduced — it was fully removed and replaced by `WKWebView` with the `com.apple.security.network.client` entitlement.
- **Only mdql's own page loads, and only it reaches the bridge.** `decidePolicyFor` allows only the controller's `loadPage` loads (main frame, `about:blank`) and cancels the rest: meta refresh, forms, `window.open`, subframes, and every `.linkActivated` action, which the JS message handlers dispatch as `openURL` / `openMarkdown` since WKWebView's own navigation races `loadHTMLString`. The message handler ignores any frame but the main one at `about:blank`.
- **Every action a document can ask for passes `AccessPolicy`.** Only http, https and mailto open, and a link or image keeps no other scheme; a link opens only a regular `.md`/`.markdown` whose realpath lies under the originally previewed document's folder. The XPC service checks again as the boundary and keeps no state (launchd may relaunch it), so each file call names the previewed document. A refusal does nothing but a grey "Not opened" notice and a log line.
- **Escape link and image attribute values on the markup tree, before formatting** (`escapingAttributeValues()`), never by repairing `HTMLFormatter`'s output.
- **swift-markdown stays pinned** to an exact revision, with `Package.resolved` committed: bump the pin deliberately and run the tests; never float it.
- Raw HTML in body text renders, except the tagfilter's tags (GFM's, plus `noscript` and `template`), which show as text; headings show all of it as text. Narrowing that further is a product decision, not a bug fix.
- **Only mdql's own script runs.** The page's CSP admits scripts carrying the render's nonce and nothing else; never add `unsafe-inline`/`unsafe-eval` or an inline `on…=` handler. The script lives in `<head>` and runs on DOMContentLoaded: never let what the page shows depend on how the body parses (docs/learnings.md).
- Registration (lsregister, pluginkit) lives only in `scripts/install.sh`, which quits viewers by pid, never by name: there can always be more than one `mdql` process.
- Re-sign the installed app with `--sign -`, never `--deep`, which breaks the extension's identity.

## Docs

- [docs/releases.md](docs/releases.md) — how the version is computed and reaches every bundle, and cutting a release: the tag, signing, notarization, publishing, and why there is no release CI.
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
