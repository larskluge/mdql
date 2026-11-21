.PHONY: install test clean

BUNDLE_ID := com.mdql.app.preview
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

install:
	@echo "Building mdql (Release)..."
	@# pipefail, or the pipe exits with tail's 0 and a failed build installs the last one.
	@set -o pipefail; xcodebuild -project mdql.xcodeproj -scheme mdql -configuration Release \
		-destination 'platform=macOS' build 2>&1 | tail -3
	@echo ""
	@BUILT="$$(xcodebuild -project mdql.xcodeproj -scheme mdql -configuration Release \
		-showBuildSettings 2>/dev/null | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p')" && \
		scripts/install.sh "$$BUILT"
	@# The version every build computes, in all three bundles of what was installed:
	@# an appex whose CFBundleVersion differs from its app's is never loaded.
	@python3 scripts/version.py --check /Applications/mdql.app
	@echo ""
	@# Verify pluginkit registration
	@FINAL="$$(pluginkit -m -v -A -i $(BUNDLE_ID) 2>/dev/null)" && \
		COUNT="$$(echo "$$FINAL" | grep -c '$(BUNDLE_ID)' || true)" && \
		if [ "$$COUNT" -gt 1 ]; then \
			echo "ERROR: $$COUNT pluginkit registrations found (expected 1):"; \
			echo "$$FINAL" | grep '$(BUNDLE_ID)'; \
			exit 1; \
		elif echo "$$FINAL" | grep -Eq '(^|[[:space:]])/Applications/mdql\.app([[:space:]/]|$$)'; then \
			echo "OK: Extension registered from /Applications"; \
		elif echo "$$FINAL" | grep -q '$(BUNDLE_ID)'; then \
			echo "WARN: Registered but not from /Applications:"; \
			echo "$$FINAL" | grep '$(BUNDLE_ID)'; \
		else \
			echo "ERROR: Extension not registered!"; \
			exit 1; \
		fi
	@# Verify no stale lsregister entries
	@STALE="$$($(LSREGISTER) -dump 2>/dev/null | grep 'path:' | grep 'mdql.app' | grep -v '.appex' | grep -Ev 'path:[[:space:]]*/Applications/mdql\.app ' | grep -v 'Application Scripts' | grep -v 'WebKit' || true)" && \
		if [ -n "$$STALE" ]; then \
			echo "WARN: Stale lsregister entries found:"; \
			echo "$$STALE" | sed 's/^/  /'; \
		else \
			echo "OK: No duplicate registrations"; \
		fi
	@echo "Done. Test with: qlmanage -p README.md"

# Every test in the repository. `version-test` runs first because it needs nothing
# at all and takes seconds: a broken version tool should not be discovered after
# a long xcodebuild.
test: version-test
	xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' test

# Xcode's own outputs, plus `build/` — where the release targets below put the
# signed bundle and the notarized zip, and which xcodebuild's clean knows nothing
# about.
clean:
	xcodebuild -project mdql.xcodeproj -scheme mdql -configuration Release clean
	rm -rf build

# ---- Release ----------------------------------------------------------------
#
# Nothing here bumps a version: every build computes it from git history
# (scripts/version.py; docs/releases.md → "The version"). A release is cut only
# when Lars asks for one, in this order:
#
#   make release-tag-dry                  # the CHANGELOG section and tag it would write
#   make release-tag                      # write them: one commit, one tag — local only
#   git push origin main --follow-tags    # main first, then the tag
#   make dist                             # build, sign, notarize, staple, zip
#   make release                          # publish it on GitHub
#
# docs/releases.md says what each step needs and how to undo it.

.PHONY: release-tag release-tag-dry version-test print-version check-version check-clean \
	build-release dist release

# `dist` lists its guards before its build so that neither costs a build to learn,
# and under `-j` that order is only a suggestion: `make -j4 dist` starts
# `build-release` alongside `check-clean` and spends a full Release build before the
# dirty-tree refusal aborts the run. Nothing here is a parallelism candidate anyway —
# every recipe is one xcodebuild or one script, each already parallel inside itself —
# so the whole file is serial and the prerequisite order is the real order.
.NOTPARALLEL:

