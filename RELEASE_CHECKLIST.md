# SwiftMediaMetadata 3.0 Release Checklist

The release workflow publishes a macOS arm64 CLI archive when the plain
semantic-version tag `3.0.0` is pushed. SwiftPM clients consume the same tag
directly from the repository.

## Before tagging

- [x] Review the intended 3.0 scope and confirm the source-breaking
  `XMPValue.languageAlternative` addition requires a major release.
- [x] Date the 3.0.0 changelog section and set the CLI version to `3.0.0`.
- [x] Review `MIGRATION.md` for exhaustive-switch guidance and adoption examples
  for synchronization, projection, structured patches, timestamps, transactional
  sidecars, capabilities, semantic comparison, and typed GPS.
- [x] Run `Scripts/verify-release.sh 3.0.0` on macOS. It runs library and CLI
  tests, builds the archive, smoke-tests the bundled geolocation resource,
  verifies archive contents/version, and writes the SHA-256 file.
- [x] Compile the `SwiftMediaMetadata` library target for arm64 iOS 16.
- [x] Run the 50,000-input parser-hardening profile under Address Sanitizer.
- [x] Resolve a clean throwaway SwiftPM consumer against the exact release
  checkout and compile `import SwiftMediaMetadata` plus a public API smoke call.
- [x] Review the generated archive, checksum, and release notes.
- [ ] Commit the final release metadata with a clean worktree.
- [ ] Confirm required CI checks pass for the exact release commit.

## Publish

- [ ] Create an annotated `3.0.0` tag on the reviewed release commit.
- [ ] Push the tag. `.github/workflows/release.yml` reruns the complete preflight
  and publishes the archive plus checksum to the GitHub release.
- [ ] Confirm the GitHub release is public and its notes describe the exhaustive
  `XMPValue` switch migration and the new metadata workflow APIs.
- [ ] Download the published archive on a clean arm64 Mac, verify its checksum,
  and run:

  ```sh
  ./swift-exif-macos-arm64/swift-exif --version
  ./swift-exif-macos-arm64/swift-exif geocode --lat 59.9139 --lon 10.7522
  ```

## Homebrew and documentation

- [ ] Update `aagedal/homebrew-tap` to version 3.0.0 using the published archive
  URL and SHA-256. Install the executable and
  `SwiftMediaMetadata_SwiftMediaMetadata.bundle` together; geocoding requires
  the adjacent resource bundle.
- [ ] Test a clean `brew upgrade aagedal/tap/swift-exif`, `swift-exif --version`,
  and the Oslo geocode smoke command.
- [ ] Update the README SwiftPM and direct-download examples from 2.0.0 to 3.0.0
  only after the public tag and assets exist.
- [ ] Commit and push the post-release installation-documentation update.

## Downstream follow-up

- [ ] Rebase and merge Photo Agent's SwiftMediaMetadata adoption branch, replace
  its candidate-revision pin with the published 3.0.0 tag, and rerun its complete
  release gates. This is intentionally downstream of the package release.
