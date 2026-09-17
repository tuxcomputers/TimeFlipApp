#!/usr/bin/env bash
# Builds a patched Swift Bundler and prints the path to it.
#
# **Why this exists rather than `mint run stackotter/swift-bundler@main`.** Swift 6.4 (Xcode 27) made
# `swiftbuild` SwiftPM's default build system, and it writes a target's resource bundle in the macOS
# layout, with the resources under `Contents/Resources`, where the `native` build system wrote them at
# the bundle's root. Swift Bundler reads the bundle's root either way, so under the new toolchain the
# app receives a `Contents` directory and none of the resources: the build and the codesign both
# succeed and the launch aborts in `DatabaseBootstrap` looking for 001_event_type.sql.
#
# macos-resource-layout.patch is the fix, and it reads whichever layout the bundle is in, so a build
# under either toolchain produces the same app. **It is meant to go away.** Once it is upstream, this
# directory and the two call sites in scripts/run.sh and scripts/package.sh go with it.
#
# Progress goes to stderr and only the binary's path to stdout, so a caller can capture it:
#
#     bundler="$(scripts/swift-bundler/build.sh)"
set -euo pipefail

# The commit the patch is written against, pinned rather than tracking `main`: a floating branch means
# the patch can stop applying on a morning nobody changed anything here.
COMMIT="c4c8a25c2744bbbf3f333f3a2510dd83301c246d"
REPO="https://github.com/stackotter/swift-bundler"

cd "$(dirname "$0")/../.."
PATCH="$PWD/scripts/swift-bundler/macos-resource-layout.patch"
# Outside `.build` deliberately: `scripts/run.sh --rebuild` deletes that whole directory, and a clean
# rebuild of the app is not a request to rebuild the tool that bundles it.
CHECKOUT="$PWD/.tools/swift-bundler"
BINARY="$CHECKOUT/.build/release/swift-bundler"

# Rebuilt when the patch is newer than the binary, so editing the patch is enough to get a new tool.
if [ -x "$BINARY" ] && [ "$BINARY" -nt "$PATCH" ]; then
    echo "$BINARY"
    exit 0
fi

echo "Building a patched Swift Bundler (a few minutes, once)..." >&2

if [ ! -d "$CHECKOUT/.git" ]; then
    rm -rf "$CHECKOUT"
    mkdir -p "$(dirname "$CHECKOUT")"
    git clone --quiet --filter=blob:none "$REPO" "$CHECKOUT" >&2
fi

git -C "$CHECKOUT" fetch --quiet origin "$COMMIT" >&2 || true
git -C "$CHECKOUT" checkout --quiet --force "$COMMIT" >&2
git -C "$CHECKOUT" clean -qfd >&2
git -C "$CHECKOUT" apply "$PATCH" >&2

swift build --package-path "$CHECKOUT" -c release --product swift-bundler >&2

[ -x "$BINARY" ] || { echo "error: the build produced no binary at $BINARY" >&2; exit 1; }

echo "$BINARY"
