# Mermaid diagrams

A ` ```mermaid ` fence renders as a diagram, in Quick Look and in the viewer. The runtime is vendored and never fetched: the preview stays offline.

## What a page loads

- **Only a page with a fence loads anything.** `TaskCheckboxes`, the walk that already reads the parse before formatting, notes a code block whose info string's first word is `mermaid` (`MermaidRuntime.isDiagram`), the fences whose class the formatter writes as `language-mermaid`. Raw HTML that looks like one does not count. `MarkdownRenderer.renderPage` says whether the page loads the runtime, and `MarkdownWebController.hasLoadedMermaid` keeps that. A page without a fence carries no Mermaid code at all; its one script is mdql's own.
- **The text first, the diagrams after.** Such a page's `<head>` names one more script, `<script id="mdql-mermaid" nonce=… async src="mdql-asset:///mermaid.js">`, under the page's own nonce, so the CSP stands as it is. `async` keeps the parser and DOMContentLoaded from waiting on megabytes of script; the load event, `didFinish`, does wait for it. `mdql-screenshot` therefore waits on `window.__mdqlDiagramsSettled` before its snapshot.
- **One script, served from the bundle.** `MermaidRuntime.SchemeHandler`, installed on every web view mdql makes, answers that one URL with mermaid.min.js followed by `MermaidRuntime.glue`, the code that draws the fences, and refuses any other. Nothing is inlined, so nothing needs escaping for an HTML parser.
- **One copy shipped.** The Quick Look extension carries mermaid.min.js; the app reads the extension's (`MermaidRuntime.locate`). The tests and `mdql-screenshot` carry their own.

## In the page

`glue` starts on DOMContentLoaded, or at once if the script arrives later. It renders each fence with `securityLevel: 'strict'` (which a `%%{init}%%` directive cannot loosen) in the theme the system's appearance asks for, and redraws on an appearance change. A fence that fails keeps its source, marked, with a note saying why. Live updates go through `__mdqlSwapBody`, which puts unchanged diagrams back rather than drawing them again ([live-updates.md](live-updates.md)).

## Updating Mermaid

`scripts/fetch-mermaid.sh <version>` installs a release from its npm registry tarball, after checking the tarball against the sha512 the registry publishes, and pins the release and the file's sha256 in `scripts/mermaid.pin`. Run without a version it installs the pinned release again and refuses a file that is not the pinned one. `make version-test` checks the vendored file against the pin (`scripts/test_fetch_mermaid.py`).

`.github/workflows/mermaid-update.yml` does this weekly: when npm's latest release is newer than the pin, it opens one pull request from the branch `mermaid-update`, or refreshes the open one, titled "major" for a major release, and dispatches `ci.yml` on it, since a pull request opened with `GITHUB_TOKEN` starts no workflow ([learnings.md](learnings.md)). It needs the repository setting "Allow GitHub Actions to create and approve pull requests".
