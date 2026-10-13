"""scripts/install.sh against a Mac that is not this one.

    python3 -m unittest discover -s scripts -p 'test_*.py'

The script copies a build into /Applications, edits the LaunchServices database, and quits
and relaunches the viewer. Here it installs into a scratch directory (MDQL_INSTALL_DIR),
`lsregister` is a stub (MDQL_LSREGISTER), and `pgrep`, `lsof`, `osascript`, `open`,
`codesign`, `qlmanage` and `sleep` are stubs on PATH. A running viewer is a real process,
a `sleep`, so that whether it was quit is a fact about a pid rather than a line in a log.
Nothing here touches /Applications, LaunchServices, or an mdql that is really running.
"""

import os
import shutil
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "install.sh"

# `pgrep -x mdql`: the viewers still alive, oldest first.
FAKE_PGREP = """#!/bin/sh
status=1
while read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then echo "$pid"; status=0; fi
done <"$FAKE/viewers"
exit $status
"""

# `lsof -p <pid> …`, from a file the test wrote for that pid. A pid named in `vanishes`
# is a viewer that quits by itself just before it is asked, which lsof answers with
# nothing and a status of 1.
FAKE_LSOF = """#!/bin/sh
while [ $# -gt 0 ]; do
    if [ "$1" = -p ]; then pid="$2"; fi
    shift
done
if [ -e "$FAKE/vanishes/$pid" ]; then
    kill "$pid"
    while kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.01; done
    exit 1
fi
[ -f "$FAKE/lsof/$pid" ] || { echo "lsof: fake has nothing for pid $pid" >&2; exit 1; }
cat "$FAKE/lsof/$pid"
"""

# A quit request. Addressed by pid (a number as the last argument) it reaches that
# process. Addressed by name, `quit app "mdql"`, it reaches one process of that name, the
# most recently launched, and exits 0 whatever else is running: what AppleScript does.
FAKE_OSASCRIPT = """#!/bin/sh
for last; do :; done
case "$last" in
"" | *[!0-9]*) pid="$(pgrep | tail -1)"; [ -n "$pid" ] || exit 0 ;;
*) pid="$last" ;;
esac
case "$(cat "$FAKE/quit/$pid" 2>/dev/null)" in
ignored) exit 0 ;;
refused) echo "execution error: Error: fake osascript refuses pid $pid (-2700)" >&2; exit 1 ;;
esac
kill "$pid"
"""

# Records its arguments, one per line, then does what LaunchServices does: a viewer that
# is already running takes the request, otherwise one is launched.
FAKE_OPEN = """#!/bin/sh
count=$(($(ls "$FAKE/opened" | wc -l) + 1))
printf '%s\\n' "$@" >"$FAKE/opened/$count"
[ ! -e "$FAKE/open-fails" ] || { echo "open: fake cannot launch anything" >&2; exit 1; }
pgrep >/dev/null && exit 0
/bin/sleep 300 </dev/null >/dev/null 2>&1 &
echo $! >>"$FAKE/viewers"
"""

FAKE_LSREGISTER = """#!/bin/sh
case "$1" in
-dump) cat "$FAKE/registrations" ;;
-u)
    if grep -qxF "$2" "$FAKE/unremovable" 2>/dev/null; then
        echo "lsregister: fake cannot unregister $2" >&2
        exit 1
    fi
    printf '%s\\n' "$2" >>"$FAKE/unregistered" ;;
-f) printf '%s\\n' "$3" >>"$FAKE/registered" ;;
*) echo "fake lsregister: unexpected arguments: $*" >&2; exit 2 ;;
esac
"""

# Every wait in the script, shortened: a quit that is ignored costs half a second here.
FAKE_SLEEP = "#!/bin/sh\nexec /bin/sleep 0.01\n"
DOES_NOTHING = "#!/bin/sh\nexit 0\n"


