#!/usr/bin/env python3
"""Cut a release: CHANGELOG.md's section for the computed version, then its tag.

Run only when Lars asks for a release (`make release-tag`). The version is
whatever `scripts/version.py` computes at HEAD; this writes it down and names
it. It reads the commits since the previous *release* — the newest section in
CHANGELOG.md — which can span more than one tag: the baseline `v0.2.6`, or a
major Lars had tagged, is a version, not a release, and has no section.

One commit, `chore(release): <version>`, holding CHANGELOG.md alone, and one
annotated tag on it. `chore` is a quiet type, so the commit leaves the computed
version where it was. It pushes nothing.

    python3 scripts/release-tag.py --dry-run   # the section and the tag, written nowhere
    python3 scripts/release-tag.py             # write, commit, tag
    python3 scripts/release-tag.py --major 1   # the release that makes it 1.0.0
"""

from __future__ import annotations

import argparse
import datetime
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from version import (  # noqa: E402  (the path above is what finds it)
    MINOR_TYPES,
    QUIET_TYPES,
    TAG_PREFIX,
    Commit,
    Version,
    VersionError,
    _git,
    commit_type,
    commits_since,
    read,
    repo_root,
)

CHANGELOG = "CHANGELOG.md"
CHANGELOG_HEADER = "# Changelog\n"
HEADING_ORDER = ("Added", "Fixed", "Other")
PATCH_TYPES = frozenset({"fix", "perf"})

_PR_SUFFIX = re.compile(r"\s*\(#\d+\)\s*$")
_PREFIX = re.compile(r"^[a-z][a-z0-9]*(?:\([^)]*\))?!?:\s")
_RELEASE_HEADING = re.compile(r"^## (\d+\.\d+\.\d+)(?=\s|$)", re.MULTILINE)


def heading_for(subject: str) -> str | None:
    """The changelog heading a commit belongs under, or None to leave it out.

    It follows the type where the version follows the level: a `fix` and an
    unprefixed subject are both patches, under different headings.
    """
    kind = commit_type(subject)
    if kind in MINOR_TYPES:
        return "Added"
    if kind in PATCH_TYPES:
        return "Fixed"
    if kind in QUIET_TYPES:
        return None
    return "Other"


def summary(subject: str) -> str:
    """The subject as a changelog line: prefix off, PR number off."""
    return _PR_SUFFIX.sub("", _PREFIX.sub("", subject, count=1)).strip()


def render_release(version: Version, date: str, commits, note: str | None = None) -> str:
    """One release's section: a heading, then each commit under its heading.

    `commits` oldest first; listed newest first under each heading. `note` is
    the release with nothing to list — a `--major` over quiet commits only —
    whose reason the number moved is the whole content.
    """
    out = [f"## {version} — {date}\n"]
    grouped: dict[str, list[str]] = {}
    for c in reversed(list(commits)):
        heading = heading_for(c.subject)
        if heading is not None:
            grouped.setdefault(heading, []).append(summary(c.subject))
    if not grouped:
        out.append(f"\n{note or 'No user-visible changes.'}\n")
        return "".join(out)
    for heading in HEADING_ORDER:
        if grouped.get(heading):
            out.append(f"\n### {heading}\n")
            out.extend(f"- {line}\n" for line in grouped[heading])
    return "".join(out)


def prepend_release(changelog: str, section: str) -> str:
    """The new section above the existing releases, newest first.

    Everything before the first `## ` heading is the preamble and stays put.
    """
    lines = changelog.splitlines(keepends=True)
    cut = next((i for i, ln in enumerate(lines) if ln.startswith("## ")), len(lines))
    head = "".join(lines[:cut])
    tail = "".join(lines[cut:])
    if not head.strip():
        head = CHANGELOG_HEADER
    parts = [head.rstrip("\n") + "\n", "\n", section.rstrip("\n") + "\n"]
    if tail.strip():
        parts.extend(["\n", tail])
    return "".join(parts)


def previous_release(changelog: str) -> Version | None:
    """The newest release CHANGELOG.md records, or None before the first."""
    m = _RELEASE_HEADING.search(changelog)
    return Version.parse(m.group(1)) if m else None


def _commits_for(root: Path, previous: Version | None) -> list[Commit]:
    if previous is None:
        raw = _git(root, "log", "--no-merges", "--reverse", "--format=%H%x00%s", "HEAD")
        return [Commit(*line.split("\x00", 1)) for line in raw.splitlines() if line]
    tag = f"{TAG_PREFIX}{previous}"
    if not _git(root, "tag", "--list", tag).strip():
        raise VersionError(
            f"{CHANGELOG}'s newest release is {previous}, but there is no tag {tag} "
            f"to read the commits since it from"
        )
    return commits_since(root, tag)


