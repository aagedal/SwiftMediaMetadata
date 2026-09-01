#!/usr/bin/env bash
# Build the swift-exif CLI for macOS (arm64). Output lands under ./dist/ as a
# tarball containing the executable, its SwiftPM resource bundle, and license.
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
  local artifact_name="swift-exif-macos-${arch}"
  local out_dir="$DIST/$artifact_name"
  local archive="$DIST/${artifact_name}.tar.gz"
  rm -rf "$out_dir"
  rm -f "$archive"
  mkdir -p "$out_dir"
  cp ".build/${arch}-apple-macosx/release/swift-exif" "$out_dir/swift-exif"
  cp -R ".build/${arch}-apple-macosx/release/SwiftMediaMetadata_SwiftMediaMetadata.bundle" "$out_dir/"
  cp LICENSE "$out_dir/LICENSE"
  strip -x "$out_dir/swift-exif"
  file "$out_dir/swift-exif"
  tar -czf "$archive" -C "$DIST" "$artifact_name"
}

build_mac arm64

echo
echo "Artifacts:"
ls -lh "$DIST"
echo
echo "Host binary quick smoke test:"
"$DIST/swift-exif-macos-arm64/swift-exif" --version
"$DIST/swift-exif-macos-arm64/swift-exif" geocode --lat 59.9139 --lon 10.7522
