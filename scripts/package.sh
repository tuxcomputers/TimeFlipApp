#!/usr/bin/env bash
# Builds a release Facet.app and wraps it in a disk image somebody else can install from.
#
#   scripts/package.sh              universal (arm64 + x86_64), the one to send
#   scripts/package.sh --arm64      Apple Silicon only, faster, for a local check
#   scripts/package.sh --output DIR somewhere other than dist/
#
# **What it produces is not notarized, and it says so.** Notarization needs a "Developer ID
# Application" certificate, which needs a paid Apple Developer Program membership. With an
# "Apple Development" certificate, or with none at all, macOS on the recipient's machine refuses
# the first launch until they clear it by hand, and the Read Me inside the image is what tells them
# how. See docs/distribution.md for the upgrade path.
#
# The recipient needs no Swift, no Xcode and no Mint: the image carries the built app.
set -euo pipefail

cd "$(dirname "$0")/.."

ARCH_ARGS=(--universal)
ARCH_LABEL="universal (Apple Silicon and Intel)"
OUTPUT_DIR="dist"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --arm64)
            ARCH_ARGS=(--arch arm64)
            ARCH_LABEL="arm64 only (Apple Silicon)"
            ;;
        --output)
            [ "$#" -ge 2 ] || { echo "error: --output needs a directory" >&2; exit 2; }
            OUTPUT_DIR="$2"
            shift
            ;;
        -h|--help)
            sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "error: unknown argument '$1' -- expected --arm64, --output DIR or --help" >&2
            exit 2
            ;;
    esac
    shift
done

VERSION="$(sed -n "s/^version = '\(.*\)'$/\1/p" Bundler.toml | head -1)"
[ -n "$VERSION" ] || { echo "error: no version found in Bundler.toml" >&2; exit 1; }

COMMIT="$(git rev-parse --short HEAD)"
DIRTY=""
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    DIRTY=" (with uncommitted changes)"
fi
BUILT_ON="$(date '+%Y-%m-%d')"

echo "Packaging Facet $VERSION from $COMMIT$DIRTY, $ARCH_LABEL."
echo

# The only source of the Google client that travels with a binary. A build sent to somebody else
# without it can do everything except sign in, so this is reported rather than assumed.
scripts/generate-credentials.sh
if [ -f Sources/FacetApp/Resources/google-client.json ]; then
    CREDENTIALS="bundled"
else
    CREDENTIALS="absent"
    echo
    echo "WARNING: no Google OAuth client is going into this build, so whoever you send it to"
    echo "         cannot connect a Google account. Everything else works. See docs/google-oauth-setup.md."
fi
echo

# Ad-hoc where there is no certificate, exactly as scripts/run.sh does it. An ad-hoc signature is
# enough for the app to run once Gatekeeper has been cleared, and it is what a fork with no Apple
# account gets.
IDENTITY="$(scripts/codesign-identity.sh)"
SIGN_ARGS=()
case "$IDENTITY" in
    "Developer ID Application:"*) SIGNING="Developer ID: $IDENTITY"; NOTARIZABLE=1 ;;
    "")                           SIGNING="ad-hoc (no certificate on this machine)"; NOTARIZABLE=0 ;;
    *)                            SIGNING="$IDENTITY"; NOTARIZABLE=0 ;;
esac
# Signed with whatever certificate there is, notarizable or not, for the reason
# scripts/codesign-identity.sh gives: an ad-hoc signature makes every build a different application
# to the Keychain, and the Google refresh token stops being readable without a prompt.
if [ -n "$IDENTITY" ]; then
    SIGN_ARGS=(--codesign --identity "$IDENTITY")
fi
echo "Signing: $SIGNING"
echo

BUNDLE=".build/bundler/apps/Facet/Facet.app"
rm -rf "$BUNDLE"
mint run stackotter/swift-bundler@main bundle Facet \
    --configuration release "${ARCH_ARGS[@]}" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}
[ -d "$BUNDLE" ] || { echo "error: the build produced no bundle at $BUNDLE" >&2; exit 1; }

echo
echo "Checking the signature that came out:"
codesign --verify --strict --verbose=2 "$BUNDLE" 2>&1 | sed 's/^/  /'

