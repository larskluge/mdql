#!/bin/bash
# Codesign a built mdql.app with the Apple Developer team's signing identity.
#
# Prefers a "Developer ID Application" certificate — the identity a distributable,
# notarizable build needs. Falls back to the team's "Apple Development" certificate,
# which is enough for a build that never leaves this Mac but which Apple's notary
# will not accept; the fallback says so, loudly, rather than producing a bundle that
# looks finished and fails an upload ten minutes later.
#
# **Every code item in the bundle needs a *different* entitlements answer.** mdql.app
# holds exactly three Mach-O items, and the mapping below is the product:
#
#   Contents/MacOS/mdql                      -> mdql/mdql.entitlements
#   Contents/PlugIns/mdqlPreview.appex       -> mdqlPreview/mdqlPreview.entitlements
#   .../mdqlPreview.appex/Contents/XPCServices/com.mdql.app.open-url.xpc
#                                            -> none, deliberately
#
# The usual shortcut for nested code — "helpers get no entitlements" — is wrong here,
# and so is "everything gets the app's". The preview extension is sandboxed and needs
# com.apple.security.network.client, without which WKWebView renders a *blank*
# preview inside the sandbox. The XPC service is unsandboxed on purpose: it exists
# precisely to do what the sandboxed extension cannot — call NSWorkspace.open and
# read sibling .md files — so handing it the extension's sandbox switches off the
# feature it was written for. The app itself is deliberately unsandboxed, which is
# why mdql/mdql.entitlements is an empty <dict/>.
#
# Neither mistake shows up in the build log, in `codesign --verify`, or in anything
# Apple's notary checks. Both ship, and the bug arrives on someone else's Mac. So the
# mapping is explicit, and the run ends by reading back the entitlements that
# actually landed in the signature.
#
# Everything is signed inside-out — deepest path first, so a bundle is sealed only
# after everything inside it is final. mdql's XPC service lives *inside* the appex
# rather than beside it, two bundles deep, so this is not a formality: seal the appex
# first and its seal records a hash of an XPC service that is about to be re-signed.
#
# Nothing is *signed* with `--deep`, which Apple deprecates for signing and which
# would stamp the app's entitlements onto every nested item — for mdql that is not a
# hypothetical objection, it is exactly the failure described above. Verifying is the
# opposite case: `--deep` is not deprecated there, and without it the walk stops one
# level short of mdql's XPC service. See the verify section.
#
# Usage: scripts/codesign-app.sh <path/to/mdql.app>

set -euo pipefail

TEAM_ID="GUGQ9MB76A"

APP="${1:?usage: scripts/codesign-app.sh <path/to/mdql.app>}"
APP="${APP%/}" # a trailing slash would break every "${item#$APP/}" below
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

APP_ENTITLEMENTS="$PROJECT_DIR/mdql/mdql.entitlements"
APPEX_ENTITLEMENTS="$PROJECT_DIR/mdqlPreview/mdqlPreview.entitlements"

# Bundle-relative paths, named once and shared by the entitlements mapping, the
# completeness check and the read-back — so the three cannot drift apart.
MAIN_REL="Contents/MacOS/mdql"
APPEX_REL="Contents/PlugIns/mdqlPreview.appex"
XPC_REL="$APPEX_REL/Contents/XPCServices/com.mdql.app.open-url.xpc"

[ -d "$APP" ] || {
	echo "error: no app bundle at $APP" >&2
	exit 1
}
for f in "$APP_ENTITLEMENTS" "$APPEX_ENTITLEMENTS"; do
	[ -f "$f" ] || {
		echo "error: no entitlements at $f" >&2
		exit 1
	}
done

identities="$(security find-identity -v -p codesigning)"

# The team a candidate identity would actually sign with, read out of its
# certificate's OU. Not out of the common name: the name carries the team only for
# Developer ID ("Developer ID Application: Lars Kluge (GUGQ9MB76A)"), while an Apple
# Development certificate's parenthetical is the developer's own ID and not the
# team's — "Apple Development: l@larskluge.com (QQRT5HT574)" is a GUGQ9MB76A
# certificate. OU is the field codesign reports back as TeamIdentifier, so this asks
# the same question check_one asks at the end of the run, before signing rather than
# after.
team_of() {
	security find-certificate -c "$1" -p 2>/dev/null |
		openssl x509 -noout -subject 2>/dev/null |
		sed -n 's/.*OU=\([^,/]*\).*/\1/p' | head -1
}

