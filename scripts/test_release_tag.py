#!/usr/bin/env python3
"""`release-tag.py`'s suite: the release path's CHANGELOG section, commit and tag."""

import contextlib
import datetime
import importlib.util
import io
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from version import Version, read

# The module has a hyphen in its name, which `import` cannot spell.
_spec = importlib.util.spec_from_file_location(
    "release_tag", pathlib.Path(__file__).parent / "release-tag.py"
)
release_tag = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(release_tag)

Commit = release_tag.Commit
heading_for = release_tag.heading_for
summary = release_tag.summary
render_release = release_tag.render_release
prepend_release = release_tag.prepend_release
previous_release = release_tag.previous_release


def commits(*subjects):
    """Commits oldest first, as the release path reads them."""
    return [Commit(sha=f"{i:040x}", subject=s) for i, s in enumerate(subjects)]


class HeadingTests(unittest.TestCase):
    def test_headings_follow_the_type(self):
        self.assertEqual(heading_for("feat: a thing"), "Added")
        self.assertEqual(heading_for("fix: a thing"), "Fixed")
        self.assertEqual(heading_for("perf: a thing"), "Fixed")
        self.assertEqual(heading_for("Polish the app shell"), "Other")
        self.assertEqual(heading_for("quicklook: a thing"), "Other")

    def test_a_bang_is_its_plain_type(self):
        self.assertEqual(heading_for("feat!: a thing"), "Added")

    def test_a_quiet_type_has_no_heading(self):
        for kind in ("chore", "docs", "ci", "test", "build", "refactor", "style"):
            self.assertIsNone(heading_for(f"{kind}: a thing"), kind)

    def test_summary_strips_the_prefix_and_the_pr_number(self):
        self.assertEqual(
            summary("fix(preview): HTML-escape code blocks (#11)"), "HTML-escape code blocks"
        )
        self.assertEqual(summary("Polish the app shell"), "Polish the app shell")


class RenderTests(unittest.TestCase):
    def test_a_release_groups_by_heading_in_a_fixed_order_newest_first(self):
        got = render_release(
            Version(0, 3, 0),
            "2026-11-22",
            commits(
                "Polish the app shell",
                "fix: one",
                "docs: not listed",
                "feat: hide the viewer with ⌘H (#20)",
                "fix: two",
            ),
        )
        self.assertEqual(
            got,
            "## 0.3.0 — 2026-11-22\n"
            "\n### Added\n- hide the viewer with ⌘H\n"
            "\n### Fixed\n- two\n- one\n"
            "\n### Other\n- Polish the app shell\n",
        )

    def test_a_release_with_nothing_to_list_carries_its_note(self):
        got = render_release(Version(1, 0, 0), "2026-11-22", commits("docs: a"), "Why it moved.")
        self.assertEqual(got, "## 1.0.0 — 2026-11-22\n\nWhy it moved.\n")

    def test_the_new_section_goes_above_the_releases_below_the_preamble(self):
        existing = "# Changelog\n\nWritten on release.\n\n## 0.1.0 — 2026-08-20\n\n- first\n"
        got = prepend_release(existing, "## 0.2.7 — 2026-11-22\n\n### Fixed\n- a\n")
        self.assertEqual(
            got,
            "# Changelog\n\nWritten on release.\n\n"
            "## 0.2.7 — 2026-11-22\n\n### Fixed\n- a\n\n"
            "## 0.1.0 — 2026-08-20\n\n- first\n",
        )

    def test_it_seeds_a_header_when_there_is_no_file_yet(self):
        self.assertEqual(prepend_release("", "## 0.1.0 — x\n"), "# Changelog\n\n## 0.1.0 — x\n")

    def test_the_previous_release_is_the_newest_section(self):
        text = "# Changelog\n\n## 0.2.7 — b\n\n- x\n\n## 0.1.0 — a\n"
        self.assertEqual(previous_release(text), Version(0, 2, 7))
        self.assertIsNone(previous_release("# Changelog\n\nNothing yet.\n"))


