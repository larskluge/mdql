# Changelog

Every release from 0.2.0 on is written by `make version`, which reads the commits
since the last tag and takes each entry's kind from the subject prefix — never by
hand. The 0.1.0 section below is the one exception: the tool only moves a version
forward, and the project already declared 0.1.0, so no run of it could have
written that section. Its heading is the line every generated release gets, so the
file reads as one sequence. `docs/releases.md` is how to cut a release.

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
