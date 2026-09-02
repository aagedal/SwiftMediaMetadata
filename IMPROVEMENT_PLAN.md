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
- [x] 7. Split oversized API files without breaking the public API
- [x] 8. Prepare and publish the 2.0 release
- [x] 9. Land the first standards-aware photo-metadata APIs for 2.1
- [x] 10. Complete the remaining 2.1 metadata workflow requests
- [ ] 11. Validate downstream adoption and prepare the next release

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
- [x] README installation examples use the new repository URL and the published
  2.0 version tag.
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

- At the time of the audit, the latest published GitHub release was 1.6.0 and
  the tap formula pointed to a retired Codeberg 1.8.1 artifact. Those findings
  drove the 2.0 release and Homebrew work recorded below.
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

Status: Completed 2026-09-01

- [x] Split `ImageMetadata.swift` into focused extensions by responsibility.
- [x] Separate filesystem commits from metadata serialization.
- [x] Standardize write results and warnings across media types in a
  source-compatible step; retain existing methods as compatibility wrappers.
- [x] Cover the common result contract, warning propagation, sidecar writes,
  and single-file batch processing with focused tests.
- [x] Reconcile Photo Agent's local fork: preserve ordered localized `rdf:Alt`
  values and filesystem visibility across atomic commits.
- [x] Run the full package, opt-in CLI, and iOS compile verification.

Completion notes:

- `ImageMetadata.swift` now contains only the core stored state and initializer;
  reading, writing, editing, extraction, sidecar, location, and format code live
  in focused extensions.
- `MetadataWriteResult<Data>` represents serialization and
  `MetadataWriteResult<URL>` represents a committed file across image, video,
  audio, and XMP writers. Existing write APIs delegate to the new contract.
- `FileCommitter` owns only the filesystem transaction and receives bytes that
  have already been serialized.
- Ported Photo Agent's localized-title carrier and atomic visibility fixes from
  its source-preserving 1.9.10 fork, including packet, embedded JPEG, exporter,
  visible-file, hidden-file, and new-destination regressions.
- Verified 1,688 package tests (48 skipped, 0 failures), all 50 opt-in CLI
  tests (0 failures), the arm64 iOS 16 library build, and 48 targeted Photo
  Agent localized-title, embedded-container, and export-visibility tests.
- SwiftPM's exported-API comparison against 2.0.0 reports the intentional new
  `XMPValue.languageAlternative` enum case as one breaking change. The 2.1
  changelog calls out the exhaustive-switch migration requirement; release
  versioning remains open until the rest of the planned feature set lands.

## 8. Version 2.0 release

Status: Completed 2026-09-01

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
- [x] Push the reviewed 2.0.0 tag and verify the published GitHub artifacts.
- [x] Update and smoke-test the external Homebrew tap using the published
  archive checksum.
- [x] Switch README installation examples from pre-release instructions to the
  published tag and verified Homebrew formula.

Completion notes:

- Published the annotated `2.0.0` tag and a public GitHub release containing the
  macOS arm64 CLI archive and SHA-256 checksum.
- Downloaded the public assets, verified the checksum and archive layout, and
  smoke-tested version reporting plus bundled Oslo reverse geocoding.
- Resolved a throwaway SwiftPM consumer at exactly 2.0.0 and compiled
  `import SwiftMediaMetadata` against the renamed product.
- Updated `aagedal/homebrew-tap` to the renamed repository, published archive,
  and matching checksum. A stable macOS 15 workflow installed the formula and
  passed its version and geocoding smoke tests.

## 9. Standards-aware photo metadata APIs

Status: Completed 2026-09-01; unreleased 2.1 work

- [x] Preserve ordered and fully tagged `rdf:Alt` values without weakening the
  scalar `x-default` convenience case.
- [x] Write `plus:ImageSupplier` as `rdf:Seq`.
- [x] Patch structures and structured-array items without dropping unknown
  sibling members; use that behavior in typed IPTC Extension and PLUS setters.
- [x] Preserve filesystem creation dates by default across atomic and direct
  writes, independently of modification-date behavior.
