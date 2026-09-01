# SwiftMediaMetadata Improvement Plan

This document tracks cross-cutting improvements that are larger than a single
format fix. Keep implementation notes and acceptance criteria here; user-facing
changes still belong in `CHANGELOG.md`.

## Status

- [x] 1. Unify filesystem writes and support modification-date preservation
- [x] 2. Rename the package and library module for the 2.0 release
- [x] 3. Add continuous integration for supported products and platforms
- [ ] 4. Rebaseline roadmap, changelog, and installation documentation
- [ ] 5. Reduce the compile-time cost of the generated geolocation database
- [ ] 6. Add persistent fuzz and property testing for binary parsers/writers
- [ ] 7. Split oversized API files without breaking the public API

## 1. Unified filesystem writes and modification dates

Status: Completed 2026-09-01

### Goals

- Use one internal implementation for atomic replacement, direct writes,
  backups, temporary-file cleanup, and filesystem attribute handling.
- Preserve the existing default behavior: successful writes update the file's
  modification date.
- Let callers preserve an existing destination timestamp during an in-place
  edit or assign a known source timestamp when writing a new destination.
- Offer the same write policy for images, videos, audio files, XMP sidecars,
  batch processing, and conditional batch processing.
- Keep `VideoMetadata.modificationDate` explicitly separate: it is embedded
  container metadata, not the filesystem modification date.

### Acceptance criteria

- [x] A shared internal file-commit helper owns all media/sidecar disk writes.
- [x] `ImageMetadata.WriteOptions` has a source-compatible modification-date
  policy whose default retains today's behavior.
- [x] Image and video writers use the shared helper.
- [x] Audio and XMP sidecar writers accept write options and use the helper.
- [x] Batch APIs accept and forward write options.
- [x] Atomic and non-atomic tests cover default, preserve-existing, and explicit
  timestamp behavior for existing and new destinations.
- [x] Backup and temporary-file behavior remains covered.
- [x] The full package test suite passes.

Completion notes:

- Added `.update`, `.preserveExisting`, and `.set(Date)` policies.
- Added `-P` / `--preserve-file-modification-date` to mutating CLI commands.
- Verified 1,642 package tests (48 skipped, 0 failures) and all 50 opt-in CLI
  tests (0 failures).

## 2. SwiftMediaMetadata 2.0 rename

Status: Completed 2026-09-01

### Goals

- Rename the Swift package, library product, module, source target, and test
  targets from `SwiftExif` to `SwiftMediaMetadata`.
- Point installation and release documentation at the renamed GitHub repository.
- Remove the retired Codeberg remote and update `origin` to the renamed GitHub
  repository.
- Keep the installed `swift-exif` command stable; this rename is about the
  package and library API surface.
- Publish the change as a deliberate 2.0 source-breaking migration, without an
  old-module compatibility target that would preserve the naming collision.

### Acceptance criteria

- [x] Clients build with `import SwiftMediaMetadata` and the new product name.
- [x] Source and test directories match their renamed SwiftPM targets.
- [x] README installation examples use the new repository URL and distinguish
  the pre-release `main` branch from the future 2.0 version tag.
- [x] The changelog documents the breaking migration and stable CLI name.
- [x] Git remotes contain only the renamed GitHub repository.
- [x] The full package and opt-in CLI test suites pass after a clean rebuild.
- [x] Remaining `SwiftExif` references are intentional migration/history notes.

Completion notes:

- Renamed the package, library product/module, source target, and both test
  targets to `SwiftMediaMetadata`; retained the `swift-exif` executable name.
- Updated `origin` to `https://github.com/aagedal/SwiftMediaMetadata.git` and
  removed the retired Codeberg remote.
- Set the CLI version to 2.0.0 and documented the 1.x import migration.
- Verified 1,642 package tests (48 skipped, 0 failures), all 50 opt-in CLI tests
  (0 failures), the SwiftPM package description, and `swift-exif --version`.

## 3. Continuous integration

Status: Completed 2026-09-01

- [x] Run the core Swift test suite on macOS.
- [x] Run black-box CLI tests with `SWIFT_EXIF_RUN_CLI_TESTS=1`.
- [x] Compile-check the library for every platform advertised in `Package.swift`.
- [x] Keep optional external-fixture/ffmpeg tests visibly reported as skipped.

Completion notes:

- Added GitHub Actions checks for the macOS library suite, the opt-in
  black-box CLI suite, and an arm64 iOS 16 library build.
- Kept the library and CLI suites as separate checks so optional test skips and
  failures are visible in the check that owns them.
- Verified 1,592 library tests (20 skipped, 0 failures), all 50 opt-in CLI
  tests (0 failures), and the iOS cross-compile command with the iPhoneOS SDK.

## 4. Roadmap and release documentation

Status: In progress

- [ ] Re-run the ExifTool/ffprobe comparison corpus before replacing the stale
  parity snapshot.
- [x] Add missing changelog entries for tags 1.9.9 and 1.9.10.
- [x] Audit package and CLI installation instructions against release artifacts.
- [x] Ensure supported-format tables and known limitations agree with the code.

Progress notes:

- The latest published GitHub release remains 1.6.0, the tap formula points to
  a retired Codeberg 1.8.1 artifact, and no 2.0.0 tag exists yet. README install
  instructions now use `main` for the renamed package and avoid promising an
  unavailable CLI binary.
- Updated the supported-format table for safe versus unsafe RAW writes, writable
  GIF/PDF/MP4/SVG metadata, and the previously omitted BMP, ARRIRAW, and IVF
  readers.
- Located both comparison corpora under the current account. Rebaselining is
  still pending because the `/tmp` harness is gone and ExifTool is not installed.

## 5. Geolocation database build cost

Status: Planned

- Benchmark clean build time and shipped size for the generated Swift literal.
- Prototype a compact bundled resource with equivalent offline behavior.
- Adopt it only if lookup performance remains acceptable and packaging works on
  every supported platform.

## 6. Parser and writer hardening

Status: Planned

- Add reusable fuzz entry points for TIFF/Exif, ISOBMFF, XMP, C2PA, and video
  bitstreams.
- Add truncation, oversized-length, nesting-depth, and write-read-write
  properties to the normal test suite.
- Retain minimized regression inputs when fuzzing finds a failure.

## 7. API maintainability

Status: Planned

- Split `ImageMetadata.swift` into focused extensions by responsibility.
- Separate filesystem concerns from metadata serialization.
- Standardize write results and warnings across media types in a future
  source-compatible step; defer type moves or removals to a major release.