# The repository a release is published to. Named once, because `release` both asks
# `origin` for the tag and hands this to `gh`: two spellings of "this repo" is how a
# fork's clone passes a tag check against the fork and then publishes to the upstream.
GH_REPO = larskluge/mdql

# CHANGELOG.md's section for the version HEAD computes, listing the commits since the
# previous release under Added / Fixed / Other, committed alone as
# `chore(release): <version>` — a quiet type, so the version stays where it was —
# and the annotated tag `v<version>` on that commit. It pushes nothing, and prints
# the undo. `RELEASE_ARGS='--major 1'` is the release that makes it 1.0.0, on Lars's
# word only: nothing infers a major.
RELEASE_ARGS ?=
release-tag:
	python3 scripts/release-tag.py $(RELEASE_ARGS)

# The same section and tag, written nowhere.
release-tag-dry:
	python3 scripts/release-tag.py --dry-run $(RELEASE_ARGS)

# The version tools' own suites, and beside them the suites of the other scripts
# here: developer-id-identity.sh and install.sh, each run against stubs. stdlib
# unittest — there is no pytest in this tree, and adding one for a handful of modules
# would be a dependency to install on every machine that runs `make test`.
version-test:
	python3 -m unittest discover -s scripts -p 'test_*.py'

# The version HEAD computes, asked once per make run however many recipes name it,
# so the zip's name, the bundle check and the tag cannot disagree because a commit
# landed between two reads. Empty when scripts/version.py fails, whose reason is then
# already on stderr.
VERSION = $(eval VERSION := $$(shell python3 scripts/version.py))$(VERSION)

# The guard in front of everything that names a version. Its own target because it
# has to answer before `make dist` spends a build and a notarization round trip on a
# zip it would then have to call `mdql-.zip`.
check-version:
	@[ -n "$(VERSION)" ] \
		|| { echo "make: scripts/version.py computed no version; its reason is above." >&2; exit 1; }

print-version: check-version
	@echo $(VERSION)

# A dist build is the one build that cannot tolerate uncommitted work.
#
# The Stamp version build phase writes `<version> (<commit>-dirty)` into version.txt
# over a dirty tree, and mdqlPreview draws it in the corner of every preview, so such
# a build ships a preview that reads `0.2.7 (a1b2c3d-dirty)` to everyone who
# downloads it. `make release`'s own clean-tree check cannot stand in for this one:
# it sees the tree whenever it happens to run, not the tree the zip was built from.
# Otherwise edit, `make dist`, `git checkout .`, `make release` passes every refusal
# there and publishes a notarized build of code that is in no commit.
check-clean:
	@dirty="$$(git status --porcelain)"; \
	[ -z "$$dirty" ] || { \
		echo "make: the working tree has uncommitted changes:" >&2; \
		printf '%s\n' "$$dirty" >&2; \
		echo "      Commit or stash them first — a dist build stamps '-dirty' into the" >&2; \
		echo "      version drawn in every preview's corner, and ships it." >&2; \
		exit 1; \
	}

# Everything a release build writes goes here rather than into DerivedData, so the
# bundle sits at a path the next target can name instead of asking xcodebuild where
# it went.
RELEASE_DERIVED = build/mdql
RELEASE_APP = $(RELEASE_DERIVED)/Build/Products/Release/mdql.app
DIST = build/dist

# Release build, then signed inside-out with the team's Developer ID identity.
#
# `CI=true` is not a claim about where this runs: it is the switch the
# `Install & Register QuickLook Extension` build phase already reads, and setting it
# is the only thing that stops the build from copying itself into /Applications and
# re-signing that copy ad-hoc. A dist build must never do that. The ad-hoc signature
# replaces the Developer ID one, so the app whose preview you then check by pressing
# Space in Finder is not the app that ships — and nothing about it looks wrong.
# `make install` is the target that installs, on its own path, unchanged.
build-release: check-version
	CI=true xcodebuild -project mdql.xcodeproj -scheme mdql -configuration Release \
		-destination 'platform=macOS' -derivedDataPath $(RELEASE_DERIVED) build
	scripts/codesign-app.sh $(RELEASE_APP)
	@# The version, checked here rather than discovered later: all three bundles carry
	@# the computed version and build number, and version.txt reads
	@# `<version> (<commit>)`, the stamp `make release` reads back to tie the zip to
	@# the tagged commit. A broken Stamp version phase would otherwise surface as a
	@# refusal after a notarization round trip, or as a preview that never loads.
	python3 scripts/version.py --check $(RELEASE_APP)

