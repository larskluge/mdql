#!/usr/bin/env python3
"""The bump tool's own suite. `python3 -m unittest discover -s scripts -p 'test_*.py'`."""

import contextlib
import datetime
import io
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

from version import (
    CHANGELOG_HEADER,
    PBXPROJ,
    Commit,
    Version,
    bump_level,
    heading_for,
    level_for,
    main,
    parse_log,
    prepend_release,
    read_version,
    release_note,
    render_release,
    summary,
    version_spots,
    write_version,
)


def commit(subject, body=""):
    return Commit(sha="0" * 40, subject=subject, body=body)


class VersionTests(unittest.TestCase):
    def test_parses_and_renders(self):
        self.assertEqual(str(Version.parse("0.1.0")), "0.1.0")
        self.assertEqual(Version.parse("12.3.45"), Version(12, 3, 45))

    def test_refuses_a_two_part_version(self):
        # Every Info.plist here shipped "1.0" hard-coded before the version
        # became a build setting. A string of that shape must never be read as
        # a version, or a bump would write 1.1 and call it a minor release.
        with self.assertRaises(ValueError):
            Version.parse("1.0")

    def test_a_patch_bump_moves_the_last_part_only(self):
        # The level most of this repository's releases land on, and the one the
        # other bumps never exercise: major and minor both zero the patch, so an
        # arithmetic slip in this branch alone would go unseen.
        self.assertEqual(Version(0, 1, 4).bumped("patch"), Version(0, 1, 5))

    def test_a_minor_bump_zeroes_the_patch(self):
        self.assertEqual(Version(0, 1, 4).bumped("minor"), Version(0, 2, 0))

    def test_a_major_bump_zeroes_both(self):
        self.assertEqual(Version(0, 4, 2).bumped("major"), Version(1, 0, 0))

    def test_none_leaves_it_alone(self):
        self.assertEqual(Version(0, 1, 4).bumped("none"), Version(0, 1, 4))

    def test_an_unknown_level_is_an_error(self):
        with self.assertRaises(ValueError):
            Version(0, 1, 0).bumped("huge")


class LevelTests(unittest.TestCase):
    def test_feat_is_minor(self):
        self.assertEqual(level_for("feat: .md link navigation + hover status bar"), "minor")

    def test_a_scope_does_not_change_the_type(self):
        self.assertEqual(level_for("feat(preview): render task lists"), "minor")

    def test_fix_and_perf_are_patch(self):
        self.assertEqual(level_for("fix: HTML-escape code blocks and link hrefs"), "patch")
        self.assertEqual(level_for("perf: the preview no longer re-parses on scroll"), "patch")

    def test_quiet_types_do_not_bump(self):
        for subject in (
            "docs: move specs to docs/specs/",
            "ci: run the suite on every push",
            "chore: add build/ to .gitignore",
            "refactor: one renderer, not two",
            "test: strengthen HTML-escape coverage",
            "build: bump the toolchain",
            "style: reformat the CSS",
        ):
            self.assertEqual(level_for(subject), "none", subject)

    def test_a_bang_is_major(self):
        self.assertEqual(level_for("feat!: the extension's bundle id changed"), "major")
        self.assertEqual(level_for("fix(preview)!: drop the legacy WebView"), "major")

    def test_a_breaking_change_footer_is_major(self):
        self.assertEqual(
            level_for("feat: a new bridge", body="BREAKING CHANGE: the old one is gone"),
            "major",
        )

    def test_an_unlabelled_subject_is_a_patch_rather_than_nothing(self):
        # 48 of this repository's 69 non-merge commits look like this. Silence
        # would drop most of every release on the floor.
        self.assertEqual(
            level_for("Give the titlebar file name Finder's path menu; fix HTML escaping"),
            "patch",
        )

    def test_an_unknown_type_is_a_patch_rather_than_nothing(self):
        self.assertEqual(level_for("quicklook: previews open faster"), "patch")


class HeadingTests(unittest.TestCase):
    def test_headings_follow_the_type_not_the_level(self):
        # `fix` and an unlabelled commit are both patch, and they do not share a
        # heading — which is why heading_for exists separately from level_for.
        self.assertEqual(heading_for("feat: a thing"), "Added")
        self.assertEqual(heading_for("fix: a thing"), "Fixed")
        self.assertEqual(heading_for("perf: a thing"), "Fixed")
        self.assertEqual(heading_for("feat!: a thing"), "Changed")
        self.assertEqual(heading_for("quicklook: a thing"), "Other")
        self.assertEqual(heading_for("Polish macOS app shell"), "Other")

    def test_a_quiet_type_has_no_heading_at_all(self):
        self.assertIsNone(heading_for("docs: a thing"))

    def test_summary_strips_the_prefix_and_the_pr_number(self):
        self.assertEqual(
            summary("fix: HTML-escape code blocks, inline code, headings (#11)"),
            "HTML-escape code blocks, inline code, headings",
        )

    def test_summary_leaves_an_unprefixed_subject_whole(self):
        self.assertEqual(
            summary("Polish macOS app shell"),
            "Polish macOS app shell",
        )


