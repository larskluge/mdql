#!/usr/bin/env python3
"""The version calculator's suite. `python3 -m unittest discover -s scripts -p 'test_*.py'`."""

import contextlib
import io
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from version import (
    APPEX,
    BADGE,
    XPC,
    Reading,
    Version,
    VersionError,
    advance,
    check_app,
    explain,
    level_for,
    main,
    read,
    stamp_text,
)

SCRIPTS = pathlib.Path(__file__).resolve().parent
REPO = SCRIPTS.parent


class VersionTests(unittest.TestCase):
    def test_parses_and_renders(self):
        self.assertEqual(str(Version.parse("0.2.6")), "0.2.6")
        self.assertEqual(Version.parse("12.3.45"), Version(12, 3, 45))

    def test_refuses_a_two_part_version(self):
        with self.assertRaises(ValueError):
            Version.parse("1.0")

    def test_a_patch_moves_the_last_part_only(self):
        self.assertEqual(Version(0, 2, 6).bumped("patch"), Version(0, 2, 7))

    def test_a_minor_zeroes_the_patch(self):
        self.assertEqual(Version(0, 2, 6).bumped("minor"), Version(0, 3, 0))

    def test_none_leaves_it_alone(self):
        self.assertEqual(Version(0, 2, 6).bumped("none"), Version(0, 2, 6))

    def test_there_is_no_major_level(self):
        # The major comes from a tag Lars asks for and from nothing a commit says.
        with self.assertRaises(ValueError):
            Version(0, 2, 6).bumped("major")


class LevelTests(unittest.TestCase):
    def test_feat_is_a_minor(self):
        self.assertEqual(level_for("feat: hide the standalone viewer with ⌘H"), "minor")

    def test_a_scope_does_not_change_the_type(self):
        self.assertEqual(level_for("feat(preview): render task lists"), "minor")

    def test_fix_and_perf_are_patches(self):
        self.assertEqual(level_for("fix: make install restarts every running viewer"), "patch")
        self.assertEqual(level_for("perf: the preview no longer re-parses on scroll"), "patch")

    def test_quiet_types_move_nothing(self):
        for kind in ("chore", "docs", "ci", "test", "build", "refactor", "style"):
            self.assertEqual(level_for(f"{kind}: something users never see"), "none", kind)

    def test_an_unprefixed_subject_is_a_patch(self):
        self.assertEqual(level_for("Checkbox toggles flip the right task"), "patch")

    def test_a_type_nobody_listed_is_a_patch(self):
        self.assertEqual(level_for("quicklook: previews open faster"), "patch")

    def test_a_bang_infers_nothing(self):
        self.assertEqual(level_for("feat!: the extension's bundle id changed"), "minor")
        self.assertEqual(level_for("fix(preview)!: drop the legacy WebView"), "patch")
        self.assertEqual(level_for("docs!: rewrite the README"), "none")


class AdvanceTests(unittest.TestCase):
    BASE = Version(0, 2, 6)

    def test_nothing_after_the_baseline_is_the_baseline(self):
        self.assertEqual(advance(self.BASE, []), self.BASE)

    def test_each_fix_is_one_patch(self):
        self.assertEqual(advance(self.BASE, ["fix: a", "perf: b", "Polish c"]), Version(0, 2, 9))

    def test_feat_then_fix_is_the_first_patch_of_the_new_minor(self):
        self.assertEqual(advance(self.BASE, ["feat: a", "fix: b"]), Version(0, 3, 1))

    def test_fix_then_feat_resets_the_patch(self):
        self.assertEqual(advance(self.BASE, ["fix: a", "fix: b", "feat: c"]), Version(0, 3, 0))

    def test_quiet_commits_move_nothing_wherever_they_fall(self):
        self.assertEqual(
            advance(self.BASE, ["docs: a", "fix: b", "chore: c", "test: d"]), Version(0, 2, 7)
        )


# ---- against real repositories ---------------------------------------------


