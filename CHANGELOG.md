# Changelog

One section per release, written by `make release-tag` when a release is cut —
the commits since the previous release, each under the heading its subject prefix
gives it — and never by hand. Every build between releases carries a version too,
computed from git history (`docs/releases.md` → "The version"), with no section
here: 0.2.6, the baseline that computation starts from, is one. The 0.1.0 section
below is the one hand-written exception, written before any tool could; its
heading is the line every generated release gets, so the file reads as one
sequence.

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
