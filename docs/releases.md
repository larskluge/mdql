# Cutting a release

One app ships out of this tree, and five commands are the whole process — three
make targets, with the review and the push in between. There is no release
workflow and no update mechanism: a release is a zip on the GitHub releases page,
and everything that produces it runs on this Mac.

```bash
make version                          # bump, changelog, commit, tag — all local
git show                              # the review
git push origin main --follow-tags    # main, and the annotated tag rides along
make dist                             # build, sign, notarize, staple, zip
make release                          # publish it
```

`--follow-tags` carries annotated tags and silently skips lightweight ones, which
is why `make version` writes `git tag -a`. With a lightweight tag that push would
exit 0 with the tag still sitting local, and `make release` would refuse a step
later with "not on origin", pointing back at a push that looked like it worked.

## The first release

`v0.1.0` was tagged by hand, and had to be. `make version` only ever moves the
version *forward* — it reads the number the project declares and bumps it — so no
run of it can produce the number already in the pbxproj. The bootstrap is one tag
on the commit that lands this tooling, and then the ordinary steps:

```bash
git tag -a v0.1.0 -m 0.1.0            # on the commit that adds versioning
git push origin main --follow-tags
make dist
make release
```

`CHANGELOG.md`'s 0.1.0 section is hand-written for the same reason. Its *heading*
is the shape every generated release uses — `## 0.1.0 — 2026-08-20`, the same
line `render_release` would have written, down to the em dash — so the file reads
as one sequence rather than a hand-written entry followed by machine-written
ones, and `scripts/changelog-section.py` finds it the way it finds any other. Its
*body* is not, and cannot be: `render_release` emits a heading with `###` groups
under it, or a heading with the one sentence a deliberately empty release gets,
and never a paragraph of prose above the groups — which is what a bootstrap note
is. This happens exactly once: with `v0.1.0` in place there is a tag to read the
commits from, and every release after it goes through `make version`.

## The bump

```bash
make version-dry     # what it would do
make version         # do it
```

It reads every non-merge commit since the last `v*` tag — every non-merge commit
in the repository, the first time — and takes one thing from each: what kind of
change it is, from the subject prefix. The log is `--no-merges` because
`Merge pull request #14 from …` carries no prefix: left in, it lands in the
changelog as an **Other** entry, and it can lift a batch that was all `docs` and
`chore` out of "nothing to release" into a release with nothing behind it. The
build number is the one count that does include merges; see *Where the number
lives*.

| | |
|---|---|
| `feat` | a minor, listed under **Added** |
| `fix`, `perf` | a patch, under **Fixed** |
| `refactor`, `chore`, `build`, `test`, `docs`, `ci`, `style` | nothing; left out of the changelog entirely |
| `!` on the type, or a `BREAKING CHANGE:` footer | a major, under **Changed** |
| anything else | a patch, under **Other** |

That last row is not a corner case here. 21 of the 69 commits behind 0.1.0 carry
a conventional prefix and 48 are plain sentences, so **Other** is where most of
a release's history lands — which is the point of the rule. A subject nobody
prefixed is still a change somebody made, and dropping it would leave the
changelog describing a third of the work.

The bump is the highest level in the batch, so one `feat` makes the whole batch
a minor. A batch of only fixes is a patch, and a batch of only `docs` and `ci`
is **no release at all** — it says so and writes nothing.

### Forcing a level

```bash
make version VERSION_ARGS='--level major'
```

`--level` takes `major`, `minor`, `patch` or `none` and overrides whatever the
commits said. The only major a batch infers for itself is one a commit *declared*
— `!` on the type, or a `BREAKING CHANGE:` footer, the row in the table above.
**Nothing else is ever read as a major**, so the 1.0 that follows a long run of
`feat`s is a thing you type.
`--level patch` on a batch that classifies as nothing is the other use: a
deliberate throwaway release, which is how the signing and notarization path
gets exercised end to end without waiting for real work. Its changelog section
says it was cut deliberately, so the number that moved for no listed reason is
not a mystery later.

### What it writes, and how to undo it

`mdql.xcodeproj/project.pbxproj` (both project-level settings) and
`CHANGELOG.md` — then one commit, `chore(release): 0.2.0`, and one annotated tag,
`v0.2.0`.

