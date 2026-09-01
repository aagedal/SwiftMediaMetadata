# SwiftMediaMetadata Improvement Plan

This document tracks cross-cutting improvements that are larger than a single
format fix. Keep implementation notes and acceptance criteria here; user-facing
changes still belong in `CHANGELOG.md`.

## Status

- [x] 1. Unify filesystem writes and support modification-date preservation
- [x] 2. Rename the package and library module for the 2.0 release
- [x] 3. Add continuous integration for supported products and platforms
- [x] 4. Rebaseline roadmap, changelog, and installation documentation
- [x] 5. Reduce the compile-time cost of the generated geolocation database
- [x] 6. Add persistent fuzz and property testing for binary parsers/writers
- [ ] 7. Split oversized API files without breaking the public API
- [ ] 8. Prepare and publish the 2.0 release

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

Status: Completed 2026-09-01

- [x] Re-run the ExifTool/ffprobe comparison corpus before replacing the stale
  parity snapshot.
- [x] Add missing changelog entries for tags 1.9.9 and 1.9.10.
- [x] Audit package and CLI installation instructions against release artifacts.
- [x] Ensure supported-format tables and known limitations agree with the code.

Completion notes:

- The latest published GitHub release remains 1.6.0, the tap formula points to
  a retired Codeberg 1.8.1 artifact, and no 2.0.0 tag exists yet. README install
  instructions now use `main` for the renamed package and avoid promising an
  unavailable CLI binary.
- Updated the supported-format table for safe versus unsafe RAW writes, writable
  GIF/PDF/MP4/SVG metadata, and the previously omitted BMP, ARRIRAW, and IVF
  readers.
- Added `Scripts/parity_report.py` so the comparison contract, tool invocations,
  discovery scope, and JSON details are reproducible rather than living in a
  temporary script.
- Re-ran the top-level corpora with ExifTool and ffprobe: all 18 still images
  matched the 32-field image contract; 4 of 35 video/audio files had no
  differences, with 128 field-level differences remaining across the rest.
- Replaced the stale parity snapshot and grouped the remaining video work by
  field family in `PARITY_PLAN.md`.

## 5. Geolocation database build cost

Status: Completed 2026-09-01

- [x] Benchmark clean build time and shipped size for the generated Swift literal.
- [x] Prototype a compact bundled resource with equivalent offline behavior.
- [x] Adopt it only if lookup performance remains acceptable and packaging works on
  every supported platform.

Completion notes:

- Replaced 2.5 MB / 54,156 lines of generated array literals with a versioned,
  bounds-checked 1.1 MB binary resource and a 229-line lazy decoder.
- Reduced the geolocation debug object from 12.0 MB to 102 KB. The debug CLI
  executable fell from 18.3 MB to 11.6 MB, plus the 1.1 MB resource bundle.
- Reduced a comparable cold scratch build of the library target from 177.35
  seconds to 37.41 seconds (79%); the SwiftPM-reported build phase fell from
  176.18 to 35.50 seconds.
- Kept the 33,536-city in-memory representation and k-d tree unchanged after
  loading. The first lookup, including decode and tree construction, completed
  in 0.414 seconds in the geolocation test run; subsequent tested lookups were
  below XCTest's displayed millisecond precision.
- Updated `Scripts/build_geolocation.swift` to regenerate the binary format and
  added database-integrity coverage alongside the existing city, distance,
  timezone, localization, and GPS-fill tests.
- Verified all 1,593 library tests (20 skipped, 0 failures), an arm64 iOS 16
  library build, and the packaged macOS release CLI. The release smoke test
  loaded the adjacent resource bundle and reverse-geocoded Oslo successfully.

## 6. Parser and writer hardening

Status: Completed 2026-09-01

- [x] Add reusable, deterministic fuzz entry points for TIFF/Exif, ISOBMFF,
  XMP, C2PA, and video bitstreams.
- [x] Add all-prefix truncation, oversized-length, nesting-depth, and
  write-read-write properties to the normal test suite.
- [x] Support longer reproducible local runs with configurable iteration count
  and seed.
- [x] Run the extended harness under Address Sanitizer; retain minimized
  regression inputs whenever a future run finds a failure.

Implementation notes:

- `ParserHardeningPropertyTests` keeps a fast 256-input deterministic byte-soup
  pass in every normal test run and exercises every truncation of representative
  valid inputs.
- `Scripts/run-parser-fuzzing.sh` raises the same harness to 50,000 inputs by
  default. `SWIFT_METADATA_FUZZ_ITERATIONS` and `SWIFT_METADATA_FUZZ_SEED` make
  failures repeatable without maintaining a separate parser implementation.
- Existing depth-limit regression tests cover ISOBMFF traversal, JUMBF, XMP,
  CBOR, TIFF child IFDs, and GPMF containers.

Completion notes:

- Verified the normal 256-input profile, the 50,000-input extended profile, and
  the same 50,000-input profile under Address Sanitizer with no failures.
- No new crashing input was found to minimize. Existing previously minimized
  overflow/depth cases remain committed beside their owning parser tests.

## 7. API maintainability

Status: Planned

- Split `ImageMetadata.swift` into focused extensions by responsibility.
- Separate filesystem concerns from metadata serialization.
- Standardize write results and warnings across media types in a future
  source-compatible step; defer type moves or removals to a major release.

## 8. Version 2.0 release

Status: In progress

- [x] Keep the CLI version, package/module rename, migration notes, and changelog
  aligned on 2.0.0.
- [x] Add one local preflight that runs library/CLI tests, builds and smoke-tests
  the archive, verifies its contents, and produces a SHA-256 checksum.
- [x] Add a tag-driven GitHub release workflow that accepts only plain semantic
  version tags, uses the 2.0 changelog section as release notes, and uploads the
  verified macOS arm64 archive and checksum.
- [x] Include the license and required geolocation resource bundle in the CLI
  archive.
- [x] Document the exact pre-tag, publish, Homebrew, and post-release checks in
  `RELEASE_CHECKLIST.md`.
- [x] Complete the pre-tag checklist and replace the changelog's `Unreleased`
  marker with the actual release date.
- [ ] Push the reviewed 2.0.0 tag and verify the published GitHub artifacts.
- [ ] Update and smoke-test the external Homebrew tap using the published
  archive checksum.
- [ ] Switch README installation examples from pre-release instructions to the
  published tag and verified Homebrew formula.
