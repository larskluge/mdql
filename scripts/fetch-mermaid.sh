#!/bin/bash
#
# Installs the vendored Mermaid runtime, mdqlPreview/Resources/mermaid.min.js,
# from the release's npm registry tarball, after checking the tarball against
# the integrity the registry publishes for it. The release and the file's
# sha256 are pinned in scripts/mermaid.pin, which `make version-test` checks
# the vendored file against.
#
#   scripts/fetch-mermaid.sh           the pinned release again; refuses a file
#                                      that is not the pinned sha256
#   scripts/fetch-mermaid.sh 11.17.2   that release, pinned from here on
#
# Runs from any directory, on macOS and Linux (bash, curl, tar, python3). The
# preview never loads Mermaid from the network: this is the only download.
# MERMAID_REGISTRY and MDQL_ROOT exist for scripts/test_fetch_mermaid.py.

set -euo pipefail

ROOT="${MDQL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REGISTRY="${MERMAID_REGISTRY:-https://registry.npmjs.org}"
PIN="$ROOT/scripts/mermaid.pin"
TARGET="$ROOT/mdqlPreview/Resources/mermaid.min.js"

fail() { echo "fetch-mermaid: $*" >&2; exit 1; }

# shellcheck source-path=SCRIPTDIR source=mermaid.pin
source "$PIN"
VERSION="${1:-$MERMAID_VERSION}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "not a release version: $VERSION"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL "$REGISTRY/mermaid/$VERSION" -o "$WORK/release.json" \
    || fail "the registry has no mermaid@$VERSION ($REGISTRY/mermaid/$VERSION)"
# The tarball's URL and its sha512, as the registry publishes them.
{ read -r TARBALL; read -r INTEGRITY; } < <(python3 -I -c '
import json, sys
dist = json.load(open(sys.argv[1]))["dist"]
print(dist["tarball"])
print(dist.get("integrity", ""))
' "$WORK/release.json")
[[ "$INTEGRITY" == sha512-* ]] || fail "mermaid@$VERSION has no sha512 integrity in the registry"

curl -fsSL "$TARBALL" -o "$WORK/release.tgz" || fail "could not download $TARBALL"
ACTUAL="sha512-$(python3 -I -c '
import base64, hashlib, sys
print(base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())
' "$WORK/release.tgz")"
[ "$ACTUAL" = "$INTEGRITY" ] \
    || fail "mermaid@$VERSION's tarball is $ACTUAL; the registry publishes $INTEGRITY"

tar -xzf "$WORK/release.tgz" -C "$WORK" package/dist/mermaid.min.js \
    || fail "mermaid@$VERSION's tarball has no package/dist/mermaid.min.js"
SHA256="$(python3 -I -c '
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
' "$WORK/package/dist/mermaid.min.js")"
if [ $# -eq 0 ] && [ "$SHA256" != "$MERMAID_SHA256" ]; then
    fail "mermaid@$VERSION's mermaid.min.js is $SHA256; scripts/mermaid.pin pins $MERMAID_SHA256"
fi

mv "$WORK/package/dist/mermaid.min.js" "$TARGET"
cat > "$WORK/mermaid.pin" <<PIN
# The vendored Mermaid runtime, mdqlPreview/Resources/mermaid.min.js: its npm
# release and the file's sha256. Written by scripts/fetch-mermaid.sh, and
# checked against the file by scripts/test_fetch_mermaid.py (make version-test).
MERMAID_VERSION=$VERSION
MERMAID_SHA256=$SHA256
PIN
mv "$WORK/mermaid.pin" "$PIN"
echo "mermaid.min.js $VERSION installed ($SHA256)"