- [x] Stop using camera Make to classify rendered TIFFs as proprietary RAW;
  use known RAW URL extensions to disambiguate TIFF-based RAW containers.
- [x] Add policy-driven IPTC-IIM ↔ XMP synchronization with explicit merge,
  replace, clear, title, date-precision, and conflict-reporting behavior.
- [x] Add a typed, conflict-aware `PhotoMetadata` projection and canonical
  mutation API while retaining the complete raw XMP graph.

Completion notes:

- The compatibility `syncIPTCToXMP()` and `syncXMPToIPTC()` entry points keep
  their existing behavior. The new `synchronize…` entry points carry the safer
  policy contract.
- Photo Agent's 48 localized-title, embedded-container, and export-visibility
  tests pass against its retained source-preserving fork.
- Verified 1,688 package tests (48 skipped, 0 failures), all 50 opt-in CLI
  tests, and the arm64 iOS 16 library build. Exported-API comparison against
  2.0.0 reports only the intentional exhaustive-enum migration below.
- This work remains unreleased while the rest of the requested 2.1 scope is
  evaluated. No 2.1 tag should be created until that review is complete.

## 10. Remaining 2.1 metadata workflow requests

Status: Completed 2026-09-01; unreleased 2.1 work

### Transactional sidecar mutation

- [x] Define a public revision token and stale-revision error that do not rely
  on modification time alone.
- [x] Add an `XMPSidecar.update(...)` operation that reads the latest disk
  state, preserves unknown XMP, applies a caller mutation, validates the
  serialized packet, and commits through `FileCommitter`.
- [x] Support bounded retries when another writer wins the revision race;
  never silently overwrite a newer sidecar after the caller's base revision.
- [x] Read back the installed sidecar and return its new revision and warnings.
- [x] Forward write options so visibility, creation date, modification date,
  backups, and atomic replacement follow the shared filesystem contract.
- [x] Cover two-writer conflicts, retry success/exhaustion, mutation failure,
  invalid output, unknown-field preservation, and interrupted-write cleanup.

Implementation notes:

- `XMPSidecarRevision` fingerprints exact packet bytes with SHA-256 and byte
  count; `.missing` also supports create-only transactions without relying on
  filesystem date precision.
- `XMPSidecar.update` applies a mutation to the latest parsed graph, validates
  generated XML, compares revisions and commits under a cross-process directory
  lock, then reads back the installed revision before releasing the lock.
- Ordinary `XMPSidecar.write` calls use the same lock. A retry reapplies the
  mutation to the competing writer's state, while an already-stale caller base
  fails before mutation and cannot overwrite newer bytes.
- Verified 1,696 package tests (48 skipped, 0 failures), all 50 opt-in CLI
  tests, and the arm64 iOS 16 library build. The eight focused transactional
  tests import only the public module and cover both atomic and direct commits.

### Semantic comparison and carrier capabilities

- [x] Expose per-format read, write, and preservation capabilities for Exif,
  IPTC-IIM, XMP, Camera Raw, ICC, and C2PA metadata domains.
- [x] Represent partial support explicitly: readable, directly writable,
  sidecar-only, preserved opaquely, intentionally stripped, or unsupported.
- [x] Define canonical semantic identities for standardized Exif, IPTC-IIM,
  XMP, Camera Raw, and C2PA values without treating XML ordering, namespace
  prefixes, equivalent GPS/date spellings, or container layout as conflicts.
- [x] Produce a round-trip preservation report containing added, removed,
  changed, unrepresentable, and opaque-preserved values. The package reports
  facts; applications retain the policy decision about acceptable differences.
- [x] Add cross-container fixtures and write/read comparisons for every
  advertised writable format, including sidecar-only proprietary RAW.

### Typed XMP GPS conversion

- [x] Add decimal-degree accessors for XMP latitude, longitude, altitude, and
  direction/reference fields without discarding the original lexical values.
- [x] Parse decimal, directional decimal, degrees/minutes/seconds, and
  degrees/decimal-minutes forms, including hemisphere suffixes and references.
