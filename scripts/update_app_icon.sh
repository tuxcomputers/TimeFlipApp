#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SMALL_SVG="$ROOT_DIR/TimeFlipApp.small.svg"
FULL_SVG="$ROOT_DIR/TimeFlipApp.svg"
ICONSET_DIR="$ROOT_DIR/Sources/TimeFlipApp/Resources/AppIcon.iconset"
ICNS_PATH="$ROOT_DIR/Sources/TimeFlipApp/Resources/AppIcon.icns"

if [[ ! -f "$SMALL_SVG" ]]; then
  echo "Missing $SMALL_SVG" >&2
  exit 1
fi

if [[ ! -f "$FULL_SVG" ]]; then
  echo "Missing $FULL_SVG" >&2
  exit 1
fi

RENDERER=""
if command -v rsvg-convert >/dev/null 2>&1; then
  RENDERER="rsvg"
elif command -v inkscape >/dev/null 2>&1; then
  RENDERER="inkscape"
else
  echo "Install rsvg-convert (librsvg) or inkscape to render SVGs." >&2
  exit 1
fi

render_svg() {
  local svg_path="$1"
  local size="$2"
  local out_path="$3"

  if [[ "$RENDERER" == "rsvg" ]]; then
    rsvg-convert "$svg_path" -w "$size" -h "$size" -o "$out_path"
  else
    inkscape "$svg_path" \
      --export-type=png \
      --export-width="$size" \
      --export-height="$size" \
      --export-filename="$out_path" \
      >/dev/null
  fi
}

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Small SVG for 16/32/64px outputs (up to 32@2x).
render_svg "$SMALL_SVG" 16 "$ICONSET_DIR/icon_16x16.png"
render_svg "$SMALL_SVG" 32 "$ICONSET_DIR/icon_16x16@2x.png"
render_svg "$SMALL_SVG" 32 "$ICONSET_DIR/icon_32x32.png"
render_svg "$SMALL_SVG" 64 "$ICONSET_DIR/icon_32x32@2x.png"

# Full SVG for the remaining sizes.
render_svg "$FULL_SVG" 128 "$ICONSET_DIR/icon_128x128.png"
render_svg "$FULL_SVG" 256 "$ICONSET_DIR/icon_128x128@2x.png"
render_svg "$FULL_SVG" 256 "$ICONSET_DIR/icon_256x256.png"
render_svg "$FULL_SVG" 512 "$ICONSET_DIR/icon_256x256@2x.png"
render_svg "$FULL_SVG" 512 "$ICONSET_DIR/icon_512x512.png"
render_svg "$FULL_SVG" 1024 "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
echo "Wrote $ICNS_PATH"
