#!/usr/bin/env python3
"""`changelog-section.py`'s suite. Runs under `make version-test` with the rest."""

import contextlib
import importlib.util
import io
import pathlib
import tempfile
import unittest

# The module has a hyphen in its name, which `import` cannot spell.
_spec = importlib.util.spec_from_file_location(
    "changelog_section", pathlib.Path(__file__).parent / "changelog-section.py"
)
changelog_section = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(changelog_section)

section = changelog_section.section

# Newest release first, and 0.1.10 sits in it on purpose: it is the version a
# prefix match confuses with 0.1.1.
CHANGELOG = """# Changelog

Written by `make version`, which reads the commits since the last tag.

## 0.2.0 — 2026-08-20

### Added

- a thing the preview gained
- another thing

### Fixed

- a thing that was wrong

## 0.1.10 — 2026-08-19

### Fixed

- the tenth patch on the first minor

## 0.1.0 — 2026-08-10

The first numbered build.
"""

# A release whose notes quote a changelog heading, which is the one place a
# `## ` line legitimately appears inside a section.
FENCED = """# Changelog

## 0.3.0 — 2026-08-21

### Changed

- the notes now quote a heading:

```markdown
## 0.2.0 — 2026-08-20
```

- an entry below the fence

## 0.2.0 — 2026-08-20

- the real 0.2.0
"""

# The same quoted heading behind CommonMark's other fence character, with a ```
# block inside it: a fence closes only on the character it opened with, so
# neither inner line ends the ~~~ block.
TILDE_FENCED = """# Changelog

## 0.3.0 — 2026-08-21

### Changed

- the notes now quote a heading:

~~~markdown
## 0.2.0 — 2026-08-20

```swift
let v = 1
```
~~~

- an entry below the fence

## 0.2.0 — 2026-08-20

- the real 0.2.0
"""

# A four-backtick block quoting a fence opener — how a release note shows what
# a fence looks like. The inner run is the shorter one, so it closes nothing.
NESTED_FENCED = """# Changelog

## 0.3.0 — 2026-08-21

### Changed

- the notes now quote a fence opener:

````markdown
```swift
````

- an entry below the fence

## 0.2.0 — 2026-08-20

- the real 0.2.0
"""


