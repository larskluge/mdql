# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build all targets
xcodebuild -project mkql.xcodeproj -scheme mkql -destination 'platform=macOS' build

# Run all tests
xcodebuild -project mkql.xcodeproj -scheme mkql -destination 'platform=macOS' test

# Run a single test
xcodebuild -project mkql.xcodeproj -scheme mkql -destination 'platform=macOS' \
  -only-testing:mkqlTests/MarkdownRendererTests/testRenderBasicMarkdown test

# Reset QuickLook cache (if extension doesn't appear after install)
qlmanage -r

# Manual preview test
qlmanage -p /path/to/file.md
```

## Architecture

macOS QuickLook preview extension for Markdown files. Three Xcode targets:

- **mkql** — Minimal host app (required to carry the extension; does nothing itself)
- **mkqlPreview** — QuickLook Preview Extension (.appex). Registered for `net.daringfireball.markdown` UTI with data-based previews (`QLIsDataBasedPreview=true`)
- **mkqlTests** — Unit tests. Compiles mkqlPreview sources directly (not hosted tests) since app extensions can't be imported as modules by test bundles

**Data flow:** Finder → `PreviewController.providePreview(for:)` → `MarkdownRenderer.render(fileAt:)` → swift-markdown `Document` parser + `HTMLFormatter` → HTML string wrapped with inlined CSS → `QLPreviewReply(dataOfContentType: .html)`

**Single external dependency:** `swift-markdown` (swiftlang/swift-markdown, branch: main) — provides GFM support (tables, strikethrough, task lists) via cmark-gfm under the hood. Added to both mkqlPreview and mkqlTests targets.

## Key Files

- `mkqlPreview/MarkdownRenderer.swift` — Core logic. `render(fileAt:)` for files, `render(markdown:title:)` for strings. Title escaping prevents XSS.
- `mkqlPreview/Resources/preview.css` — Inkpad-derived design tokens. Uses CSS custom properties with `@media (prefers-color-scheme: dark)` for automatic dark mode. Key tokens: text `#3f3b3d`, bg `#f9f9f9`, links `#4183c4`.
- `mkqlPreview/PreviewController.swift` — Thin QLPreviewingController glue.
- `mkqlTests/Fixtures/` — Test markdown files (basic, gfm, empty, special-chars).

## Project Constraints

- Xcode project (not SPM) because Quick Look extensions require `.appex` embedded in `.app`
- Deployment target: macOS 12.0
- App sandbox enabled on both host app and extension; extension has read-only file access
- CSS is loaded from the extension bundle at runtime via `Bundle(for: PreviewController.self)`
