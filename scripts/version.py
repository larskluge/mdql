#!/usr/bin/env python3
"""Work out mdql's next version from the commits since its last tag.

One app ships out of this tree, so a commit is read on one axis only: what kind
of change it is, taken from the subject prefix (`feat`, `fix`, …).

Of the 69 non-merge commits behind the first release — the ones a release reads;
`git rev-list --count HEAD` counts 71 including merges, and that count is the
build number — only 21 carry a conventional prefix. So the rule that an
unrecognised subject is a patch listed under **Other** is not a corner case
here: it covers 48 of those 69, and it is what keeps them from vanishing out of
the changelog entirely.

The version lives in `mdql.xcodeproj/project.pbxproj`, which is hand-maintained:
there is no project.yml and no xcodegen in this repository, so the pbxproj *is*
the source and this edits it in place.
"""

from __future__ import annotations

import argparse
import datetime
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# Ascending, and the order is the comparison — `max(..., key=LEVELS.index)` is
# how a batch's bump is resolved.
LEVELS = ("none", "patch", "minor", "major")

MINOR_TYPES = frozenset({"feat"})
PATCH_TYPES = frozenset({"fix", "perf"})
# Types that claim, by their own name, not to be user-visible. A batch of
# nothing but these produces no release rather than a number with nothing
# behind it.
QUIET_TYPES = frozenset({"refactor", "chore", "build", "test", "docs", "ci", "style"})

# The scope in `feat(preview):` is matched and not captured: it names a part of
# the app, and nothing here reads it — the type and the `!` decide everything.
_SUBJECT = re.compile(r"^(?P<type>[a-z][a-z0-9]*)(?:\([^)]*\))?(?P<bang>!)?:\s")
_BREAKING = re.compile(r"^BREAKING[ -]CHANGE:", re.MULTILINE)
_PR_SUFFIX = re.compile(r"\s*\(#\d+\)\s*$")


@dataclass(frozen=True, order=True)
class Version:
    major: int
    minor: int
    patch: int

    @classmethod
    def parse(cls, text: str) -> "Version":
        m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", text.strip())
        if not m:
            raise ValueError(f"not a three-part version: {text!r}")
        return cls(*(int(g) for g in m.groups()))

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"

    def bumped(self, level: str) -> "Version":
        if level == "major":
            return Version(self.major + 1, 0, 0)
        if level == "minor":
            return Version(self.major, self.minor + 1, 0)
        if level == "patch":
            return Version(self.major, self.minor, self.patch + 1)
        if level == "none":
            return self
        raise ValueError(f"unknown level: {level!r}")


@dataclass(frozen=True)
class Commit:
    """A commit as the changelog needs it, and no more.

    There is no file list here. A tree that ships two apps has to read every
    commit on a second axis — which app the changed paths reach — and choose
    between them. mdql is one app: every commit reaches it, so the paths decide
    nothing and the `git log` below asks for no `--name-only`.
    """

    sha: str
    subject: str
    body: str


def _type_of(subject: str):
    return _SUBJECT.match(subject)


def level_for(subject: str, body: str = "") -> str:
    """How far this one commit would move the version on its own."""
    m = _type_of(subject)
    if (m and m.group("bang")) or _BREAKING.search(body or ""):
        return "major"
    if m is None:
        # Most of this repository's subjects look like this — plain sentences
        # about what changed, written before the prefixes started. A patch that
        # shows up in the changelog beats silence.
        return "patch"
    kind = m.group("type")
    if kind in MINOR_TYPES:
        return "minor"
    if kind in PATCH_TYPES:
        return "patch"
    if kind in QUIET_TYPES:
        return "none"
    return "patch"


def heading_for(subject: str, body: str = "") -> str | None:
    """The changelog heading this commit belongs under, or None to omit it.

    Separate from `level_for` because the heading follows the *type* where the
    level follows severity: a `fix` and an unlabelled subject are both patches
    and belong under different headings.
    """
    m = _type_of(subject)
    if (m and m.group("bang")) or _BREAKING.search(body or ""):
        return "Changed"
    if m is None:
        return "Other"
    kind = m.group("type")
    if kind in MINOR_TYPES:
        return "Added"
    if kind in PATCH_TYPES:
        return "Fixed"
    if kind in QUIET_TYPES:
        return None
    return "Other"


