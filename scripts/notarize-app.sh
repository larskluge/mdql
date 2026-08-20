#!/bin/bash
# Notarize an already-signed mdql.app and emit a zip that opens on someone else's Mac
# with a plain double-click.
#
# Signing alone is not enough. macOS quarantines anything downloaded, and a
# quarantined bundle that Apple has not notarized is refused with a dialog that
# offers no way forward except a right-click-Open workaround most people never find.
# Notarization is what removes that dialog, and stapling is what lets it stay removed
# on a machine that is offline or behind a firewall.
#
# The staple is written into the .app, so the distributable zip has to be made
# *after* stapling — a zip taken before it carries an un-stapled app and Apple's
# ticket has to be fetched over the network at first launch. That ordering is the
# whole reason this script exists rather than four commands in the Makefile.
#
# Credentials, two ways, and which one is used depends on what is set.
#
#   Locally — a keychain profile, created once with:
#     xcrun notarytool store-credentials mdql-notary \
#       --apple-id <apple-id> --team-id GUGQ9MB76A
#
#   In CI — an App Store Connect API key, via NOTARY_KEY (path to the .p8),
#   NOTARY_KEY_ID and NOTARY_ISSUER. `store-credentials` is interactive and the
#   release runner is a VM that did not exist a minute ago and will not exist a
#   minute after; an API key needs no keychain, carries no Apple ID password, and can
#   be revoked on its own.
#
# A notary profile is a *team* credential rather than a per-app one, so a Mac that
# already notarizes something else for team GUGQ9MB76A does not need a second one —
# point NOTARY_PROFILE at the existing name instead.
#
# The API key wins when all three variables are present. Nothing falls back silently:
# a half-set API key is an error, because the alternative is a release job that
# quietly used somebody's local profile.
#
# Usage: scripts/notarize-app.sh <path/to/mdql.app> <output.zip>

set -euo pipefail

TEAM_ID="GUGQ9MB76A"
PROFILE="${NOTARY_PROFILE:-mdql-notary}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"

# How long to wait for Apple before giving up. Notarization normally takes a couple of
# minutes; without a bound a submission that never comes back blocks `make dist`
# forever, on a laptop as easily as on a CI runner. When the timeout fires notarytool
# stops polling and exits non-zero — the submission keeps processing on Apple's side,
# so this run fails with the submission ID and the log can still be fetched later. It
# produces no zip either way; see the staple-and-package section.
NOTARY_TIMEOUT="30m"

# Both arguments are checked before anything else, so that a bare run reports the
# usage rather than whichever credential happens to be missing.
#
# The output name is required rather than defaulted. There is exactly one name a
# release can use — `make dist` passes build/dist/mdql-<version>.zip, and `make
# release` refuses to publish anything else — and a default would have to re-read
# MARKETING_VERSION out of the pbxproj, putting a second reader of the version in the
# tree to silently drift from the Makefile's. An unnamed by-hand run producing an
# unpublishable mdql.zip is the failure this replaces with an instant usage error.
USAGE="usage: scripts/notarize-app.sh <path/to/mdql.app> <output.zip>   (make dist: build/dist/mdql-<version>.zip)"
APP="${1:?"$USAGE"}"
OUT="${2:?"$USAGE"}"

[ -d "$APP" ] || {
	echo "error: no app bundle at $APP" >&2
	exit 1
}

# Whatever is at $OUT goes now, at the start, rather than being overwritten at the
# end. `make release` publishes whatever sits at that path, and a stale zip from an
# earlier version is worse than no zip at all: after a failed run it is still there,
# still named after the version being released, and nothing about it looks old.
# Creating the directory here also fails a bad output path in the first second rather
# than after a five-minute upload.
rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"

# How this run authenticates to Apple. An array, not a flag string: a NOTARY_KEY path
# containing a space splits out of a string into arguments notarytool cannot make
# sense of, and the file-exists check passes first, so the failure surfaces as an
# opaque notary error rather than as the quoting bug it is. /bin/bash on macOS is 3.2,
# which does have arrays; the only trap is expanding an *empty* one under `set -u`,
# and both arms below set at least two elements.
#
# CREDENTIAL_KIND names the mechanism and nothing more. A profile name is not a
# secret; the key ID and issuer UUID are identifiers that have no business in a build
# log, and docs/releases.md proposes this script for CI, where stderr is public.
set_credentials() {
	local set_count=0
	if [ -n "$NOTARY_KEY" ]; then set_count=$((set_count + 1)); fi
	if [ -n "$NOTARY_KEY_ID" ]; then set_count=$((set_count + 1)); fi
	if [ -n "$NOTARY_ISSUER" ]; then set_count=$((set_count + 1)); fi

	if [ "$set_count" -eq 3 ]; then
		[ -f "$NOTARY_KEY" ] || {
			echo "error: NOTARY_KEY is set to '$NOTARY_KEY', which is not a file." >&2
			exit 1
		}
		CREDENTIALS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
		CREDENTIAL_KIND="App Store Connect API key"
	elif [ "$set_count" -eq 0 ]; then
		CREDENTIALS=(--keychain-profile "$PROFILE")
		CREDENTIAL_KIND="keychain profile $PROFILE"
	else
		echo "error: NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER must be set together." >&2
		echo "  $set_count of 3 are set. Set all three to use an API key, or none to use" >&2
		echo "  the '$PROFILE' keychain profile." >&2
		exit 1
	fi
}
set_credentials

# --- Pre-flight -------------------------------------------------------------
# Apple rejects an unsigned bundle, a bundle signed with anything other than a
# Developer ID Application certificate, and a bundle without the hardened runtime.
# Each rejection costs a full upload and a wait, so all three are checked here where
# the answer is instant and the fix is obvious.