**It pushes nothing.** Automatic and unreviewed are not the same thing: the run
stops at a local commit, so `git show` is a review of something that has gone
nowhere, and the changelog it wrote *is* the evidence — every commit listed under
the heading it was classified into. A miscall is visible there, and the remedy is

```bash
git reset --hard HEAD~1 && git tag -d v0.2.0
```

Both halves matter, and skipping the `git tag -d` half is quiet rather than
loud: `v0.2.0` is left pointing at a commit on no branch, `v0.2.0..HEAD` reads as
no commits at all, and every later run would report "nothing to release (0.1.0
stands)" and exit 0. The next `make version` refuses instead — it names both
numbers, says a skipped `git tag -d` is the likely cause, and prints the command
— but that refusal is the second line of defence, not the plan.

It refuses to run when `git status` reports `project.pbxproj` or `CHANGELOG.md` as
modified, staged **or untracked**, and it names which: an untracked `CHANGELOG.md`
is not an edit anybody made, so calling it one sends the reader hunting for a
change that does not exist — while `git add` would sweep the whole file into the
release commit just the same. It stages *and commits* by explicit pathspec rather
than `git add -A`: `~/code/mdql` is a shared checkout worked in by more than one
session, and a release commit must not sweep up somebody else's work in progress.
Staging alone was not enough — a bare `git commit -m …` commits the whole index,
so whatever another session had staged rode along and the tag pointed at it. The
pathspec on the commit, which is `--only` semantics, is what holds it to those
two files.

It also refuses a tag name that already exists, before writing anything: a
release commit that failed to get its tag is one nothing downstream — `make
dist`, `make release`, the changelog's own numbering — can find. That refusal and
the stale-tag one both fire under `--dry-run` too, so `make version-dry` is not
always exit 0. It is the honest answer: a dry run that printed a plan the real
run would then refuse is worse than no dry run.

## Where the number lives