def _roll_back(root: Path, head: str, path: Path, original: bytes | None) -> None:
    """Put HEAD, the index and CHANGELOG.md back as they were before the write.

    Half a release is worse than none: an edited CHANGELOG.md makes the next run
    refuse the file, and a release commit without its tag makes it refuse the
    missing tag, each with nothing to say how to get out.
    """
    _git(root, "reset", "--quiet", "--soft", head)
    if original is None:
        _git(root, "rm", "--quiet", "--cached", "--ignore-unmatch", "--", CHANGELOG)
        path.unlink(missing_ok=True)
    else:
        _git(root, "checkout", head, "--", CHANGELOG)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="release-tag", description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="print the plan, write nothing")
    parser.add_argument(
        "--major", type=int, metavar="N", help="release as N.0.0 (only when Lars asks for it)"
    )
    args = parser.parse_args(argv)

    try:
        root = repo_root()
        # As `make release` requires, and before anything is written: a tag cut on a
        # branch names a commit the squash-merge then discards.
        branch = _git(root, "rev-parse", "--abbrev-ref", "HEAD").strip()
        if branch != "main":
            where = "detached" if branch == "HEAD" else f"on '{branch}'"
            raise VersionError(f"HEAD is {where}, not main: a release is cut from main")
        # CHANGELOG.md by name first, since it is the file this writes; then the rest
        # of the tracked tree below, once the reading has looked at it.
        if not args.dry_run:
            dirty = _git(root, "status", "--porcelain", "--", CHANGELOG).strip()
            if dirty:
                raise VersionError(
                    f"a release commits {CHANGELOG}, and git reports it modified, staged "
                    f"or untracked — commit it or move it aside first:\n{dirty}"
                )
        reading = read(root)
        if reading.dirty and not args.dry_run:
            # `make dist` refuses a dirty tree anyway; the tag would name a commit
            # whose build is not what sat in the tree when it was cut.
            raise VersionError(
                "the working tree has uncommitted changes to tracked files; a release "
                "is cut from a clean tree"
            )
        version = reading.version
        if args.major is not None:
            if args.major <= version.major:
                raise VersionError(
                    f"--major {args.major} would not move the major: the version is "
                    f"already {version}"
                )
            version = Version(args.major, 0, 0)

        tag = f"{TAG_PREFIX}{version}"
        taken = _git(root, "tag", "--list", tag).strip()
        if taken:
            at = _git(root, "rev-parse", "--short", f"{tag}^{{commit}}").strip()
            raise VersionError(
                f"{tag} already exists (on {at}): the version has not moved since it "
                f"was tagged, so there is nothing new to release. A `fix` or `feat` "
                f"moves it; nothing has been written."
            )

        path = root / CHANGELOG
        changelog = path.read_text() if path.exists() else ""
        previous = previous_release(changelog)
        commits = _commits_for(root, previous)
        note = f"No user-visible changes; the major moved to {version.major}." if args.major else None
        section = render_release(version, datetime.date.today().isoformat(), commits, note)

        since = f"since {previous}" if previous else "from the first commit"
        print(f"mdql: release {version}, {len(commits)} commits {since}\n")
        print(section)
        if args.dry_run:
            print("release-tag: --dry-run, nothing written.")
            return 0

        original = path.read_bytes() if path.exists() else None
        head = _git(root, "rev-parse", "HEAD").strip()
        path.write_text(prepend_release(changelog, section))
        try:
            _git(root, "add", "--", CHANGELOG)
            # Committed by pathspec, which is `--only`: the commit holds CHANGELOG.md
            # and nothing else the index might carry.
            _git(root, "commit", "-m", f"chore(release): {version}", "--", CHANGELOG)
            # Annotated, because `git push --follow-tags` carries annotated tags and
            # silently skips lightweight ones.
            _git(root, "tag", "-a", tag, "-m", str(version))
        except BaseException as exc:
            # Any way out, a refused hook or a Ctrl-C alike, leaves no half-release.
            try:
                _roll_back(root, head, path, original)
            except VersionError as undo:
                raise VersionError(
                    f"{exc}\nUndoing it failed too, so the release is half-written: {undo}\n"
                    f"HEAD was {head[:7]}; `git reset --hard {head[:7]}` puts it back."
                ) from exc
            if not isinstance(exc, VersionError):
                raise
            raise VersionError(f"{exc}\nUndone: HEAD and {CHANGELOG} are as they were.") from exc
    except VersionError as exc:
        print(f"release-tag: {exc}", file=sys.stderr)
        return 1

    print(f"release-tag: committed and tagged {tag}. Nothing has been pushed.")
    print(f"release-tag: undo with `git reset --hard HEAD~1 && git tag -d {tag}`.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
