#!/bin/bash
#
# Upgrade mdqlPreview/Resources/mermaid.min.js (the vendored Mermaid runtime).
#
# The preview inlines this file into every rendered HTML document that contains
# a ```mermaid fence. It is never loaded from the network at runtime — bump the
# pinned version + sha256 here and re-run to upgrade.

set -euo pipefail

VERSION="11.12.2"
SHA256="d0830a6c05546e9edb8fe20a8f545f3e0dc7c4c3134d584bad9c13a99d7a71e0"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

curl -fsSL "https://unpkg.com/mermaid@${VERSION}/dist/mermaid.min.js" -o "$TMP"
echo "$SHA256  $TMP" | shasum -a 256 -c -
mv "$TMP" mdqlPreview/Resources/mermaid.min.js
trap - EXIT

echo "mermaid.min.js ${VERSION} installed ($(shasum -a 256 mdqlPreview/Resources/mermaid.min.js | cut -d' ' -f1))"
