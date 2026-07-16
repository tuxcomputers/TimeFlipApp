#!/bin/sh
set -e

cd "$(dirname "$0")/.."

DB_DIR="$HOME/Library/Application Support/TimeFlip"

args=""
for arg in "$@"; do
    case "$arg" in
        --rebuild)
            echo "Forcing a clean rebuild..."
            rm -rf .build
            ;;
        --clean)
            echo "Deleting local database..."
            rm -f "$DB_DIR/appdata.sqlite" "$DB_DIR/appdata.sqlite-wal" "$DB_DIR/appdata.sqlite-shm"
            ;;
        *)
            args="$args $arg"
            ;;
    esac
done

mint run stackotter/swift-bundler@main run TimeFlip $args
