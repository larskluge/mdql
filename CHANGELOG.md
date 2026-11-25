# Changelog

One section per release, written by `make release-tag` when a release is cut —
the commits since the previous release, each under the heading its subject prefix
gives it — and never by hand. Every build between releases carries a version too,
computed from git history (`docs/releases.md` → "The version"), with no section
here: 0.2.6, the baseline that computation starts from, is one. The 0.1.0 section
below is the one hand-written exception, written before any tool could; its
heading is the line every generated release gets, so the file reads as one
sequence.

## 0.4.7 — 2026-11-25

### Fixed
- the viewer's version badge reads the embedded Quick Look extension's version.txt, not 'dev' (mdql-m2d)

## 0.4.6 — 2026-11-25

### Added
- Mermaid fences render as SVG diagrams
- Errors show: problems in a glass notice on top, what is fine to miss at the bottom, nothing fails silently (mdql-4el)
- hide the standalone viewer with ⌘H

### Fixed
- Mermaid 12.3.0 (major: 11.17.2 → 12.3.0)
- in the viewer, a heading a section link scrolls to lands below the titlebar fade (mdql-7co)
- headings get GitHub's slugs as ids, so other.md#section and #section links scroll to them (mdql-4et)
- a 1 MB Markdown file renders in 0.14 s, not 5.4 s (mdql-4hx)
- a fence's info string can no longer break out of its code block's class (mdql-k9a)
- make install restarts every running viewer on the new build

### Other
- owl.toml: drop the per-suite timeout owl no longer reads (owl-det)
- Checkbox toggles flip the right task; section links to other files open there (mdql-eay)
- A previewed file can no longer leave mdql's page, open any scheme, or read any .md (mdql-1mx)
- Raw-text tags no longer hang the preview; only mdql's own script runs (mdql-3k9)
- Fix leaked "about:" WebContent processes after view dismissal
- Full-screen appearance: one observer, and tests of the full-screen case (mdql-jrw)
- Fix dark mode override in full-screen QuickLook
- AGENTS.md under 20 KB: Learnings move to docs/learnings.md (mdql-o4h)
- CLAUDE.md: symlink to AGENTS.md (mdql-4eg)
- Track work in Beads, with its Dolt remote on outpost
- CI: no push trigger; on main owl dispatches ci.yml
- Classify mdql for owl
- Tests: keep this machine's git config out of the throwaway repositories
- CI: route to tart-ci by allowlist — push, dispatch, same-repo PR
- CI: macOS jobs run on tart-ci, the on-demand Tart runner

## 0.1.0 — 2026-08-20

The first numbered build. Everything before it shipped unversioned; the
repository's own history is the record, and this is where the record starts.

### Added
- Quick Look preview for Markdown in Finder, live-updating as the file changes on disk
- GitHub Flavored Markdown: tables, task lists, strikethrough, fenced code with language hints
- relative `.md` links followed in place, with a back button and a status bar naming where each link goes
- clickable task-list checkboxes, toggled straight back into the file on disk
- a standalone viewer app, rendering a file exactly the way Quick Look does
- light and dark rendering, following the system appearance