class BumpLevelTests(unittest.TestCase):
    def test_the_bump_is_the_highest_level_in_the_batch(self):
        self.assertEqual(
            bump_level([commit("fix: one"), commit("feat: two"), commit("docs: three")]),
            "minor",
        )

    def test_a_breaking_commit_beats_a_feat_in_the_same_batch(self):
        # The only comparison that reads LEVELS' order past "minor": with a
        # `feat` and a `feat!` in one release, minor and major are both on the
        # table and the higher one has to win, or a breaking change ships as a
        # minor release.
        self.assertEqual(
            bump_level(
                [commit("feat: a new bridge"), commit("feat!: the bundle id changed")]
            ),
            "major",
        )
        self.assertEqual(
            bump_level(
                [
                    commit("feat: a new bridge"),
                    commit("fix: a thing", body="BREAKING CHANGE: the old one is gone"),
                ]
            ),
            "major",
        )

    def test_a_fixes_only_batch_is_a_patch(self):
        self.assertEqual(bump_level([commit("fix: one"), commit("fix: two")]), "patch")

    def test_an_unprefixed_batch_is_a_patch(self):
        self.assertEqual(
            bump_level([commit("Use standard document window chrome"), commit("ci: two")]),
            "patch",
        )

    def test_a_quiet_only_batch_is_no_release(self):
        self.assertEqual(bump_level([commit("docs: one"), commit("ci: two")]), "none")

    def test_no_commits_at_all_is_no_release(self):
        self.assertEqual(bump_level([]), "none")


class ChangelogTests(unittest.TestCase):
    def test_a_release_groups_by_heading_in_a_fixed_order(self):
        got = render_release(
            Version(0, 2, 0),
            "2026-08-20",
            [
                commit("fix: HTML-escape code blocks and link hrefs"),
                commit("feat: .md link navigation + hover status bar (#10)"),
                commit("docs: not in the changelog"),
                commit("Polish macOS app shell"),
            ],
        )
        self.assertEqual(
            got,
            "## 0.2.0 — 2026-08-20\n"
            "\n"
            "### Added\n"
            "- .md link navigation + hover status bar\n"
            "\n"
            "### Fixed\n"
            "- HTML-escape code blocks and link hrefs\n"
            "\n"
            "### Other\n"
            "- Polish macOS app shell\n",
        )

    def test_a_breaking_change_gets_a_changed_group_with_its_bullet(self):
        # "Changed" is the only heading no other test renders, and it carries
        # the one kind of entry a reader cannot afford to miss: drop it from
        # HEADING_ORDER and every breaking change leaves the changelog silently.
        got = render_release(
            Version(1, 0, 0),
            "2026-08-20",
            [
                commit("feat!: the extension's bundle id changed"),
                commit("fix: HTML-escape code blocks"),
            ],
        )
        self.assertEqual(
            got,
            "## 1.0.0 — 2026-08-20\n"
            "\n"
            "### Changed\n"
            "- the extension's bundle id changed\n"
            "\n"
            "### Fixed\n"
            "- HTML-escape code blocks\n",
        )

    def test_a_quiet_commit_reaches_no_heading(self):
        got = render_release(Version(0, 1, 1), "2026-08-20", [commit("ci: a thing")])
        self.assertNotIn("###", got)
        self.assertIn("## 0.1.1 — 2026-08-20", got)

    def test_a_note_replaces_the_body(self):
        got = render_release(
            Version(0, 1, 1),
            "2026-08-20",
            [],
            note="No changes; a patch release cut deliberately.",
        )
        self.assertEqual(
            got,
            "## 0.1.1 — 2026-08-20\n\nNo changes; a patch release cut deliberately.\n",
        )

    def test_new_releases_go_under_the_header_newest_first(self):
        existing = CHANGELOG_HEADER + "\n## 0.1.0 — 2026-08-01\n\n### Added\n- the first one\n"
        got = prepend_release(existing, "## 0.2.0 — 2026-08-20\n\n### Added\n- the second one\n")
        self.assertTrue(got.startswith(CHANGELOG_HEADER))
        self.assertLess(got.index("0.2.0"), got.index("0.1.0"))
        self.assertIn("the first one", got)

    def test_a_preamble_under_the_header_stays_above_the_releases(self):
        # CHANGELOG.md opens with a paragraph saying what writes it. Inserting
        # directly after the "# Changelog" line would push that paragraph below
        # the newest release, where it reads as part of it.
        existing = (
            CHANGELOG_HEADER
            + "\nWritten by `scripts/version.py`, and never by hand.\n"
            + "\n## 0.1.0 — 2026-08-01\n\n### Added\n- the first one\n"
        )
        got = prepend_release(existing, "## 0.2.0 — 2026-08-20\n\n### Added\n- the second one\n")
        self.assertLess(got.index("never by hand"), got.index("0.2.0"))
        self.assertLess(got.index("0.2.0"), got.index("0.1.0"))

    def test_a_preamble_survives_when_there_are_no_releases_yet(self):
        existing = CHANGELOG_HEADER + "\nWritten by `scripts/version.py`.\n"
        got = prepend_release(existing, "## 0.1.0 — 2026-08-20\n\n### Added\n- one\n")
        self.assertLess(got.index("Written by"), got.index("0.1.0"))

    def test_it_seeds_a_header_when_there_is_no_file_yet(self):
        got = prepend_release("", "## 0.1.0 — 2026-08-20\n\n### Added\n- one\n")
        self.assertTrue(got.startswith(CHANGELOG_HEADER))
        self.assertIn("0.1.0", got)