def lsof_output(pid, documents):
    """`lsof -p <pid> +fg -F ftGn` for a viewer showing `documents`, as macOS prints it:
    the executable, stdio, the files Metal and WebKit keep open, a watched directory, and
    each document, the only regular files opened event-only (O_EVTONLY, 0x8000)."""
    files = [
        ("cwd", "DIR", None, "/"),
        ("txt", "REG", None, "/Applications/mdql.app/Contents/MacOS/mdql"),
        ("0", "CHR", "0x1", "/dev/null"),
        ("3", "unix", "0x3", "->0x71d9d78d86b39ebc"),
        ("4", "REG", "0x1", "/System/Library/Extensions/AppleMetalOpenGLRenderer.bundle/Contents/Resources/default.metallib"),
        ("5", "DIR", "0x8000", "/Users/ada/Notes"),
    ]
    files += [(str(6 + n), "REG", "0x8001", str(d)) for n, d in enumerate(documents)]
    files += [
        ("30", "REG", "0x10003", "/Users/ada/Library/WebKit/com.mdql.app/WebsiteData/EnhancedSecurity/EnhancedSecuritySites.db-wal"),
        ("31", "REG", "0x3", "/Users/ada/Library/WebKit/com.mdql.app/WebsiteData/EnhancedSecurity/EnhancedSecuritySites.db"),
    ]
    lines = [f"p{pid}"]
    for descriptor, kind, flags, name in files:
        lines += [f"f{descriptor}", f"t{kind}"]
        if flags:
            lines.append(f"G{flags};0x0")
        lines.append(f"n{name}")
    return "\n".join(lines) + "\n"


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


class InstallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = SCRIPT.read_text()
        for override in ("MDQL_INSTALL_DIR", "MDQL_LSREGISTER"):
            if override not in source:
                raise AssertionError(
                    f"install.sh no longer reads {override}: run here, it would install "
                    "into the real /Applications and LaunchServices.")
        cls._tmp = tempfile.TemporaryDirectory()
        cls.bin = Path(cls._tmp.name)
        stubs = {
            "pgrep": FAKE_PGREP, "lsof": FAKE_LSOF, "osascript": FAKE_OSASCRIPT,
            "open": FAKE_OPEN, "lsregister": FAKE_LSREGISTER, "sleep": FAKE_SLEEP,
            "codesign": DOES_NOTHING, "qlmanage": DOES_NOTHING,
        }
        for name, body in stubs.items():
            stub = cls.bin / name
            stub.write_text(body)
            stub.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def setUp(self):
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.work)
        self.fake = self.work / "fake"
        for directory in ("lsof", "quit", "opened", "vanishes"):
            (self.fake / directory).mkdir(parents=True)
        (self.fake / "viewers").write_text("")
        (self.fake / "registrations").write_text("")
        self.addCleanup(self.kill_viewers)

        self.built = self.work / "built"
        executable = self.built / "mdql.app" / "Contents" / "MacOS" / "mdql"
        executable.parent.mkdir(parents=True)
        executable.write_text("the new build\n")
        self.applications = self.work / "Applications"
        self.app = str(self.applications / "mdql.app")
        self.documents = self.work / "Documents"
        self.documents.mkdir()

    def kill_viewers(self):
        for pid in self.viewers():
            os.kill(pid, signal.SIGKILL)

    def viewers(self):
        """The pids of the viewers still running, oldest first."""
        pids = [int(line) for line in (self.fake / "viewers").read_text().split()]
        return [pid for pid in pids if alive(pid)]

    def document(self, name, exists=True):
        path = self.documents / name
        if exists:
            path.write_text(f"# {name}\n")
        return str(path)

    def viewer(self, *documents, quit=None):
        """Start a viewer showing `documents`. `quit` is how it answers a quit request:
        "ignored" (it carries on, as one that hangs does) or "refused" (the request itself
        fails); by default it quits."""
        # Started by a shell that exits at once, so the viewer is nobody's child here and
        # is gone when killed, instead of lingering as a zombie this process must reap.
        pid = int(subprocess.run(
            ["/bin/sh", "-c", "/bin/sleep 300 </dev/null >/dev/null 2>&1 & echo $!"],
            check=True, capture_output=True, text=True,
        ).stdout)
        with (self.fake / "viewers").open("a") as viewers:
            viewers.write(f"{pid}\n")
        (self.fake / "lsof" / str(pid)).write_text(lsof_output(pid, documents))
        if quit:
            (self.fake / "quit" / str(pid)).write_text(quit)
        return pid

    def install(self, skip_launch=False):
        environment = dict(
            os.environ,
            FAKE=str(self.fake),
            MDQL_INSTALL_DIR=str(self.applications),
            MDQL_LSREGISTER=str(self.bin / "lsregister"),
            PATH=f"{self.bin}:{os.environ['PATH']}",
        )
        environment.pop("SKIP_LAUNCH", None)
        if skip_launch:
            environment["SKIP_LAUNCH"] = "1"
        return subprocess.run(
            [str(SCRIPT), str(self.built)], env=environment, capture_output=True, text=True,
        )

    def installed(self, **options):
        result = self.install(**options)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def opened(self):
        """The arguments of each `open`, in order."""
        calls = sorted((self.fake / "opened").iterdir(), key=lambda call: int(call.name))
        return [call.read_text().splitlines() for call in calls]

    def lines(self, name):
        path = self.fake / name
        return path.read_text().splitlines() if path.exists() else []

    # ---- Installing ---------------------------------------------------------------

    def test_the_build_is_copied_and_registered(self):
        self.installed()
        executable = self.applications / "mdql.app" / "Contents" / "MacOS" / "mdql"
        self.assertEqual(executable.read_text(), "the new build\n")
        self.assertEqual(self.lines("registered"), [self.app])

    def test_with_no_viewer_running_the_app_is_launched_once_and_quit_again(self):
        self.installed()
        self.assertEqual(self.opened(), [[self.app]])
        self.assertEqual(self.viewers(), [])

    # ---- A viewer that is already running -------------------------------------------

    def test_a_running_viewer_comes_back_on_the_new_build_with_its_documents(self):
        notes = self.document("release notes.md")
        plan = self.document("plan.md")
        previous = self.viewer(notes, plan)
        result = self.installed()
        self.assertFalse(alive(previous))
        self.assertEqual(self.opened(), [["-a", self.app, notes, plan]])
        self.assertEqual(len(self.viewers()), 1)
        for document in (notes, plan):
            self.assertIn(document, result.stdout)

    def test_two_running_viewers_are_both_replaced(self):
        # 2026-10-13: a viewer launched from a test build was running beside the one from
        # /Applications. A quit addressed to "mdql" reached the newer of the two, and the
        # older one, with the documents, went on running the build just replaced.
        notes = self.document("notes.md")
        plan = self.document("plan.md")
        draft = self.document("draft.md")
        installed = self.viewer(notes, plan)
        stray = self.viewer(draft)
        self.installed()
        self.assertFalse(alive(installed))
        self.assertFalse(alive(stray))
        self.assertEqual(self.opened(), [["-a", self.app, notes, plan, draft]])
        self.assertEqual(len(self.viewers()), 1)

    def test_a_document_open_in_two_viewers_is_reopened_once(self):
        notes = self.document("notes.md")
        plan = self.document("plan.md")
        self.viewer(notes)
        self.viewer(notes, plan)
        self.installed()
        self.assertEqual(self.opened(), [["-a", self.app, notes, plan]])

    def test_a_document_deleted_meanwhile_is_named_and_not_reopened(self):
        notes = self.document("notes.md")
        gone = self.document("gone.md", exists=False)
        self.viewer(notes, gone)
        result = self.installed()
        self.assertEqual(self.opened(), [["-a", self.app, notes]])
        self.assertIn(gone, result.stdout + result.stderr)

    def test_a_viewer_with_nothing_left_to_show_is_quit_like_any_other(self):
        previous = self.viewer(self.document("gone.md", exists=False))
        self.installed()
        self.assertFalse(alive(previous))
        self.assertEqual(self.opened(), [[self.app]])
        self.assertEqual(self.viewers(), [])

    def test_a_viewer_that_quits_by_itself_meanwhile_is_not_an_error(self):
        notes = self.document("notes.md")
        self.viewer(notes)
        leaving = self.viewer(self.document("plan.md"))
        (self.fake / "vanishes" / str(leaving)).touch()
        self.installed()
        self.assertEqual(self.opened(), [["-a", self.app, notes]])

    def test_documents_that_could_not_be_reopened_are_named(self):
        notes = self.document("notes.md")
        plan = self.document("plan.md")
        self.viewer(notes, plan)
        (self.fake / "open-fails").touch()
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("open: fake cannot launch anything", result.stderr)
        for document in (notes, plan):
            self.assertIn(document, result.stderr)

    # ---- A viewer that will not go ------------------------------------------------

    def test_a_viewer_that_ignores_the_quit_fails_the_install_and_is_named(self):
        stuck = self.viewer(self.document("notes.md"), quit="ignored")
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(alive(stuck))
        self.assertIn(f"pid {stuck}", result.stderr)
        self.assertIn("did not quit", result.stderr)
        self.assertEqual(self.opened(), [])

    def test_a_quit_request_that_fails_is_reported_with_its_error(self):
        stuck = self.viewer(quit="refused")
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(alive(stuck))
        self.assertIn(f"fake osascript refuses pid {stuck}", result.stderr)
        self.assertEqual(self.opened(), [])
        self.assertNotIn("Not reopening", result.stdout + result.stderr)

    def test_the_documents_of_a_viewer_that_quit_come_back_though_another_would_not(self):
        notes = self.document("notes.md")
        plan = self.document("plan.md")
        stuck = self.viewer(notes, quit="ignored")
        willing = self.viewer(plan)
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(alive(stuck))
        self.assertFalse(alive(willing))
        self.assertEqual(self.opened(), [["-a", self.app, plan]])

    def test_when_a_viewers_documents_cannot_be_listed_nothing_is_quit(self):
        listed = self.viewer(self.document("notes.md"))
        unlisted = self.viewer(self.document("plan.md"))
        (self.fake / "lsof" / str(unlisted)).unlink()
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.viewers(), [listed, unlisted])
        self.assertEqual(self.opened(), [])
        self.assertIn(f"lsof: fake has nothing for pid {unlisted}", result.stderr)
        self.assertIn(f"mdql (pid {unlisted})", result.stderr)

    # ---- From an Xcode build, which can launch nothing -------------------------------

    def test_skip_launch_leaves_a_running_viewer_alone_and_warns(self):
        previous = self.viewer(self.document("notes.md"))
        result = self.installed(skip_launch=True)
        self.assertEqual(self.viewers(), [previous])
        self.assertEqual(self.opened(), [])
        self.assertRegex(result.stdout + result.stderr, rf"warning: .*pid {previous}")

    def test_skip_launch_says_nothing_when_no_viewer_runs(self):
        result = self.installed(skip_launch=True)
        self.assertEqual(self.opened(), [])
        self.assertNotIn("warning", result.stdout + result.stderr)

    # ---- LaunchServices registrations ---------------------------------------------

    def register(self, *paths):
        """Write the lines of `lsregister -dump` that the script reads, one per bundle."""
        dump = "".join(
            f"path:                       {path} (0x{0x7288 + 4 * n:x})\n"
            for n, path in enumerate(paths)
        )
        (self.fake / "registrations").write_text(dump)

    def test_every_other_registered_mdql_is_unregistered(self):
        strays = [
            "/Users/ada/Library/Developer/Xcode/DerivedData/mdql-atkyhyac/Build/Products/Debug/mdql.app",
            "/Users/ada/code/mdql/build/mdql/Build/Products/Release/mdql.app",
            "/Users/ada/worktrees/mdql/gone (2)/build/mdql/Build/Products/Release/mdql.app",
            "/private/var/folders/rl/abc/T/tmp.p9qANxAMYW/mdql-0.1.0/mdql.app",
        ]
        self.register(
            self.app,
            f"{self.app}/Contents/PlugIns/mdqlPreview.appex",
            *strays,
            f"{strays[0]}/Contents/PlugIns/mdqlPreview.appex",
            "/Applications/Notes.app",
            "/Applications/notmdql.app",
            "/Users/ada/Library/WebKit/com.mdql.app",
        )
        self.installed()
        unregistered = [path for path in self.lines("unregistered") if path.endswith("/mdql.app")]
        self.assertEqual(sorted(unregistered), sorted(strays))
        self.assertEqual(self.lines("registered"), [self.app])

    def test_a_registration_that_cannot_be_removed_is_reported(self):
        stray = "/Users/ada/code/mdql/build/mdql/Build/Products/Release/mdql.app"
        self.register(self.app, stray)
        (self.fake / "unremovable").write_text(f"{stray}\n")
        result = self.installed()
        self.assertIn("lsregister: fake cannot unregister", result.stderr)
        self.assertRegex(result.stderr, rf"warning: .*{stray}")


if __name__ == "__main__":
    unittest.main()