def summary(subject: str) -> str:
    """The subject as a changelog line: prefix off, PR number off.

    Subjects in this repository are already sentences about what changed, which
    is why nothing here rewrites them.
    """
    # `_SUBJECT` is anchored at the start, so on a subject that carries no
    # prefix the substitution is already a no-op and needs no guard around it.
    return _PR_SUFFIX.sub("", _SUBJECT.sub("", subject, count=1)).strip()


def bump_level(commits) -> str:
    """The highest level in the batch: one `feat` makes the whole batch minor."""
    return max(
        (level_for(c.subject, c.body) for c in commits), key=LEVELS.index, default="none"
    )


# ---- the changelog ---------------------------------------------------------

CHANGELOG_HEADER = "# Changelog\n"

# The order sections appear in a release, whatever order the commits arrived in.
HEADING_ORDER = ("Changed", "Added", "Fixed", "Other")


def release_note(entries, forced=None) -> str | None:
    """The sentence a release with nothing to list needs, or None.

    Reachable one way: an explicit `--level patch` cutting a build from commits
    that all classify as nothing — a throwaway release, which is how a signing
    or install path gets verified end to end without waiting for real work.
    Left unsaid, that release's section in the changelog is a heading with
    nothing under it and no hint of why the number moved.
    """
    if any(heading_for(c.subject, c.body) for c in entries):
        return None
    if forced:
        return f"No changes; a {forced} release cut deliberately."
    return None


def render_release(version, date, entries, note=None) -> str:
    """One release's section: a heading, then the commits under theirs.

    `note` is for the release that has nothing to list, where the reason the
    number moved is the whole content.
    """
    out = [f"## {version} — {date}\n"]
    if note:
        out.append(f"\n{note}\n")
        return "".join(out)
    grouped: dict[str, list[str]] = {}
    for c in entries:
        heading = heading_for(c.subject, c.body)
        if heading is None:
            continue
        grouped.setdefault(heading, []).append(summary(c.subject))
    for heading in HEADING_ORDER:
        lines = grouped.get(heading)
        if not lines:
            continue
        out.append(f"\n### {heading}\n")
        out.extend(f"- {line}\n" for line in lines)
    return "".join(out)


