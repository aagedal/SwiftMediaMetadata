#!/usr/bin/env bash

# Run the complete, reproducible preflight for a SwiftMediaMetadata release.
# This script prepares and verifies the archive but deliberately does not create
# a git tag, push anything, or publish a GitHub release.

set -euo pipefail

cd "$(dirname "$0")/.."

expected_version="${1:-}"
if [[ ! "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: Scripts/verify-release.sh <major.minor.patch>" >&2
  exit 64
fi

source_version="$({
  sed -n 's/^[[:space:]]*version: "\([0-9][0-9.]*\)",$/\1/p' Sources/CLI/SwiftMediaMetadata.swift
} | head -n 1)"
if [[ "$source_version" != "$expected_version" ]]; then
  echo "CLI source version is '$source_version', expected '$expected_version'" >&2
  exit 1
fi

echo "==> Validate package manifest"
release_tmp="$(mktemp -d)"
trap 'rm -rf "$release_tmp"' EXIT
swift package dump-package > "$release_tmp/package.json"
grep -q '"name" : "SwiftMediaMetadata"' "$release_tmp/package.json"

echo "==> Run library tests"
swift test --filter SwiftMediaMetadataTests

echo "==> Run black-box CLI tests"
Scripts/run-cli-tests.sh

echo "==> Build release archive"
Scripts/build-release.sh

artifact="dist/swift-exif-macos-arm64.tar.gz"
binary="dist/swift-exif-macos-arm64/swift-exif"
bundle="dist/swift-exif-macos-arm64/SwiftMediaMetadata_SwiftMediaMetadata.bundle"

test -x "$binary"
test -d "$bundle"
test -f "dist/swift-exif-macos-arm64/LICENSE"
test -f "$artifact"

actual_version="$($binary --version)"
if [[ "$actual_version" != "$expected_version" ]]; then
  echo "Built CLI reports '$actual_version', expected '$expected_version'" >&2
  exit 1
fi

archive_listing="$(tar -tzf "$artifact")"
grep -q '^swift-exif-macos-arm64/swift-exif$' <<< "$archive_listing"
grep -q '^swift-exif-macos-arm64/SwiftMediaMetadata_SwiftMediaMetadata.bundle/' <<< "$archive_listing"
grep -q '^swift-exif-macos-arm64/LICENSE$' <<< "$archive_listing"

(
  cd dist
  shasum -a 256 "$(basename "$artifact")" > "$(basename "$artifact").sha256"
)

awk '
  /^## \[2\.0\.0\]/ { in_release = 1; next }
  in_release && /^## \[/ { exit }
  in_release { print }
' CHANGELOG.md > dist/release-notes.md
grep -q '\*\*Breaking:\*\*' dist/release-notes.md

echo
echo "Release preflight passed for $expected_version"
cat "$artifact.sha256"