# Every identity whose name contains $1 *and* whose certificate is team $TEAM_ID, one
# bare common name per line. The team filter is the point: a Mac with a second
# Developer ID, or with a personal-team "Apple Development" certificate, otherwise
# gets all six items signed by the wrong authority and finds out at check_one, which
# reports the wrong team without hinting that the fix is choosing another identity.
pick() {
	local name team
	# `|| true` because grep exits 1 when nothing matches, which here is an answer and
	# not a failure — under `pipefail` it would otherwise exit the whole script before
	# the "no identity available" message below could explain what happened.
	{ printf '%s\n' "$identities" | grep -F "$1" || true; } |
		sed -E 's/^[^"]*"(.*)"$/\1/' |
		while IFS= read -r name; do
			# A certificate this Mac lists but cannot produce is not assumed to be the
			# right team: it is named and skipped, so a run that then finds no identity
			# at all says why rather than looking like an empty keychain.
			if ! team="$(team_of "$name")" || [ -z "$team" ]; then
				echo "warning: could not read a team out of the certificate for '$name'; skipping it." >&2
			elif [ "$team" = "$TEAM_ID" ]; then
				printf '%s\n' "$name"
			fi
		done
}

matches="$(pick "Developer ID Application")"
kind="Developer ID — distributable, notarizable"
if [ -z "$matches" ]; then
	matches="$(pick "Apple Development")"
	kind="Apple Development — local install only, NOT notarizable"
fi

if [ -z "$matches" ]; then
	echo "error: no codesigning identity available for team $TEAM_ID." >&2
	echo "  Create one in Xcode: Settings -> Accounts -> select the $TEAM_ID team ->" >&2
	echo "  Manage Certificates -> + -> 'Developer ID Application' (needed to notarize)" >&2
	echo "  or 'Apple Development' (enough for a local install)." >&2
	exit 1
fi

# Two certificates of the same kind on the same team — a renewal overlap, or a second
# Developer ID — is not something to settle by taking the first. codesign is handed
# the *name*, and refuses an ambiguous one anyway; saying which ones matched is the
# difference between a fixable message and a mystery.
if [ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" -gt 1 ]; then
	echo "error: team $TEAM_ID has more than one '$kind' identity on this Mac:" >&2
	printf '%s\n' "$matches" | sed 's/^/    /' >&2
	echo "  Remove the one you do not sign releases with in Keychain Access; codesign" >&2
	echo "  cannot be given an ambiguous identity name." >&2
	exit 1
fi
identity="$matches"

echo "Signing $APP"
echo "  identity: $identity"
echo "  kind:     $kind"

# --- Everything inside, deepest first ---------------------------------------
#
# Nested bundles and loose Mach-O executables alike, discovered rather than listed:
# a hardcoded list of mdql's three items is a list that silently stops being complete
# the day a fourth target is added, and an unsigned nested binary is a notarization
# rejection rather than a build error.
#
# Symlinks are skipped by `-type d`/`-type f`, since signing through one seals the
# wrong path.
#
# Sorted by path depth, descending: an executable inside a bundle is signed before
# the bundle that contains it, or sealing the bundle records a hash of a binary that
# is about to change.

nested_items() {
	# Nested bundles.
	find "$APP" -type d \( \
		-name "*.framework" -o -name "*.app" -o -name "*.xpc" -o \
		-name "*.appex" -o -name "*.bundle" -o -name "*.systemextension" \
		\) ! -path "$APP"
	# Loose Mach-O files. `file` rather than the executable bit: a shell script in
	# Resources is executable and must not be signed as code, and a dylib is Mach-O
	# without being executable.
	find "$APP" -type f | while read -r f; do
		case "$(file -b "$f")" in
		Mach-O*) printf '%s\n' "$f" ;;
		esac
	done
}

