#!/bin/sh
# Launch the archived app -- the previous implementation, built as it was at 3ee3b47 (the commit
# before "Archive the app sources ahead of the rebuild"), so it can be used for real time tracking
# while the rebuild is incomplete.
#
# The bundle is prebuilt and installed at ~/Applications/TimeFlip-old.app. It is not built from
# Archive/ on the fly, and could not be: Archive/ is outside every target path in the current
# Package.swift, and the manifest that compiled it (AppAuth, CoreBluetooth) is only in the old
# commit. Rebuilding it means a worktree at that commit -- see "Rebuilding" below.
#
# usage: scripts/old.sh [--console] [--rebuild]
#   (no flag)   launch detached, the way a menu bar app is normally started
#   --console   run in the foreground with its output on this terminal, Ctrl-C to quit
#   --rebuild   rebuild the bundle from the archived commit, then launch
set -e

APP="$HOME/Applications/TimeFlip-old.app"
BIN="$APP/Contents/MacOS/TimeFlip"
WORKTREE="$(cd "$(dirname "$0")/.." && pwd)-old"
OLD_COMMIT="3ee3b47"
DB_DIR="$HOME/Library/Application Support/TimeFlip"

console=no
rebuild=no
for arg in "$@"; do
    case "$arg" in
        --console) console=yes ;;
        --rebuild) rebuild=yes ;;
        *) echo "usage: $(basename "$0") [--console] [--rebuild]" >&2; exit 2 ;;
    esac
done

if [ "$rebuild" = yes ]; then
    if [ ! -d "$WORKTREE" ]; then
        echo "Creating a worktree at $OLD_COMMIT in $WORKTREE..."
        git -C "$(dirname "$0")/.." worktree add --detach "$WORKTREE" "$OLD_COMMIT"
    fi
    echo "Building the archived app (release)..."
    (cd "$WORKTREE" && mint run stackotter/swift-bundler@main bundle TimeFlip -c release)
    rm -rf "$APP"
    mkdir -p "$HOME/Applications"
    cp -R "$WORKTREE/.build/bundler/apps/TimeFlip/TimeFlip.app" "$APP"
    echo "Installed $APP"
fi

if [ ! -x "$BIN" ]; then
    echo "error: $APP is not installed. Run '$(basename "$0") --rebuild' to build it." >&2
    exit 1
fi

# The old app and the rebuild share a single-instance lock and a status item, so whichever is up
# owns the cube. Say which is running rather than letting the second one exit quietly on stderr
# nobody reads.
if pgrep -f "$BIN" > /dev/null 2>&1; then
    echo "The archived app is already running (pid $(pgrep -f "$BIN" | tr '\n' ' ')); nothing to do."
    exit 0
fi
if pgrep -f "\.build/bundler/apps/TimeFlip/TimeFlip\.app/Contents/MacOS/TimeFlip" > /dev/null 2>&1; then
    echo "The rebuild is running from .build; quit it first or the archived app will stand down." >&2
fi

# Both apps open whatever appdata.sqlite points at, and it is a symlink that scripts/switch-database.sh
# moves between the real database and the throwaway one. A day's tracking recorded into test.sqlite is
# a day's tracking lost, so name the target rather than assume it.
if [ -L "$DB_DIR/appdata.sqlite" ]; then
    linked=$(basename "$(readlink "$DB_DIR/appdata.sqlite")")
    echo "Database: $linked"
    if [ "$linked" != "production.sqlite" ]; then
        echo "  ^ not production.sqlite -- run scripts/switch-database.sh prod to record real time." >&2
    fi
fi

if [ "$console" = yes ]; then
    echo "Running $APP in the foreground; Ctrl-C to quit."
    exec "$BIN"
fi

# `open` by path rather than by bundle identifier: the rebuild carries the same identifier
# (dev.evernoob.timeflip), so asking Launch Services for the identifier could start either one.
open "$APP"
echo "Launched $APP -- it is a menu bar app (LSUIElement), so look in the status bar, not the Dock."