- [x] Emit spec-compliant XMP GPS strings from typed values with documented
  precision and stable round trips.
- [x] Validate coordinate ranges and reject contradictory sign/hemisphere
  inputs instead of silently changing meaning.
- [x] Reconcile typed XMP GPS with Exif GPS in the conflict-aware projection
  while retaining both carrier candidates when they disagree.
- [x] Cover poles, antimeridian, zero coordinates, all hemispheres, malformed
  input, precision retention, and Exif/XMP disagreement.

Completion notes:

- `ImageFormat.metadataCapabilities` separates read, write, and preservation
  behavior for every advertised image and RAW carrier. Proprietary RAW remains
  explicitly sidecar-only under the safe default contract.
- Semantic snapshots use expanded XMP names, normalized Exif numeric values,
  unordered IIM repeatables, canonical dates/GPS, exact ICC fingerprints, and
  canonical C2PA CBOR maps/assertion references. Preservation reports keep
  policy outside the package.
- `XMPGPSCoordinate` and `XMPGPSMetadata` retain source lexical values while
  exposing validated decimal coordinates, signed altitude, direction, and
  references. Writers use stable XMP coordinate and rational forms.
- Added 16 public-module tests for capabilities, comparison classification,
  semantic normalization, GPS parsing/emission, edge coordinates, malformed
  data, and XMP/Exif projection conflicts, alongside the existing per-format
  writer/read-back fixtures and proprietary-RAW sidecar coverage.
- Verified 1,712 package tests (48 skipped, 0 failures), all 50 opt-in CLI
  tests (0 failures), and the arm64 iOS 16 library build.

## 11. Downstream adoption and next-release readiness

Status: In progress; do not tag while final release metadata and verification are pending

- [x] Integrate the new synchronization, `PhotoMetadata`, structured-patch,
  creation-date, and TIFF-detection APIs into Photo Agent and identify which
  package workarounds can be removed safely.
- [x] Run Photo Agent's localized-title, embedded-container,
  export-visibility, sidecar-concurrency, and metadata-preservation suites
  against the package candidate rather than only its 1.9.10-based fork.
- [x] Confirm Camera Raw and app-private metadata remain owned by Photo Agent
  where the package intentionally provides only lossless transport.
- [x] Complete API documentation and migration examples for synchronization
  policy, projection conflicts, structured patches, timestamp behavior, and
  any newly added sidecar/comparison/GPS APIs.
- [x] Re-run the exported-API audit against 2.0.0 and decide release versioning
  for the exhaustive `XMPValue.languageAlternative` and
  `PhotoMetadataValue.number` cases before tagging.
- [ ] Run the full package, CLI, iOS, extended parser-hardening, downstream app,
  archive, checksum, and clean-consumer verification gates.
- [ ] Update the changelog date, CLI version, release checklist, Homebrew
  formula, and migration notes only after the final feature set and version are
  approved.
- [ ] Create and publish a tag only after every applicable item above is
  complete; until then, keep the work marked unreleased.

Progress notes:

- Added `MIGRATION.md` with 1.x-to-2.0 instructions and adoption-oriented examples
  for every new metadata workflow API. It also records downstream ownership and
  validation boundaries so applications do not rebuild XMP from the canonical
  projection or mistake lossless Camera Raw transport for package ownership.
- Audited Photo Agent's retained 1.9.10 fork integration without modifying its
  dirty worktree. Candidate removals are the manual `dc:title` save/restore
  synchronizer, eight creation-date capture/restore blocks, the rendered-TIFF
  `allowUnsafeRawEmbed` escape hatch, and the private byte-comparison sidecar
  retry loop. Each remains pending until it is applied in Photo Agent's real
  worktree and the focused suites are rerun there.
- Re-ran `swift-api-digester` against freshly built 2.0.0 and current modules
  with Swift 6.3.3. The only reported source break is the added
  `XMPValue.languageAlternative` case. `PhotoMetadataValue.number` is part of a
  type that did not exist in 2.0.0, so it adds no separate baseline break. The
  next release is therefore planned as 3.0.0; the CLI version, release date,
  checklist, artifacts, formula, and tag remain unchanged until the downstream
  and full verification gates pass.