@unittest.skipUnless(shutil.which("git"), "git is not on PATH")
class CutTests(unittest.TestCase):
    """`main()` against a throwaway repository shaped like this one's history."""

    PREAMBLE = "# Changelog\n\nWritten on release by `make release-tag`.\n"

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = pathlib.Path(tmp.name).resolve()
        self.root = base / "repo"
        self.hooks = base / "hooks"
        self.root.mkdir()
        self.hooks.mkdir()
        isolated = mock.patch.dict(
            os.environ, {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        )
        isolated.start()
        self.addCleanup(isolated.stop)
        self.git("init", "--quiet", "--initial-branch=main")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("config", "core.hooksPath", str(self.hooks))

        # 0.1.0, released; then history up to the v0.2.6 baseline, which is a version
        # and not a release: CHANGELOG.md has no section for it.
        self.changelog = self.root / "CHANGELOG.md"
        self.changelog.write_text(self.PREAMBLE + "\n## 0.1.0 — 2026-08-20\n\n- the first build\n")
        (self.root / "README.md").write_text("mdql\n")
        self.git("add", "-A")
        self.git("commit", "-m", "Import the tree")
        self.tag("v0.1.0")
        self.commit("feat: hide the viewer with ⌘H", "Fix the install path")
        self.tag("v0.2.6")

    def git(self, *args) -> str:
        return subprocess.run(
            ["git", *args], cwd=self.root, check=True, capture_output=True, text=True
        ).stdout

    def commit(self, *subjects) -> None:
        for subject in subjects:
            self.git("commit", "--allow-empty", "-m", subject)

    def tag(self, name) -> None:
        self.git("tag", "-a", name, "-m", name[1:])

    def head(self) -> str:
        return self.git("rev-parse", "HEAD").strip()

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        here = os.getcwd()
        os.chdir(self.root)
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = release_tag.main(list(argv))
        finally:
            os.chdir(here)
        return code, out.getvalue(), err.getvalue()

    def assert_nothing_written(self, head, changelog):
        self.assertEqual(self.head(), head)
        self.assertEqual(self.changelog.read_bytes(), changelog)

    def test_a_release_writes_the_section_commits_it_alone_and_tags_it(self):
        self.commit("fix: checkbox toggles flip the right task", "docs: a note")
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)

        today = datetime.date.today().isoformat()
        self.assertEqual(
            self.changelog.read_text(),
            self.PREAMBLE
            + f"\n## 0.2.7 — {today}\n"
            "\n### Added\n- hide the viewer with ⌘H\n"
            "\n### Fixed\n- checkbox toggles flip the right task\n"
            "\n### Other\n- Fix the install path\n"
            "\n## 0.1.0 — 2026-08-20\n\n- the first build\n",
        )
        self.assertEqual(self.git("log", "-1", "--format=%s").strip(), "chore(release): 0.2.7")
        self.assertEqual(
            self.git("show", "--name-only", "--format=", "HEAD").split(), ["CHANGELOG.md"]
        )
        self.assertEqual(self.git("cat-file", "-t", "v0.2.7").strip(), "tag", "annotated")
        self.assertEqual(self.git("rev-parse", "v0.2.7^{commit}").strip(), self.head())
        self.assertIn("Nothing has been pushed", out)

    def test_the_release_commit_leaves_the_computed_version_where_it_was(self):
        self.commit("fix: a")
        self.assertEqual(str(read(self.root).version), "0.2.7")
        self.run_main()
        self.assertEqual(str(read(self.root).version), "0.2.7")

    def test_the_next_release_reads_from_this_one(self):
        self.commit("fix: a")
        self.run_main()
        self.commit("feat: b")
        code, _, err = self.run_main()
        self.assertEqual(code, 0, err)
        newest = self.changelog.read_text().split("\n## ")[1]
        self.assertTrue(newest.startswith("0.3.0 — "), newest)
        self.assertNotIn("- a\n", newest)
        self.assertIn("### Added\n- b\n", newest)

    def test_nothing_new_since_a_release_is_refused_without_writing(self):
        self.commit("fix: a")
        self.run_main()
        self.commit("docs: only this")
        head, changelog = self.head(), self.changelog.read_bytes()
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("v0.2.7 already exists", err)
        self.assert_nothing_written(head, changelog)

    def test_a_version_tagged_but_never_released_is_refused_too(self):
        # HEAD computes 0.2.6, the baseline: its tag sits on another commit.
        self.commit("docs: after the baseline")
        head, changelog = self.head(), self.changelog.read_bytes()
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("v0.2.6 already exists", err)
        self.assert_nothing_written(head, changelog)

    def test_a_dry_run_prints_the_section_and_writes_nothing(self):
        self.commit("fix: a")
        head, changelog = self.head(), self.changelog.read_bytes()
        code, out, _ = self.run_main("--dry-run")
        self.assertEqual(code, 0)
        self.assertIn("## 0.2.7 — ", out)
        self.assertIn("nothing written", out)
        self.assert_nothing_written(head, changelog)
        self.assertNotIn("v0.2.7", self.git("tag", "--list").split())

    def test_major_is_the_release_that_makes_it_one_point_oh(self):
        self.commit("fix: a")
        code, _, err = self.run_main("--major", "1")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.git("rev-parse", "v1.0.0^{commit}").strip(), self.head())
        self.assertIn("\n## 1.0.0 — ", self.changelog.read_text())
        self.assertEqual(str(read(self.root).version), "1.0.0")

    def test_a_major_that_does_not_move_it_is_refused(self):
        self.commit("fix: a")
        code, _, err = self.run_main("--major", "0")
        self.assertEqual(code, 1)
        self.assertIn("would not move the major", err)

    def test_a_major_over_quiet_commits_only_says_why_it_moved(self):
        # Release 0.2.7 first, so nothing listable is left since the previous release.
        self.commit("fix: a")
        self.run_main()
        self.commit("docs: b")
        code, _, err = self.run_main("--major", "1")
        self.assertEqual(code, 0, err)
        self.assertIn("No user-visible changes; the major moved to 1.", self.changelog.read_text())

    def test_a_changelog_with_edits_is_refused_by_state(self):
        self.commit("fix: a")
        self.changelog.write_text(self.changelog.read_text() + "\nhand edit\n")
        head = self.head()
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("modified, staged or untracked", err)
        self.assertIn("CHANGELOG.md", err)
        self.assertEqual(self.head(), head)

    def test_a_dirty_tree_is_refused(self):
        self.commit("fix: a")
        (self.root / "README.md").write_text("edited\n")
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("uncommitted changes", err)

    def test_the_newest_release_needs_its_tag(self):
        self.git("tag", "-d", "v0.1.0")
        self.commit("fix: a")
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("no tag v0.1.0", err)

    def test_an_untracked_file_is_neither_refused_nor_swept_in(self):
        self.commit("fix: a")
        (self.root / "other.md").write_text("somebody's half-finished note\n")
        code, _, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertEqual(
            self.git("show", "--name-only", "--format=", "HEAD").split(), ["CHANGELOG.md"]
        )
        self.assertIn("?? other.md", self.git("status", "--porcelain"))

    def test_a_failing_hook_is_reported_in_gits_own_words(self):
        self.commit("fix: a")
        hook = self.hooks / "pre-commit"
        hook.write_text("#!/bin/sh\necho 'refused: main-lock not held' >&2\nexit 1\n")
        hook.chmod(0o755)
        head, changelog = self.head(), self.changelog.read_bytes()
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("refused: main-lock not held", err)
        self.assertNotIn("v0.2.7", self.git("tag", "--list").split())
        # Nothing left half-done: a rerun would otherwise refuse the edited file.
        self.assert_nothing_written(head, changelog)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_a_tag_that_fails_takes_its_commit_with_it(self):
        self.commit("fix: a")
        # A tag git cannot make: signing is required and the signer fails.
        self.git("config", "tag.gpgSign", "true")
        self.git("config", "gpg.program", "false")
        head, changelog = self.head(), self.changelog.read_bytes()
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("git tag", err)
        # Left behind, the untagged release commit would make every rerun refuse:
        # the newest section's tag is missing.
        self.assert_nothing_written(head, changelog)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertNotIn("v0.2.7", self.git("tag", "--list").split())

    def test_a_release_is_cut_on_main_only(self):
        self.git("checkout", "--quiet", "-b", "topic")
        self.commit("fix: a")
        head, changelog = self.head(), self.changelog.read_bytes()
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("'topic', not main", err)
        self.assert_nothing_written(head, changelog)

    def test_a_detached_head_is_refused(self):
        self.commit("fix: a")
        self.git("checkout", "--quiet", "--detach")
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("not main", err)


if __name__ == "__main__":
    unittest.main()
