# SwiftMediaMetadata 2.0 Release Checklist

The release workflow publishes a macOS arm64 CLI archive when a plain semantic
version tag such as `2.0.0` is pushed. SwiftPM clients consume the same tag
directly from the repository.

## Before tagging

- [x] Review all changes intended for 2.0 and confirm the worktree is clean.
- [x] Replace `Unreleased` in the 2.0.0 changelog heading with the release date.
- [x] Confirm `Sources/CLI/SwiftMediaMetadata.swift` reports `2.0.0`.
- [x] Run `Scripts/verify-release.sh 2.0.0` on macOS. It runs library and CLI
  tests, builds the archive, smoke-tests the bundled geolocation resource,
  verifies archive contents/version, and writes the SHA-256 file.
- [x] Review the 1.x migration note and supported-format table in `README.md`.
- [x] Commit the final release metadata.

## Publish

- [x] Create an annotated `2.0.0` tag on the reviewed release commit.
- [x] Push the tag. `.github/workflows/release.yml` reruns the complete preflight
  and publishes the archive plus checksum to the GitHub release.
- [x] Confirm the GitHub release is public and its changelog-derived notes
  accurately describe the breaking module/package rename.
- [x] Download the published archive on a clean arm64 Mac and run:

  ```sh
  ./swift-exif-macos-arm64/swift-exif --version
  ./swift-exif-macos-arm64/swift-exif geocode --lat 59.9139 --lon 10.7522
  ```

## Homebrew and documentation

- [x] Update `aagedal/homebrew-tap` to version 2.0.0 using the published archive
  URL and SHA-256. Install the executable and
  `SwiftMediaMetadata_SwiftMediaMetadata.bundle` together; geocoding requires
  the adjacent resource bundle.
- [x] Test a clean `brew install aagedal/tap/swift-exif`, `swift-exif --version`,
  and the Oslo geocode smoke command.
- [x] Replace the README's pre-release `branch: "main"` SwiftPM dependency with
  `from: "2.0.0"`, restore the verified Homebrew install command, and remove
  the warning that the 2.0 binary is unpublished.
- [x] Commit and push the post-release installation-documentation update.

## Final verification

- [x] Resolve a throwaway SwiftPM package against `from: "2.0.0"` and compile
  `import SwiftMediaMetadata`.
- [x] Confirm the release page, checksum link, README links, and changelog compare
  link all resolve against the renamed repository.
- [x] Record any deferred hardening/API-maintainability work in
  `IMPROVEMENT_PLAN.md`; it is not a reason to silently expand the 2.0 API.