- Verified the current package suite after the documentation and versioning
  updates: 1,712 tests ran, 48 optional tests were skipped, and no tests failed.
- Built a disposable copy of Photo Agent's committed `main` state against this
  package candidate after applying only the required module/product rename.
  The first run passed 85 of 86 focused adoption tests; the remaining test
  expected a Sony-authored `.tiff` to be rejected as proprietary RAW, which is
  precisely the obsolete behavior replaced by URL-extension classification.
  Updating that expectation in the disposable copy produced 86 of 86 passing
  localized-title, embedded-container, export-visibility, sidecar-concurrency,
  and metadata-preservation tests.
- Confirmed Photo Agent still owns its typed Camera Raw settings, angled-crop
  conversion, masks, brush payloads, and private XMP namespace while the
  package carries their raw graph losslessly. All 14 focused Camera Raw and
  private-XMP ownership tests passed against the package candidate. No files in
  Photo Agent's dirty working tree were modified.
- Refreshed the package-side candidate gates on 2026-09-02: all 1,712 package
  tests passed with 48 expected optional skips, all 50 opt-in CLI tests passed,
  the 50,000-input deterministic parser-hardening profile passed, and the arm64
  iOS 16 library cross-compile succeeded.
- Built and smoke-tested the macOS arm64 archive, verified its license and
  bundled geolocation database, and recorded candidate SHA-256
  `b678f00070629b830bee4d218edaa6f0816208ba48e3c5d659266cb4608fac9c`.
  A clean disposable SwiftPM consumer also compiled `import SwiftMediaMetadata`
  and exercised the public `ImageMetadata` API. These are candidate results,
  not the final 3.0.0 release gate: the CLI deliberately remains at 2.0.0 until
  downstream adoption and release metadata are approved.
- Generalized `Scripts/verify-release.sh` to extract notes for its requested
  semantic version. Previously a future 3.0.0 tag would have silently published
  the 2.0.0 changelog section even though the script accepted arbitrary plain
  semantic versions. The extracted section must be non-empty, but future
  non-breaking releases are no longer rejected for omitting a `Breaking:` note.
- Integrated the 3.0.0 package candidate into Photo Agent on isolated branch
  `codex/swift-media-metadata-3-adoption` at commit `eb32cf7`, leaving its dirty
  `main` checkout untouched. The app now exact-pins the upstream
  `SwiftMediaMetadata` product at candidate revision `4b1c2ff`, removes its
  1.9.10 vendored fork, and imports the renamed module directly.
- Replaced Photo Agent's manual IPTC/XMP mirroring, eight creation-date
  save/restore blocks, rendered-TIFF RAW escape hatch, sidecar byte-comparison
  retry transaction, and PLUS `rdf:Seq` XML seed with the package's
  synchronization, filesystem-date restoration, URL-aware TIFF detection,
  revisioned sidecar update, and typed structured-patch APIs. Its preservation
  boundary now consumes `PhotoMetadata.rawXMP`, retaining Camera Raw,
  app-private, unknown, and recursive XMP values.
- The migrated app builds for testing; its 62-test focused metadata integration
  set and repository validation script pass. The first complete downstream
  runs exposed a pre-existing fixed-delay timer assertion that passed alone but
  starved under the parallel suite. Separate test-only commit `0aae2da` replaced
  its final 40 ms sleep with the project's bounded eventual-state pattern; no
  production coordinator code changed. The complete scheme then passed all
  1,883 tests with no skips.
- Re-ran the deterministic 50,000-input parser-hardening profile under Address
  Sanitizer after the downstream migration. All four selected property-test
  methods passed with no sanitizer failure.
- Every component of the full candidate gate has now passed. Its checklist item
  remains open until the approved 3.0.0 CLI/release metadata is applied and the
  same gates are repeated against those final release inputs.