class ReleaseNoteTests(unittest.TestCase):
    def test_a_release_with_real_entries_needs_no_note(self):
        entries = [commit("feat: a thing")]
        self.assertIsNone(release_note(entries))
        self.assertIsNone(release_note(entries, forced="patch"))

    def test_a_forced_bump_with_nothing_to_list_says_it_was_deliberate(self):
        self.assertEqual(
            release_note([], forced="patch"),
            "No changes; a patch release cut deliberately.",
        )

    def test_commits_that_classify_as_nothing_still_count_as_no_entries(self):
        # `chore` and `ci` carry no heading, so a batch of them is a release
        # with nothing to list — which is exactly the forced-bump case.
        entries = [commit("chore: tidy"), commit("ci: a thing")]
        self.assertIn("deliberately", release_note(entries, forced="patch"))

    def test_an_unforced_batch_never_gets_a_note(self):
        # Unforced, the version only moves when some commit carries a heading,
        # so there is nothing to explain.
        self.assertIsNone(release_note([commit("chore: tidy")]))


# A trimmed but faithful pbxproj: real tabs, unquoted values, both project-level
# configurations, one target-level configuration that carries no version of its
# own, and the version-stamp build phase whose shell script mentions
# MARKETING_VERSION in passing. Raw string, so the `\"` and `\n` inside that
# script stay the literal backslashes the real file holds.
PBXPROJ_FIXTURE = r"""// !$*UTF8*$!
{
	archiveVersion = 1;
	objects = {

/* Begin PBXShellScriptBuildPhase section */
		D10000010000000000000001 /* Stamp version.txt */ = {
			isa = PBXShellScriptBuildPhase;
			shellScript = "echo \"${MARKETING_VERSION}\" > \"$DERIVED_FILE_DIR/version.txt\"\n";
		};
/* End PBXShellScriptBuildPhase section */

/* Begin XCBuildConfiguration section */
		C10000010000000000000001 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CURRENT_PROJECT_VERSION = 71;
				MACOSX_DEPLOYMENT_TARGET = 26.0;
				MARKETING_VERSION = 0.1.0;
				SDKROOT = macosx;
			};
			name = Debug;
		};
		C10000020000000000000002 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CURRENT_PROJECT_VERSION = 71;
				MACOSX_DEPLOYMENT_TARGET = 26.0;
				MARKETING_VERSION = 0.1.0;
				SDKROOT = macosx;
			};
			name = Release;
		};
		C20000010000000000000001 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = mdql/mdql.entitlements;
				INFOPLIST_FILE = mdql/Info.plist;
				PRODUCT_BUNDLE_IDENTIFIER = com.mdql.app;
			};
			name = Debug;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		B30000040000000000000004 /* Build configuration list for PBXProject "mdql" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				C10000010000000000000001 /* Debug */,
				C10000020000000000000002 /* Release */,
			);
		};
/* End XCConfigurationList section */
	};
}
"""

_MARKETING_LINE = "\t\t\t\tMARKETING_VERSION = 0.1.0;\n"
_TARGET_SETTING = "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.mdql.app;\n"


