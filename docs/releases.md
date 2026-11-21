# Versions and releases

mdql's version is never bumped and never stored: every build computes it from
git history, so whatever gets installed already shows the right number. A
*release* — a notarized zip on the GitHub releases page — is a separate thing,
cut only when Lars asks for one. There is no release workflow and no update
mechanism; everything that produces a release runs on this Mac:

```bash
make release-tag-dry                  # the CHANGELOG section and tag it would write
make release-tag                      # write them: one commit, one annotated tag — local only
git push origin main --follow-tags    # main, and the annotated tag rides along
make dist                             # build, sign, notarize, staple, zip
make release                          # publish it
```

## The version

`python3 scripts/version.py` prints it, `--build` the build number, and
`--explain` how history reads: the baseline, then each commit with the version
it leaves behind.

- **Baseline:** the highest `vX.Y.Z` tag reachable from `HEAD` — highest by
  version, so `v0.10.0` beats `v0.9.0`, and a tag on a branch never merged is no
  baseline. A tag that names no version (`vNightly`, `v0.3.0-rc1`) is skipped.
- **After it,** each non-merge commit, oldest first, by its subject prefix:

  | | |
  |---|---|
  | `feat` | bumps the minor and zeroes the patch |
  | `fix`, `perf` | bumps the patch |
  | an unprefixed subject, or a type not listed here | bumps the patch: it is still a change somebody made |
  | `chore`, `docs`, `ci`, `test`, `build`, `refactor`, `style` | nothing |

  Order matters: on 0.2.6, `feat` then `fix` reads 0.3.1, and `fix` then `feat`
  reads 0.3.0. Merge commits are skipped: `Merge pull request #14 from …` carries
  no prefix and would add a patch on top of the commits it brings in, which are
  counted already.
- **The major** comes only from a tag Lars asks for: "make it 1.0" → an agent
  puts `git tag -a v1.0.0 -m 1.0.0` on `main`'s HEAD and pushes it
  (`git push origin v1.0.0`), or cuts that release with `--major` (below).
  Nothing infers one: a `!` after the type or a `BREAKING CHANGE:` footer reads
  as the plain type.
- **The build number** is `git rev-list --count HEAD`, merges included. It is
  `CFBundleVersion`, and macOS reads a build number that went down as a
  downgrade.

AGENTS.md's prefix rule is what keeps the number honest: every subject starts
with the prefix its change deserves.

**Where it starts.** `v0.2.6`, an annotated tag on `a5a174a` (the last product
commit of 2026-11-21), is the baseline. Most subjects before it carry no prefix,
so counting from `v0.1.0` would read nearly every one as a patch. By meaning, the
history since 0.1.0 reads 0.2.6 — the ⌘H feature 0.2.0, the install fix 0.2.1,
five fixes on 2026-11-21 — and Lars agreed to tag that. `v0.2.6` is a version,
not a release: it has no `CHANGELOG.md` section and no download.

**What it refuses.** A clone with no reachable `vX.Y.Z` tag, and a shallow clone,
whose commit count would be too low. Either fails the build, naming the git
command that fixes it; CI checks out with `fetch-depth: 0` for that reason.

