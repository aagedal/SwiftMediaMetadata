# SwiftMediaMetadata 3.0.1 Release Checklist

The release workflow publishes a macOS arm64 CLI archive when the plain
semantic-version tag `3.0.1` is pushed. SwiftPM clients consume the same tag
directly from the repository.

## Before tagging

- [x] Confirm the RTMD change is source- and ABI-compatible and retains
  file-absolute sample-offset behavior.
- [x] Add RTMD discovery, sample-offset, negative, and extended-size regression
  coverage.
- [x] Repair the bare-JPEG fixture lookup for current SwiftPM resource bundles.
- [x] Make release packaging discover SwiftPM's current binary output path.
- [x] Date the 3.0.1 changelog section and set the CLI version to `3.0.1`.
- [x] Run `Scripts/verify-release.sh 3.0.1` on macOS. It runs library and CLI
  tests, builds the archive, smoke-tests the bundled geolocation resource,
  verifies archive contents/version, and writes the SHA-256 file.
- [x] Compile the `SwiftMediaMetadata` library target for arm64 iOS 16.
- [x] Review the generated archive, checksum, and release notes.
- [ ] Commit the final release metadata with a clean worktree.
- [ ] Confirm required CI checks pass for the exact release commit.

## Publish

- [ ] Create an annotated `3.0.1` tag on the reviewed release commit.
- [ ] Push the tag. `.github/workflows/release.yml` reruns the complete preflight
  and publishes the archive plus checksum to the GitHub release.
- [ ] Confirm the GitHub release is public and its notes describe the RTMD memory
  fix and its regression coverage.
- [ ] Download the published archive on a clean arm64 Mac, verify its checksum,
  and run:

  ```sh
  ./swift-exif-macos-arm64/swift-exif --version
  ./swift-exif-macos-arm64/swift-exif geocode --lat 59.9139 --lon 10.7522
  ```
- [ ] Confirm the README's 3.0.1 release and download links resolve.

## Homebrew and documentation

- [ ] Update `aagedal/homebrew-tap` to version 3.0.1 using the published archive
  URL and SHA-256. Install the executable and
  `SwiftMediaMetadata_SwiftMediaMetadata.bundle` together; geocoding requires
  the adjacent resource bundle.
- [ ] Test a clean `brew upgrade aagedal/tap/swift-exif`, `swift-exif --version`,
  and the Oslo geocode smoke command.
- [x] Update the README SwiftPM and direct-download examples to 3.0.1.

## Downstream follow-up

- [ ] Pin Aagedal Media Player to the published 3.0.1 tag and repeat the
  full-application memory profile before shipping the app update.
