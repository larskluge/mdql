#!/usr/bin/env python3
"""Pull one release's section out of CHANGELOG.md.

`make version` already decided what a release changed, from the commits, and
wrote it under a heading — so the GitHub release body reads that back rather
than describing the same release a second time in a different voice.

The headings are `scripts/version.py`'s (`render_release`): `## 0.2.0 —
2026-08-20`, with `### `-level groups under them. A section runs to the next
`## ` heading — one outside a code fence, since a section that quotes markdown
has `## ` lines of its own — or to the end of the file.

Markdown out, and only markdown: the one reader is `gh release create
--notes-file`, which takes the file as the release body verbatim.

    python3 scripts/changelog-section.py --version 0.2.0
    python3 scripts/changelog-section.py --version 0.2.0 --output build/notes.md
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


# CommonMark's two fence characters, three or more of one of them. The run is
# captured whole because its length is half of what decides a close.
_FENCE = re.compile(r"^(?P<run>`{3,}|~{3,})")


def _fenced(lines: list[str]) -> list[bool]:
    """For each line, whether it sits inside a fenced code block.

    A release note that quotes markdown — this changelog's own headings, say —
    carries `## ` lines inside a fence. Read literally they end the section
    early, which drops the entries below them and hands `gh` a release body
    whose code fence is never closed.

    Which is why the fence is tracked by CommonMark's own rule — a fence closes
    only on the same character, run at least as long — rather than by "any line
    that starts with a marker". Backticks alone did not see a `~~~markdown`
    block at all, so a heading quoted inside one truncated the section exactly
    as above; and a ````` ```` ````` block quoting a ``` fence toggled on the
    way in and again on the inner line, leaving the state inverted past its end
    so that the next `## ` stopped being a boundary — one release's notes then
    swallowing the whole release below it.
    """
    inside: list[bool] = []
    open_run: str | None = None
    for line in lines:
        # The delimiter itself is recorded under the state it opens or closes
        # from; only `## ` lines are ever asked about, so which side a fence
        # line falls on does not matter.
        inside.append(open_run is not None)
        m = _FENCE.match(line.lstrip())
        if m is None:
            continue
        run = m.group("run")
        if open_run is None:
            open_run = run
        elif run[0] == open_run[0] and len(run) >= len(open_run):
            open_run = None
    return inside


def section(changelog: str, version: str, source: str = "CHANGELOG.md") -> str:
    """The body of one release's section, without its own `## ` heading.

    Raises LookupError naming what was looked for and the file it was looked
    for in — both when the heading is missing and when it is there with an
    empty body — because the alternative, an empty string, becomes a release
    with no notes and nobody notices until it is published.
    """
    # The date is whatever `make version` stamped, so only the version is
    # matched and the rest of the line is left alone. The lookahead is what
    # makes the match exact: without it `0.1.1` finds `## 0.1.10 — …` and
    # publishes the wrong release's notes. `$` covers a heading that carries no
    # date at all, which is what a hand-written first entry looks like.
    wanted = re.compile(rf"^## {re.escape(version)}(?=\s|$)")
    lines = changelog.splitlines()
    fenced = _fenced(lines)
    start = None
    for i, line in enumerate(lines):
        if not fenced[i] and wanted.match(line):
            start = i + 1
            break
    if start is None:
        raise LookupError(
            f"{source} has no `## {version}` section. "
            f"`make version` writes one per release; if this version was never "
            f"released, there is nothing to publish."
        )

    end = len(lines)
    for i in range(start, len(lines)):
        if lines[i].startswith("## ") and not fenced[i]:
            end = i
            break
    body = "\n".join(lines[start:end]).strip()
    if not body:
        raise LookupError(
            f"{source} has a `## {version}` heading with nothing under it. "
            f"An empty section publishes a release with no notes; write the "
            f"entry before tagging."
        )
    return body + "\n"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="e.g. 0.2.0")
    parser.add_argument("--changelog", default=None, help="defaults to the repo's CHANGELOG.md")
    parser.add_argument("--output", default=None, help="defaults to stdout")
    args = parser.parse_args(argv)

    path = (
        Path(args.changelog)
        if args.changelog
        else Path(__file__).resolve().parent.parent / "CHANGELOG.md"
    )
    try:
        # The path, not the word "CHANGELOG.md": with `--changelog` in play the
        # error has to point at the file that was actually read.
        body = section(path.read_text(), args.version, source=str(path))
    except OSError as exc:
        print(f"error: cannot read {path}: {exc}", file=sys.stderr)
        return 1
    except LookupError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.output:
        out = Path(args.output)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(body)
        print(f"wrote {out} ({len(body)} bytes)", file=sys.stderr)
    else:
        sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