@unittest.skipUnless(shutil.which("git"), "git is not on PATH")
class RepositoryTests(unittest.TestCase):
    """`read()` against throwaway repositories: everything it says comes out of git."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = pathlib.Path(tmp.name).resolve()
        self.root = self.base / "repo"
        self.root.mkdir()
        # This machine's own git config must not reach in: a global hook, signing key
        # or `core.autocrlf` would pass or fail these for reasons that are not the code.
        isolated = mock.patch.dict(
            os.environ, {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        )
        isolated.start()
        self.addCleanup(isolated.stop)
        self.git("init", "--quiet", "--initial-branch=main")
        self.git("config", "user.name", "Version Test")
        self.git("config", "user.email", "version-test@example.invalid")
        (self.root / "README.md").write_text("mdql\n")
        self.git("add", "-A")
        self.git("commit", "-m", "Import the tree")

    def git(self, *args, cwd=None) -> str:
        return subprocess.run(
            ["git", *args], cwd=cwd or self.root, check=True, capture_output=True, text=True
        ).stdout

    def commit(self, *subjects, body="") -> None:
        for subject in subjects:
            message = subject + (f"\n\n{body}" if body else "")
            self.git("commit", "--allow-empty", "-m", message)

    def tag(self, name, ref="HEAD") -> None:
        self.git("tag", "-a", name, "-m", name[1:], ref)

    def version(self) -> str:
        return str(read(self.root).version)

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        here = os.getcwd()
        os.chdir(self.root)
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = main(list(argv))
        finally:
            os.chdir(here)
        return code, out.getvalue(), err.getvalue()

    def test_this_machines_git_config_does_not_reach_the_repository(self):
        listed = self.git("config", "--list", "--show-scope").splitlines()
        self.assertEqual({line.split("\t")[0] for line in listed}, {"local"})

    def test_on_the_baseline_tag_it_is_the_tag(self):
        self.tag("v0.2.6")
        self.assertEqual(self.version(), "0.2.6")
        code, out, _ = self.run_main()
        self.assertEqual((code, out), (0, "0.2.6\n"))

    def test_every_kind_of_commit_after_the_baseline(self):
        self.tag("v0.2.6")
        self.commit(
            "fix: a",            # 0.2.7
            "docs: b",           # 0.2.7
            "perf: c",           # 0.2.8
            "Unprefixed d",      # 0.2.9
            "feat: e",           # 0.3.0
            "ci: f",             # 0.3.0
            "fix: g",            # 0.3.1
            "refactor: h",       # 0.3.1
        )
        self.assertEqual(self.version(), "0.3.1")

    def test_explain_shows_each_step(self):
        self.tag("v0.2.6")
        self.commit("feat: a new thing", "fix: a bug in it")
        text = explain(read(self.root))
        lines = text.splitlines()
        self.assertEqual(lines[0], "0.2.6  v0.2.6")
        self.assertRegex(lines[1], r"^0\.3\.0  minor  [0-9a-f]{7}  feat: a new thing$")
        self.assertRegex(lines[2], r"^0\.3\.1  patch  [0-9a-f]{7}  fix: a bug in it$")
        self.assertTrue(lines[3].startswith("= 0.3.1, build "))

    def test_a_breaking_footer_or_a_bang_infers_no_major(self):
        self.tag("v0.2.6")
        self.commit("feat!: the bridge changed", body="BREAKING CHANGE: the old one is gone")
        self.assertEqual(self.version(), "0.3.0")

    def test_a_merge_counts_its_commits_once_and_itself_not_at_all(self):
        self.tag("v0.2.6")
        self.git("checkout", "--quiet", "-b", "topic")
        self.commit("fix: on the branch")
        self.git("checkout", "--quiet", "main")
        self.commit("docs: on main meanwhile")
        self.git("merge", "--quiet", "--no-ff", "-m", "Merge branch 'topic'", "topic")
        reading = read(self.root)
        # "Merge branch 'topic'" is unprefixed: counted, it would be a second patch.
        self.assertEqual(str(reading.version), "0.2.7")
        self.assertNotIn("Merge branch 'topic'", [c.subject for c in reading.commits])

    def test_the_build_number_counts_every_commit_merges_included(self):
        self.tag("v0.2.6")
        self.git("checkout", "--quiet", "-b", "topic")
        self.commit("fix: on the branch")
        self.git("checkout", "--quiet", "main")
        self.commit("docs: on main meanwhile")
        self.git("merge", "--quiet", "--no-ff", "-m", "Merge branch 'topic'", "topic")
        # Import, fix, docs, merge. Dropping the merge would let it go down later,
        # which macOS reads as a downgrade.
        self.assertEqual(read(self.root).build, 4)
        code, out, _ = self.run_main("--build")
        self.assertEqual((code, out), (0, "4\n"))

    def test_a_later_major_tag_is_the_new_baseline(self):
        self.tag("v0.2.6")
        self.commit("feat: a", "fix: b")
        self.assertEqual(self.version(), "0.3.1")
        self.tag("v1.0.0")
        self.assertEqual(self.version(), "1.0.0")
        self.commit("fix: c", "feat: d", "fix: e")
        self.assertEqual(self.version(), "1.1.1")

    def test_the_highest_version_wins_not_the_last_string(self):
        self.tag("v0.9.0")
        self.commit("docs: a")
        self.tag("v0.10.0")
        self.commit("fix: b")
        # Plain string order puts v0.9.0 above v0.10.0.
        self.assertEqual(self.version(), "0.10.1")

    def test_a_tag_on_a_commit_head_does_not_contain_is_no_baseline(self):
        self.tag("v0.2.6")
        self.git("checkout", "--quiet", "-b", "abandoned")
        self.commit("feat: never merged")
        self.tag("v5.0.0")
        self.git("checkout", "--quiet", "main")
        self.commit("fix: on main")
        self.assertEqual(self.version(), "0.2.7")

    def test_a_tag_that_names_no_version_is_no_baseline(self):
        self.tag("v0.2.6")
        self.commit("fix: a")
        self.git("tag", "vNightly")
        self.git("tag", "v0.3.0-rc1")
        self.assertEqual(self.version(), "0.2.7")

    def test_a_lightweight_tag_is_a_baseline_too(self):
        self.git("tag", "v0.2.6")
        self.commit("fix: a")
        self.assertEqual(self.version(), "0.2.7")

    def test_no_tag_at_all_is_refused_by_name(self):
        self.commit("fix: a")
        with self.assertRaises(VersionError) as raised:
            read(self.root)
        self.assertIn("no vX.Y.Z tag is reachable from HEAD", str(raised.exception))
        code, out, err = self.run_main()
        self.assertEqual((code, out), (1, ""))
        self.assertIn("git fetch --tags", err)

    def test_a_shallow_clone_is_refused(self):
        self.tag("v0.2.6")
        self.commit("fix: a", "fix: b")
        shallow = self.base / "shallow"
        self.git("clone", "--quiet", "--depth", "1", f"file://{self.root}", str(shallow), cwd=self.base)
        with self.assertRaises(VersionError) as raised:
            read(shallow)
        self.assertIn("shallow", str(raised.exception))

    def test_the_badge_is_the_version_and_the_commit(self):
        self.tag("v0.2.6")
        reading = read(self.root)
        short = self.git("rev-parse", "--short", "HEAD").strip()
        self.assertEqual(reading.badge, f"0.2.6 ({short})")

    def test_an_edit_to_a_tracked_file_marks_the_badge_dirty(self):
        self.tag("v0.2.6")
        (self.root / "README.md").write_text("edited\n")
        self.assertTrue(read(self.root).badge.endswith("-dirty)"))
        self.git("add", "README.md")
        self.assertTrue(read(self.root).badge.endswith("-dirty)"), "staged counts too")

    def test_an_untracked_file_does_not(self):
        self.tag("v0.2.6")
        (self.root / "scratch.txt").write_text("not in any build\n")
        self.assertFalse(read(self.root).dirty)

    def test_write_puts_version_build_and_badge_one_per_line(self):
        self.tag("v0.2.6")
        self.commit("fix: a")
        stamp = self.base / "out" / "mdql-version.stamp"
        code, _, _ = self.run_main("--write", str(stamp))
        self.assertEqual(code, 0)
        version, build, badge = stamp.read_text().splitlines()
        self.assertEqual((version, build), ("0.2.7", "2"))
        self.assertRegex(badge, r"^0\.2\.7 \([0-9a-f]{7,}\)$")

    def test_write_leaves_an_unchanged_stamp_untouched(self):
        self.tag("v0.2.6")
        stamp = self.base / "mdql-version.stamp"
        self.run_main("--write", str(stamp))
        os.utime(stamp, (1_000_000, 1_000_000))
        self.run_main("--write", str(stamp))
        self.assertEqual(stamp.stat().st_mtime, 1_000_000)


# ---- the build ---------------------------------------------------------------

READING = Reading(
    tag="v0.2.6",
    baseline=Version(0, 2, 6),
    commits=(),
    version=Version(0, 2, 7),
    build=91,
    short="a1b2c3d",
    dirty=False,
)


def write_plist(path: pathlib.Path, **keys) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        plistlib.dump({"CFBundleIdentifier": "com.mdql.app.test", **keys}, f)


@unittest.skipUnless(shutil.which("plutil"), "plutil is macOS's")
class StampScriptTests(unittest.TestCase):
    """scripts/stamp-version.sh, as the Stamp version build phases run it."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = pathlib.Path(tmp.name)
        self.stamp = self.dir / "mdql-version.stamp"
        self.stamp.write_text(stamp_text(READING))
        # As ProcessInfoPlistFile leaves it: the source Info.plists carry no version.
        self.plist = self.dir / "mdql.app/Contents/Info.plist"
        write_plist(self.plist)

    def stamp_version(self, *args):
        return subprocess.run(
            [str(SCRIPTS / "stamp-version.sh"), *map(str, args)], capture_output=True, text=True
        )

    def info(self):
        with open(self.plist, "rb") as f:
            return plistlib.load(f)

    def test_it_writes_both_keys_into_the_plist(self):
        done = self.stamp_version(self.stamp, self.plist)
        self.assertEqual(done.returncode, 0, done.stderr)
        info = self.info()
        self.assertEqual(info["CFBundleShortVersionString"], "0.2.7")
        self.assertEqual(info["CFBundleVersion"], "91")
        self.assertEqual(info["CFBundleIdentifier"], "com.mdql.app.test")

    def test_it_replaces_what_an_earlier_build_stamped(self):
        write_plist(self.plist, CFBundleShortVersionString="0.2.6", CFBundleVersion="90")
        self.stamp_version(self.stamp, self.plist)
        self.assertEqual(self.info()["CFBundleVersion"], "91")

    def test_a_binary_plist_is_stamped_too(self):
        with open(self.plist, "wb") as f:
            plistlib.dump({"CFBundleIdentifier": "x"}, f, fmt=plistlib.FMT_BINARY)
        done = self.stamp_version(self.stamp, self.plist)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.info()["CFBundleShortVersionString"], "0.2.7")

    def test_a_third_argument_gets_the_badge(self):
        badge = self.dir / "mdqlPreview.appex/Contents/Resources/version.txt"
        self.stamp_version(self.stamp, self.plist, badge)
        self.assertEqual(badge.read_text(), "0.2.7 (a1b2c3d)\n")

    def test_a_missing_stamp_file_fails_and_says_who_writes_it(self):
        done = self.stamp_version(self.dir / "nowhere", self.plist)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("mdql-version target", done.stderr)
        self.assertNotIn("CFBundleVersion", self.info())

    def test_a_short_stamp_file_fails_and_shows_it(self):
        self.stamp.write_text("0.2.7\n")
        done = self.stamp_version(self.stamp, self.plist)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("one per line", done.stderr)
        self.assertNotIn("CFBundleShortVersionString", self.info())


