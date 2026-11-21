#!/bin/bash
# The "Stamp version" build phase of mdql, mdqlPreview and mdql-open-url.
#
#   stamp-version.sh <stamp file> <built Info.plist> [<version.txt>]
#
# Writes the version and build number the mdql-version target computed into this
# bundle's built Info.plist, and with a third argument the badge into version.txt.
# Every bundle reads the one stamp file, written once per build, so the three can
# never disagree: macOS refuses to load an app extension whose CFBundleVersion
# differs from its containing app's.
set -euo pipefail

usage="usage: scripts/stamp-version.sh <stamp file> <Info.plist> [<version.txt>]"
stamp="${1:?$usage}"
plist="${2:?$usage}"
badge_out="${3:-}"

[ -f "$stamp" ] || {
	echo "error: no stamp file at $stamp. The mdql-version target writes it" >&2
	echo "       (scripts/version.py --write), and every bundle target depends on it." >&2
	exit 1
}
version="$(sed -n 1p "$stamp")"
build="$(sed -n 2p "$stamp")"
badge="$(sed -n 3p "$stamp")"
[ -n "$version" ] && [ -n "$build" ] && [ -n "$badge" ] || {
	echo "error: $stamp should hold the version, the build number and the badge," >&2
	echo "       one per line; it holds:" >&2
	sed 's/^/       /' "$stamp" >&2
	exit 1
}

plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$build" "$plist"
if [ -n "$badge_out" ]; then
	mkdir -p "$(dirname "$badge_out")"
	printf '%s\n' "$badge" >"$badge_out"
fi
echo "stamped $version ($build) into $plist"
