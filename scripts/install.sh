#!/bin/bash
#
# Install mdql.app to /Applications and register the QuickLook extension.
#
# Usage: scripts/install.sh <built-products-dir>
#
# Called by both the Xcode post-build phase and `make install`.
# Single source of truth for installation and registration cleanup.
# (AppDelegate cannot do this — the app is sandboxed.)

set -euo pipefail

BUILT_PRODUCTS_DIR="${1:?Usage: $0 <built-products-dir>}"

APP_NAME="mdql.app"
INSTALL_DIR="/Applications"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
DERIVED_DATA_DIR="$HOME/Library/Developer/Xcode/DerivedData"

# 1. Copy to /Applications and re-sign (without --deep to preserve extension signature)
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME"
cp -R "$BUILT_PRODUCTS_DIR/$APP_NAME" "$INSTALL_DIR/$APP_NAME"
codesign --force --sign - "$INSTALL_DIR/$APP_NAME" 2>/dev/null || true
echo "Installed $APP_NAME to $INSTALL_DIR"

# 2. Unregister all DerivedData builds
for dir in "$DERIVED_DATA_DIR"/mdql-*/Build/Products/*/; do
    app="$dir$APP_NAME"
    [ -d "$app" ] || continue
    "$LSREGISTER" -u "$app" 2>/dev/null || true
done
# Also unregister paths that no longer exist on disk
"$LSREGISTER" -dump 2>/dev/null | grep 'path:' | grep "DerivedData.*$APP_NAME " | grep -v '.appex' | while read -r line; do
    path="$(echo "$line" | sed 's/.*path: *//' | sed 's/ *(0x.*//')"
    "$LSREGISTER" -u "$path" 2>/dev/null || true
done || true

# 3. Unregister stale sandbox container dirs
"$LSREGISTER" -u "$HOME/Library/Application Scripts/com.mdql.app" 2>/dev/null || true
"$LSREGISTER" -u "$HOME/Library/WebKit/com.mdql.app" 2>/dev/null || true

# 4. Register from /Applications and reset QuickLook
"$LSREGISTER" -f -R "$INSTALL_DIR/$APP_NAME"
qlmanage -r 2>/dev/null || true

# 5. Launch app to finalize pluginkit registration, then quit
#    (pluginkit only discovers extensions when the host app is launched)
if [ "${SKIP_LAUNCH:-}" != "1" ]; then
    open "$INSTALL_DIR/$APP_NAME"
    sleep 2
    osascript -e 'quit app "mdql"' 2>/dev/null || true
fi

echo "Registered $INSTALL_DIR/$APP_NAME"