## How a build gets it

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` appear nowhere in
`mdql.xcodeproj`, and none of the three `Info.plist`s names a version. Instead:

- **`mdql-version`**, an aggregate target, runs `Compute version`
  (`scripts/version.py --write`) on every build, into
  `$(BUILT_PRODUCTS_DIR)/mdql-version.stamp`: the version, the build number and
  the badge, one per line.
- **mdql-open-url, mdqlPreview and mdql** each depend on it and carry a
  `Stamp version` phase (`scripts/stamp-version.sh`) that writes
  `CFBundleShortVersionString` and `CFBundleVersion` into the bundle's own built
  `Info.plist` before Xcode signs it. mdqlPreview's also writes the badge into
  its `version.txt`.

One computation per build is the point. **macOS refuses to load an app extension
whose `CFBundleVersion` disagrees with its containing app's**, and mdql ships two
pieces of nested code inside the app — `mdqlPreview.appex`, and the
`com.mdql.app.open-url.xpc` service inside that. Three bundles each asking git
would disagree whenever a commit landed mid-build, and everything would stay
green while it happened: the project builds, the tests pass, and the preview
stops appearing. Read from one stamp file, they cannot.

The app's `Stamp version` runs after **Embed Foundation Extensions**, not before
it: Xcode processes the app's `Info.plist` only once the appex is embedded, so a
stamp ahead of the embed is a dependency cycle and the build fails.

Every build takes this one path — Xcode's own Run, `make install`, `make dist`,
CI — and nothing passes a version in from outside. The two that ship check what
they built: `make install` runs `scripts/version.py --check
/Applications/mdql.app` once it has installed, and `make dist` runs it on the
signed bundle. All three `Info.plist`s must carry the computed version and build
number, and `version.txt` must read `<version> (<commit>)`. The static side is in
`make version-test`: `ProjectTests` in `scripts/test_version.py` read this
repository's own pbxproj and fail on a stored version, an `Info.plist` with one
of its own, or a bundle target missing its dependency or its stamp phase.

**The badge.** `version.txt` reads `0.2.7 (a1b2c3d)`, or `0.2.7 (a1b2c3d-dirty)`
when tracked files had uncommitted changes. `MarkdownRenderer` draws it in the
corner of every preview, which is how to tell which build Finder is actually
running, and `make release` reads it back out of the zip, the only thing tying a
published artifact to the commit it was built from.

`make print-version` prints the version `make dist` names its zip after. The
Makefile asks `scripts/version.py` once per run, so the zip's name, the bundle
check and the tag cannot disagree because a commit landed between two reads.

`make version-test` is the suite of all of it — `scripts/test_version.py`,
`scripts/test_release_tag.py` and `scripts/test_changelog_section.py`, stdlib
`unittest` against throwaway git repositories, no pytest to install — and it runs
the suites of `developer-id-identity.sh` and `install.sh` with them. It runs first
in `make test`, and first in CI, because it needs nothing and takes seconds.

## Cutting a release

Only when Lars asks for one.

```bash
make release-tag-dry     # what it would write
make release-tag         # write it
```

It takes the version `HEAD` computes, writes its `CHANGELOG.md` section, commits
that file alone as `chore(release): <version>`, and puts the annotated tag
`v<version>` on that commit. `chore` is a quiet type, so the commit leaves the
computed version where it was, and the tag sits on the commit `make dist` builds.

The section lists the commits since the **previous release** — the newest section
already in `CHANGELOG.md`, read from its tag — rather than since the newest tag:
`v0.2.6`, or a major Lars had tagged, is a version and not a release, so the
release after it still lists everything since the one before. Each commit goes
under the heading its prefix gives it:

| | |
|---|---|
| `feat` | **Added** |
| `fix`, `perf` | **Fixed** |
| anything else that moved the version | **Other** |
| the quiet types | left out |

**It pushes nothing.** The run stops at a local commit and tag. If the commit or
the tag fails (a hook refuses it, a signer is missing), it undoes what it wrote,
so a rerun starts clean. `git show` is the review, and the remedy for a miscall is

```bash
git reset --hard HEAD~1 && git tag -d v0.2.7
```

Both halves: left behind, `v0.2.7` names a discarded commit, and the next
`make release-tag` refuses the version as already tagged.

It refuses before writing anything:

- a `HEAD` that is not on `main`, detached included — `make release-tag-dry` too,
  so a dry run never shows a plan the real run refuses: a tag cut on a branch names a
  commit the squash-merge then discards, and `make release` would refuse it only
  after a build and a notarization round trip;
- a `CHANGELOG.md` git reports as modified, staged or untracked, or any other
  uncommitted change to a tracked file: a release is cut from a clean tree, as
  `make dist` requires anyway;
- a version whose tag already exists. Nothing — no `fix`, `feat` or unprefixed
  commit — has moved the version since that tag, so there is nothing new to
  release; the next such commit to land moves it;
- a newest `CHANGELOG.md` section with no tag, since that tag is where the
  commits are read from.

**A major as a release.** `make release-tag RELEASE_ARGS='--major 1'` cuts the
release as 1.0.0: the section, the commit, and `v1.0.0` on it. It is the
"make it 1.0" tag put on the release's own commit, and from then on every build
computes from it. A major that would not move is refused.

The tag is annotated because `git push origin main --follow-tags` carries
annotated tags and silently skips lightweight ones: with a lightweight one the
push would exit 0 with the tag still local, and `make release` would refuse a
step later with "not on origin".

### The first release

`v0.1.0` was tagged by hand, before any tool here existed, and `CHANGELOG.md`'s
0.1.0 section is hand-written for the same reason. Its *heading* is the shape
every generated release uses — `## 0.1.0 — 2026-08-20`, the line `render_release`
writes, down to the em dash — so the file reads as one sequence and
`scripts/changelog-section.py` finds it like any other. Its body is prose, which
`render_release` never writes. It is also where the next release starts reading.

