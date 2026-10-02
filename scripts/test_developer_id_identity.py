"""scripts/developer-id-identity.sh against a keychain that is not the Mac's.

    python3 -m unittest discover -s scripts -p 'test_*.py'

The script asks `security` which identities are valid and reads each one's certificate
with `openssl`. Here `security` is a stub on PATH that lists throwaway certificates made
for the run: fictional people and teams, issued by two stand-in authorities that carry
the real ones' names, "Developer ID Certification Authority" with OU "Apple Certification
Authority" (expires 2027-02-01) and with OU "G2". Nothing reads or writes a real keychain.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "developer-id-identity.sh"

PREVIOUS = "Apple Certification Authority"
G2 = "G2"
TEAM = "TEAM123456"
OTHER_TEAM = "OTHER67890"

FAKE_SECURITY = """#!/bin/sh
case "$1" in
find-identity) cat "$FAKE_KEYCHAIN/identities" ;;
find-certificate) cat "$FAKE_KEYCHAIN/certificates" ;;
*) echo "fake security: unexpected arguments: $*" >&2; exit 2 ;;
esac
"""


def openssl(*arguments, cwd):
    return subprocess.run(
        ["openssl", *arguments], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout


class Certificate:
    def __init__(self, name, sha1, pem):
        self.name = name
        self.sha1 = sha1
        self.pem = pem


class DeveloperIDIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.work = Path(cls._tmp.name)
        cls.bin = cls.work / "bin"
        cls.bin.mkdir()
        security = cls.bin / "security"
        security.write_text(FAKE_SECURITY)
        security.chmod(0o755)
        for unit in (PREVIOUS, G2):
            openssl(
                "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
                "-subj", f"/CN=Developer ID Certification Authority/OU={unit}/O=Apple Inc./C=US",
                "-keyout", f"{unit}.key", "-out", f"{unit}.pem",
                cwd=cls.work,
            )
        cls.serial = 0

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    @classmethod
    def issue(cls, authority, days, team=TEAM, kind="Developer ID Application", person="Ada Example"):
        cls.serial += 1
        stem = f"leaf-{cls.serial}"
        common_name = f"{kind}: {person} ({team})"
        openssl(
            "req", "-new", "-newkey", "rsa:2048", "-nodes",
            "-subj", f"/UID={team}/CN={common_name}/OU={team}/O={person}/C=US",
            "-keyout", f"{stem}.key", "-out", f"{stem}.csr",
            cwd=cls.work,
        )
        openssl(
            "x509", "-req", "-in", f"{stem}.csr", "-CA", f"{authority}.pem",
            "-CAkey", f"{authority}.key", "-set_serial", str(cls.serial),
            "-days", str(days), "-out", f"{stem}.pem",
            cwd=cls.work,
        )
        fingerprint = openssl("x509", "-in", f"{stem}.pem", "-noout", "-fingerprint", "-sha1", cwd=cls.work)
        sha1 = fingerprint.strip().split("=", 1)[1].replace(":", "")
        return Certificate(common_name, sha1, (cls.work / f"{stem}.pem").read_text())

    def choose(self, valid, team=None, in_keychain=None):
        """Run the script with `valid` as the valid identities; `in_keychain` are the
        certificates `security find-certificate` can produce (default: the same)."""
        keychain = Path(tempfile.mkdtemp(dir=self.work))
        lines = [f'  {n}) {c.sha1} "{c.name}"' for n, c in enumerate(valid, 1)]
        lines.append(f"     {len(valid)} valid identities found")
        (keychain / "identities").write_text("\n".join(lines) + "\n")
        held = valid if in_keychain is None else in_keychain
        (keychain / "certificates").write_text(
            "".join(f"SHA-256 hash: {'0' * 64}\nSHA-1 hash: {c.sha1}\n{c.pem}" for c in held)
        )
        environment = dict(os.environ, FAKE_KEYCHAIN=str(keychain))
        environment["PATH"] = f"{self.bin}:{environment['PATH']}"
        return subprocess.run(
            [str(SCRIPT)] + ([team] if team else []),
            env=environment, capture_output=True, text=True,
        )

    def chosen(self, valid, **options):
        result = self.choose(valid, **options)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(len(lines), 1, result.stdout)
        sha1, team, authority, expires, name = lines[0].split("\t")
        self.assertRegex(expires, r"^\d{4}-\d{2}-\d{2}$")
        return {"sha1": sha1, "team": team, "authority": authority, "name": name}

    def test_no_developer_id_identity_prints_nothing(self):
        development = self.issue(G2, 300, kind="Apple Development")
        result = self.choose([development])
        self.assertEqual((result.returncode, result.stdout), (0, ""), result.stderr)

    def test_the_only_identity_is_chosen_whatever_issued_it(self):
        previous = self.issue(PREVIOUS, 120)
        self.assertEqual(
            self.chosen([previous]),
            {"sha1": previous.sha1, "team": TEAM, "authority": PREVIOUS, "name": previous.name},
        )

    def test_g2_is_chosen_over_the_previous_authority_even_when_it_expires_first(self):
        previous = self.issue(PREVIOUS, 400)
        g2 = self.issue(G2, 100)
        for order in ([previous, g2], [g2, previous]):
            choice = self.chosen(order)
            self.assertEqual((choice["sha1"], choice["authority"]), (g2.sha1, G2))

    def test_of_two_g2_certificates_the_later_expiry_is_chosen(self):
        expiring = self.issue(G2, 20)
        renewed = self.issue(G2, 365)
        for order in ([expiring, renewed], [renewed, expiring]):
            self.assertEqual(self.chosen(order)["sha1"], renewed.sha1)

    def test_a_team_filter_ignores_another_teams_identity(self):
        ours = self.issue(PREVIOUS, 120)
        theirs = self.issue(G2, 365, team=OTHER_TEAM, person="Bo Sample")
        choice = self.chosen([theirs, ours], team=TEAM)
        self.assertEqual((choice["sha1"], choice["team"]), (ours.sha1, TEAM))
        result = self.choose([theirs], team=TEAM)
        self.assertEqual((result.returncode, result.stdout), (0, ""), result.stderr)

    def test_identities_of_two_teams_without_a_filter_are_refused(self):
        ours = self.issue(G2, 365)
        theirs = self.issue(G2, 365, team=OTHER_TEAM, person="Bo Sample")
        result = self.choose([ours, theirs])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn(TEAM, result.stderr)
        self.assertIn(OTHER_TEAM, result.stderr)

    def test_a_certificate_that_is_no_longer_valid_is_never_chosen(self):
        # Still in the keychain, so find-certificate lists it; find-identity -v does not.
        lapsed = self.issue(G2, 900)
        previous = self.issue(PREVIOUS, 120)
        choice = self.chosen([previous], in_keychain=[lapsed, previous])
        self.assertEqual(choice["sha1"], previous.sha1)

    def test_an_identity_whose_certificate_cannot_be_read_is_an_error(self):
        listed = self.issue(G2, 365)
        result = self.choose([listed], in_keychain=[])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn(listed.sha1, result.stderr)


if __name__ == "__main__":
    unittest.main()