Two build settings, `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, declared
at **project** level — in the two configurations of the build configuration list
belonging to the `mdql` project — so all five targets inherit one number and
none of them declares its own. The three bundles that ship inside `mdql.app`
each pick it up the same way: `mdql/Info.plist`, `mdqlPreview/Info.plist` and
`mdql-open-url/Info.plist` all give `CFBundleShortVersionString` as
`$(MARKETING_VERSION)` and `CFBundleVersion` as `$(CURRENT_PROJECT_VERSION)`.

Project level is not tidiness. **macOS refuses to load an app extension whose
`CFBundleVersion` disagrees with its containing app's**, and mdql ships two
pieces of nested code inside the app — `mdqlPreview.appex`, and the
`com.mdql.app.open-url.xpc` service inside that. A target-level override on any
one of them lets the three numbers drift apart, and everything stays green while
it happens: the project builds, the tests pass, and the preview stops appearing
on the machine it is installed on.

So `scripts/version.py` refuses to run when the shape breaks — a third
occurrence of either setting, only one, or two that disagree — and each refusal
names the file, the lines, and what would have shipped. CI runs that check on
every push and pull request: `make version-test` is `.github/workflows/ci.yml`'s
first step, and it carries `test_the_repositorys_own_pbxproj_is_sound`, which
reads this repository's actual pbxproj rather than a fixture. A change that adds
a target-level override fails there in milliseconds, rather than at the next
release.

`mdql.xcodeproj` is hand-maintained. There is no `project.yml` and no xcodegen in
this repository, so the pbxproj *is* the source and `make version` edits it in
place, rewriting four values and nothing else.

The build number is `git rev-list --count HEAD` at bump time — every commit,
merges included, which is where it parts company with the changelog's
`--no-merges` log. It becomes `CFBundleVersion`, and macOS reads a build number
that went down as a downgrade, so the count that never drops is the right one to
write. It only moves when the version moves.

`make print-version` prints what the tree currently declares — the same read
`make dist` uses to name the zip, so the artifact cannot disagree with the app
inside it. That read takes every *distinct* `MARKETING_VERSION` in the pbxproj,
not the first one, and `check-version` — a prerequisite of `print-version`,
`dist` and `release` alike — refuses anything but exactly one, listing what it
found. The first match is Debug's while every release is built from Release, so
reading one value would hide the case worth reporting: a zip named
`mdql-0.1.0.zip` holding an app that calls itself something else.
`scripts/version.py` refuses that shape too, but it does not run anywhere on the
dist path.

The preview extension also bundles a `version.txt`, written by the
`Generate version.txt` build phase on every single build — it is
`alwaysOutOfDate` — and stamped `0.1.0 (a1b2c3d)`, or `…-dirty` when the tree had
uncommitted changes. `MarkdownRenderer` draws it in the corner of every preview,
which is how to tell which build is the one Finder is actually running, and
`make release` reads it back out of the zip, which is the only thing tying a
published artifact to the commit it was built from.

`make version-test` is the bump tool's own suite — `scripts/test_version.py` and
`scripts/test_changelog_section.py`, stdlib `unittest`, no pytest to install. It
runs first in `make test`, and first in CI, because it needs nothing and takes
milliseconds: a broken bump tool should not be discovered after a long
`xcodebuild`.

## The build to hand to someone else

```bash
make dist
```

Release build into `build/mdql`, signed by `scripts/codesign-app.sh`, notarized
and stapled by `scripts/notarize-app.sh`, out as
`build/dist/mdql-<version>.zip`. Three things about it are worth knowing before
the first run.

**It refuses a dirty tree.** The `Generate version.txt` build phase writes
`${MARKETING_VERSION} (${HASH}${DIRTY})` into the extension's resources and
`MarkdownRenderer` draws it in the corner of every preview, so a build made over
uncommitted changes ships a badge reading `0.1.0 (a1b2c3d-dirty)` to everyone who
downloads it. `make release`'s own clean-tree check cannot stand in for this one:
it sees the tree whenever it happens to run, not the tree the zip was built from
— edit, `make dist`, `git checkout .`, and every refusal there passes on a
notarized build of code that is in no commit. So `make dist` asks first, and
prints the files in the way. Both of its guards are prerequisites, listed ahead
of the build so that neither answer costs a build to learn, and the Makefile is
`.NOTPARALLEL:` so that ordering survives `make -j`: without it, `-j4` starts the
Release build alongside `check-clean` and spends the whole build before the
dirty-tree refusal aborts the run.

**Signing is not one decision.** mdql.app holds three Mach-O items and each
takes a different answer:

| | |
|---|---|
| `Contents/MacOS/mdql` | `mdql/mdql.entitlements` — an empty `<dict/>`; the host app is deliberately unsandboxed |
| `…/PlugIns/mdqlPreview.appex` | `mdqlPreview/mdqlPreview.entitlements` — sandboxed, with `com.apple.security.network.client`, without which WKWebView renders a **blank** preview inside the sandbox |
| `…/mdqlPreview.appex/Contents/XPCServices/com.mdql.app.open-url.xpc` | none, deliberately — it is unsandboxed because it exists to do what the sandboxed extension cannot: call `NSWorkspace.open` and read sibling `.md` files |

Signing all three with the app's entitlements, or all three with none, produces
a bundle that signs, verifies and notarizes cleanly and is broken in the user's
hands. Nothing downstream looks at entitlements, so `codesign-app.sh` reads them
back out of the finished signature and fails if the appex lost its sandbox or
network access, or if the XPC service gained any entitlement at all.

**The build must not install itself.** The `Install & Register QuickLook
Extension` build phase copies the built app to `/Applications` and re-signs the
copy ad-hoc, which would replace the Developer ID signature on the very thing
being shipped. `make build-release` sets `CI=true`, the escape hatch that phase
already reads, so a dist build never touches `/Applications`. `make install` is
the target that installs, and it deliberately keeps its own path.

### What it needs, once

A **Developer ID Application** certificate for team `GUGQ9MB76A`. Xcode →
Settings → Accounts → the `GUGQ9MB76A` team → Manage Certificates → + →
*Developer ID Application*. `codesign-app.sh` falls back to an *Apple
Development* certificate when there is none, which is fine for a build that
never leaves this Mac and which Apple's notary will refuse — it says so rather
than letting the failure arrive ten minutes into an upload.

Both candidates are filtered by team: the script reads each certificate's `OU`,
which is the field `codesign` reports back as `TeamIdentifier`, and takes only
`GUGQ9MB76A`'s. A Mac carrying somebody else's Developer ID therefore gets a
refusal naming the team rather than a bundle signed by the wrong authority, and
two identities on the same team are an error listing both — `codesign` cannot be
handed an ambiguous identity name.

A **notarytool keychain profile**:

```bash
xcrun notarytool store-credentials mdql-notary \
  --apple-id <apple-id> --team-id GUGQ9MB76A