class SectionTests(unittest.TestCase):
    def test_it_takes_the_named_version(self):
        body = section(CHANGELOG, "0.2.0")
        self.assertIn("a thing the preview gained", body)
        self.assertIn("a thing that was wrong", body)

    def test_it_stops_at_the_next_release(self):
        body = section(CHANGELOG, "0.2.0")
        self.assertNotIn(
            "the tenth patch on the first minor",
            body,
            "the 0.2.0 section ran into the release below it",
        )
        self.assertNotIn("The first numbered build", body)

    def test_the_oldest_release_runs_to_the_end_of_the_file(self):
        """Nothing follows it, so the section ends where the file does rather
        than at a `## ` that is never reached."""
        self.assertEqual(section(CHANGELOG, "0.1.0"), "The first numbered build.\n")

    def test_it_drops_the_heading_itself(self):
        self.assertNotIn("## 0.2.0", section(CHANGELOG, "0.2.0"))

    def test_the_preamble_is_never_returned(self):
        self.assertNotIn("Written by", section(CHANGELOG, "0.1.0"))

    def test_the_body_is_trimmed_and_newline_terminated(self):
        """`gh release create --notes-file` prints the file as it stands, so a
        leading blank line is a blank line at the top of the release page."""
        body = section(CHANGELOG, "0.2.0")
        self.assertTrue(body.startswith("### Added"))
        self.assertTrue(body.endswith("wrong\n"))

    def test_a_missing_release_is_an_error_and_not_an_empty_string(self):
        """The failure this exists for: an empty body publishes a release with
        no notes, and nothing says so until somebody reads the page."""
        with self.assertRaises(LookupError) as raised:
            section(CHANGELOG, "9.9.9")
        self.assertIn("9.9.9", str(raised.exception))

    def test_an_empty_section_is_an_error_and_not_a_bare_newline(self):
        """A heading with the next release right under it: found, but with
        nothing to publish. Returning "\\n" here hands `gh release create
        --notes-file` an empty release body."""
        with self.assertRaises(LookupError) as raised:
            section("## 0.2.0 — a\n## 0.1.0 — b\n\n- two\n", "0.2.0")
        message = str(raised.exception)
        self.assertIn("0.2.0", message)
        self.assertIn("nothing under it", message)

    def test_a_whitespace_only_section_is_an_error(self):
        """Blank lines and stray indentation are as empty as no lines at all."""
        with self.assertRaises(LookupError):
            section("## 0.2.0 — a\n\n   \n\n## 0.1.0 — b\n\n- two\n", "0.2.0")

    def test_an_empty_last_section_is_an_error(self):
        """The end-of-file path has to refuse an empty body too."""
        with self.assertRaises(LookupError):
            section("# Changelog\n\n## 0.1.0 — a\n\n", "0.1.0")

    def test_a_version_is_not_matched_by_prefix(self):
        """`0.2.0` must not be found by asking for `0.2`."""
        with self.assertRaises(LookupError):
            section(CHANGELOG, "0.2")

    def test_a_double_digit_patch_is_not_matched_by_its_prefix(self):
        """`0.1.1` and `0.1.10` are different releases. Matching on the prefix
        would publish the wrong one's notes under the right one's tag."""
        with self.assertRaises(LookupError):
            section(CHANGELOG, "0.1.1")
        self.assertNotIn("tenth patch", section(CHANGELOG, "0.1.0"))
        self.assertIn("tenth patch", section(CHANGELOG, "0.1.10"))

    def test_a_heading_without_a_date_still_matches(self):
        """The date is `make version`'s stamp; a heading edited by hand may have
        none, and the release notes are still there to publish."""
        dateless = CHANGELOG.replace("## 0.2.0 — 2026-08-20", "## 0.2.0")
        self.assertIn("a thing the preview gained", section(dateless, "0.2.0"))

    def test_a_fenced_heading_does_not_end_the_section(self):
        """Ending at the quoted `## ` drops every entry below it and ships a
        release body whose fence is never closed."""
        body = section(FENCED, "0.3.0")
        self.assertIn("an entry below the fence", body)
        self.assertEqual(body.count("```"), 2, "the fence was cut in half")
        self.assertNotIn("the real 0.2.0", body)

    def test_a_fenced_heading_is_not_taken_for_the_section_itself(self):
        """The quoted `## 0.2.0` sits above the real one; matching it would
        publish 0.3.0's notes as 0.2.0's."""
        self.assertEqual(section(FENCED, "0.2.0"), "- the real 0.2.0\n")

    def test_a_tilde_fence_hides_a_heading_the_same_way_backticks_do(self):
        """`~~~` is CommonMark's other fence character. Unknown to the reader,
        the heading quoted inside one is read as the end of the section: the
        entries below it are dropped and `gh` gets an unclosed fence."""
        body = section(TILDE_FENCED, "0.3.0")
        self.assertIn("an entry below the fence", body)
        self.assertEqual(body.count("~~~"), 2, "the fence was cut in half")
        self.assertNotIn("the real 0.2.0", body)
        self.assertEqual(section(TILDE_FENCED, "0.2.0"), "- the real 0.2.0\n")

    def test_a_backtick_fence_does_not_close_a_tilde_one(self):
        """The ``` block quoted inside the ~~~ block. Closing on the wrong
        character reopens the section mid-quote, and the `## ` above it becomes
        a boundary after all."""
        body = section(TILDE_FENCED, "0.3.0")
        self.assertEqual(body.count("```"), 2)
        self.assertIn("let v = 1", body)

    def test_a_shorter_inner_fence_neither_closes_nor_reopens_the_block(self):
        """A ```` ```` ```` block quoting a ``` fence. Toggling on any marker
        leaves the state inverted past the block's end, so the next `## ` stops
        being a boundary and 0.3.0's notes swallow the release below them."""
        body = section(NESTED_FENCED, "0.3.0")
        self.assertIn("an entry below the fence", body)
        self.assertNotIn("the real 0.2.0", body)
        self.assertEqual(section(NESTED_FENCED, "0.2.0"), "- the real 0.2.0\n")

    def test_the_error_names_the_file_that_was_read(self):
        """With `--changelog` in play, "CHANGELOG.md" points at the wrong file
        and the reader edits a file that was never opened."""
        for version in ("9.9.9", "0.2.0"):
            with self.subTest(version=version):
                with self.assertRaises(LookupError) as raised:
                    section("## 0.2.0 — a\n", version, source="docs/other.md")
                self.assertIn("docs/other.md", str(raised.exception))
                self.assertNotIn("CHANGELOG.md", str(raised.exception))


class CommandLineTests(unittest.TestCase):
    def test_it_reports_the_changelog_it_was_pointed_at(self):
        with tempfile.TemporaryDirectory() as tmp:
            other = pathlib.Path(tmp) / "other.md"
            other.write_text("## 0.1.0 — a\n\n- one\n")
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                code = changelog_section.main(
                    ["--version", "9.9.9", "--changelog", str(other)]
                )
        self.assertEqual(code, 1)
        self.assertIn(str(other), stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
