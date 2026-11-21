#!/usr/bin/env python3
"""mdql's version, computed from git history at every build. Nothing stores it.

The rule, which docs/releases.md → "The version" explains:

- Baseline: the highest `vX.Y.Z` tag reachable from HEAD.
- After it, each non-merge commit, oldest first: `feat` bumps the minor and
  zeroes the patch; `fix`, `perf`, an unprefixed subject or any type not listed
  here bumps the patch; the quiet types bump nothing.
- Nothing infers a major. It moves only with a tag Lars asks for (`v1.0.0`);
  a `!` or a `BREAKING CHANGE:` footer reads as its plain type.
- The build number is `git rev-list --count HEAD`, merges included.

    python3 scripts/version.py               # 0.2.7
    python3 scripts/version.py --build       # 75
    python3 scripts/version.py --explain     # the baseline, then each commit's step
    python3 scripts/version.py --write FILE  # what the Xcode build phases stamp
    python3 scripts/version.py --check APP   # a built mdql.app carries it throughout
"""

from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

TAG_PREFIX = "v"

MINOR_TYPES = frozenset({"feat"})
# Types that claim, by their own name, not to be user-visible.
QUIET_TYPES = frozenset({"chore", "docs", "ci", "test", "build", "refactor", "style"})

# The scope in `feat(preview):` and a `!` are matched and not captured: only the
# type decides anything.
_SUBJECT = re.compile(r"^(?P<type>[a-z][a-z0-9]*)(?:\([^)]*\))?!?:\s")


class VersionError(Exception):
    """A version that cannot be computed, or a build that does not carry it."""


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
        if level == "minor":
            return Version(self.major, self.minor + 1, 0)
        if level == "patch":
            return Version(self.major, self.minor, self.patch + 1)
        if level == "none":
            return self
        raise ValueError(f"unknown level: {level!r}")


def commit_type(subject: str) -> str | None:
    """The conventional type a subject opens with, or None when it has none."""
    m = _SUBJECT.match(subject)
    return m.group("type") if m else None


def level_for(subject: str) -> str:
    """How far one commit moves the version: `minor`, `patch` or `none`.

    An unprefixed subject, or a type this list does not know, is a patch: it is
    still a change somebody made.
    """
    kind = commit_type(subject)
    if kind in MINOR_TYPES:
        return "minor"
    if kind in QUIET_TYPES:
        return "none"
    return "patch"


def advance(baseline: Version, subjects) -> Version:
    """The baseline moved by each subject in turn, oldest first.

    In order, not by the batch's highest level: a `fix` after a `feat` is the
    first patch of the new minor, so `feat` then `fix` on 0.2.6 reads 0.3.1.
    """
    version = baseline
    for subject in subjects:
        version = version.bumped(level_for(subject))
    return version


# ---- git --------------------------------------------------------------------


@dataclass(frozen=True)
class Commit:
    sha: str
    subject: str


def _git(root: Path, *args: str) -> str:
    """One git command's stdout, or a VersionError carrying what git said."""
    try:
        return subprocess.run(
            ["git", *args], cwd=root, check=True, capture_output=True, text=True
        ).stdout
    except subprocess.CalledProcessError as exc:
        said = (exc.stderr or "").strip() or (exc.stdout or "").strip()
        raise VersionError(
            f"`git {' '.join(args)}` failed (exit {exc.returncode})"
            + (f": {said}" if said else " and said nothing")
        ) from exc


def repo_root(start: Path | None = None) -> Path:
    return Path(_git(start or Path.cwd(), "rev-parse", "--show-toplevel").strip())


def baseline_tag(root: Path, ref: str = "HEAD") -> tuple[str, Version]:
    """The highest `vX.Y.Z` tag reachable from `ref`, and the version it names.

    Highest by version, not nearest by topology, so the number never goes down
    because somebody tagged an older version on a later commit. Tags that name
    no version (`vNightly`, `v0.3.0-rc1`) are not baselines and are skipped.
    """
    found = []
    for tag in _git(root, "tag", "--merged", ref, "--list", f"{TAG_PREFIX}*").split():
        try:
            found.append((Version.parse(tag[len(TAG_PREFIX) :]), tag))
        except ValueError:
            continue
    if not found:
        raise VersionError(
            f"no {TAG_PREFIX}X.Y.Z tag is reachable from {ref}, so there is no "
            f"baseline to count from. A clone without tags: `git fetch --tags`."
        )
    version, tag = max(found)
    return tag, version


def commits_since(root: Path, tag: str, ref: str = "HEAD") -> list[Commit]:
    """The non-merge commits after `tag` up to `ref`, oldest first.

    `--no-merges` because a merge is not a change of its own: `Merge pull request
    #14 from …` carries no prefix and would otherwise count as a patch on top of
    the commits it brings in, which are counted already.
    """
    raw = _git(root, "log", "--no-merges", "--reverse", "--format=%H%x00%s", f"{tag}..{ref}")
    commits = []
    for line in raw.splitlines():
        if line:
            sha, subject = line.split("\x00", 1)
            commits.append(Commit(sha=sha, subject=subject.strip()))
    return commits