def prepend_release(changelog: str, section: str) -> str:
    """The new section above the existing releases, newest first.

    Above the *releases*, not directly under the header: CHANGELOG.md opens with
    a paragraph naming what writes it, and inserting after the `# Changelog`
    line alone would push that paragraph below the newest release, where it
    reads as part of it. So everything before the first `## ` heading is
    preamble and stays put.
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


# ---- project.pbxproj, the source of truth -----------------------------------

VERSION_KEYS = ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION")

PBXPROJ = "mdql.xcodeproj/project.pbxproj"

# Xcode's own shape for a build setting: tab indentation, an unquoted value, a
# trailing semicolon. Anchored at both ends because the same words appear inside
# the version-stamp build phase's `shellScript = "…${MARKETING_VERSION}…"`, and
# a loose search would count that as a third occurrence and refuse to run.
_SETTING = re.compile(
    r"^\t*(?P<key>MARKETING_VERSION|CURRENT_PROJECT_VERSION) = (?P<value>[^;\n]*);$"
)


def version_spots(text: str) -> dict[str, tuple[tuple[int, int], str]]:
    """Where each version setting lives, by line index, and what it holds now.

    Both settings are declared once at PROJECT level in each of the two
    configurations of `Build configuration list for PBXProject "mdql"`, so all
    five targets inherit one number. That shape is what this checks, and
    anything that would make a write ambiguous raises `LookupError` naming it —
    because every failure here is otherwise silent: the project builds, the
    tests pass, and something ships a number nobody chose.
    """
    lines = text.splitlines()
    found: dict[str, list[tuple[int, str]]] = {key: [] for key in VERSION_KEYS}
    for i, line in enumerate(lines):
        m = _SETTING.match(line)
        if m:
            found[m.group("key")].append((i, m.group("value")))

    spots: dict[str, tuple[tuple[int, int], str]] = {}
    for key in VERSION_KEYS:
        hits = found[key]
        if not hits:
            raise LookupError(
                f"{PBXPROJ} has no {key} — it belongs in both configurations of "
                f"the project-level build configuration list, which is where "
                f"every target inherits it from"
            )
        if len(hits) == 1:
            raise LookupError(
                f"{PBXPROJ} sets {key} once (line {hits[0][0] + 1}); the other "
                f"project-level configuration has none, so one of Debug and "
                f"Release would keep the old number"
            )
        if len(hits) > 2:
            where = ", ".join(str(i + 1) for i, _ in hits)
            raise LookupError(
                f"{PBXPROJ} sets {key} {len(hits)} times (lines {where}), and only "
                f"the two project-level configurations should: a target-level "
                f"override shadows the project setting, so bumping the project "
                f"value leaves that one target shipping a stale number with every "
                f"build still green"
            )
        (i, first), (j, second) = hits
        if first != second:
            raise LookupError(
                f"{PBXPROJ} disagrees about {key}: {first!r} on line {i + 1}, "
                f"{second!r} on line {j + 1}. The two project-level configurations "
                f"already hold different values, so there is no single current "
                f"version to bump"
            )
        spots[key] = ((i, j), first)
    return spots


def read_version(text: str) -> Version:
    """The version the project currently declares.

    Only the version comes back: the build number a bump writes is the commit
    count, not the old value plus one, so nothing here has a use for what
    CURRENT_PROJECT_VERSION holds. It is still checked, because a value that is
    not a number means the file has been mangled by hand, and overwriting it
    with a fresh count would erase the only evidence of that.

    Both failures are re-raised naming the file and the setting: `Version.parse`
    and `isdigit` on their own say what the string was but not where it came
    from, and this one is read out of a 1000-line file nobody reads by hand.
    """
    spots = version_spots(text)
    build = spots["CURRENT_PROJECT_VERSION"][1]
    if not build.isdigit():
        raise ValueError(f"{PBXPROJ}: CURRENT_PROJECT_VERSION is not a number: {build!r}")
    try:
        return Version.parse(spots["MARKETING_VERSION"][1])
    except ValueError as exc:
        raise ValueError(f"{PBXPROJ}: MARKETING_VERSION is {exc}") from exc


def write_version(text: str, version: Version, build: int) -> str:
    """Rewrite both occurrences of both settings, and nothing else.

    Only the value's own span is replaced, so indentation, ordering and line
    endings come through untouched: this file is hand-maintained and also
    rewritten by Xcode, and a bump whose diff is anything other than four
    changed values is a bump nobody can review.

    The lines to rewrite are the ones `version_spots` already found, and using
    those indices is what makes any line terminator work. Re-deriving them here
    from `splitlines(keepends=True)` did not: on a file with CRLF endings the
    kept carriage return sits where the pattern's `;$` anchor wants the end of
    the line, so every match failed, the text came back byte-identical, and the
    bump reported a version it had not written.
    """
    spots = version_spots(text)  # Raises before a single byte is rewritten.
    wanted = {
        "MARKETING_VERSION": str(version),
        "CURRENT_PROJECT_VERSION": str(build),
    }
    lines = text.splitlines(keepends=True)
    for key, (indices, value) in spots.items():
        for i in indices:
            line = lines[i]
            body = line.rstrip("\r\n")
            # `version_spots` matched `<indent>KEY = value;` against exactly
            # this text, so the value's span is the tail before the semicolon.
            head = body[: len(body) - len(value) - 1]
            lines[i] = f"{head}{wanted[key]};{line[len(body):]}"
    return "".join(lines)


# ---- git, and the run ------------------------------------------------------

# One `git log` call for everything: a record separator, then sha, subject and
# body NUL-separated.
LOG_FORMAT = "%x1e%H%x00%s%x00%b"

TAG_PREFIX = "v"
# Everything a bump writes, and the only paths it ever stages *or commits* —
# both steps below name this pathspec. `git add -A`, or a `git commit` without
# it, would sweep another session's work into a release commit; ~/code/mdql is
# a shared checkout and its index is not ours.
WRITTEN_PATHS = (PBXPROJ, "CHANGELOG.md")


def parse_log(raw: str) -> list[Commit]:
    commits = []
    for record in raw.split("\x1e"):
        if not record.strip():
            continue
        sha, subject, body = record.split("\x00", 2)
        commits.append(Commit(sha=sha.strip(), subject=subject.strip(), body=body.strip()))
    return commits


def _git(*args, cwd=None) -> str:
    """Run one git command, or exit saying what git said.

    `capture_output` is what makes the handler necessary: with it and no handler,
    a failing pre-commit hook's output and git's own `fatal: tag 'v0.3.0'
    already exists` both vanish into a CalledProcessError traceback, and the
    user is left with a half-written tree and no word about which step failed.
    """
    try:
        return subprocess.run(
            ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
        ).stdout
    except subprocess.CalledProcessError as exc:
        # stdout only when stderr is empty: hooks and porcelain commands split
        # their reporting between the two, and the point is to lose neither.
        said = (exc.stderr or "").strip() or (exc.stdout or "").strip()
        raise SystemExit(
            f"version: `git {' '.join(args)}` failed (exit {exc.returncode})"
            + (f":\n{said}" if said else " and said nothing.")
        ) from exc


def _repo_root() -> Path:
    # The one git call with no `cwd`, on purpose: it is what finds the root that
    # every other call is then pinned to, so there is nothing to pin it to yet.
    # It resolves against the process's own directory, which is how `make
    # version` from anywhere inside the checkout reaches the right repository.
    return Path(_git("rev-parse", "--show-toplevel").strip())


def _last_tag(root: Path):
    """The newest release tag, which is the baseline the next release reads from.

    `-v:refname` and not `-refname`: plain refname sort is lexicographic, and
    once this repository reaches a two-digit part it puts v0.1.9 above v0.1.10.
    The baseline would then be a tag two releases back, and every commit already
    shipped in v0.1.10 would be listed a second time in the next changelog.
    """
    tags = _git("tag", "--list", f"{TAG_PREFIX}*", "--sort=-v:refname", cwd=root).split()
    return tags[0] if tags else None


def _tag_version(tag: str):
    """The version a tag names, or None when it names something else.

    A `vNightly` or `v0.2.0-rc1` is a tag, not a release, and comparing it
    against the project's version is not possible rather than false.
    """
    try:
        return Version.parse(tag[len(TAG_PREFIX) :])
    except ValueError:
        return None


def _require_tag_not_ahead(tag: str, current: Version) -> None:
    """Refuse a newest tag that stands ahead of the version in the pbxproj.

    The wedge: the undo line this tool prints was run without its `git tag -d`
    half, so the pbxproj is back at 0.1.0 while v0.2.0 still points at the
    discarded commit. `v0.2.0..HEAD` is then empty, every later run reports
    "nothing to release (0.1.0 stands)" and exits 0, and nothing ever says why.
    """
    tagged = _tag_version(tag)
    if tagged is None:
        print(
            f"version: the newest {TAG_PREFIX}* tag is {tag}, which names no version, "
            f"so it says nothing about what has been released",
            file=sys.stderr,
        )
        return
    if tagged > current:
        raise SystemExit(
            f"version: the newest tag is {tag} but {PBXPROJ} says {current}. A tag "
            f"ahead of the project is what an undone release leaves behind when the "
            f"`git tag -d` half of the undo was skipped: the commits since {tag} are "
            f"then read as none, and every run reports nothing to release. Delete it "
            f"with `git tag -d {tag}` (and from the remote too, if it was pushed)."
        )


def _require_tag_free(root: Path, tag_name: str) -> None:
    """Refuse a tag name that is taken, before anything has been written.

    Up front rather than at `git tag`: by then the release commit exists, and a
    release commit that failed to get its tag is one nothing downstream — the
    dist path, `make release`, the changelog's own numbering — can find.
    """
    if _git("tag", "--list", tag_name, cwd=root).strip():
        raise SystemExit(
            f"version: {tag_name} already exists, so it cannot be cut again — nothing "
            f"has been written. `git show {tag_name}` to see what it points at, "
            f"`git tag -d {tag_name}` if it is the leftover of an undone release."
        )


def _commits_since(tag, root: Path) -> list[Commit]:
    """The commits a release reads. `--no-merges` because a merge is not one.

    `Merge pull request #14 from …` carries no conventional prefix, so without
    the flag it classifies as a patch under **Other** and lands in the changelog
    as an entry — and worse, it can lift a batch that was all `docs` and `chore`
    out of "nothing to release" into a release with nothing behind it.
    """
    span = [f"{tag}..HEAD"] if tag else ["HEAD"]
    return parse_log(_git("log", "--no-merges", f"--format={LOG_FORMAT}", *span, cwd=root))


def _require_clean(root: Path) -> None:
    """Refuse to run over uncommitted changes to anything a bump writes.

    Not politeness: this repository is worked in by several sessions at once,
    and a release commit that picked up somebody's half-finished pbxproj is a
    release nobody can review.

    Only these paths, because only these are committed: work staged anywhere
    else stays staged and out of the release, so refusing over it would stop a
    release for something that cannot reach it.
    """
    dirty = _git("status", "--porcelain", "--", *WRITTEN_PATHS, cwd=root).strip()
    if dirty:
        # "already modified" named only one of the three states `git status`
        # reports here. A CHANGELOG.md that was never committed comes back as
        # `?? CHANGELOG.md`, and under that word the reader goes looking for an
        # edit nobody made — while `git add` would still sweep the whole file
        # into the release commit.
        raise SystemExit(
            "version: a release commits these, and git reports them as modified, "
            "staged or untracked — commit them or move them aside first:\n" + dirty
        )


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="version",
        description="Bump mdql's version from the commits since its last tag.",
    )
    parser.add_argument(
        "--level",
        choices=LEVELS,
        help="force the level instead of reading it out of the commits",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="print the plan and write nothing"
    )
    args = parser.parse_args(argv)

    root = _repo_root()
    if not args.dry_run:
        _require_clean(root)

    pbxproj = root / PBXPROJ
    # Newline translation off, on the read as well as the write below.
    # `Path.read_text()` decodes universal newlines, so a pbxproj checked out
    # with CRLF endings reached `write_version` as LF and went back out as LF:
    # every one of a thousand lines rewritten, which is precisely the diff
    # `write_version` goes to the trouble of not producing. Off, the bytes
    # round-trip and that function's CRLF handling is the code that runs.
    with open(pbxproj, newline="") as f:
        text = f.read()
    current = read_version(text)

    tag = _last_tag(root)
    if tag is None:
        print(
            f"version: no {TAG_PREFIX}* tag — reading from the root commit, which is "
            f"every commit in the repository",
            file=sys.stderr,
        )
    else:
        _require_tag_not_ahead(tag, current)
    commits = _commits_since(tag, root)

    level = args.level or bump_level(commits)
    version = current.bumped(level)
    if version == current:
        print(f"version: nothing to release ({current} stands)")
        return 0

    # Before the plan is printed and before --dry-run returns, because a taken
    # tag means this release cannot be cut at all — a dry run that reported a
    # plan the real run then refuses would be worse than useless.
    tag_name = f"{TAG_PREFIX}{version}"
    _require_tag_free(root, tag_name)

    print(f"mdql: {current} → {version}  ({level})")
    for c in commits:
        if heading_for(c.subject, c.body) is not None:
            print(f"    {level_for(c.subject, c.body):6} {c.sha[:7]}  {c.subject}")

    if args.dry_run:
        print("version: --dry-run, nothing written.")
        return 0

    # Every commit, merges included: this is CFBundleVersion, and macOS reads a
    # build number that went down as a downgrade. `--no-merges` belongs on the
    # log — which reads what a release *changed* — and nowhere near the count.
    build = int(_git("rev-list", "--count", "HEAD", cwd=root).strip())
    with open(pbxproj, "w", newline="") as f:
        f.write(write_version(text, version, build))

    section = render_release(
        version,
        datetime.date.today().isoformat(),
        commits,
        note=release_note(commits, args.level),
    )
    # No `newline=""` here, unlike the pbxproj above: this file is written by
    # this tool alone and `render_release` composes its lines with "\n", so
    # carrying a CRLF tail through would leave one file holding both endings.
    # The pbxproj is the other case — Xcode's file and the maintainer's, which
    # this only ever reaches into for four values.
    changelog = root / "CHANGELOG.md"
    changelog.write_text(
        prepend_release(changelog.read_text() if changelog.exists() else "", section)
    )

    _git("add", "--", *WRITTEN_PATHS, cwd=root)
    # Staged by pathspec and committed by the same pathspec, which is `--only`
    # semantics. Staging alone was not enough: a bare `git commit -m …` commits
    # the whole index, so whatever another session had already staged in this
    # shared checkout rode along into the release commit and the tag pointed at
    # it. The pathspec is what holds the commit to the two paths above.
    _git("commit", "-m", f"chore(release): {version}", "--", *WRITTEN_PATHS, cwd=root)
    # Annotated, not lightweight, and the one word `-a` is what the release flow
    # rests on: `git push --follow-tags` — the command the docs and the Makefile
    # both hand the user — carries annotated tags and silently skips lightweight
    # ones. It exits 0 either way, and `make release` then refuses with "not on
    # origin", pointing back at the push that just appeared to work.
    _git("tag", "-a", tag_name, "-m", str(version), cwd=root)

    print(f"\nversion: committed and tagged — {version} (build {build})")
    # Both halves of the undo, and neither is optional: `git reset --hard` is
    # safe here only because the commit holds nothing but WRITTEN_PATHS, and
    # leaving the tag behind points it at a discarded commit — the wedge
    # `_require_tag_not_ahead` exists to refuse.
    print(
        f"version: nothing has been pushed. `git show` to review, "
        f"`git reset --hard HEAD~1 && git tag -d {tag_name}` to undo."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