# The build to hand to someone else: notarized, stapled, and verified against a
# quarantined copy of the shipped zip. Needs a Developer ID Application certificate
# for team GUGQ9MB76A and a notarytool keychain profile (`mdql-notary`, or any
# profile for the same team via `NOTARY_PROFILE=<name>`), plus a network round trip
# that usually takes a couple of minutes. docs/releases.md has the setup.
#
# The zip carries its version, because a file sitting in somebody's Downloads folder
# should say which build it is.
#
# `check-clean` runs before the build rather than after it, since the answer does not
# change during one and costs a full build and a notarization round trip to learn
# late. `build-release` carries `check-version` itself, so a build is never spent on a
# tree whose version cannot be computed; make builds a phony prerequisite once per
# run, so naming it in both places does not make `make dist` ask twice.
dist: check-version check-clean build-release
	scripts/notarize-app.sh $(RELEASE_APP) $(DIST)/mdql-$(VERSION).zip

# Publish the release on GitHub: the notarized zip, with this version's CHANGELOG
# section as the body.
#
# Every refusal below has to fail before anything is published, because a published
# release is not reversible for anyone who has already downloaded it. They are in
# cost order — a local stat before a git command before a network round trip — so the
# commonest mistake, having forgotten `make dist`, is not reported after a trip to
# origin:
#
#   the version computes     `check-version`, above: without one there is no zip
#                            name to look for
#   the zip exists           without it there is nothing to publish
#   the tag exists           `make release-tag` creates it; without one there is
#                            nothing to release
#   the tag is HEAD          otherwise this publishes a build of a different commit
#                            than the one that was reviewed
#   HEAD is main             a release cut off a branch is a release of something
#                            nobody merged
#   the tree is clean        the zip was built from the tree, so uncommitted changes
#                            in it are shipped and unrecorded
#   origin is this repo      the tag check asks `origin`, `gh` publishes to
#                            $(GH_REPO); on a fork's clone those are two repositories
#   the zip is the build     see below
#   the zip is of the tag    every build stamps the commit it came from into its own
#                            version.txt; this is the only check that ties the
#                            artifact to the tag, see below
#   the tag is on origin     `gh release create` *creates* a tag it cannot find — on
#                            the remote default branch's HEAD, not on this commit.
#                            An unpushed tag therefore publishes a release of
#                            whatever else is on origin/main, under the right name.
#
# The zip check opens the artifact instead of trusting its name. Every check above it
# reasons about the tree or the remote; none looks inside the file being uploaded, and
# the file is whatever was left at that path — possibly days old, possibly from
# before a `make dist` that failed halfway, possibly not a zip at all. So it is
# unpacked and made to prove the properties this whole path exists to give a
# downloader: one mdql.app and nothing else beside it, calling itself the version
# being tagged, built from the tagged commit, carrying a stapled notarization ticket,
# and accepted by Gatekeeper as an install.
#
# Built from the tagged commit is the one those checks cannot infer from the tree,
# and the one everything else quietly assumes. `make dist`, `git reset --hard <older
# tag>`, `make release` satisfies every refusal here — tag is HEAD, branch is main,
# tree is clean, the app calls itself the right version — and publishes a build of a
# commit that is not the tag, whose previews read `0.1.0 (f1e1eab)` while the release
# says 49aa524. The evidence is inside the bundle: the extension's Stamp version build
# phase is alwaysOutOfDate and writes `<version> (<commit>)` into its Resources on
# every single build, so each artifact carries the commit
# it was made from precisely so it can be asked. So it is asked, and a `-dirty` stamp
# is refused with it — `check-clean` saw the tree at dist time, this sees the tree the
# build actually read.
#
# The body is the changelog section plus a fixed **Install** stanza appended here.
# Here rather than in CHANGELOG.md because the changelog says what changed and this
# is boilerplate for a download page — repeating it in every section would be four
# identical paragraphs in the file by 0.5.0. The release page is where it is needed:
# somebody standing in front of the zip is one drag away from the step both README.md
# and docs/releases.md single out as the one people miss, and a bundle copied into
# /Applications and never launched previews nothing, with no error to explain why.
#
# The remote check asks for `$tag` and `$tag^{}` and compares the commit: a
# lightweight tag answers on the first ref, an annotated one only on the peeled
# second. Asking for one of them refuses a correctly pushed tag of the other kind,
# and says the opposite of what happened. It is only meaningful if `origin` is the
# repository being published to, which is what the origin check earlier establishes:
# `gh` is given `--repo $(GH_REPO)` and never consults `origin`, so on a clone whose
# origin is a fork the tag would be validated on the fork and then created on
# $(GH_REPO)'s default-branch HEAD — the exact failure the remote check is here to
# prevent, and invisible to the remote check itself. It runs with the cheap git
# reads rather than beside the check it guards, so a clone that could never publish
# is told so before a build gets unpacked and assessed.
release: check-version
	@set -e; \
	version="$(VERSION)"; tag="v$$version"; zip="$(DIST)/mdql-$$version.zip"; \
	notes="$(DIST)/notes-$$version.md"; \
	[ -f "$$zip" ] \
		|| { echo "make: there is no $$zip — run \`make dist\` first." >&2; exit 1; }; \
	git rev-parse -q --verify "refs/tags/$$tag" >/dev/null \
		|| { echo "make: there is no tag $$tag — run \`make release-tag\` first." >&2; exit 1; }; \
	tagged="$$(git rev-parse "$$tag^{commit}")"; head="$$(git rev-parse HEAD)"; \
	[ "$$tagged" = "$$head" ] \
		|| { echo "make: $$tag points at $$tagged but HEAD is $$head." >&2; \
		     echo "      Check out the tagged commit, or cut a release at HEAD." >&2; exit 1; }; \
	branch="$$(git rev-parse --abbrev-ref HEAD)"; \
	[ "$$branch" = "main" ] \
		|| { echo "make: HEAD is on '$$branch', not main — a release is cut from main." >&2; exit 1; }; \
	[ -z "$$(git status --porcelain)" ] \
		|| { echo "make: the working tree has uncommitted changes:" >&2; git status --short >&2; exit 1; }; \
	origin_url="$$(git remote get-url origin 2>&1)" \
		|| { echo "make: this clone has no 'origin' remote:" >&2; \
		     printf '%s\n' "$$origin_url" | sed 's/^/      /' >&2; \
		     echo "      The tag check below asks origin, and the release is published to" >&2; \
		     echo "      $(GH_REPO); with no origin the first cannot vouch for the second." >&2; \
		     exit 1; }; \
	origin_repo="$$(printf '%s\n' "$$origin_url" \
		| sed -E 's#^(ssh://)?(git@)?github\.com[:/]##; s#^https://([^@/]*@)?github\.com/##; s#\.git$$##')"; \
	[ "$$origin_repo" = "$(GH_REPO)" ] \
		|| { echo "make: origin is $$origin_url, which is not $(GH_REPO)." >&2; \
		     echo "      The tag check below asks origin; gh publishes to $(GH_REPO) and never" >&2; \
		     echo "      consults origin. Two repositories here means the tag is validated on one" >&2; \
		     echo "      and created on the other's default branch. Release from a clone of" >&2; \
		     echo "      $(GH_REPO)." >&2; exit 1; }; \
	work="$$(mktemp -d)"; trap 'rm -rf "$$work"' EXIT; \
	ditto -x -k "$$zip" "$$work/unpacked" 2>"$$work/ditto.err" \
		|| { echo "make: $$zip is not a zip archive that can be unpacked:" >&2; \
		     sed 's/^/      /' "$$work/ditto.err" >&2; \
		     echo "      Rebuild it with \`make dist\`." >&2; exit 1; }; \
	top="$$(ls -A "$$work/unpacked")"; \
	{ [ "$$top" = "mdql.app" ] && [ -d "$$work/unpacked/mdql.app" ]; } \
		|| { echo "make: $$zip should unpack to exactly one mdql.app bundle; it holds:" >&2; \
		     ls -lA "$$work/unpacked" | sed 's/^/      /' >&2; exit 1; }; \
	app="$$work/unpacked/mdql.app"; \
	built="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$$app/Contents/Info.plist" 2>&1)" \
		|| { echo "make: the app in $$zip has no readable CFBundleShortVersionString:" >&2; \
		     printf '%s\n' "$$built" | sed 's/^/      /' >&2; exit 1; }; \
	[ "$$built" = "$$version" ] \
		|| { echo "make: $$zip holds an app that calls itself $$built, but this release is $$version." >&2; \
		     echo "      The zip is from another build. Run \`make dist\` again." >&2; exit 1; }; \
	stamp="Contents/PlugIns/mdqlPreview.appex/Contents/Resources/version.txt"; \
	stamped="$$(cat "$$app/$$stamp" 2>&1)" \
		|| { echo "make: the app in $$zip carries no $$stamp:" >&2; \
		     printf '%s\n' "$$stamped" | sed 's/^/      /' >&2; \
		     echo "      Every build writes one, so this zip is not one of ours." >&2; \
		     echo "      Run \`make dist\` at $$tag." >&2; exit 1; }; \
	built_hash="$$(printf '%s\n' "$$stamped" | sed -n 's/^[^(]*(\([^)]*\))$$/\1/p')"; \
	[ -n "$$built_hash" ] \
		|| { echo "make: $$stamp in $$zip reads '$$stamped', not '<version> (<commit>)'." >&2; \
		     echo "      Nothing in it can be checked against $$tag. Run \`make dist\` at $$tag." >&2; \
		     exit 1; }; \
	[ "$$built_hash" = "$${built_hash%-dirty}" ] \
		|| { echo "make: $$zip holds a build of an uncommitted tree — it stamped '$$stamped'." >&2; \
		     echo "      Whatever was edited is in no commit and would ship unrecorded." >&2; \
		     echo "      Run \`make dist\` at $$tag, on a clean tree." >&2; exit 1; }; \
	tagged_short="$$(git rev-parse --short "$$tag^{commit}")"; \
	built_commit="$$(git rev-parse -q --verify "$$built_hash^{commit}" 2>/dev/null)" || built_commit=""; \
	[ "$$built_commit" = "$$tagged" ] \
		|| { echo "make: $$zip holds a build of commit $$built_hash, but $$tag is $$tagged_short." >&2; \
		     echo "      Every other check here reads the tree, not the artifact, so nothing else" >&2; \
		     echo "      would notice. Run \`make dist\` at the tagged commit." >&2; exit 1; }; \
	staple="$$(xcrun stapler validate "$$app" 2>&1)" \
		|| { echo "make: the app in $$zip is not notarized and stapled:" >&2; \
		     printf '%s\n' "$$staple" | sed 's/^/      /' >&2; \
		     echo "      Downloaders would get Gatekeeper's 'cannot be opened' dialog." >&2; \
		     echo "      Run \`make dist\` again." >&2; exit 1; }; \
	assessment="$$(spctl -a -vvv -t install "$$app" 2>&1)" \
		|| { echo "make: Gatekeeper rejects the app in $$zip:" >&2; \
		     printf '%s\n' "$$assessment" | sed 's/^/      /' >&2; exit 1; }; \
	printf '%s\n' "$$assessment" | sed 's/^/  /'; \
	git ls-remote --tags origin "$$tag" "$$tag^{}" | awk '{print $$1}' | grep -qx "$$tagged" \
		|| { echo "make: $$tag is not on origin, or points elsewhere there." >&2; \
		     echo "      Run \`git push origin main --follow-tags\` first: gh would otherwise" >&2; \
		     echo "      create the tag on origin/main's HEAD and release that instead." >&2; exit 1; }; \
	python3 scripts/changelog-section.py --version "$$version" --output "$$notes"; \
	{ printf '\n---\n\n## Install\n\n'; \
	  printf '1. Download `mdql-%s.zip` below and unzip it.\n' "$$version"; \
	  printf '2. Drag `mdql.app` to `/Applications`.\n'; \
	  printf '3. **Launch it once.** macOS only discovers the Quick Look extension once its\n'; \
	  printf '   host app has been opened, so a bundle copied in and never launched previews\n'; \
	  printf '   nothing.\n'; \
	  printf '4. Press Space on any `.md` file in Finder.\n'; \
	  printf '\nRequires macOS 26.0 or later.\n'; } >>"$$notes"; \
	gh release create "$$tag" --repo $(GH_REPO) --title "$$tag" \
		--notes-file "$$notes" "$$zip"