signature="$(codesign -dvv "$APP" 2>&1)" || {
	echo "error: $APP is not signed — run scripts/codesign-app.sh first." >&2
	exit 1
}

authority="$(printf '%s\n' "$signature" | sed -n 's/^Authority=//p' | head -1)"
case "$authority" in
"Developer ID Application:"*) ;;
*)
	echo "error: signed with '${authority:-no authority}', which Apple will not notarize." >&2
	echo "  Notarization requires a 'Developer ID Application' certificate. scripts/codesign-app.sh" >&2
	echo "  falls back to 'Apple Development' when no Developer ID exists on team $TEAM_ID — create" >&2
	echo "  one in Xcode: Settings -> Accounts -> Manage Certificates -> + -> Developer ID Application." >&2
	exit 1
	;;
esac

case "$(printf '%s\n' "$signature" | sed -n 's/^CodeDirectory .*flags=//p' | head -1)" in
*runtime*) ;;
*)
	echo "error: $APP is signed without the hardened runtime; Apple will reject it." >&2
	echo "  scripts/codesign-app.sh passes --options runtime — re-sign with it." >&2
	exit 1
	;;
esac

echo "Notarizing $APP"
echo "  identity: $authority"
echo "  auth:     $CREDENTIAL_KIND"

# --- Submit -----------------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ditto -c -k --keepParent "$APP" "$WORK/upload.zip"

# `notarytool --wait` reports a rejected submission in its output rather than in its
# exit status, so both are inspected. Either way the notary log is the only thing that
# says *why*, and it is fetched and printed rather than left behind a submission ID
# the caller would have to look up by hand.
set +e
xcrun notarytool submit "$WORK/upload.zip" "${CREDENTIALS[@]}" \
	--wait --timeout "$NOTARY_TIMEOUT" 2>&1 | tee "$WORK/submit.txt"
rc="${PIPESTATUS[0]}"
set -e

submission="$(sed -n 's/^ *id: //p' "$WORK/submit.txt" | head -1)"
status="$(sed -n 's/^ *status: //p' "$WORK/submit.txt" | tail -1)"

if [ "$rc" -ne 0 ] || [ "$status" != "Accepted" ]; then
	echo >&2
	echo "error: notarization failed (status: ${status:-unknown})." >&2
	if [ -n "$submission" ]; then
		echo "--- notary log for $submission ---" >&2
		xcrun notarytool log "$submission" "${CREDENTIALS[@]}" >&2 ||
			echo "  (could not fetch the log; re-run 'xcrun notarytool log $submission' with the same credentials)" >&2
	else
		echo "  No submission ID was returned, which usually means authentication failed." >&2
		echo "  This run used: $CREDENTIAL_KIND" >&2
		if [ -n "$NOTARY_KEY" ]; then
			echo "  Check the API key is a Developer ID key for team $TEAM_ID and has not been revoked." >&2
		else
			echo "  There is no '$PROFILE' keychain profile, or its password has been revoked." >&2
			echo "  Two ways forward — create mdql's own profile:" >&2
			echo "    xcrun notarytool store-credentials $PROFILE --apple-id <apple-id> --team-id $TEAM_ID" >&2
			echo "  or reuse a profile this Mac already has for team $TEAM_ID, since a notary" >&2
			echo "  profile is a team credential and not a per-app one:" >&2
			echo "    NOTARY_PROFILE=<name> make dist" >&2
		fi
	fi
	exit 1
fi

# --- Staple and package -----------------------------------------------------
#
# The zip is built inside $WORK and every check runs against it there. $OUT is written
# by one `mv` at the very end, after the last check has passed, because `make release`
# publishes whatever is at that path and is entitled to assume a failed `make dist`
# left nothing there. Written first and checked afterwards, the failures below would
# each abort under `set -e` with the rejected zip already sitting at the published
# name — `stapler validate` on an un-stapled bundle exits 65.

xcrun stapler staple "$APP"

APP_NAME="$(basename "$APP")"
ZIP="$WORK/$(basename "$OUT")"
ditto -c -k --keepParent "$APP" "$ZIP"

# The claim this script makes is "double-clicks cleanly on someone else's Mac", so it
# is verified against the artifact actually being shipped, unpacked, and carrying the
# quarantine flag a download would attach — not against the build directory, where
# Gatekeeper would pass it on the strength of it being local.
CHECK="$WORK/check"
mkdir -p "$CHECK"
ditto -x -k "$ZIP" "$CHECK"
xattr -w com.apple.quarantine "0083;00000000;notarize-app.sh;" "$CHECK/$APP_NAME"

xcrun stapler validate "$CHECK/$APP_NAME" || {
	echo >&2
	echo "error: the packaged app carries no stapled notarization ticket." >&2
	echo "  Apple accepted the submission, so it is the staple that did not land — this" >&2
	echo "  build would be refused on a Mac that is offline or behind a firewall." >&2
	echo "  Nothing was written to $OUT." >&2
	exit 1
}
assessment="$(spctl -a -vvv -t install "$CHECK/$APP_NAME" 2>&1)" || {
	echo "error: the packaged app was rejected by Gatekeeper:" >&2
	printf '%s\n' "$assessment" >&2
	echo "  Nothing was written to $OUT." >&2
	exit 1
}
printf '%s\n' "$assessment" | sed 's/^/  /'

mv "$ZIP" "$OUT"

echo
echo "Ready to send: $OUT ($(du -h "$OUT" | cut -f1))"