class PbxprojTests(unittest.TestCase):
    def test_it_reads_the_version(self):
        self.assertEqual(read_version(PBXPROJ_FIXTURE), Version(0, 1, 0))

    def test_the_shell_script_mention_is_not_a_third_occurrence(self):
        # `shellScript = "…${MARKETING_VERSION}…"` sits on one long line in the
        # real file. Matched loosely it reads as a third declaration and every
        # bump refuses to run.
        self.assertIn("${MARKETING_VERSION}", PBXPROJ_FIXTURE)
        self.assertEqual(len(version_spots(PBXPROJ_FIXTURE)["MARKETING_VERSION"][0]), 2)

    def test_a_write_round_trips_through_the_reader(self):
        got = write_version(PBXPROJ_FIXTURE, Version(0, 2, 0), 72)
        self.assertEqual(read_version(got), Version(0, 2, 0))
        self.assertEqual(version_spots(got)["CURRENT_PROJECT_VERSION"][1], "72")

    def test_it_rewrites_both_occurrences_of_both_settings(self):
        got = write_version(PBXPROJ_FIXTURE, Version(0, 2, 0), 72)
        self.assertEqual(got.count("\t\t\t\tMARKETING_VERSION = 0.2.0;\n"), 2)
        self.assertEqual(got.count("\t\t\t\tCURRENT_PROJECT_VERSION = 72;\n"), 2)
        self.assertNotIn("0.1.0", got)
        self.assertNotIn("CURRENT_PROJECT_VERSION = 71", got)

    def test_a_write_leaves_every_other_line_byte_identical(self):
        got = write_version(PBXPROJ_FIXTURE, Version(0, 2, 0), 72)
        before = PBXPROJ_FIXTURE.splitlines(keepends=True)
        after = got.splitlines(keepends=True)
        self.assertEqual(len(before), len(after))
        changed = [(a, b) for a, b in zip(before, after) if a != b]
        self.assertEqual(len(changed), 4, changed)
        for a, b in changed:
            # Only the value moved: same indentation, same key, same semicolon.
            self.assertEqual(a[: a.index("=")], b[: b.index("=")])
            self.assertTrue(b.endswith(";\n"), b)
        self.assertIn("${MARKETING_VERSION}", got)
        self.assertIn(_TARGET_SETTING, got)

    def test_a_file_with_crlf_endings_is_written_not_quietly_skipped(self):
        # Xcode writes LF, but a checkout through a tool that normalises endings
        # does not have to. A carriage return sits exactly where the pattern's
        # `;$` wants the end of the line: matched against that, every setting
        # missed, the text came back byte-identical, and the bump announced a
        # version it had not written.
        crlf = PBXPROJ_FIXTURE.replace("\n", "\r\n")
        got = write_version(crlf, Version(0, 2, 0), 72)
        self.assertEqual(got.count("\tMARKETING_VERSION = 0.2.0;\r\n"), 2)
        self.assertEqual(got.count("\tCURRENT_PROJECT_VERSION = 72;\r\n"), 2)
        self.assertNotIn("0.1.0", got)
        self.assertEqual(got.count("\n"), got.count("\r\n"))  # no line lost its CR
        self.assertEqual(read_version(got), Version(0, 2, 0))

    def test_a_setting_that_appears_once_is_an_error(self):
        without = PBXPROJ_FIXTURE.replace(_MARKETING_LINE, "", 1)
        with self.assertRaises(LookupError) as raised:
            version_spots(without)
        message = str(raised.exception)
        self.assertIn("MARKETING_VERSION", message)
        self.assertIn("once", message)
        surviving = without.splitlines().index(_MARKETING_LINE.rstrip("\n")) + 1
        self.assertIn(f"line {surviving}", message)

    def test_a_setting_that_appears_nowhere_is_an_error(self):
        without = PBXPROJ_FIXTURE.replace(_MARKETING_LINE, "")
        with self.assertRaises(LookupError) as raised:
            version_spots(without)
        self.assertIn("has no MARKETING_VERSION", str(raised.exception))

    def test_a_target_level_override_is_an_error_that_says_so(self):
        # The failure worth naming: a third declaration inside one target's own
        # configuration shadows the project's, so bumping the project value
        # leaves that target on the old number and nothing goes red.
        shadowed = PBXPROJ_FIXTURE.replace(
            _TARGET_SETTING, _TARGET_SETTING + _MARKETING_LINE, 1
        )
        with self.assertRaises(LookupError) as raised:
            version_spots(shadowed)
        message = str(raised.exception)
        self.assertIn("MARKETING_VERSION 3 times", message)
        self.assertIn("target-level", message)

    def test_two_configurations_that_disagree_are_an_error(self):
        # Debug says one thing and Release another: there is no single current
        # version, so there is nothing to bump *from*.
        drifted = PBXPROJ_FIXTURE.replace(
            "MARKETING_VERSION = 0.1.0;", "MARKETING_VERSION = 0.1.1;", 1
        )
        with self.assertRaises(LookupError) as raised:
            version_spots(drifted)
        message = str(raised.exception)
        self.assertIn("disagrees about MARKETING_VERSION", message)
        self.assertIn("0.1.1", message)
        self.assertIn("0.1.0", message)

    def test_a_two_part_version_in_the_project_is_refused(self):
        # What the Info.plists held before the version became a build setting,
        # and the shape a hand-edit reaches for.
        placeholder = PBXPROJ_FIXTURE.replace(
            "MARKETING_VERSION = 0.1.0;", "MARKETING_VERSION = 1.0;"
        )
        with self.assertRaises(ValueError) as raised:
            read_version(placeholder)
        message = str(raised.exception)
        self.assertIn("1.0", message)
        self.assertIn("MARKETING_VERSION", message)
        self.assertIn(PBXPROJ, message)

    def test_a_build_number_that_is_not_a_number_is_refused_by_name(self):
        broken = PBXPROJ_FIXTURE.replace(
            "CURRENT_PROJECT_VERSION = 71;", "CURRENT_PROJECT_VERSION = 71a;"
        )
        with self.assertRaises(ValueError) as raised:
            read_version(broken)
        self.assertIn("CURRENT_PROJECT_VERSION", str(raised.exception))

    def test_the_repositorys_own_pbxproj_is_sound(self):
        # The guard nothing else provides: a hand-edit that adds a target-level
        # override, drops a setting, or lets the two configurations drift fails
        # here rather than at the next release.
        root = pathlib.Path(__file__).resolve().parent.parent
        text = (root / PBXPROJ).read_text()
        self.assertGreaterEqual(read_version(text), Version(0, 1, 0))
        self.assertGreater(int(version_spots(text)["CURRENT_PROJECT_VERSION"][1]), 0)


