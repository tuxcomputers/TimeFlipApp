#!/bin/sh
set -e

cd "$(dirname "$0")/.."

DB_DIR="$HOME/Library/Application Support/Facet"

args=""
for arg in "$@"; do
    case "$arg" in
        --rebuild)
            echo "Forcing a clean rebuild..."
            rm -rf .build
            ;;
        --clean)
            printf "This will delete the local databases -- the appdata.sqlite symlink,\n"
            printf "production.sqlite, test.sqlite and the debug.sqlite trace (%s). Continue? [y/N] " "$DB_DIR"
            read -r confirm < /dev/tty
            case "$confirm" in
                [yY]|[yY][eE][sS])
                    echo "Deleting local database..."
                    # `debug` among them since 2026-08-22: the trace is its own file now, and a "clean" that
                    # left it behind would carry every row from before the wipe into whatever came next.
                    for db in appdata production test debug; do
                        rm -f "$DB_DIR/$db.sqlite" "$DB_DIR/$db.sqlite-wal" "$DB_DIR/$db.sqlite-shm"
                    done
                    ;;
                *)
                    echo "Aborted; database left untouched."
                    exit 1
                    ;;
            esac
            ;;
        *)
            args="$args $arg"
            ;;
    esac
done

# Signed with a real certificate where there is one, and ad-hoc where there is not.
#
# **This is what stops macOS asking for Keychain access after every rebuild.** An ad-hoc signature's designated
# requirement is the cdhash of the binary, so every build is a different application as far as the Keychain is
# concerned and the permission granted to the last one matches nothing. A certificate makes the requirement
# `identifier "au.com.tux.facet" and anchor apple generic and certificate leaf[subject.CN] = "..."`, which is the
# same for every build, so "Always Allow" is answered once and holds.
#
# Found rather than configured, so a contributor with no certificate still gets a working script: without one the
# app is ad-hoc signed exactly as before, and the only cost is the prompt. `FACET_CODESIGN_IDENTITY` overrides the
# search for anyone holding more than one.
identity="$(scripts/codesign-identity.sh)"

# Before the build, always: this is what puts the Google client into the binary, and it is the only source
# that travels with it. Run every time rather than when missing, so pointing at a different project is a
# matter of changing the file and building. It exits 0 with no credentials and says so, which is a fork's
# ordinary case.
scripts/generate-credentials.sh

if [ -n "$identity" ]; then
    echo "Signing as: $identity"
    mint run stackotter/swift-bundler@main run Facet --codesign --identity "$identity" $args
else
    printf 'No codesigning identity found, so this build is ad-hoc signed.\n'
    printf 'macOS will ask for Keychain access again after every rebuild; see docs/google-oauth-setup.md.\n'
    mint run stackotter/swift-bundler@main run Facet $args
fi
