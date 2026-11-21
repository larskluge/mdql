"""The vendored Mermaid runtime against its pin, and scripts/fetch-mermaid.sh.

    python3 -m unittest discover -s scripts -p 'test_*.py'

The script runs against a registry on disk (MERMAID_REGISTRY, a file:// URL that
curl reads like the npm registry) and installs into a scratch copy of the repo
(MDQL_ROOT), from a directory that is not the repo. Nothing here touches the
network or this checkout's mermaid.min.js.
"""

import base64
import hashlib
import io
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "fetch-mermaid.sh"
PIN = REPO / "scripts" / "mermaid.pin"
RUNTIME = REPO / "mdqlPreview" / "Resources" / "mermaid.min.js"


def read_pin(path):
    pin = {}
    for line in path.read_text().splitlines():
        if line and not line.startswith("#"):
            key, value = line.split("=", 1)
            pin[key] = value
    return pin


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class VendoredRuntimeTests(unittest.TestCase):
    def test_runtime_is_the_pinned_file(self):
        # A hand edit, a botched copy, or a new file without its pin all land here.
        self.assertEqual(sha256(RUNTIME), read_pin(PIN)["MERMAID_SHA256"],
                         "mermaid.min.js is not the file scripts/mermaid.pin pins: run scripts/fetch-mermaid.sh")

    def test_pin_names_a_release(self):
        version = read_pin(PIN)["MERMAID_VERSION"]
        self.assertRegex(version, r"^\d+\.\d+\.\d+$")


class FetchMermaidTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.root = self.tmp / "repo"
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "mdqlPreview" / "Resources").mkdir(parents=True)
        self.registry = self.tmp / "registry"
        (self.registry / "mermaid").mkdir(parents=True)
        self.elsewhere = self.tmp / "elsewhere"
        self.elsewhere.mkdir()
        self.target = self.root / "mdqlPreview" / "Resources" / "mermaid.min.js"
        self.target.write_bytes(b"old runtime")
        self.pin = self.root / "scripts" / "mermaid.pin"

    def publish(self, version, runtime, integrity=None):
        """Puts a release in the fake registry: its tarball and its metadata."""
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
            info = tarfile.TarInfo("package/dist/mermaid.min.js")
            info.size = len(runtime)
            tar.addfile(info, io.BytesIO(runtime))
        tarball = self.registry / f"mermaid-{version}.tgz"
        tarball.write_bytes(buffer.getvalue())
        real = "sha512-" + base64.b64encode(hashlib.sha512(tarball.read_bytes()).digest()).decode()
        (self.registry / "mermaid" / version).write_text(json.dumps(
            {"version": version, "dist": {"tarball": tarball.as_uri(), "integrity": integrity or real}}))

    def write_pin(self, version, sha):
        self.pin.write_text(f"# pin\nMERMAID_VERSION={version}\nMERMAID_SHA256={sha}\n")

    def run_script(self, *args):
        env = dict(os.environ, MDQL_ROOT=str(self.root), MERMAID_REGISTRY=self.registry.as_uri())
        return subprocess.run([str(SCRIPT), *args], cwd=self.elsewhere, env=env, capture_output=True, text=True)

    def test_a_named_release_is_installed_and_pinned(self):
        self.write_pin("1.0.0", "0" * 64)
        self.publish("2.0.0", b"runtime two")
        result = self.run_script("2.0.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.target.read_bytes(), b"runtime two")
        pin = read_pin(self.pin)
        self.assertEqual(pin["MERMAID_VERSION"], "2.0.0")
        self.assertEqual(pin["MERMAID_SHA256"], hashlib.sha256(b"runtime two").hexdigest())

    def test_the_pinned_release_is_installed_when_it_matches(self):
        self.write_pin("2.0.0", hashlib.sha256(b"runtime two").hexdigest())
        self.publish("2.0.0", b"runtime two")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.target.read_bytes(), b"runtime two")

    def test_a_tarball_unlike_the_registrys_integrity_is_refused(self):
        self.write_pin("1.0.0", "0" * 64)
        before = self.pin.read_text()
        self.publish("2.0.0", b"runtime two", integrity="sha512-" + base64.b64encode(b"x" * 64).decode())
        result = self.run_script("2.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("the registry publishes", result.stderr)
        self.assertEqual(self.target.read_bytes(), b"old runtime", "a refused release must not be installed")
        self.assertEqual(self.pin.read_text(), before, "a refused release must not be pinned")

    def test_the_pinned_release_is_refused_when_its_file_is_not_the_pinned_one(self):
        self.write_pin("2.0.0", "0" * 64)
        self.publish("2.0.0", b"runtime two")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("scripts/mermaid.pin pins", result.stderr)
        self.assertEqual(self.target.read_bytes(), b"old runtime")

    def test_a_release_without_sha512_integrity_is_refused(self):
        self.write_pin("1.0.0", "0" * 64)
        self.publish("2.0.0", b"runtime two", integrity="")
        meta = self.registry / "mermaid" / "2.0.0"
        release = json.loads(meta.read_text())
        del release["dist"]["integrity"]
        meta.write_text(json.dumps(release))
        result = self.run_script("2.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no sha512 integrity", result.stderr)
        self.assertEqual(self.target.read_bytes(), b"old runtime")

    def test_a_version_that_is_not_a_release_is_refused(self):
        self.write_pin("1.0.0", "0" * 64)
        result = self.run_script("latest")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a release version", result.stderr)


if __name__ == "__main__":
    unittest.main()
