#!/usr/bin/env bash
# Cross-compile swift-exif for macOS (arm64, x86_64, universal) and fully
# static Linux (x86_64-musl, aarch64-musl). Output lands under ./dist/.
#
# Prerequisites:
#   - Xcode 16+ / Swift 6.3+ on macOS
#   - Swift Static Linux SDK installed:
#       swift sdk install https://download.swift.org/swift-6.3.1-release/static-sdk/swift-6.3.1-RELEASE/swift-6.3.1-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
#         --checksum fac05271c1f7d060bd203240ce5251d5ca902d30ac899f553765dbb3a88b97ad

set -euo pipefail

cd "$(dirname "$0")/.."

# The Static Linux SDK is compiled against the open-source swift.org toolchain,
# not the one Xcode ships. Source swiftly's env so `swift` resolves to the
# matching swift.org release (6.3.1-RELEASE).
if [ -f "$HOME/.swiftly/env.sh" ]; then
  # shellcheck disable=SC1091
  source "$HOME/.swiftly/env.sh"
fi

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

# Cross-compiling release with `-O` / `-Osize` + whole-module-optimization
# stalls the swift-6.3.1-linux-musl optimizer indefinitely (frontend pinned at
# ~100% CPU without ever producing a binary). `-Onone` compiles in a few
# minutes and produces a working static ELF. The resulting binary is larger
# and slower than macOS but still a self-contained CLI tool.
build_linux_static() {
  local arch="$1"   # x86_64 or aarch64
  local triple="${arch}-swift-linux-musl"
  echo "==> Linux ${arch}-musl (static)"

  # Locate the SDK's libz.a for this arch. The `link "z"` in the modulemap
  # alone isn't honored under --static-swift-stdlib, so we pass the archive
  # path explicitly.
  local sdk_root="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.1-RELEASE_static-linux-0.1.0.artifactbundle/swift-6.3.1-RELEASE_static-linux-0.1.0/swift-linux-musl/musl-1.2.5.sdk"
  local libz="${sdk_root}/${arch}/usr/lib/libz.a"
  if [ ! -f "$libz" ]; then
    echo "error: missing static libz at $libz — is the Static Linux SDK installed?" >&2
    return 1
  fi

  swift build -c release \
    --swift-sdk "$triple" \
    --static-swift-stdlib \
    --product swift-exif \
    -Xswiftc -Onone \
    -Xlinker "$libz" \
    --disable-sandbox

  local src=".build/${triple}/release/swift-exif"
  local out="$DIST/swift-exif-linux-${arch}"
  cp "$src" "$out"

  # Strip debug info first; UPX needs a clean ELF.
  local llvm_strip
  if command -v llvm-strip >/dev/null; then
    llvm_strip=llvm-strip
  elif [ -x /opt/homebrew/opt/llvm/bin/llvm-strip ]; then
    llvm_strip=/opt/homebrew/opt/llvm/bin/llvm-strip
  fi
  if [ -n "${llvm_strip:-}" ]; then "$llvm_strip" "$out"; fi

  # UPX shrinks the binary from ~70 MB to ~25 MB at the cost of a few
  # hundred milliseconds of one-time decompression at startup. Skip
  # silently if UPX isn't installed.
  if command -v upx >/dev/null; then
    upx --best --no-progress "$out" >/dev/null 2>&1 || true
  fi

  file "$out"
}

# Clean previous products (keeps cache).
rm -f "$DIST"/swift-exif-*

build_mac arm64
build_mac x86_64

build_linux_static x86_64
build_linux_static aarch64

echo
echo "Artifacts:"
ls -lh "$DIST"
echo
echo "Host binary quick smoke test:"
"$DIST/swift-exif-macos-arm64" --version