```

A notary profile is a team credential, not a per-app one, so a Mac that already
notarizes something else for `GUGQ9MB76A` needs no second profile — point
`make dist` at the existing one with `NOTARY_PROFILE=<name> make dist`.

### Why notarization is not optional

This app is *downloaded*. macOS attaches a quarantine flag to anything that
arrives that way, and a quarantined bundle Apple has not notarized is refused
with a dialog whose only way forward is a right-click-Open workaround that
ordinary people do not find. Notarization removes the dialog; stapling the
ticket into the bundle is what keeps it removed on a Mac that is offline.

So `notarize-app.sh` zips *after* stapling, and then verifies the claim it makes:
it unpacks the zip that is actually being shipped, sets the quarantine flag a
download would set, and runs `stapler validate` and Gatekeeper against that copy
— not against the build directory, where Gatekeeper would wave it through for
being local.

The zip reaches `build/dist/mdql-<version>.zip` only after those checks pass, by
one `mv`. Written first and checked afterwards, a rejected build would be sitting
at the published name for `make release` to find; a failed run leaves nothing
there instead, including whatever an earlier run left. The wait on Apple is
bounded at 30 minutes — when that fires, the submission keeps processing on
Apple's side and the run fails with the submission ID, so the log can still be
fetched.

## Publishing

```bash
make release
```

`gh release create v<version> --repo larskluge/mdql`, with the zip and a body
in two parts: this version's `CHANGELOG.md` section — the section
`scripts/changelog-section.py` pulls out, so the release notes and the changelog
cannot describe the same release in two different voices — and, appended under a
rule, a fixed **Install** stanza: download, drag to `/Applications`, **launch it
once**, press Space. The Makefile appends it rather than `CHANGELOG.md` carrying
it, because the changelog says what changed and this is boilerplate for a
download page; repeated per section it would be four identical paragraphs in the
file by 0.5.0. The release page is where it earns its place — somebody standing
in front of the zip is one drag away from the step both `README.md` and this
document single out as the one people miss.

It refuses unless all of these hold, checked cheapest first so that the
commonest mistake — having forgotten `make dist` — is not reported after a round
trip to `origin`: the version is exactly one, the zip exists, the tag exists, the
tag points at `HEAD`, `HEAD` is on `main`, the working tree is clean, **`origin`
is `larskluge/mdql`**, **the zip is the build being released and was built from
the tagged commit**, and **the tag is already on `origin`**. A published release
is not reversible for anybody who has already downloaded it, which is why all of
it fails before `gh` is called rather than after.

`origin` is checked because two of these steps mean "this repository" in
different ways: the tag check asks `origin`, while `gh` is given
`--repo larskluge/mdql` and never consults `origin` at all. On a fork's clone the
tag would be validated on the fork and the release then created on
`larskluge/mdql`'s default-branch HEAD — the exact failure the tag check exists to
prevent, and invisible to it. The check normalises `git remote get-url origin`,
so all three spellings (`git@github.com:…`, `https://…`, `ssh://…`) pass, and it
runs with the cheap git reads: a clone that could never publish is told so before
a build gets unpacked and assessed.

The zip check opens the artifact rather than trusting its name. Everything above
it reasons about the *tree*; nothing there looks inside the file being uploaded,
and that file is whatever was left at the path — possibly days old, possibly from
a `make dist` that failed halfway, possibly not a zip at all. So it is unpacked
into a temporary directory and made to prove the five things this whole path
exists to give a downloader: one `mdql.app` and nothing beside it, whose
`CFBundleShortVersionString` is the version being released, built from the tagged
commit, carrying a stapled notarization ticket, and accepted by Gatekeeper as an
install.