# Which entitlements each discovered item is signed with, decided by the innermost
# bundle it belongs to — so the appex's own executable is treated like the appex, and
# the XPC service's like the XPC service. Prints the entitlements path, prints
# nothing for the items that must carry none, and returns non-zero for a path the
# mapping has no answer for: a target added later must be signed deliberately rather
# than inheriting whichever arm happened to catch it.
#
# Order matters — the XPC service's path is also under the appex's.
entitlements_for() {
	case "${1#"$APP"/}" in
	"$XPC_REL" | "$XPC_REL"/*) ;;
	"$APPEX_REL" | "$APPEX_REL"/*) printf '%s' "$APPEX_ENTITLEMENTS" ;;
	"$MAIN_REL") printf '%s' "$APP_ENTITLEMENTS" ;;
	*) return 1 ;;
	esac
}

# awk counts slashes so `sort -rn` puts the deepest path first. A file rather than an
# array: /bin/bash on macOS is 3.2, which has neither `mapfile` nor a safe way to
# expand an empty array under `set -u`.
ORDER_FILE="$(mktemp)"
trap 'rm -f "$ORDER_FILE"' EXIT
nested_items | awk -F/ '{print NF"\t"$0}' | sort -rn | cut -f2- >"$ORDER_FILE"
nested_count="$(wc -l <"$ORDER_FILE" | tr -d ' ')"

while IFS= read -r item; do
	[ -n "$item" ] || continue
	rel="${item#"$APP"/}"
	if ! ent="$(entitlements_for "$item")"; then
		echo "error: no entitlements decision for $rel." >&2
		echo "  Add it to entitlements_for() in scripts/codesign-app.sh. Whether a new" >&2
		echo "  nested target is sandboxed is a product decision, not a default." >&2
		exit 1
	fi
	if [ -n "$ent" ]; then
		codesign --force --sign "$identity" \
			--entitlements "$ent" \
			--options runtime --timestamp "$item"
		echo "  nested:   $rel  <- ${ent#"$PROJECT_DIR"/}"
	else
		codesign --force --sign "$identity" --options runtime --timestamp "$item"
		echo "  nested:   $rel  <- no entitlements, by design"
	fi
done <"$ORDER_FILE"

# --- Then the app itself ----------------------------------------------------
#
# mdql/mdql.entitlements is an empty <dict/>, so this is equivalent to signing with
# none. It is passed anyway: the app's signature should be derived from a file in the
# repo that someone chose, not from an omission nobody would notice changing.

codesign --force --sign "$identity" \
	--entitlements "$APP_ENTITLEMENTS" \
	--options runtime --timestamp \
	"$APP"

# --- Verify, and verify what actually matters -------------------------------
#
# `--verify --strict` walks nested code and is the check that the seals agree — but
# only one level down. mdql's XPC service lives *inside* the appex, and a plain
# `--strict` walk never visits it: tamper with the .xpc's Info.plist after a clean
# sign and this still reports "valid on disk" and exits 0. `--deep` is what descends
# the second level. Apple deprecates `--deep` for *signing*, where it would stamp one
# entitlements file onto everything; for verifying it is neither deprecated nor
# optional here.
#
# It is still not the check that these are the *right* seals — it passes just as
# happily on a nested binary that was left ad-hoc signed with no authority at all,
# inside an app whose outer signature is Developer ID. So every code item is asked, by
# name, who signed it and whether it has the hardened runtime: the two things Apple's
# notary refuses on, and the two a green build says nothing about.
#
# Then the entitlements are read back out of the signature, because nothing else in
# the pipeline looks at them and a wrong answer there is invisible until a stranger
# opens a .md file and gets a blank window.

codesign --verify --strict --deep --verbose=2 "$APP"

problems=0

check_one() {
	local path="$1" label="$2" info team flags
	info="$(codesign -dvv "$path" 2>&1)" || {
		echo "error: $label is not signed at all." >&2
		problems=$((problems + 1))
		return
	}
	team="$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p' | head -1)"
	# Only the flags field. `flags=` is mid-line on codesign's CodeDirectory line, so
	# taking the rest of it puts `hashes=250+7 location=embedded` inside the error
	# below, where it reads like part of the complaint and buries the one value the
	# reader has to act on.
	flags="$(printf '%s\n' "$info" | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p' | head -1)"
	if [ "$team" != "$TEAM_ID" ]; then
		echo "error: $label is signed by team '${team:-none}', expected '$TEAM_ID'." >&2
		problems=$((problems + 1))
	fi
	case "$flags" in
	*runtime*) ;;
	*)
		echo "error: $label has no hardened runtime (flags=${flags:-none}); Apple will reject it." >&2
		problems=$((problems + 1))
		;;
	esac
}

# `codesign -d --entitlements -` prints nothing at all when an item has none. When it
# has any, the shape depends on the toolchain: older codesign prints a `[Dict]` header
# and one `[Key] <name>` line per entitlement, newer versions print an XML plist.
#
# The read is a separate step from the tests so that "could not ask" and "asked, and
# the answer was none" stay distinguishable: both are empty output.
embedded_entitlements() {
	local path="$1" label="$2"
	codesign -d --entitlements - "$path" 2>/dev/null || {
		echo "error: could not read entitlements back from $label." >&2
		return 1
	}
}

# The entitlement key names in that output, one per line — and non-zero for output in
# neither shape. The XPC service's test below is a *negative* one, so an unrecognised
# shape looks exactly like "no entitlements": a future Xcode changing the format would
# turn the one check that would notice the XPC service gaining a sandbox into a check
# that always passes. Both known shapes are parsed, and anything else is an error.
entitlement_keys() {
	case "$1" in
	"") ;; # no entitlements at all
	*"[Dict]"*) printf '%s\n' "$1" | sed -n 's/^.*\[Key\] //p' ;;
	*"<plist"*) printf '%s\n' "$1" | sed -n 's|.*<key>\(.*\)</key>.*|\1|p' ;;
	*) return 1 ;;
	esac
}

unreadable_entitlements() {
	echo "error: could not read the entitlements of $1 in a form this script understands." >&2
	printf '%s\n' "$2" | sed 's/^/    /' >&2
	echo "  Neither a [Dict]/[Key] dump nor an XML plist. Treating that as 'no entitlements'" >&2
	echo "  is how a sandboxed XPC service would ship unnoticed, so it is a failure instead." >&2
	echo "  Teach entitlement_keys() in scripts/codesign-app.sh the new shape." >&2
}

has_key() { printf '%s\n' "$1" | grep -qxF "$2"; }

if ! appex_ents="$(embedded_entitlements "$APP/$APPEX_REL" "$APPEX_REL")"; then
	problems=$((problems + 1))
elif ! appex_keys="$(entitlement_keys "$appex_ents")"; then
	unreadable_entitlements "$APPEX_REL" "$appex_ents"
	problems=$((problems + 1))
else
	if ! has_key "$appex_keys" com.apple.security.app-sandbox; then
		echo "error: $APPEX_REL is signed without com.apple.security.app-sandbox." >&2
		echo "  A Quick Look preview extension has to be sandboxed; macOS will not load it." >&2
		echo "  Sign it with ${APPEX_ENTITLEMENTS#"$PROJECT_DIR"/}." >&2
		problems=$((problems + 1))
	fi
	if ! has_key "$appex_keys" com.apple.security.network.client; then
		echo "error: $APPEX_REL is signed without com.apple.security.network.client." >&2
		echo "  Without it WKWebView renders a blank preview inside the sandbox, and nothing" >&2
		echo "  about the signature looks wrong. Sign it with ${APPEX_ENTITLEMENTS#"$PROJECT_DIR"/}." >&2
		problems=$((problems + 1))
	fi
fi

if ! xpc_ents="$(embedded_entitlements "$APP/$XPC_REL" "$XPC_REL")"; then
	problems=$((problems + 1))
elif ! xpc_keys="$(entitlement_keys "$xpc_ents")"; then
	unreadable_entitlements "$XPC_REL" "$xpc_ents"
	problems=$((problems + 1))
elif [ -n "$xpc_keys" ]; then
	echo "error: $XPC_REL carries entitlements:" >&2
	printf '%s\n' "$xpc_keys" | sed 's/^/    /' >&2
	echo "  It is unsandboxed by design — it exists because the sandboxed extension cannot" >&2
	echo "  call NSWorkspace.open or read sibling .md files. Sandbox it and the one feature" >&2
	echo "  it was written for stops working. Sign it with no --entitlements at all." >&2
	problems=$((problems + 1))
fi

while IFS= read -r item; do
	[ -n "$item" ] || continue
	check_one "$item" "${item#"$APP"/}"
done <"$ORDER_FILE"
check_one "$APP" "$(basename "$APP")"

# Discovery keeps the item list from going stale; this keeps discovery from quietly
# finding less than a release needs. An mdql.app built without its extension launches,
# signs, notarizes and previews nothing — there is no other point in the pipeline
# where that shows up as an error.
for required in \
	"$MAIN_REL" \
	"$APPEX_REL/Contents/MacOS/mdqlPreview" \
	"$XPC_REL/Contents/MacOS/com.mdql.app.open-url"; do
	if ! grep -qxF "$APP/$required" "$ORDER_FILE"; then
		echo "error: $required is missing from $APP — it was never built or never copied in." >&2
		problems=$((problems + 1))
	fi
done

if [ "$problems" -ne 0 ]; then
	echo >&2
	echo "error: $problems code item(s) in $APP are not signed the way a release needs." >&2
	echo "  Every nested binary must carry team $TEAM_ID and the hardened runtime, the" >&2
	echo "  preview extension must be sandboxed with network access, and the XPC service" >&2
	echo "  must have no entitlements." >&2
	exit 1
fi

echo "  team:     $TEAM_ID (verified across $nested_count nested item(s) and the app)"
echo "  ents:     appex sandboxed with network.client, xpc service unsandboxed (read back from the signature)"