class LogParsingTests(unittest.TestCase):
    def test_it_reads_sha_subject_and_body(self):
        raw = (
            "\x1eabc123\x00feat: a thing\x00the body\nsecond line\n"
            "\x1edef456\x00fix: another\x00\n"
        )
        got = parse_log(raw)
        self.assertEqual(len(got), 2)
        self.assertEqual(got[0].sha, "abc123")
        self.assertEqual(got[0].subject, "feat: a thing")
        self.assertEqual(got[0].body, "the body\nsecond line")
        self.assertEqual(got[1].subject, "fix: another")
        self.assertEqual(got[1].body, "")

    def test_a_subject_holding_a_colon_survives_intact(self):
        got = parse_log(
            "\x1eabc\x00Give the titlebar file name Finder's path menu; fix HTML escaping\x00\n"
        )
        self.assertEqual(
            got[0].subject,
            "Give the titlebar file name Finder's path menu; fix HTML escaping",
        )

    def test_empty_output_is_no_commits(self):
        self.assertEqual(parse_log(""), [])


# ---- the run itself --------------------------------------------------------


@unittest.skipUnless(shutil.which("git"), "git is not on PATH")
class ReleaseRunTests(unittest.TestCase):
    """`main()` against a throwaway repository, read back through git.

    Everything past the pure functions — which paths the commit holds, what kind
    of object the tag is, what --dry-run refrains from doing, which failures
    stop the run before it writes — exists only as repository state. So these
    build a repository, run the tool in it, and ask git what it left behind.
    """

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = pathlib.Path(tmp.name).resolve()
        self.root = base / "repo"
        # Outside the worktree, so a hook file never shows up as untracked work
        # in the assertions about what the release commit left staged.
        self.hooks = base / "hooks"
        self.root.mkdir()
        self.hooks.mkdir()

        self.git("-c", "init.defaultBranch=main", "init", "--quiet")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        # This machine's own git config must not reach in: a global signing key
        # or hooks path would fail the commit for reasons that are not the code.
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        self.git("config", "core.hooksPath", str(self.hooks))
        # A machine with `core.autocrlf = true` would rewrite the endings under
        # the CRLF test below, and it would then pass or fail for git's reasons
        # rather than the tool's.
        self.git("config", "core.autocrlf", "false")

        self.pbxproj = self.root / PBXPROJ
        self.pbxproj.parent.mkdir(parents=True)
        self.pbxproj.write_text(PBXPROJ_FIXTURE)
        self.changelog = self.root / "CHANGELOG.md"
        self.changelog.write_text(CHANGELOG_HEADER + "\nWritten by `make version`.\n")
        (self.root / "README.md").write_text("mdql\n")
        self.git("add", "-A")
        self.git("commit", "-m", "Import the tree")

    def git(self, *args) -> str:
        done = subprocess.run(
            ["git", *args], cwd=self.root, check=True, capture_output=True, text=True
        )
        return done.stdout

    def commit(self, subject: str) -> None:
        self.git("commit", "--allow-empty", "-m", subject)

    def run_main(self, *argv):
        """`main()` with the repository as its working directory, output captured.

        The tool finds its root with `git rev-parse` from the process's own
        directory, so the chdir is how a test points it at this repository —
        and the `finally` is why one failing test does not move every later one.
        It also keeps what was printed, which is otherwise lost on the runs that
        end in SystemExit — exactly the runs whose reporting is under test.
        """
        out, err = io.StringIO(), io.StringIO()
        here = os.getcwd()
        os.chdir(self.root)
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = main(list(argv))
        finally:
            os.chdir(here)
            self.printed, self.warned = out.getvalue(), err.getvalue()
        return code, self.printed, self.warned

    def head(self) -> str:
        return self.git("rev-parse", "HEAD").strip()

    def tags(self) -> list:
        return self.git("tag", "--list").split()

    def stamp_version(self, version: Version, subject: str) -> None:
        """Move the project to `version` and commit it, as a release would.

        A test that needs a baseline other than the fixture's 0.1.0 needs the
        pbxproj to agree with the tag it puts there: `_require_tag_not_ahead`
        refuses a tag that stands ahead of the project, and rightly.
        """
        self.pbxproj.write_text(write_version(self.pbxproj.read_text(), version, 71))
        self.git("commit", "-m", subject, "--", PBXPROJ)

    def test_a_dry_run_writes_nothing_and_leaves_no_commit_or_tag(self):
        self.commit("feat: .md link navigation")
        pbxproj, changelog, head = (
            self.pbxproj.read_bytes(),
            self.changelog.read_bytes(),
            self.head(),
        )
        code, out, _ = self.run_main("--dry-run")
        self.assertEqual(code, 0)
        self.assertIn("0.1.0 → 0.2.0", out)
        self.assertIn("nothing written", out)
        self.assertEqual(self.pbxproj.read_bytes(), pbxproj)
        self.assertEqual(self.changelog.read_bytes(), changelog)
        self.assertEqual(self.head(), head)
        self.assertEqual(self.tags(), [])

    def test_a_batch_that_says_it_is_not_user_visible_releases_nothing(self):
        # From the tag the tree was released at, so the batch is only these two.
        self.git("tag", "-a", "v0.1.0", "-m", "0.1.0")
        self.commit("docs: move specs to docs/specs/")
        self.commit("ci: run the suite on every push")
        head = self.head()
        code, out, _ = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn("nothing to release (0.1.0 stands)", out)
        self.assertEqual(read_version(self.pbxproj.read_text()), Version(0, 1, 0))
        self.assertEqual(self.head(), head)
        self.assertEqual(self.tags(), ["v0.1.0"])  # no new one

    def test_a_release_writes_the_project_the_changelog_the_commit_and_the_tag(self):
        self.commit("feat: .md link navigation")
        self.commit("fix: HTML-escape code blocks")
        self.commit("docs: not in the changelog")
        before = int(self.git("rev-list", "--count", "HEAD").strip())

        code, out, _ = self.run_main()
        self.assertEqual(code, 0)

        text = self.pbxproj.read_text()
        self.assertEqual(read_version(text), Version(0, 2, 0))
        self.assertEqual(text.count("MARKETING_VERSION = 0.2.0;"), 2)

        changelog = self.changelog.read_text()
        self.assertIn("## 0.2.0 — ", changelog)
        self.assertIn("- .md link navigation", changelog)
        self.assertIn("- HTML-escape code blocks", changelog)
        self.assertNotIn("not in the changelog", changelog)
        self.assertLess(changelog.index("Written by"), changelog.index("## 0.2.0"))

        subject = self.git("log", "-1", "--format=%s").strip()
        self.assertEqual(subject, "chore(release): 0.2.0")
        self.assertEqual(int(self.git("rev-list", "--count", "HEAD").strip()), before + 1)
        self.assertEqual(self.tags(), ["v0.2.0"])
        self.assertIn("v0.2.0", out)

    def test_the_section_is_dated_today(self):
        # The heading is what `changelog-section.py` matches on and what the
        # release page shows. A date off by a day is wrong on both and there is
        # nothing downstream that could notice.
        self.commit("feat: .md link navigation")
        self.run_main()
        today = datetime.date.today().isoformat()
        self.assertIn(f"## 0.2.0 — {today}\n", self.changelog.read_text())

    def test_a_forced_level_is_released_instead_of_the_one_the_commits_ask_for(self):
        # `--level` earns its place here: `make version VERSION_ARGS='--level
        # major'` is the only route from 0.x to 1.0.0, because no subject short
        # of a `!` or a BREAKING CHANGE footer ever asks for a major, and this
        # tree's do not.
        self.commit("fix: HTML-escape code blocks")
        code, out, _ = self.run_main("--level", "major")
        self.assertEqual(code, 0)
        self.assertIn("0.1.0 → 1.0.0  (major)", out)
        self.assertEqual(read_version(self.pbxproj.read_text()), Version(1, 0, 0))
        self.assertEqual(
            self.git("log", "-1", "--format=%s").strip(), "chore(release): 1.0.0"
        )
        self.assertEqual(self.tags(), ["v1.0.0"])
        self.assertIn("## 1.0.0 — ", self.changelog.read_text())
        self.assertIn("- HTML-escape code blocks", self.changelog.read_text())

    def test_a_forced_release_with_nothing_to_list_says_it_was_deliberate(self):
        # `release_note`'s one branch, and `--level` is the only way `main()`
        # reaches it: a throwaway build cut to take the signing and install path
        # end to end. Unsaid, its section is a heading with nothing under it and
        # no hint of why the number moved.
        self.git("tag", "-a", "v0.1.0", "-m", "0.1.0")
        self.commit("chore: add build/ to .gitignore")
        code, _, _ = self.run_main("--level", "patch")
        self.assertEqual(code, 0)
        changelog = self.changelog.read_text()
        self.assertIn("## 0.1.1 — ", changelog)
        self.assertIn("No changes; a patch release cut deliberately.", changelog)
        self.assertNotIn("###", changelog)
        self.assertEqual(self.tags(), ["v0.1.0", "v0.1.1"])

    def test_the_build_number_written_is_the_commit_count(self):
        self.commit("feat: .md link navigation")
        counted = int(self.git("rev-list", "--count", "HEAD").strip())
        # Not the fixture's own 71, so a write that changed nothing cannot pass.
        self.assertNotEqual(counted, 71)
        self.run_main()
        spots = version_spots(self.pbxproj.read_text())
        self.assertEqual(spots["CURRENT_PROJECT_VERSION"][1], str(counted))
        # Taken before the release commit, which is therefore not in it.
        after = int(self.git("rev-list", "--count", "HEAD").strip())
        self.assertEqual(after, counted + 1)

    def test_a_merge_is_no_changelog_entry_but_is_still_counted_in_the_build(self):
        # mdql's own history has merges in it — 71 commits, 69 without them —
        # and the two readings of that history pull opposite ways, which is why
        # one test holds both.
        self.git("checkout", "--quiet", "-b", "side")
        self.commit("fix: done on the side branch")
        self.git("checkout", "--quiet", "main")
        self.commit("feat: done on main")
        self.git("merge", "--no-ff", "-m", "Merge pull request #14 from side", "side")

        counted = int(self.git("rev-list", "--count", "HEAD").strip())
        without = int(self.git("rev-list", "--count", "--no-merges", "HEAD").strip())
        self.assertNotEqual(counted, without, "no merge commit was made, so this proves nothing")

        self.run_main()

        changelog = self.changelog.read_text()
        self.assertIn("- done on the side branch", changelog)
        self.assertIn("- done on main", changelog)
        # A merge subject carries no prefix, so read as a commit it becomes a
        # patch under **Other** — an entry saying nothing, and enough on its own
        # to lift a batch of pure `docs` out of "nothing to release".
        self.assertNotIn("Merge pull request", changelog)
        # The other reading: this is CFBundleVersion, and dropping the merges
        # from the count would write 69 where 71 already shipped — a number that
        # went *down*, which macOS treats as a downgrade.
        self.assertEqual(
            version_spots(self.pbxproj.read_text())["CURRENT_PROJECT_VERSION"][1],
            str(counted),
        )

    def test_the_release_commit_holds_only_the_paths_the_bump_wrote(self):
        # A shared checkout with another session's work already staged. It must
        # be exactly as staged afterwards, and nowhere in the release commit:
        # a `git commit` without a pathspec commits the whole index, and the tag
        # then points at somebody else's half-finished work.
        self.commit("feat: .md link navigation")
        (self.root / "OTHER.swift").write_text("struct Other {}\n")
        self.git("add", "OTHER.swift")
        (self.root / "README.md").write_text("mdql, edited in another session\n")
        self.git("add", "README.md")

        self.run_main()

        self.assertEqual(
            sorted(self.git("show", "--name-only", "--format=", "HEAD").split()),
            sorted(["CHANGELOG.md", PBXPROJ]),
        )
        self.assertEqual(
            self.git("status", "--porcelain").strip().splitlines(),
            ["A  OTHER.swift", "M  README.md"],
        )

    def test_a_crlf_project_file_keeps_its_endings_and_moves_four_lines(self):
        # `write_version` handles CRLF, but `main()` read the file with
        # `Path.read_text()`, whose universal-newline decoding turned every
        # \r\n into \n before that code was ever reached — and wrote LF back.
        # The release commit then rewrote all thousand lines: 1032 insertions,
        # 1032 deletions, a diff nobody can review, over four changed values.
        self.pbxproj.write_bytes(PBXPROJ_FIXTURE.replace("\n", "\r\n").encode())
        self.git("commit", "-m", "chore: check the project out with CRLF", "--", PBXPROJ)
        self.commit("feat: .md link navigation")

        self.run_main()

        raw = self.pbxproj.read_bytes()
        self.assertNotIn(b"\n", raw.replace(b"\r\n", b""), "a line lost its CR")
        self.assertEqual(read_version(self.pbxproj.read_text()), Version(0, 2, 0))
        stat = self.git("show", "--numstat", "--format=", "HEAD", "--", PBXPROJ).split()
        self.assertEqual(
            stat[:2],
            ["4", "4"],
            f"the release rewrote more than the four version values: {stat}",
        )

    def test_the_tag_is_annotated_so_follow_tags_will_carry_it(self):
        # `git push --follow-tags` pushes annotated tags and silently skips
        # lightweight ones, so this one word decides whether a release ever
        # reaches origin.
        self.commit("feat: .md link navigation")
        self.run_main()
        self.assertEqual(self.git("cat-file", "-t", "v0.2.0").strip(), "tag")
        self.assertIn("0.2.0", self.git("tag", "-n1", "--list", "v0.2.0"))

    def test_only_the_commits_after_the_last_tag_are_read(self):
        self.commit("feat: before the tag")
        self.git("tag", "-a", "v0.1.0", "-m", "0.1.0")
        self.commit("fix: after the tag")
        code, out, _ = self.run_main("--dry-run")
        self.assertEqual(code, 0)
        self.assertIn("after the tag", out)
        self.assertNotIn("before the tag", out)
        self.assertIn("0.1.0 → 0.1.1", out)

    def test_the_newest_tag_is_the_newest_version_not_the_last_string(self):
        # v0.1.9 sorts above v0.1.10 as a string. Taken as the baseline it is a
        # release behind, so everything already shipped in v0.1.10 is listed a
        # second time under the next number — which is where a repository first
        # reaches a two-digit part, and never before.
        self.git("tag", "-a", "v0.1.9", "-m", "0.1.9")
        self.commit("fix: already shipped in 0.1.10")
        self.stamp_version(Version(0, 1, 10), "chore(release): 0.1.10")
        self.git("tag", "-a", "v0.1.10", "-m", "0.1.10")
        self.commit("fix: only in the next release")

        code, out, _ = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn("0.1.10 → 0.1.11", out)
        changelog = self.changelog.read_text()
        self.assertIn("- only in the next release", changelog)
        self.assertNotIn("already shipped in 0.1.10", changelog)
        self.assertIn("v0.1.11", self.tags())

    def test_a_dirty_project_file_is_refused_without_writing_anything(self):
        self.commit("feat: .md link navigation")
        self.pbxproj.write_text(self.pbxproj.read_text() + "// a half-finished edit\n")
        pbxproj, changelog, head = (
            self.pbxproj.read_bytes(),
            self.changelog.read_bytes(),
            self.head(),
        )
        with self.assertRaises(SystemExit) as raised:
            self.run_main()
        self.assertIn(PBXPROJ, str(raised.exception))
        self.assertEqual(self.pbxproj.read_bytes(), pbxproj)
        self.assertEqual(self.changelog.read_bytes(), changelog)
        self.assertEqual(self.head(), head)
        self.assertEqual(self.tags(), [])

    def test_an_untracked_file_the_bump_writes_is_refused_and_called_untracked(self):
        # `git status --porcelain` answers `?? CHANGELOG.md` for a file that was
        # never committed. The refusal is right — `git add` would sweep the
        # whole file into the release commit — but under the words "already
        # modified" the reader goes looking for an edit nobody made.
        self.commit("feat: .md link navigation")
        self.git("rm", "--cached", "--quiet", "--", "CHANGELOG.md")
        self.git("commit", "-m", "chore: stop tracking the changelog")
        head = self.head()
        with self.assertRaises(SystemExit) as raised:
            self.run_main()
        message = str(raised.exception)
        self.assertIn("?? CHANGELOG.md", message)
        self.assertIn("untracked", message)
        self.assertEqual(self.head(), head)
        self.assertEqual(self.tags(), [])

    def test_a_tag_ahead_of_the_project_is_refused_by_name(self):
        # The undo run without its `git tag -d`: the project is back at 0.1.0
        # while v0.2.0 still stands, so v0.2.0..HEAD is empty and every run from
        # here would report "nothing to release" and exit 0, for ever.
        self.commit("feat: .md link navigation")
        self.git("tag", "-a", "v0.2.0", "-m", "0.2.0")
        head = self.head()
        with self.assertRaises(SystemExit) as raised:
            self.run_main()
        message = str(raised.exception)
        self.assertIn("v0.2.0", message)
        self.assertIn("0.1.0", message)
        self.assertIn("git tag -d v0.2.0", message)
        self.assertEqual(self.head(), head)

    def test_a_tag_name_already_taken_is_refused_before_anything_is_written(self):
        # Reachable past the guard above only when the newest tag names no
        # version — a moving `vNightly`, here left behind on the tree the work
        # started from — so there is nothing to compare the project against and
        # the collision survives to the tag check.
        self.git("tag", "vNightly")
        self.commit("feat: .md link navigation")
        self.git("tag", "-a", "v0.2.0", "-m", "0.2.0")
        newest = self.git("tag", "--list", "v*", "--sort=-v:refname").split()[0]
        if newest != "vNightly":
            self.skipTest(f"this git sorts {newest} newest; the case needs vNightly there")
        pbxproj, head = self.pbxproj.read_bytes(), self.head()
        with self.assertRaises(SystemExit) as raised:
            self.run_main()
        self.assertIn("v0.2.0 already exists", str(raised.exception))
        # The tag it could not read is named rather than passed over in silence.
        self.assertIn("vNightly", self.warned)
        self.assertEqual(self.pbxproj.read_bytes(), pbxproj)
        self.assertEqual(self.head(), head)

    def test_a_failing_hook_is_reported_in_gits_own_words(self):
        # captured output with no handler is output nobody sees: the user got a
        # CalledProcessError traceback and never learned the hook had spoken.
        self.commit("feat: .md link navigation")
        hook = self.hooks / "pre-commit"
        hook.write_text("#!/bin/sh\necho 'pre-commit: the suite is red' >&2\nexit 3\n")
        hook.chmod(0o755)
        with self.assertRaises(SystemExit) as raised:
            self.run_main()
        message = str(raised.exception)
        self.assertIn("pre-commit: the suite is red", message)
        self.assertIn("git commit", message)
        self.assertRegex(message, r"failed \(exit \d+\)")
        # The commit failed, so nothing was tagged: the run stopped where it broke.
        self.assertEqual(self.tags(), [])


if __name__ == "__main__":
    unittest.main()
