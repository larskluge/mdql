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
# Both overridable, so scripts/test_install.py can run this against a scratch directory
# and a stub. Prefixed because Xcode exports an INSTALL_DIR of its own to build phases.
INSTALL_DIR="${MDQL_INSTALL_DIR:-/Applications}"
LSREGISTER="${MDQL_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister}"
VIEWER="${APP_NAME%.app}" # the process name of the app, which is also the standalone viewer

# Pids of every running viewer, whichever bundle it was launched from.
viewer_pids() {
    pgrep -x -U "$(id -u)" "$VIEWER" || [ $? -eq 1 ] # 1: none running
}

# The documents a viewer is showing, one per line. FileWatcher holds each open
# event-only (O_EVTONLY, 0x8000), which `lsof +fg` reports and which sets them apart
# from the regular files WebKit and Metal keep open in the same process.
viewer_documents() { # <pid>
    local line type="" flags=0
    lsof -p "$1" +fg -F ftGn | while IFS= read -r line; do
        case "$line" in
        f*) type="" && flags=0 ;;
        t*) type="${line#t}" ;;
        G*) flags="${line#G}" && flags="${flags%%;*}" ;;
        n*) if [ "$type" = REG ] && ((flags & 0x8000)); then printf '%s\n' "${line#n}"; fi ;;
        esac
    done
}

# Ask one process to quit, the way the Dock's Quit does. By pid, because a quit addressed
# to the name reaches a single process: `osascript -e 'quit app "mdql"'` with two viewers
# running quits the newer one and exits 0, which is how an install once left the older
# one, documents open, running the build it had just replaced.
quit_viewer() { # <pid>
    osascript -l JavaScript -e 'ObjC.import("AppKit")
function run(argv) {
    const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(argv[0]))
    if (app.isNil()) throw new Error(`no running application has pid ${argv[0]}`)
    if (!app.terminate) throw new Error(`pid ${argv[0]} could not be sent a quit request`)
}' "$1"
}

# Quit the given viewers and wait for each to go, which takes a fraction of a second
# unless the viewer cannot answer at all: one that hangs, or is stopped in a debugger.
# Prints the pids still running after 5 s, and says why on stderr.
quit_viewers() { # <pid>...
    local pid error tries
    for pid in "$@"; do
        error="$(quit_viewer "$pid" 2>&1)" || true # reported below, if the viewer is still there
        tries=50
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$tries" -eq 0 ]; then
                echo "error: $VIEWER (pid $pid) did not quit${error:+: $error}" >&2
                echo "$pid"
                break
            fi
            tries=$((tries - 1))
            sleep 0.1
        done
    done
}

# 1. Copy to /Applications and re-sign (without --deep to preserve extension signature)
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME"
cp -R "$BUILT_PRODUCTS_DIR/$APP_NAME" "$INSTALL_DIR/$APP_NAME"
codesign --force --sign - "$INSTALL_DIR/$APP_NAME" 2>/dev/null || true
echo "Installed $APP_NAME to $INSTALL_DIR"

# 2. Unregister every other mdql.app LaunchServices knows of: DerivedData builds,
#    `make dist` output, a release zip unpacked to be checked. Whether the bundle still
#    exists does not matter. A second registration is a second app as far as
#    LaunchServices is concerned, and it has launched one beside the running viewer to
#    open a document.
"$LSREGISTER" -dump | sed -n 's/^[[:space:]]*path:[[:space:]]*\(.*\) (0x[0-9a-f]*)$/\1/p' | sort -u | while IFS= read -r path; do
    case "$path" in
    "$INSTALL_DIR/$APP_NAME") ;;
    */"$APP_NAME") "$LSREGISTER" -u "$path" || echo "warning: could not unregister $path from LaunchServices" >&2 ;;
    esac
done || {
    echo "error: could not read the LaunchServices registrations (lsregister -dump)" >&2
    exit 1
}

# 3. Unregister stale sandbox container dirs
"$LSREGISTER" -u "$HOME/Library/Application Scripts/com.mdql.app" 2>/dev/null || true
"$LSREGISTER" -u "$HOME/Library/WebKit/com.mdql.app" 2>/dev/null || true

# 4. Register from /Applications and reset QuickLook
"$LSREGISTER" -f -R "$INSTALL_DIR/$APP_NAME"
qlmanage -r 2>/dev/null || true

# 5. Launch the app to finalize pluginkit registration
#    (pluginkit only discovers extensions when the host app is launched)
#
#    A viewer that is already running is the build this install replaced, and `open`
#    would only bring it forward. So every one is quit first, and the documents they
#    were showing are reopened in the new build, which is then left running. With
#    nothing to reopen, the app is launched for pluginkit's sake and quit again.
running="$(viewer_pids)"
if [ "${SKIP_LAUNCH:-}" = "1" ]; then
    # The Xcode build phase, which launches nothing: the viewer stays as it is. Said
    # in the form Xcode lists as a build warning.
    if [ -n "$running" ]; then
        echo "warning: $VIEWER (pid ${running//$'\n'/ }) is running the build this one replaced. Run \`make install\`, or quit and reopen it." >&2
    fi
else
    # Every viewer's documents, as `<pid> <tab> <path>` lines, before any viewer is quit:
    # once one is gone there is nothing left to ask, and a document that is not reopened
    # is a window lost.
    showing=""
    for pid in $running; do
        documents="$(viewer_documents "$pid")" || {
            kill -0 "$pid" 2>/dev/null || continue # it quit by itself in the meantime
            echo "error: could not list the documents $VIEWER (pid $pid) has open, so no viewer was quit." >&2
            echo "       It is running the build this install replaced: quit and reopen it." >&2
            exit 1
        }
        while IFS= read -r document; do
            [ -z "$document" ] || showing+="$pid"$'\t'"$document"$'\n'
        done <<<"$documents"
    done

    stale="$(quit_viewers $running)"
    stale="${stale//$'\n'/ }"

    # What the viewers that quit were showing, each document once. A viewer that is
    # still running still has its windows.
    reopen=()
    seen=$'\n'
    while IFS=$'\t' read -r pid document; do
        [ -n "$document" ] || continue
        case " $stale " in *" $pid "*) continue ;; esac
        case "$seen" in *$'\n'"$document"$'\n'*) continue ;; esac
        seen+="$document"$'\n'
        if [ -f "$document" ]; then
            reopen+=("$document")
        else
            echo "Not reopening $document, which no longer exists."
        fi
    done <<<"${showing%$'\n'}"

    if [ ${#reopen[@]} -gt 0 ]; then
        open -a "$INSTALL_DIR/$APP_NAME" "${reopen[@]}" || {
            echo "error: could not reopen the documents the viewer was showing:" >&2
            printf '  %s\n' "${reopen[@]}" >&2
            exit 1
        }
        echo "Relaunched $VIEWER on the new build, showing:"
        printf '  %s\n' "${reopen[@]}"
    elif [ -z "$stale" ]; then
        open "$INSTALL_DIR/$APP_NAME"
        sleep 2
        [ -z "$(quit_viewers $(viewer_pids))" ] || exit 1
    fi

    if [ -n "$stale" ]; then
        echo "error: $VIEWER (pid $stale) is still running the build this install replaced." >&2
        echo "       Quit it and reopen its documents to get the new one." >&2
        exit 1
    fi
fi

echo "Registered $INSTALL_DIR/$APP_NAME"
