.PHONY: install test clean

BUNDLE_ID := com.mdql.app.preview
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

install:
	@echo "Building mdql (Release)..."
	@xcodebuild -project mdql.xcodeproj -scheme mdql -configuration Release \
		-destination 'platform=macOS' build 2>&1 | tail -3
	@echo ""
	@BUILT="$$(xcodebuild -project mdql.xcodeproj -scheme mdql -configuration Release \
		-showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $$NF}')" && \
		scripts/install.sh "$$BUILT"
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
# at all and takes milliseconds: a broken bump tool should not be discovered after
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
# The whole process, in order, is:
#
#   make version                          # bump, changelog, commit, tag — local only
#   git show                              # the review
#   git push origin main --follow-tags    # main first, then the tag
#   make dist                             # build, sign, notarize, staple, zip
#   make release                          # publish it on GitHub
#
# docs/releases.md says what each step needs and how to undo it.

.PHONY: version version-dry version-test print-version check-version check-clean \
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

# Bump the version from the commits since the last tag. The level comes from each
# subject's prefix — `feat` a minor, `fix`/`perf` a patch, `chore`/`docs`/`ci` and
# friends nothing at all — and an unprefixed subject is a patch listed under
# **Other**, which is most of this repository's history. It writes the two
# project-level settings in mdql.xcodeproj/project.pbxproj and CHANGELOG.md, then
# commits and tags.
#
# It pushes nothing, which is what makes a fully automatic bump safe: the run stops
# at a local commit, the changelog it wrote is the evidence table, `git show` is the
# review, and `git reset --hard HEAD~1 && git tag -d v<version>` is the undo.
#
# Force a level with `make version VERSION_ARGS='--level major'`. That is also how
# 1.0 happens, since nothing infers a major on its own.
VERSION_ARGS ?=
version:
	python3 scripts/version.py $(VERSION_ARGS)

# The same reading, written nowhere. What to run before the real one.
version-dry:
	python3 scripts/version.py --dry-run $(VERSION_ARGS)

# The bump tool's own suite. stdlib unittest — there is no pytest in this tree, and
# adding one for two modules of pure functions would be a dependency to install on
# every machine that runs `make test`.
version-test:
	python3 -m unittest discover -s scripts -p 'test_*.py'

# What a release would call itself right now, read out of the one place that holds
# it rather than passed in, so the zip a release ships can never be named something
# the app inside it does not call itself.
#
# `sort -u` rather than `head -1`, because the setting appears once per project-level
# configuration and the first match is Debug's while every release is built from
# Release. Reading either one on its own hides the case worth reporting: a pbxproj
# whose two configurations disagree, which is how a zip named mdql-0.1.0.zip comes to
# hold an app that calls itself 9.9.9. scripts/version.py refuses that too, but it
# does not run anywhere on the dist path, so nothing else would notice. Every
# distinct value therefore survives into VERSION, and `check-version` refuses on
# anything but one. The pattern is anchored on the `KEY = value;` setting form
# because the version-stamp build phase's shellScript also mentions
# `${MARKETING_VERSION}`.
VERSION = $(shell sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);$$/\1/p' mdql.xcodeproj/project.pbxproj | sort -u)

# The guard in front of everything that names a version. Its own target because it
# has to answer before `make dist` spends a build and a notarization round trip on a
# zip it would then have to call `mdql-.zip`.
check-version:
	@[ -n "$(VERSION)" ] \
		|| { echo "make: no MARKETING_VERSION in mdql.xcodeproj/project.pbxproj." >&2; exit 1; }
	@[ $(words $(VERSION)) -eq 1 ] \
		|| { echo "make: mdql.xcodeproj/project.pbxproj declares $(words $(VERSION)) different MARKETING_VERSIONs: $(VERSION)" >&2; \
		     echo "      The project-level Debug and Release configurations disagree, so there is" >&2; \
		     echo "      no one version to build, to name a zip after, or to tag. Set them to the" >&2; \
		     echo "      same value — \`make version\` writes both." >&2; exit 1; }

print-version: check-version
	@echo $(VERSION)

# A dist build is the one build that cannot tolerate uncommitted work.
#
# The version-stamp build phase writes `${MARKETING_VERSION} (${HASH}${DIRTY})` into
# version.txt and mdqlPreview draws it in the corner of every preview, so a build
# made over a dirty tree ships a preview that reads `0.1.0 (a1b2c3d-dirty)` to
# everyone who downloads it. `make release`'s own clean-tree check cannot stand in
# for this one: it sees the tree whenever it happens to run, not the tree the zip was
# built from. Otherwise edit, `make dist`, `git checkout .`, `make release` passes
# every refusal there and publishes a notarized build of code that is in no commit.
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
	@# The version stamp, checked here rather than discovered later.
	@#
	@# `release` refuses to publish a zip whose version.txt does not read
	@# `<version> (<commit>)` — that stamp is the only thing tying a published
	@# artifact to the tagged commit. Nothing else asserts the format, so a change to
	@# the `Generate version.txt` build phase would pass every test in the repository
	@# and surface as a refusal after a full build and a notarization round trip. It
	@# costs nothing to ask now.
	@stamp="$(RELEASE_APP)/Contents/PlugIns/mdqlPreview.appex/Contents/Resources/version.txt"; \
	read -r stamped <"$$stamp" 2>/dev/null || { \
		echo "make: the build wrote no $$stamp." >&2; \
		echo "      The 'Generate version.txt' build phase on the mdqlPreview target writes it" >&2; \
		echo "      on every build; \`make release\` reads it back to prove the zip is a build" >&2; \
		echo "      of the tagged commit." >&2; exit 1; }; \
	case "$$stamped" in \
	"$(VERSION) ("*")") ;; \
	*) echo "make: version.txt reads '$$stamped', not '$(VERSION) (<commit>)'." >&2; \
	   echo "      \`make release\` parses that shape to check the zip was built from the" >&2; \
	   echo "      tagged commit, and would refuse this build. Fix the 'Generate version.txt'" >&2; \
	   echo "      build phase on the mdqlPreview target." >&2; exit 1 ;; \
	esac; \
	echo "  stamped:  $$stamped"

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
# late. `build-release` carries `check-version` itself, because it reads VERSION to
# check the stamp the build wrote; make builds a phony prerequisite once per run, so
# naming it in both places does not make `make dist` ask twice.
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
#   the version is one       `check-version`, above: an empty or self-contradicting
#                            MARKETING_VERSION names a zip nothing built
#   the zip exists           without it there is nothing to publish
#   the tag exists           `make version` creates it; without one there is
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
# says 49aa524. The evidence is inside the bundle: the `Generate version.txt` build
# phase is alwaysOutOfDate and writes `${MARKETING_VERSION} (${HASH}${DIRTY})` into
# the extension's Resources on every single build, so each artifact carries the commit
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
		|| { echo "make: there is no tag $$tag — run \`make version\` first." >&2; exit 1; }; \
	tagged="$$(git rev-parse "$$tag^{commit}")"; head="$$(git rev-parse HEAD)"; \
	[ "$$tagged" = "$$head" ] \
		|| { echo "make: $$tag points at $$tagged but HEAD is $$head." >&2; \
		     echo "      Check out the tagged commit, or bump again." >&2; exit 1; }; \
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
