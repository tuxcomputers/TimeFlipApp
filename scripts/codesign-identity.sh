#!/bin/sh
# Prints the codesigning identity to build with, or nothing when there is none.
#
# **One place, because two things build the app** -- `scripts/run.sh` and `Tests/Scripted/lib.sh` -- and a
# build that misses the identity is not obviously broken. It produces an ad-hoc signature, which is a
# different application as far as the Keychain is concerned, so the refresh token behind Google sync
# stops being readable without a prompt. That is not a build error, a test failure or anything visible:
# the sync simply never runs, and the app looks like it forgot how (measured 2026-08-16, when a hand-run
# `swift-bundler bundle` replaced a signed build and the scripted checks found the sweep silent).
#
# `FACET_CODESIGN_IDENTITY` overrides the search, for anyone holding more than one.
# See docs/google-oauth-setup.md for what to do when there is no identity at all.
if [ -n "${FACET_CODESIGN_IDENTITY:-}" ]; then
    printf '%s' "$FACET_CODESIGN_IDENTITY"
    exit 0
fi

security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Apple Development|Developer ID Application):' \
    | head -1 \
    | sed -E 's/.*"(.*)".*/\1/' \
    | tr -d '\n'