## The build to hand to someone else

```bash
make dist
```

Release build into `build/mdql`, signed by `scripts/codesign-app.sh`, checked by
`scripts/version.py --check`, notarized and stapled by `scripts/notarize-app.sh`,
out as `build/dist/mdql-<version>.zip`. Three things about it are worth knowing before
the first run.

**It refuses a dirty tree.** The extension's `Stamp version` phase writes the
badge into its `version.txt` and `MarkdownRenderer` draws it in the corner of
every preview, so a build made over uncommitted changes ships a badge reading
`0.2.7 (a1b2c3d-dirty)` to everyone who downloads it. `make release`'s own clean-tree check cannot stand in for this one:
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

A **Developer ID Application** certificate for team `GUGQ9MB76A`, issued by
Apple's G2 authority — "Renewing the Developer ID certificate" below has the
steps. `codesign-app.sh` falls back to an *Apple
Development* certificate when there is none, which is fine for a build that
never leaves this Mac and which Apple's notary will refuse — it says so rather
than letting the failure arrive ten minutes into an upload.

Both candidates are filtered by team: each certificate's `OU` is read, which is
the field `codesign` reports back as `TeamIdentifier`, and only `GUGQ9MB76A`'s
are taken. A Mac carrying somebody else's Developer ID therefore gets a refusal
naming the team rather than a bundle signed by the wrong authority. Two
Developer ID identities on the team are expected around a renewal:
`scripts/developer-id-identity.sh` takes the one issued by G2, then the later
expiry, and the app is signed with its SHA-1, since `codesign` cannot be handed
a name two identities share. Two *Apple Development* identities are still an
error listing both.

A **notarytool keychain profile**:

```bash
xcrun notarytool store-credentials mdql-notary \
  --apple-id <apple-id> --team-id GUGQ9MB76A
```

A notary profile is a team credential, not a per-app one, so a Mac that already
notarizes something else for `GUGQ9MB76A` needs no second profile — point
`make dist` at the existing one with `NOTARY_PROFILE=<name> make dist`.

### Renewing the Developer ID certificate

**The Developer ID certificate from August 2026 ends on February 1, 2027.** It
was issued by Apple's original Developer ID authority, which expires that day
and takes every certificate it issued with it; replacements come from the G2
authority, and the one created on October 2, 2026 runs to September 17, 2031
([Apple's steps](https://developer.apple.com/help/account/certificates/replace-developer-id-certificates)).
`codesign-app.sh` prints the issuer and the expiry of what it signs with, and
warns while that is the previous authority's.

Nothing already released needs re-signing: a zip `make dist` produced is
notarized and carries a secure timestamp, which is the case Apple says keeps
working. There is no `.pkg`, the one thing Apple says must be re-signed.

1. Keychain Access → Certificate Assistant → Request a Certificate From a
   Certificate Authority, "Saved to disk". The private key is made in the login
   keychain and stays there.
2. [Certificates](https://developer.apple.com/account/resources/certificates/list)
   → + → Developer ID Application → **G2 Sub-CA (Xcode 11.4.1 or later)** →
   upload the request, download the `.cer`, double-click it. Account Holder only.
   Any other Sub-CA issues another certificate that ends in February 2027. Do not
   revoke the old one; the two coexist.
3. `scripts/developer-id-identity.sh GUGQ9MB76A` now prints the new one (third
   field `G2`), and the next `make dist` reads `issuer:   Developer ID
   Certification Authority, OU G2` with no warning.

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
trip to `origin`: the version computes, the zip exists, the tag exists, the
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
a commit that is not the tag. The evidence is inside the bundle: the extension's
`Stamp version` phase writes `<version> (<commit>)` into its `version.txt` on every
build, so the artifact carries the commit it was made from. `make release` reads
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

`.github/workflows/ci.yml`, on every pull request to `main` and on `main` when owl
dispatches it, checks out the whole history and every tag (`fetch-depth: 0`,
since the build computes its version from both and refuses a shallow clone), then
runs three steps in this order:

1. **Test the version tooling** — `make version-test`, first because it needs
   nothing installed and takes seconds.
2. **Build** —
   `xcodebuild build -project mdql.xcodeproj -scheme mdql -destination "platform=macOS"`.
3. **Run tests** — `make test`, which is `version-test` again in seconds and
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