@dataclass(frozen=True)
class Reading:
    """Everything a build needs from history, read once."""

    tag: str
    baseline: Version
    commits: tuple
    version: Version
    build: int
    short: str
    dirty: bool

    @property
    def badge(self) -> str:
        """What version.txt holds, and the preview draws in its corner."""
        return f"{self.version} ({self.short}{'-dirty' if self.dirty else ''})"


def read(root: Path) -> Reading:
    # A shallow clone has a tag or not depending on how deep it went, and always
    # counts too few commits: the build number would go down. Refused, rather
    # than stamped into a build that macOS then reads as a downgrade.
    if _git(root, "rev-parse", "--is-shallow-repository").strip() == "true":
        raise VersionError(
            "this clone is shallow, so the build number (`git rev-list --count HEAD`) "
            "would count only part of the history. `git fetch --unshallow --tags`."
        )
    tag, baseline = baseline_tag(root)
    commits = tuple(commits_since(root, tag))
    return Reading(
        tag=tag,
        baseline=baseline,
        commits=commits,
        version=advance(baseline, (c.subject for c in commits)),
        build=int(_git(root, "rev-list", "--count", "HEAD").strip()),
        short=_git(root, "rev-parse", "--short", "HEAD").strip(),
        # Tracked changes, staged or not; an untracked file is in no build input
        # until it is added, which is what `git diff --quiet` always meant here.
        dirty=bool(_git(root, "status", "--porcelain", "--untracked-files=no").strip()),
    )


def explain(reading: Reading) -> str:
    lines = [f"{reading.baseline}  {reading.tag}"]
    version = reading.baseline
    for c in reading.commits:
        level = level_for(c.subject)
        version = version.bumped(level)
        lines.append(f"{version}  {level:5}  {c.sha[:7]}  {c.subject}")
    lines.append(f"= {reading.version}, build {reading.build}")
    return "\n".join(lines) + "\n"


# ---- the build --------------------------------------------------------------

# What the `mdql-version` target writes and every Stamp version phase reads:
# the version, the build number and the badge, one per line.
def stamp_text(reading: Reading) -> str:
    return f"{reading.version}\n{reading.build}\n{reading.badge}\n"


def write_stamp(reading: Reading, path: Path) -> None:
    """Write the stamp file, leaving it untouched when it already says this."""
    text = stamp_text(reading)
    if path.exists() and path.read_text() == text:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


APPEX = "Contents/PlugIns/mdqlPreview.appex"
XPC = f"{APPEX}/Contents/XPCServices/com.mdql.app.open-url.xpc"
BADGE = f"{APPEX}/Contents/Resources/version.txt"
BUNDLES = (("mdql.app", ""), ("mdqlPreview.appex", APPEX), ("open-url.xpc", XPC))


def check_app(app: Path, reading: Reading) -> list[str]:
    """Each way `app` disagrees with `reading`; empty when it carries it throughout.

    macOS refuses to load an app extension whose CFBundleVersion differs from
    its containing app's, and nothing else in a build says so: the bundle signs,
    installs and registers, and Quick Look shows nothing.
    """
    problems = []
    for name, sub in BUNDLES:
        plist = app / sub / "Contents/Info.plist" if sub else app / "Contents/Info.plist"
        try:
            with open(plist, "rb") as f:
                info = plistlib.load(f)
        except (OSError, plistlib.InvalidFileException) as exc:
            problems.append(f"{name}: cannot read {plist}: {exc}")
            continue
        for key, want in (
            ("CFBundleShortVersionString", str(reading.version)),
            ("CFBundleVersion", str(reading.build)),
        ):
            got = info.get(key)
            if got != want:
                problems.append(f"{name}: {key} is {got!r}, not {want!r}")
    try:
        badge = (app / BADGE).read_text().strip()
    except OSError as exc:
        problems.append(f"version.txt: cannot read {app / BADGE}: {exc}")
    else:
        # The dirty mark is the tree's state when the build read it, which may
        # since have changed; the version and the commit may not.
        wanted = re.compile(rf"{re.escape(str(reading.version))} \({re.escape(reading.short)}(-dirty)?\)")
        if not wanted.fullmatch(badge):
            problems.append(f"version.txt reads {badge!r}, not {reading.badge!r}")
    return problems


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="version", description="Print mdql's version, computed from git history."
    )
    what = parser.add_mutually_exclusive_group()
    what.add_argument("--build", action="store_true", help="print the build number instead")
    what.add_argument("--explain", action="store_true", help="show how history reads")
    what.add_argument("--write", metavar="FILE", type=Path, help="write the build phases' stamp file")
    what.add_argument("--check", metavar="APP", type=Path, help="check a built mdql.app carries it")
    args = parser.parse_args(argv)

    try:
        reading = read(repo_root())
        if args.check:
            problems = check_app(args.check, reading)
            if problems:
                raise VersionError(
                    f"{args.check} does not carry {reading.version} (build "
                    f"{reading.build}) throughout:\n  " + "\n  ".join(problems)
                )
            print(f"version: {args.check} carries {reading.version} (build {reading.build}), badge {reading.badge!r}")
        elif args.write:
            write_stamp(reading, args.write)
        elif args.explain:
            sys.stdout.write(explain(reading))
        elif args.build:
            print(reading.build)
        else:
            print(reading.version)
    except VersionError as exc:
        print(f"version: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