# Gatekeeper's own verdict, printed whatever it is. It is `rejected` for everything short of a
# notarized Developer ID build, and that rejection is precisely what the Read Me is written for, so
# a non-zero exit here is a result rather than a failure.
echo
echo "What Gatekeeper makes of it on this machine:"
spctl --assess --type execute --verbose=4 "$BUNDLE" 2>&1 | sed 's/^/  /' || true

# The executable is named for the app (Facet), not for the SwiftPM product (FacetApp), so it is read
# off the plist rather than guessed at.
PLIST="$BUNDLE/Contents/Info.plist"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
ARCHS="$(lipo -archs "$BUNDLE/Contents/MacOS/$EXECUTABLE")"
MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST" 2>/dev/null || echo 'unset')"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
VOLUME="$STAGING/Facet $VERSION"
mkdir -p "$VOLUME"
cp -R "$BUNDLE" "$VOLUME/Facet.app"
ln -s /Applications "$VOLUME/Applications"

cat > "$VOLUME/Read Me First.txt" <<READ_ME
Facet $VERSION
Built $BUILT_ON from $COMMIT, $ARCH_LABEL, macOS $MINIMUM or later.

1. INSTALL

   Drag Facet across onto the Applications shortcut in this window.

2. THE FIRST LAUNCH WILL BE REFUSED, AND THAT IS EXPECTED

   This build is not notarized by Apple, so the first time you open it macOS says it cannot
   check it for malicious software. Nothing is wrong with the download. To get past it:

     Open Applications, double-click Facet, and read the message.
     Then open System Settings > Privacy & Security, scroll to the bottom, and press
     "Open Anyway" beside Facet. Confirm, and it opens.

   You only do this once. Every later launch is normal.

3. THERE IS NO WINDOW AND NO DOCK ICON

   Facet lives in the menu bar, at the top right of the screen, and nowhere else. If nothing
   seems to happen when you open it, look up there rather than at the Dock. Clicking it opens
   the menu; Settings is in that menu.

4. WHAT IT NEEDS

   macOS $MINIMUM or later. It asks for Bluetooth the first time it looks for a device, which
   it needs to talk to a TimeFlip2 cube. Say yes, or it cannot find one. Without a cube it
   still works: you can time activities from the menu bar by hand.

   A Google account is optional, and only used to copy what you record into a calendar Facet
   makes for itself. It never reads your existing calendars.

5. WHERE YOUR DATA GOES

   One SQLite file, on your own machine, at:
     ~/Library/Application Support/Facet/

   Nothing is sent anywhere except the Google calendar, and only if you connect an account.

6. TO UNINSTALL

   Quit it from the menu bar, drag Facet out of Applications, and delete the folder above.

HELP AND DOCUMENTATION

   https://facet.tux.com.au

   Bugs and feedback: https://github.com/tuxcomputers/TimeFlipApp/issues
READ_ME

mkdir -p "$OUTPUT_DIR"
DMG="$OUTPUT_DIR/Facet-$VERSION.dmg"
rm -f "$DMG"

hdiutil create \
    -volname "Facet $VERSION" \
    -srcfolder "$VOLUME" \
    -ov -format UDZO \
    "$DMG" >/dev/null

if [ -n "$IDENTITY" ]; then
    codesign --sign "$IDENTITY" --timestamp "$DMG"
fi

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

echo
echo "Built $DMG"
echo "  version    $VERSION ($COMMIT$DIRTY)"
echo "  built      $BUILT_ON"
echo "  contains   $ARCHS, macOS $MINIMUM or later"
echo "  signing    $SIGNING"
echo "  Google     credentials $CREDENTIALS"
echo "  size       $SIZE"
echo "  sha256     $SHA"
echo

if [ "$NOTARIZABLE" = "1" ]; then
    echo "This is signed with a Developer ID, so it CAN be notarized, and it has not been."
    echo "Until it is, the recipient still has to clear Gatekeeper by hand. Two commands:"
    echo
    echo "  xcrun notarytool submit \"$DMG\" --keychain-profile facet-notary --wait"
    echo "  xcrun stapler staple \"$DMG\""
    echo
    echo "See docs/distribution.md for setting the keychain profile up the first time."
else
    echo "NOT NOTARIZED, and it cannot be from this machine: notarization needs a"
    echo "\"Developer ID Application\" certificate and there is none here. Whoever you send this"
    echo "to has to clear Gatekeeper by hand, and the Read Me inside the image tells them how."
    echo "docs/distribution.md is what to do about that permanently."
fi
