#!/usr/bin/env bash
# Build the swift-exif CLI for macOS (arm64). Output lands under ./dist/.
#
# Linux static builds are no longer produced as part of the release.
# See "Building from source" in README.md for the recipe a downstream
# contributor can follow to cross-compile a static-musl Linux binary.

set -euo pipefail

cd "$(dirname "$0")/.."

DIST="$(pwd)/dist"
mkdir -p "$DIST"

build_mac() {
  local arch="$1"
  echo "==> macOS ${arch}"
  swift build -c release \
    --arch "$arch" \
    --product swift-exif \
    --disable-sandbox
  local out="$DIST/swift-exif-macos-${arch}"
  cp ".build/${arch}-apple-macosx/release/swift-exif" "$out"
  strip -x "$out"
  file "$out"
}

# Clean previous macOS products (keeps SwiftPM cache).
rm -f "$DIST"/swift-exif-macos-*

build_mac arm64

echo
echo "Artifacts:"
ls -lh "$DIST"
echo
echo "Host binary quick smoke test:"
"$DIST/swift-exif-macos-arm64" --version