Built from the tagged commit is the one of those the tree cannot answer, and the
one everything else quietly assumes. `make dist`, `git reset --hard <older tag>`,
`make release` satisfies every refusal above — tag is `HEAD`, branch is `main`,
tree is clean, the app calls itself the right version — and publishes a build of
a commit that is not the tag. The evidence is inside the bundle: the
`Generate version.txt` build phase writes `${MARKETING_VERSION} (${HASH}${DIRTY})`
into the extension's resources on every build, so the artifact carries the commit
it was made from. `make release` reads
`mdql.app/Contents/PlugIns/mdqlPreview.appex/Contents/Resources/version.txt` out
of the unpacked bundle, resolves that hash, and requires it to be
`v<version>^{commit}`. A `-dirty` stamp is refused with it: `check-clean` saw the
tree whenever `make dist` ran, this sees the tree the build actually read.

The tag on `origin` is not bookkeeping either: `gh release create` creates a tag
it cannot find on the remote, placing it on the remote default branch's HEAD. An
unpushed tag would therefore publish a release of whatever else is on
`origin/main` under the right name, and the mistake is only visible to whoever
downloads it. The check asks `origin` for both `<tag>` and `<tag>^{}` and
compares the commit, so it answers alike for an annotated tag and a lightweight
one.

## Why there is no release CI

Two workflows run on this repository, and neither of them releases.

`.github/workflows/ci.yml`, on every push to `main` and every pull request, runs
three steps in this order:

1. **Test the version tooling** — `make version-test`, first because it needs
   nothing installed and takes milliseconds.
2. **Build** —
   `xcodebuild build -project mdql.xcodeproj -scheme mdql -destination "platform=macOS"`.
3. **Run tests** — `make test`, which is `version-test` again in milliseconds and
   then `xcodebuild … -scheme mdql … test`.

The third step calls the Makefile's own target rather than repeating the
`xcodebuild` line, because the repeated copy did not survive contact with this
repository: it named `-scheme mdqlTests`, which is a *target*, and the only scheme
that runs the suite is `mdql`. That error was invisible, because both steps used
to end in `| xcpretty || xcodebuild …` — a pipeline exits with its *last*
command's status, and `xcpretty` exits 0 on any log it can read, so the step was
green whatever `xcodebuild` said, and the `||` fallback never ran either. The
Xcode suite therefore ran on no push and no pull request while every run reported
success. Nothing is piped now; `xcodebuild`'s own exit status is the step's, and a
single entry point cannot drift from itself.

`.github/workflows/pr-preview.yml`, on every pull request to `main`, builds the
`mdql-screenshot` target, renders `mdqlTests/Fixtures/front-matter.md` to a PNG,
commits it to the PR branch — which is what its `contents: write` permission is
for — and posts it as a PR comment. It publishes a screenshot, not a release.

Everything above could run in a GitHub Actions job on a macOS runner, and does
not, on purpose. It would need these, and every one of them is created by a
human and pasted in by hand:

| Secret | Where it comes from |
|---|---|
| the Developer ID certificate | Keychain Access → export the *Developer ID Application* identity **with its private key** → base64 the `.p12` |
| its export password | the password given to that export |
| the notary API key | App Store Connect → Users and Access → Integrations → Keys, role **Developer ID** → base64 the `.p8` |
| its key ID and issuer ID | shown beside that key |

`scripts/notarize-app.sh` already accepts that key trio as `NOTARY_KEY`,
`NOTARY_KEY_ID` and `NOTARY_ISSUER`, so the workflow would be short. It is still
not here: a workflow nobody has given credentials to is scaffolding that looks
like a pipeline, and it fails on the one day somebody depends on it. The make
targets are the process. Add the workflow when the secrets exist, not before.

## What the person who downloads it does

Unzip, drag `mdql.app` to `/Applications`, and **launch it once** — pluginkit
only discovers the extension when its host app has been opened, so a bundle
copied in and never launched previews nothing. Then press Space on any `.md`
file in Finder. Those four steps are the **Install** stanza `make release`
appends to every release body, so the person downloading the zip reads them
without having to find this file.