class CheckAppTests(unittest.TestCase):
    """`--check`: what make install and make dist ask of a built mdql.app."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.app = pathlib.Path(tmp.name) / "mdql.app"
        self.build(version="0.2.7", build="91")

    def build(self, version, build, appex_build=None, badge="0.2.7 (a1b2c3d)"):
        for sub in ("", APPEX, XPC):
            write_plist(
                self.app / sub / "Contents/Info.plist" if sub else self.app / "Contents/Info.plist",
                CFBundleShortVersionString=version,
                CFBundleVersion=appex_build if (sub == APPEX and appex_build) else build,
            )
        (self.app / BADGE).parent.mkdir(parents=True, exist_ok=True)
        (self.app / BADGE).write_text(badge + "\n")

    def test_a_build_that_carries_it_throughout_passes(self):
        self.assertEqual(check_app(self.app, READING), [])

    def test_a_dirty_badge_passes_since_the_tree_may_have_changed_since(self):
        self.build(version="0.2.7", build="91", badge="0.2.7 (a1b2c3d-dirty)")
        self.assertEqual(check_app(self.app, READING), [])

    def test_an_appex_that_disagrees_with_its_app_is_named(self):
        self.build(version="0.2.7", build="91", appex_build="90")
        self.assertEqual(
            check_app(self.app, READING), ["mdqlPreview.appex: CFBundleVersion is '90', not '91'"]
        )

    def test_a_build_of_another_version_is_named_in_every_bundle(self):
        self.build(version="0.2.6", build="91", badge="0.2.6 (a1b2c3d)")
        problems = check_app(self.app, READING)
        self.assertEqual(len(problems), 4, problems)
        self.assertTrue(problems[0].startswith("mdql.app: CFBundleShortVersionString is '0.2.6'"))
        self.assertIn("version.txt reads", problems[3])

    def test_a_badge_of_another_commit_is_refused(self):
        self.build(version="0.2.7", build="91", badge="0.2.7 (fffffff)")
        self.assertEqual(
            check_app(self.app, READING), ["version.txt reads '0.2.7 (fffffff)', not '0.2.7 (a1b2c3d)'"]
        )

    def test_a_bundle_with_no_info_plist_is_named(self):
        (self.app / XPC / "Contents/Info.plist").unlink()
        (problem,) = check_app(self.app, READING)
        self.assertTrue(problem.startswith("open-url.xpc: cannot read"), problem)


# ---- this repository's own project -------------------------------------------


class ProjectTests(unittest.TestCase):
    """The project as it is checked in: the Xcode path a build without make takes."""

    @classmethod
    def setUpClass(cls):
        cls.pbxproj = (REPO / "mdql.xcodeproj/project.pbxproj").read_text()

    def block(self, ident: str) -> str:
        """One object's `{ … }` body, by its id."""
        m = re.search(rf"^\t\t{ident} /\* .*? \*/ = {{$", self.pbxproj, re.MULTILINE)
        self.assertIsNotNone(m, f"no object {ident}")
        return self.pbxproj[m.start() : self.pbxproj.index("\n\t\t};\n", m.start())]

    def target(self, name: str) -> str:
        m = re.search(
            rf"^\t\t(\w+) /\* {re.escape(name)} \*/ = {{\n\t\t\tisa = PBX(Native|Aggregate)Target;",
            self.pbxproj,
            re.MULTILINE,
        )
        self.assertIsNotNone(m, f"no target {name}")
        return self.block(m.group(1))

    def test_no_version_is_stored_in_the_project(self):
        self.assertIsNone(
            re.search(r"^\s*(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = ", self.pbxproj, re.MULTILINE)
        )

    def test_no_info_plist_carries_a_version_of_its_own(self):
        for plist in ("mdql/Info.plist", "mdqlPreview/Info.plist", "mdql-open-url/Info.plist"):
            text = (REPO / plist).read_text()
            self.assertNotIn("CFBundleShortVersionString", text, plist)
            self.assertNotIn("<key>CFBundleVersion</key>", text, plist)

    def test_the_version_target_computes_it_once_per_build(self):
        target = self.target("mdql-version")
        (phase,) = re.findall(r"(\w+) /\* Compute version \*/", target)
        body = self.block(phase)
        self.assertIn("alwaysOutOfDate = 1;", body)
        self.assertIn("scripts/version.py --write", body)
        self.assertIn('"$(BUILT_PRODUCTS_DIR)/mdql-version.stamp",', body)

    def test_every_bundle_target_depends_on_it_and_stamps_its_plist(self):
        dependency_ids = {
            m.group(1)
            for m in re.finditer(
                r"^\t\t(\w+) /\* PBXTargetDependency \*/ = \{\n\t\t\tisa = PBXTargetDependency;\n"
                r"\t\t\ttarget = \w+ /\* mdql-version \*/;",
                self.pbxproj,
                re.MULTILINE,
            )
        }
        for name in ("mdql", "mdqlPreview", "mdql-open-url"):
            with self.subTest(target=name):
                target = self.target(name)
                deps = set(re.findall(r"(\w+) /\* PBXTargetDependency \*/", target))
                self.assertTrue(deps & dependency_ids, f"{name} does not depend on mdql-version")
                (phase,) = re.findall(r"(\w+) /\* Stamp version \*/", target)
                body = self.block(phase)
                self.assertIn("alwaysOutOfDate = 1;", body)
                self.assertIn('"$(BUILT_PRODUCTS_DIR)/mdql-version.stamp",', body)
                self.assertIn('"$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)",', body)
                self.assertIn("scripts/stamp-version.sh", body)

    def test_only_the_extension_writes_the_badge(self):
        for name, writes in (("mdql", False), ("mdqlPreview", True), ("mdql-open-url", False)):
            (phase,) = re.findall(r"(\w+) /\* Stamp version \*/", self.target(name))
            self.assertEqual("version.txt" in self.block(phase), writes, name)

    def test_the_apps_stamp_runs_after_it_embeds_the_extension(self):
        # The app's Info.plist is processed only once the appex is embedded, so a
        # stamp ahead of the embed is a dependency cycle and the build fails.
        phases = self.target("mdql").split("buildPhases = (")[1].split(");")[0]
        self.assertLess(phases.index("Embed Foundation Extensions"), phases.index("Stamp version"))
        self.assertLess(phases.index("Stamp version"), phases.index("Install & Register"))


if __name__ == "__main__":
    unittest.main()
