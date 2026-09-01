# Changelog

All notable changes to swift-exif (CLI) and the SwiftMediaMetadata library.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers follow [Semantic Versioning](https://semver.org/) and track
the CLI; the library target follows the same numbering.

## [2.0.0] — Unreleased

### Added

- Deterministic parser property tests now exercise TIFF/Exif, ISOBMFF, XMP,
  C2PA/JUMBF, and video bitstreams with truncations, malformed lengths, seeded
  byte soup, and write-read-write stability checks. A reusable script supports
  longer reproducible local runs.
- Release tooling now provides a single macOS preflight, a tag-driven GitHub
  release workflow, SHA-256 checksums, archive-content validation, and a
  step-by-step 2.0 release/Homebrew checklist.
- `ImageMetadata.WriteOptions.FileModificationDatePolicy` controls filesystem
  modification dates independently of timestamps embedded in media metadata.
  Use `.preserveExisting` for in-place edits or `.set(Date)` when a new output
  should inherit a source file's date. Image, video, audio, XMP sidecar, and
  batch writes share the policy.
- Mutating CLI commands accept `-P` / `--preserve-file-modification-date`.

### Changed

- **Breaking:** the Swift package, library product, importable module, source
  target, and test targets are renamed from `SwiftExif` to
  `SwiftMediaMetadata`. Clients must use the renamed GitHub repository, depend
  on the `SwiftMediaMetadata` product, and replace `import SwiftExif` with
  `import SwiftMediaMetadata`. The installed `swift-exif` CLI command is
  unchanged.
- Image, video, audio, and XMP sidecar writes now use one internal filesystem
  transaction for atomic replacement, backups, temporary-file cleanup, and
  file attributes.
- The 33,536-city offline geolocation database is now a versioned bundled
  resource instead of 54,000 lines of generated Swift literals. Reverse
  geocoding behavior is unchanged, while a measured clean library build is 79%
  faster and the geolocation debug object shrinks from 12.0 MB to 102 KB.

## [1.9.10] — 2026-07-01

### Fixed

- Camera Raw brush-mask XMP now serializes the nested `crs:Masks` container as
  `rdf:Seq`, matching Adobe Camera Raw and preserving the complete
  Mask/Aggregate → Masks → Mask/Paint → Dabs structure across rewrites.

## [1.9.9] — 2026-06-23

### Fixed

- Clearing XMP now removes the embedded packet from JPEG, PNG, and JPEG XL
  output. Previously `stripXMP()` and `stripAllMetadata()` could leave the
  original XMP behind in those formats.

## [1.9.8] — 2026-06-23

### Added

- **`GeoLocation.countryCodeAlpha2`** exposes the ISO 3166-1 alpha-2 country
  code (e.g. `"FR"`) alongside the existing alpha-3 `countryCode`. The alpha-2
  was already the source of truth in the embedded database (alpha-3 is derived
  from it) but was discarded during lookup; it is now surfaced so callers can
  drive Foundation's offline country-name localization.
  ([`Sources/SwiftMediaMetadata/Geolocation/ReverseGeocoder.swift`](Sources/SwiftMediaMetadata/Geolocation/ReverseGeocoder.swift))
- **`GeoLocation.localizedCountry(_:)`** returns the country name localized into
  a given `Locale` (defaulting to `.current`), resolved offline via Foundation
  from `countryCodeAlpha2`, falling back to the English `country` field for
  unknown codes. City and region names remain English-only.
  ([`Sources/SwiftMediaMetadata/Geolocation/ReverseGeocoder.swift`](Sources/SwiftMediaMetadata/Geolocation/ReverseGeocoder.swift))

### Fixed

- **UInt32 overflow traps in H.264/H.265 SPS parsing.** A crafted SPS NAL could
  make the Exp-Golomb `readUE()` decode a near-`UInt32.max` value, after which
  the SPS parsers' trapping UInt32 arithmetic (`ue + 1`, bit-depth `+ 8`,
  width/height-in-MBs `+ 1`, crop-window sums) crashed the whole process
  (SIGTRAP) on any malformed `.mp4`/`.mov`/`.ts`/MKV reached via `MPEGReader` or
  `MP4VisualSampleEntry`. The arithmetic is now widened to 64-bit, so adversarial
  input yields a clamped/garbage dimension instead of a trap; valid streams are
  unchanged. Adds `MPEGBitstreamFuzzTests`.

### Tests

- Hardened the IPTC marker tests with a write→read→write byte-stability
  invariant, guarding against any future "flip the marker on each write" parity
  regression. Test-only; no change to the shipped library.

## [1.9.7] — 2026-06-19

### Fixed

- **`IPTCWriter` dropped the UTF-8 `CodedCharacterSet` (1:90) marker on
  re-write.** The marker was written only when the input `IPTCData` lacked one,
  while the serialization loop always skipped existing 1:90 datasets — so a write
  whose input already carried a marker silently dropped it, and across a
  multi-write pipeline the marker flipped on/off by parity, leaving non-ASCII
  IPTC text undeclared and mojibaked on readers defaulting to ISO-8859-1. One
  canonical UTF-8 marker is now emitted unconditionally when non-ASCII content is
  present, idempotent across repeated writes. Adds `CodedCharacterSetMarkerTests`.
  ([`Sources/SwiftMediaMetadata/IPTC/IPTCWriter.swift`](Sources/SwiftMediaMetadata/IPTC/IPTCWriter.swift))

## [1.9.6] — 2026-06-17

### Changed

- **`XMPReader` is now libxml2-free, backed by a pure-Swift tokenizer.**
  Foundation's `XMLParser` wraps libxml2, whose process-global state is not
  thread-safe and can race other in-process libxml2 users (notably ImageIO),
  surfacing as `EXC_BAD_ACCESS` during concurrent image decode + XMP parse. A
  dependency-free `PureXMLTokenizer` now emits the same SAX events, leaving the
  XMP-building logic unchanged; XMP read + write are 100% pure Swift. Handles
  entities (predefined + decimal/hex numeric refs), CDATA, comments, PIs, xmlns
  scoping, and self-closing tags. Adds `XMPPureTokenizerTests`.

## [1.9.5] — 2026-06-16

### Changed

- **`ImageMetadata.write(to:)` now losslessly wraps a bare JPEG XL codestream
  into container format instead of refusing the write.** A bare codestream
  (`FF 0A …`) has no box structure to hold an `Exif`/`xml ` box, so any metadata
  write — orientation (rotate), keywords, rating, GPS, IPTC — previously threw
  `MetadataError.writeNotSupported("…container format required")`. The writer now
  wraps the codestream in a container (`JXL ` signature + `ftyp` + metadata boxes
  + a `jxlc` box holding the codestream copied byte-for-byte, no re-encode),
  giving those boxes a home. A bare file with nothing to embed is returned
  unchanged, and re-writing an already-wrapped file replaces its metadata boxes
  in place rather than wrapping again.
  ([`Sources/SwiftMediaMetadata/JPEGXL/JXLWriter.swift`](Sources/SwiftMediaMetadata/JPEGXL/JXLWriter.swift))

### Added

- **`JXLFile.rawCodestream`** retains the original bare-codestream bytes
  (including the `FF 0A` signature) at parse time so the writer can wrap them on
  demand; nil for container files.
  ([`Sources/SwiftMediaMetadata/JPEGXL/JXLFile.swift`](Sources/SwiftMediaMetadata/JPEGXL/JXLFile.swift))

## [1.9.4] — 2026-06-13

### Changed

- **`ImageMetadata.write(to:)` now refuses to embed metadata into proprietary
  TIFF-based RAW by default.** Rewriting an ARW/NEF/NRW/CR2/RW2/ORF/PEF/SRW via
  `TIFFWriter`'s full IFD rebuild cannot preserve maker-private structures —
  notably Sony's encrypted `SR2Private` block, which holds the white-balance
  calibration. The rewrite corrupted the file: the RAW then decoded with a
  broken white balance (e.g. CIRAWFilter fell back to a garbage neutral and
  rendered green) and the raster bloated with orphaned data; `exiftool
  -validate` reported "SR2Private parsing aborted" alongside an XMP/Photoshop
  packet embedded into IFD0. Such writes now throw
  `MetadataError.rawWriteUnsupported`. RAW metadata belongs in an XMP sidecar.
  DNG/GPR (Adobe's open, writable TIFF spec) and CR3 (ISOBMFF, its own writer)
  are unaffected. The format is detected from parsed content, with the target
  extension as a backstop for odd/truncated variants.
  ([`Sources/SwiftMediaMetadata/API/ImageMetadata.swift`](Sources/SwiftMediaMetadata/API/ImageMetadata.swift))

### Added

- **`WriteOptions.allowUnsafeRawEmbed`** (default `false`) to opt back into RAW
  embedding for callers that have verified a specific format round-trips
  losslessly, and **`MetadataError.rawWriteUnsupported(ImageFormat.RawFormat)`**
  to surface the refusal with the offending format.
  ([`Sources/SwiftMediaMetadata/API/MetadataError.swift`](Sources/SwiftMediaMetadata/API/MetadataError.swift))

## [1.9.3] — 2026-06-12

### Added

- **Namespace-aware field accessors for XMP struct fields.** Struct fields are
  keyed `"<namespaceURI><name>"` — intentional, since a struct's fields may
  come from a different namespace than the property holding it — but consumers
  had to hand-concatenate those keys, and a bare-name lookup compiles fine
  while silently never matching. Documented the convention on `XMPValue` and
  added `subscript(namespace:property:)` and `simpleField(namespace:property:)`
  on `[String: XMPValue]`, mirroring `XMPData.value`/`setValue`.
  ([`Sources/SwiftMediaMetadata/XMP/XMPData.swift`](Sources/SwiftMediaMetadata/XMP/XMPData.swift))
- **Namespace-block APIs on `XMPData`** for whole-block operations like crs
  (Camera Raw settings) replacement: `properties(in:)` returns a namespace's
  properties keyed by local name, `removeAll(namespace:)` drops every property
  in a namespace, and `replaceAll(namespace:from:)` swaps the entire block for
  another `XMPData`'s — carrying the parsed rdf:Bag/Seq container forms along
  so vendor arrays keep their shape on the next write. Matching is
  namespace-exact, not raw prefix: Adobe URIs nest (`xmpRights`, `xmpMM`,
  `stEvt` all start with the `xmp` URI), so removing the `xmp` block leaves
  those untouched.
  ([`Sources/SwiftMediaMetadata/XMP/XMPData.swift`](Sources/SwiftMediaMetadata/XMP/XMPData.swift))

### Fixed

- **`rdf:Bag` vs `rdf:Seq` container parity with ExifTool.** The writer emitted
  every array as `rdf:Bag`, so spec-ordered properties (`dc:creator`,
  `xmpMM:History`, `tiff:BitsPerSample`, the `crs:` tone curves and
  mask/gradient corrections, …) and vendor Seq arrays (digiKam's `TagsList`)
  all collapsed to Bag on rewrite. Two mechanisms now pick the container,
  mirroring ExifTool: a spec table of known-Seq properties
  (`XMPWriter.seqProperties`) that is normalized to Seq regardless of input,
  and the container form observed at parse time
  (`XMPData.arrayForms`) for everything else, so unknown vendor arrays keep
  whatever container they arrived in. Applies to nested struct fields too
  (e.g. `crs:CorrectionMasks` inside a correction). `XMPValue` is unchanged —
  no API break. Verified against ExifTool end-to-end: containers in a
  `swift-exif write` rewrite now match what ExifTool itself writes for
  `dc:creator` (Seq), `dc:subject` (Bag), `xmpMM:History` (Seq of structs),
  and `XMP-digiKam:TagsList` (Seq).
  ([`Sources/SwiftMediaMetadata/XMP/XMPWriter.swift`](Sources/SwiftMediaMetadata/XMP/XMPWriter.swift),
  [`Sources/SwiftMediaMetadata/XMP/XMPReader.swift`](Sources/SwiftMediaMetadata/XMP/XMPReader.swift))

- **XMP properties in unknown namespaces survive a rewrite.** The XMP reader
  accepts any namespace the document declares (it honors live `xmlns`
  declarations), but the writer could only serialize namespaces in its
  hardcoded prefix table — so reading and rewriting a file silently dropped
  digiKam / ACDSee / MicrosoftPhoto-style vendor properties. `XMPWriter` now
  assigns generated `ns1`/`ns2`/… prefixes to namespaces outside the known
  table, splitting the stored `"<namespaceURI><localName>"` key at its last
  `/` or `#` (stable on round-trip even when the split point differs from the
  original declaration). Verified end-to-end: `XMP-digiKam:ColorLabel` and
  `TagsList` written by ExifTool survive a `swift-exif write` rewrite and read
  back identically in ExifTool.
  ([`Sources/SwiftMediaMetadata/XMP/XMPWriter.swift`](Sources/SwiftMediaMetadata/XMP/XMPWriter.swift))
- **Newlines and tabs in simple XMP values survive a round-trip.** Simple
  properties are serialized as XML attributes, and conforming XML parsers
  normalize literal tab/LF/CR in attribute values to spaces (XML 1.0 §3.3.3) —
  so a multi-line caption or instructions field came back flattened to one
  line. `escapeXML` now emits them as character references (`&#xA;` etc.),
  which ExifTool reads back as real newlines. Remaining C0 control characters
  — illegal in XML 1.0 in any form, and previously emitted raw, making the
  packet unparseable — are stripped.
- **Region `unit` strings are XML-escaped on write.** `stArea:unit` and
  `stDim:unit` were interpolated into the packet unescaped; a quote or angle
  bracket in a file-supplied unit string corrupted the rewritten XMP.
- **The XMP reader's depth-cap error message is no longer clobbered** by the
  generic "delegate aborted" error that `abortParsing()` reports through the
  same delegate callback.

## [1.9.2] — 2026-06-11

### Fixed

- **ACR-style `rdf:Seq` structured arrays and attribute-form `rdf:li` parse
  correctly.** Adobe Camera Raw writes `MaskGroupBasedCorrections` as
  `rdf:Seq` (not Bag), and the nested `CorrectionMasks` items are
  attribute-form `rdf:li` elements with no `rdf:Description` child. The reader
  only prepared structured items for Bag and never read attributes off the
  `li` itself, so the entire mask structure silently parsed as an empty array.
  `li` now starts a structured item inside Seq as well as Bag and captures
  namespaced attribute-form fields directly on the element. Plain string Seqs
  are unaffected. Regression test uses the exact shape Camera Raw 18.3.2
  writes. *(This section documents the already-pushed `1.9.2` tag, which
  shipped without a changelog entry.)*
  ([`Sources/SwiftMediaMetadata/XMP/XMPReader.swift`](Sources/SwiftMediaMetadata/XMP/XMPReader.swift))

## [1.9.1] — 2026-06-05

### Fixed

- **An oversized Exif tag no longer aborts the whole JPEG write.** JPEG's Exif
  APP1 segment has a hard ~64 KB ceiling (`JPEGWriter.maxSegmentPayload`,
  65,533 bytes), and `JPEGWriter` threw `MetadataError.invalidSegmentLength` for
  any segment over it. Copying EXIF wholesale from a camera RAW could blow past
  that limit — a Sony A1 (ILCE-1) `.ARW` embeds a ~1.5 MB C2PA / Content
  Credentials manifest (JUMBF) in IFD0 tag `0xCD41` — so `copy`-ing its metadata
  onto a rendered JPEG failed outright and silently dropped *all* the copied
  EXIF/IPTC/XMP, even though only one tag was the problem. The JPEG write path
  now caps the Exif APP1 gracefully: when the serialized payload would overflow,
  it progressively drops the largest droppable values and re-serializes until it
  fits — priority **IFD1 thumbnail → large proprietary external-value blobs
  (largest first, e.g. the C2PA manifest) → MakerNote (dropped last)** — and
  records a non-fatal warning through the existing `writeToDataWithWarnings()`
  channel (now also printed by the `copy` command). Standard tags
  (Make/Model/LensModel/exposure) and, in practice, the MakerNote survive.
  (Copying a source C2PA manifest into a re-encoded derivative is semantically
  invalid anyway — its content-binding hash covers the original pixels — so
  dropping it on JPEG write is correct, not lossy; C2PA's real JPEG home is an
  APP11 JUMBF box, never the Exif IFD.) An equivalent final guard drops an
  unusually large XMP (APP1) or IPTC (APP13) segment with a warning rather than
  aborting. Verified end-to-end on two real ILCE-1 C2PA ARWs (Exif APP1 shrank
  from ~1.6 MB to 43,786 bytes, MakerNote retained). Regression tests in
  `OversizedExifTests`.
  ([`Sources/SwiftMediaMetadata/Exif/ExifWriter.swift`](Sources/SwiftMediaMetadata/Exif/ExifWriter.swift),
  [`Sources/SwiftMediaMetadata/API/ImageMetadata.swift`](Sources/SwiftMediaMetadata/API/ImageMetadata.swift))

## [1.9.0] — 2026-06-03

### Added

- **IVF (On2 IVF) containers are now read** as a video format, with first-class
  support for the experimental **AV2** codec (FourCC `AV02`) alongside VP8/VP9/
  AV1. A new `VideoFormat.ivf` case is detected by the `DKIF` signature or the
  `.ivf` extension. The reader takes everything from the 32-byte container
  header and the frame table — codec, dimensions, frame rate (from the time
  base), frame count, duration, and overall bit rate — and never decodes the
  payload (AV2's bitstream syntax is still unstable, so reading its sequence
  header for bit depth / chroma / profile would risk reporting wrong metadata).
  Because IVF muxers routinely leave the header `frameCount` at 0, the count is
  recovered by walking the frame table; a stream that ends in an incomplete
  frame (a file that is truncated or still being encoded) is tolerated and
  flagged via `VideoMetadata.warnings` rather than rejected.
  ([`Sources/SwiftMediaMetadata/Video/IVFReader.swift`](Sources/SwiftMediaMetadata/Video/IVFReader.swift))
- **GoPro `.GPR` files are now recognized** as a DNG/TIFF-based RAW format. A
  new `RawFormat.gpr` case is detected via the `.gpr` extension or a GoPro
  `Make` (so the data-only API works too), and `FileFormat` now reports GPR.
  ([`Sources/SwiftMediaMetadata/RAW`](Sources/SwiftMediaMetadata))
- **Sony `.ARW` files are now recognized by content**, not just extension. A
  non-DNG TIFF whose `Make` is "SONY" is detected as `RawFormat.arw` (mirroring
  the existing Olympus→ORF and Pentax→PEF heuristics), so `FileFormat` reports
  ARW and the data-only API routes through the RAW reader instead of labeling
  the file a generic TIFF.
  ([`Sources/SwiftMediaMetadata/API/FormatDetector.swift`](Sources/SwiftMediaMetadata/API/FormatDetector.swift))
- **Expanded Sony MakerNote tag coverage** from ~15 to ~50 directly-readable
  tags, verified against ExifTool's `Sony.pm` Main table on a real ILCE-1 ARW.
  New tags include `Contrast`, `Saturation`, `Sharpness`, `Brightness`, `HDR`,
  `VignettingCorrection`, `LateralChromaticAberration`, `DistortionCorrectionSetting`,
  `RAWFileType`, `MeteringMode2`, `FlashAction`, `ElectronicFrontCurtainShutter`,
  `Shadows`, `Highlights`, `Fade`, `SharpnessRange`, `Clarity`, `JPEG-HEIFSwitch`,
  `FocusLocation`/`FocusLocation2`, `ColorTemperature`, `Rating`, and more. A
  width-tolerant scalar reader replaces the fixed-width helpers, so tags whose
  declared int width differs from a sibling's (e.g. `HighISONoiseReduction`,
  `ImageStabilization`) and signed values (`Highlights: -3`) are no longer
  silently dropped. Several long-standing mislabels are corrected in passing:
  `0x2002` is `Rating` (was `SonyImageSize`), `0x2014` is `WBShiftAB_GM` (was
  `WB_RGBLevels`), `PictureEffect` is `0x200E` (was `0x200C`), `SoftSkinEffect`
  is `0x200F` (was `0x200D`), and `0xB026` `ImageStabilization` (was an
  unreachable `ImageStabilizationOld`). Scalar tags now emit `.int` uniformly
  (previously a mix of `.int`/`.uint`).
  ([`Sources/SwiftMediaMetadata/MakerNote/SonyMakerNote.swift`](Sources/SwiftMediaMetadata/MakerNote/SonyMakerNote.swift))
- **C2PA / Content Credentials are now surfaced in `read` output** under the
  `C2PA:` group (the `read --group c2pa` filter previously matched nothing). The
  exporter emits manifest count, active-manifest label, claim generator,
  title/format/instanceID, signature algorithm, certificate count, the signer
  and issuer common names (decoded from the leaf certificate via the X.509
  parser), the assertion labels, and the first `c2pa.actions` action with its
  digital-source type and software agent — mirroring the existing video
  exporter's keys. Regression test `testC2PASurfacedInExportedDictionary`.
  ([`Sources/SwiftMediaMetadata/API/MetadataExporter.swift`](Sources/SwiftMediaMetadata/API/MetadataExporter.swift))
- **Expanded DNG structural-tag extraction**, benefiting all DNG/RAW files.
  New tags: `BlackLevel`, `WhiteLevel`, `ActiveArea`, `DefaultScale`,
  `DefaultUserCrop`, `LocalizedCameraModel`, `AnalogBalance`, `BayerGreenSplit`,
  `LinearResponseLimit`, `AntiAliasStrength`, `ShadowScale`, `BestQualityScale`,
  `CFAPlaneColor`, `CFALayout`, `CFARepeatPatternDim`, plus standard TIFF
  structural tags (`BitsPerSample`, `PhotometricInterpretation`,
  `SamplesPerPixel`, `PlanarConfiguration`, `SubfileType`). The count==2-only
  `numericPair` helper is generalized to `numericArray(count:)` (which had been
  dropping `ActiveArea`, count 4). New print conversions: Compression 9 →
  "JBIG B&W", `CalibrationIlluminant` via the existing LightSource table, and
  `PhotometricInterpretation`, `SubfileType`, `ProfileEmbedPolicy`, `CFALayout`.
  Coverage on the sample GPR rises from 49 to 76 tags.

### Fixed

- **Over-length IPTC fields no longer abort an unrelated write.** Every write
  re-serializes the whole IPTC block, and `IPTCWriter` hard-threw
  `dataExceedsMaxLength` for any field exceeding its spec limit. Agency/wire
  JPEGs routinely ship over-spec fields (e.g. a 34-byte `By-line` against the
  32-byte 2:80 maximum), so an unrelated edit — such as a photo app setting an
  XMP star `Rating` — failed outright, and the same file became unwritable for
  any change. Matching ExifTool, over-length values are now preserved verbatim
  and reported as a non-fatal warning through the existing
  `writeToDataWithWarnings()` channel (and printed by the `write` command);
  `IPTCData.validate()` stays strict for callers that gate submissions. The
  `Rating` CLI tag now maps to `xmp:Rating` instead of being skipped as unknown.
  Regression tests `testWritePreservesOverLengthIPTCWhenSettingRating` and the
  reworked over-length cases in `IPTCWriterTests`.
  ([`Sources/SwiftMediaMetadata/IPTC/IPTCWriter.swift`](Sources/SwiftMediaMetadata/IPTC/IPTCWriter.swift))
- **Writing metadata to a CR3 no longer corrupts the file.** CR3 stores
  absolute file offsets in each track's `co64`/`stco` chunk table and in the
  Canon `CTBO` box. Rebuilding `moov` (re-serialized `CMT1`/`CMT2`/`CMT4`) or
  the XMP `uuid` box changes their size and relocates `mdat`, but the writer
  copied those offset tables verbatim — so after any edit the embedded
  full-resolution JPEG (`JpgFromRaw`), preview, and `CTMD` timed-metadata track
  pointed at stale locations and became unreadable (ExifTool reported "Error
  reading meta data"). The writer now rebuilds in two passes: measure the new
  `moov`, recompute the top-level layout, then rewrite every `co64`/`stco`
  entry and remap each `CTBO` entry to its relocated offset and size. Verified
  on a real EOS R1 CR3 (ExifTool `Validate: OK`, `JpgFromRaw` intact, stable
  across repeated writes); offset fix-up mirrors ExifTool's `QuickTime.pm`
  CR3 handling. Regression test `testWriteFixesChunkAndCTBOOffsets` builds a
  CR3 with real `co64`/`CTBO` tables and asserts both track the relocated
  `mdat` after writing.
  ([`Sources/SwiftMediaMetadata/CR3/CR3Writer.swift`](Sources/SwiftMediaMetadata/CR3/CR3Writer.swift))
- **Canon MakerNotes are now read from CR3 files.** CR3 carries the Canon
  MakerNotes as the `CMT3` IFD, not as a JPEG/TIFF `0x927C` blob, so the
  `MakerNoteReader` dispatch never fired and `read --group makernote` returned
  nothing on a CR3. The CR3 pipeline now interprets the resolved `CMT3` IFD via
  `CanonMakerNote` (refactored to expose an IFD entry point), surfacing
  `FirmwareVersion`, `LensModel`, body/internal serial numbers, `ShutterCount`,
  `CameraTemperature`, AF info, focal-length data, and more.
  ([`Sources/SwiftMediaMetadata/Canon/CanonUUIDBoxes.swift`](Sources/SwiftMediaMetadata/Canon/CanonUUIDBoxes.swift))
- **CR3 thumbnail/preview extraction now works on current Canon bodies.**
  `extractThumbnail()` returned `nil` for CR3 because it required an Exif IFD1
  (which CR3 has not), short-circuiting before the `THMB` box was ever consulted;
  it now returns the parsed `THMB` JPEG directly. The embedded-JPEG reader also
  no longer assumes a fixed 14-byte `THMB`/`PRVW` header (newer bodies such as
  the EOS R1 use 16) — it locates the `0xFFD8` SOI marker instead — and the
  preview `uuid`, which sits at the top level rather than inside `moov` in real
  files, is now scanned there too.
  ([`Sources/SwiftMediaMetadata/API/ImageMetadata.swift`](Sources/SwiftMediaMetadata/API/ImageMetadata.swift))
- **Wrong DNG tag constants above `0xC630`** are corrected. ~17 `DNGTag`
  constants pointed at the wrong tag IDs (sourced from a bad table), so the
  corresponding fields silently parsed to `nil` on every DNG file — e.g.
  `profileName` read `0xC698` instead of `0xC6F8`, `defaultCropOrigin` read
  `0xC68D` (actually `ActiveArea`), and all three `OpcodeList` tags were wrong.
  Constants are now verified against ExifTool's `Exif.pm` table; the bogus
  `lensInfo` (an EXIF tag) is dropped. New tests build fixtures from literal
  on-disk tag IDs so a constant regression fails the suite.
- **Integer-overflow trap walking a Canon CRM `CTMD` sample table** is fixed. A
  crafted file with a 64-bit `co64` chunk offset near `UInt64.max` made the
  per-sample `chunkBaseOffset + sampleOffsetInChunk` addition — and the
  `offset + length` bounds check in `sliceFile` — overflow `UInt64` and trap
  (SIGTRAP), crashing the parser. Both additions are now overflow-safe
  (`addingReportingOverflow` for the running offset; subtraction-form bounds
  check against the file size in `sliceFile`), matching the hardening already
  applied to the ISOBMFF box parser and BRAW frame window. The out-of-range
  chunk is dropped gracefully. Regression test
  `testCTMDRejectsOverflowingCo64ChunkOffset`.
  ([`Sources/SwiftMediaMetadata/Video/CRMReader.swift`](Sources/SwiftMediaMetadata/Video/CRMReader.swift))
- **Out-of-memory abort from a fabricated CRM sample-table count** is fixed. The
  `stsz`/`stsc`/`stco`/`co64` parsers fed the file's 32-bit entry count straight
  into `reserveCapacity(Int(count))` / `Array(repeating:count:)`, so a tiny file
  declaring `sample_count == 0xFFFFFFFF` forced a ~17 GB allocation and aborted
  the process. Each count is now capped against the bytes actually present
  (`min(Int(count), remainingCount / entrySize)`), with a 2^24 hard ceiling for
  the size-less `stsz` form that has no payload to bound against — matching the
  count-capping convention already used in `MP4Chapters`, `MXFMCAReader`, and
  `MPEGBitstream`. Regression test `testCTMDRejectsFabricatedSampleCount`.
  ([`Sources/SwiftMediaMetadata/Video/CRMReader.swift`](Sources/SwiftMediaMetadata/Video/CRMReader.swift))
- **Relocated MakerNote (0x927C) internal offsets are now fixed up** on every
  write path that rebuilds a TIFF block — `TIFFWriter` (TIFF/DNG) **and**
  `ExifWriter` (embedded EXIF in JPEG/PNG/AVIF/HEIF/JPEG XL/WebP). Modeled on
  ExifTool's `FixBase`/`RebuildMakerNotes`: a MakerNote whose internal pointers
  are relative to the note/embedded-TIFF start (Nikon, Fujifilm, Panasonic,
  Olympus, Apple) moves with the block and is copied verbatim, while one whose
  pointers are TIFF-absolute (Canon, DJI, Samsung, Pentax, and modern "Sony5"
  Alpha/RX/FX notes) has every out-of-line value-offset field shifted by the
  relocation delta (and a Canon TIFF footer patched to match). Older
  "SONY DSC"/"SONY CAM"-prefixed notes use an unconfirmed base and fall back to
  verbatim+warn. The fix-up preserves byte length and is fully
  bounds-checked; a note that can't be classified or safely patched (unknown
  manufacturer, parse failure, a chained MakerNote IFD) is still copied verbatim
  and surfaces the non-fatal `writeToDataWithWarnings()` warning, so output is
  never more corrupt than a plain copy. This converts the 1.8.2 "known
  limitation" into a fix. New `IFDParser` records each out-of-line value's
  TIFF-relative source offset on `IFDEntry.sourceOffset` (excluded from
  equality) to compute the delta. New tests: `MakerNoteRelocatorTests` plus
  end-to-end coverage in `TIFFWriterTests` and `ExifRoundTripTests`.
  ([`Sources/SwiftMediaMetadata/MakerNote/MakerNoteRelocator.swift`](Sources/SwiftMediaMetadata/MakerNote/MakerNoteRelocator.swift),
  [`Sources/SwiftMediaMetadata/TIFF/TIFFWriter.swift`](Sources/SwiftMediaMetadata/TIFF/TIFFWriter.swift),
  [`Sources/SwiftMediaMetadata/Exif/ExifWriter.swift`](Sources/SwiftMediaMetadata/Exif/ExifWriter.swift),
  [`Sources/SwiftMediaMetadata/Exif/IFDParser.swift`](Sources/SwiftMediaMetadata/Exif/IFDParser.swift),
  [`Sources/SwiftMediaMetadata/Exif/IFDEntry.swift`](Sources/SwiftMediaMetadata/Exif/IFDEntry.swift))
- **`co64` chunk offsets are bounded before `Int` conversion in the RTMD, BRAW,
  and MP4 chapter readers.** `Int(offset)` traps when a `co64` chunk offset
  exceeds `Int64.max`, and `sampleFileOffsets` accumulates with wrapping `&+`,
  so a crafted MP4/MXF could push per-sample offsets anywhere in `UInt64` and
  crash the parser. A prior fix covered only `brawFrameWindow`; three sibling
  consumers were left unguarded — `RTMDReader` (4 sites), the BRAW `mebx`
  motion walker (`walkMebxSamples`), and `MP4Chapters`. All now bound in
  `UInt64` space then use subtraction-form comparisons so the `Int` math can't
  overflow (a new `RTMDReader.sampleByteRange` helper also closes a pre-existing
  `off + size` overflow in the old guard). Regression test drives an
  out-of-range `co64` offset through the BRAW `mebx` motion path.
  ([`Sources/SwiftMediaMetadata/Video/RTMDReader.swift`](Sources/SwiftMediaMetadata/Video/RTMDReader.swift),
  [`Sources/SwiftMediaMetadata/Video/BRAWFrameReader.swift`](Sources/SwiftMediaMetadata/Video/BRAWFrameReader.swift),
  [`Sources/SwiftMediaMetadata/Video/MP4Chapters.swift`](Sources/SwiftMediaMetadata/Video/MP4Chapters.swift))
- **`co64` chunk offset bounded before `Int` conversion in `brawFrameWindow`.**
  The function did `Int(chunkOffset)` before any bounds check on a raw 64-bit
  `co64` value, so a crafted BRAW-codec MP4 with an offset ≥ 2⁶³ trapped on the
  conversion. The offset is now bounded in `UInt64` space first, then compared
  with subtraction so the `Int` math can't overflow.
- **Integer-overflow trap in the ISOBMFF extended-size bounds checks** is fixed.
  A box using extended size (`size32 == 1`) can declare a 64-bit `largesize`
  near `Int.max`; the `Int(size64)` cast was guarded, but the following
  `reader.offset + payloadSize <= endOffset` check overflowed and trapped
  (SIGTRAP) whenever the box did not start at offset 0 — a malformed file with
  a small leading box followed by an oversized extended box crashed the parser.
  The same flaw existed in `parseTopLevelBoxesSkippingMdat`. Both checks are
  rewritten in overflow-safe subtraction form, and the same hardening is applied
  to `BinaryReader.readBytes`/`skip`/`slice` (which also now rejects a negative
  `count` in `slice` rather than forming an invalid `Range` and trapping).
- **`GPMFReader` out-of-bounds trap on a sliced `Data` input** is fixed. The
  public `parse()`/`telemetry()` seeded the walk with absolute indices
  (`data.startIndex ..< data.endIndex`) while `parseEntries` treats offsets as
  relative to `startIndex`, so a caller passing a slice with non-zero
  `startIndex` (e.g. `GPMFReader.parse(buffer[100...])`) double-counted
  `startIndex` and indexed past `endIndex`, trapping. The walk is now seeded
  with `0 ..< data.count` — identical for the common `startIndex == 0` case,
  correct for slices. Regression test traps (signal 5) without the fix.
  ([`Sources/SwiftMediaMetadata/Video/GPMFReader.swift`](Sources/SwiftMediaMetadata/Video/GPMFReader.swift))
- **Integer-overflow traps in `MP4Parser`'s top-level box walker** are fixed —
  the same extended-size flaw already hardened in `ISOBMFFBoxReader`, but in the
  parallel `parseTopLevelBoxes` behind the public `MP4Parser.parse` that the
  earlier pass missed. A box using extended size (`size32 == 1`) could declare a
  64-bit `largesize` beyond `Int.max` (so the `Int(size64)` cast trapped) or
  near `Int.max` (so the following `reader.offset + payloadSize <= data.count`
  and `boxStart + boxSize` checks overflowed and trapped). The cast is now
  guarded (`size64 >= 16, size64 <= UInt64(Int.max)`) and both bounds checks are
  rewritten in overflow-safe subtraction form; the oversized box is dropped
  gracefully. Regression test `testParseRejectsOverflowingExtendedSize` traps
  (signal 5) without the fix.
  ([`Sources/SwiftMediaMetadata/Video/MP4Parser.swift`](Sources/SwiftMediaMetadata/Video/MP4Parser.swift))
- **`ARRIJSONParser` out-of-bounds trap on a sliced `Data` input** is fixed. The
  public `findEmbeddedJSONBlobs(in:)` scanned with a zero-based cursor
  (`data[i]`, `data.subdata(in: payloadStart..<payloadEnd)`), so a caller passing
  a `Data` slice with non-zero `startIndex` indexed outside the slice and trapped
  on the first byte read. Both the discovery loop and `findFollowingSchema` now
  rebase every subscript and `subdata` range onto `data.startIndex` — identical
  for the common `startIndex == 0` case, correct for slices. Regression test
  traps (signal 5) without the fix.
  ([`Sources/SwiftMediaMetadata/Video/ARRIJSONParser.swift`](Sources/SwiftMediaMetadata/Video/ARRIJSONParser.swift))
- **Trap converting an out-of-range AIFF sample rate to `Int`** is fixed. A
  `COMM` chunk carries the sample rate as an 80-bit IEEE-754 extended float; an
  exponent below the `0x7FFF` Inf/NaN sentinel can still overflow `pow` to
  `+inf`, and a finite value can exceed `Int.max`. `Int(rate.rounded())` and the
  `Int(rate) * channels * sampleSize` bitrate then trapped (SIGTRAP — "Double
  value cannot be converted to Int because it is either infinite or NaN").
  `readExtendedFloat80` now returns `nil` for any non-finite result, and the
  caller range-checks `rate` before each narrowing conversion (computing bitrate
  in `Double`, which saturates instead of trapping). Regression test
  `testCommChunkRejectsOutOfRangeSampleRate` traps (signal 5) without the fix.
  ([`Sources/SwiftMediaMetadata/Audio/AIFFParser.swift`](Sources/SwiftMediaMetadata/Audio/AIFFParser.swift))
- **Int64-overflow trap deriving an MXF aspect ratio** is fixed.
  `parsePictureDescriptor` computed DAR/SAR by multiplying four
  attacker-controlled, `UInt32`-derived values (`StoredWidth`/`StoredHeight` and
  the `AspectRatio` numerator/denominator); two operands near `2^32` multiply to
  `~2^64`, overflowing `Int64` and trapping the process — the existing `Int64`
  cast guarded 32-bit `Int` but not `Int64` overflow itself. The multiplications
  now use `multipliedReportingOverflow`, and the non-essential DAR/SAR derivation
  is skipped on absurd values, matching the keep-what-parsed degradation posture
  used elsewhere. Regression test in `MXFReaderTests`.
  ([`Sources/SwiftMediaMetadata/Video/MXFReader.swift`](Sources/SwiftMediaMetadata/Video/MXFReader.swift))
- **Eager over-allocation from a DNG `numericArray` element count** is fixed.
  `numericArray` called `reserveCapacity(entry.count)` from the
  attacker-controlled `UInt32` count before validating that the value bytes
  actually back that many elements, so a crafted DNG/TIFF entry with an oversized
  count could force a huge allocation ahead of the per-element reads bailing out.
  It now applies the same `valueData.count >= total * unitSize` guard its sibling
  decoders (`srationals`/`rationals`/`longArray`/`doubleArray`) already use.
  ([`Sources/SwiftMediaMetadata/RAW/DNGMetadata.swift`](Sources/SwiftMediaMetadata/RAW/DNGMetadata.swift))
- **ID3 frame decoders now index relative to `startIndex`.** `decodeTextFrame`,
  `decodeCommentFrame`, and `extractAPIC` indexed their `Data` parameter with
  zero-based offsets and bounded against `data.count`, which would trap on any
  non-zero-based slice. They now base offsets on `data.startIndex` and bound
  against `data.endIndex`, matching every other decoder in the file. (Safe
  today since callers re-base via `Data(...)`, but fragile against refactors.)
- **MakerNotes are now parsed for TIFF-based files and RAWs** (ARW, NEF, ORF,
  CR2, DNG, plain TIFF, …). `TIFFFileParser.extractExif` populated IFD0, the
  Exif/GPS sub-IFDs and IFD1 but never invoked `MakerNoteReader`, so every
  TIFF/RAW silently dropped its manufacturer MakerNote (the JPEG path already
  parsed it). It now parses the MakerNote from the Exif sub-IFD exactly as the
  JPEG path does. Regression coverage builds an absolute-offset Sony note.
  ([`Sources/SwiftMediaMetadata/TIFF/TIFFFileParser.swift`](Sources/SwiftMediaMetadata/TIFF/TIFFFileParser.swift))
- **Modern Sony ("Sony5") MakerNotes now read correctly.** Sony Alpha/RX/FX
  bodies store their MakerNote IFD's out-of-line value pointers as TIFF-absolute
  offsets, but `SonyMakerNote.parse` re-parsed the isolated note blob with
  `tiffStart: 0`, so the tail pointers ran past the blob and `parseIFD` threw —
  dropping the **entire** Sony MakerNote on every real ARW. The parser now
  receives the note's TIFF-relative base offset (`IFDEntry.sourceOffset`) and
  auto-detects whether pointers are block-relative or TIFF-absolute, rebasing
  the latter. Combined with the MakerNote-relocator fix below, Sony notes also
  survive a metadata rewrite intact. Regression test
  `testSonyAbsoluteOffsetMakerNote`.
  ([`Sources/SwiftMediaMetadata/MakerNote/SonyMakerNote.swift`](Sources/SwiftMediaMetadata/MakerNote/SonyMakerNote.swift),
  [`Sources/SwiftMediaMetadata/MakerNote/MakerNoteReader.swift`](Sources/SwiftMediaMetadata/MakerNote/MakerNoteReader.swift))
- **Relocating a Sony MakerNote on write no longer corrupts it.** The
  MakerNote-relocator classified Sony as relative/verbatim, but Sony5 pointers
  are TIFF-absolute (above), so a write that moved the block left every internal
  pointer dangling — silently destroying the note. Sony is now treated as an
  absolute-offset note whose out-of-line value-offset fields are shifted by the
  relocation delta (non-prefixed Sony5 only; "SONY DSC"/"SONY CAM"-prefixed
  notes fall back to verbatim+warn). Regression tests `testSonyNoteGetsAbsoluteFixUp`
  and `testSonyPrefixedNoteWarnsVerbatim`.
  ([`Sources/SwiftMediaMetadata/MakerNote/MakerNoteRelocator.swift`](Sources/SwiftMediaMetadata/MakerNote/MakerNoteRelocator.swift))
- **Sony MakerNote tag `0xB020` is no longer mislabeled `SerialNumber`.** Per
  ExifTool's `Sony.pm` it is the ASCII `CreativeStyle` preset ("Standard",
  "Vivid", …); reading it as a serial number emitted a bogus value that collided
  with the real body serial (ExifIFD `0xA431`). It is now surfaced as
  `CreativeStyle` with trailing NUL/space trimming. Tests updated accordingly.
  ([`Sources/SwiftMediaMetadata/MakerNote/SonyMakerNote.swift`](Sources/SwiftMediaMetadata/MakerNote/SonyMakerNote.swift))
- **C2PA signing certificates stored under a text `x5chain` label are now
  read.** `parseSignature` looked for the COSE x5chain only under the registered
  integer header label 33; Sony's in-camera C2PA signer places it under the
  text label `"x5chain"`, so the certificate chain came back empty and the
  signer could not be identified. The header is now searched for both forms, in
  the protected and (as a fallback) the unprotected bucket. Regression test
  `testParseSignatureTextX5Chain`.
  ([`Sources/SwiftMediaMetadata/C2PA/C2PAReader.swift`](Sources/SwiftMediaMetadata/C2PA/C2PAReader.swift))
- **C2PA v1 claim assertion references are now parsed.** The claim parser only
  read the v2 `created_assertions` / `gathered_assertions` arrays, so a v1 claim
  (e.g. Sony's in-camera `SONY_CAMERA` generator) reported zero assertion
  references even though its assertion store was populated. The v1 `assertions`
  array is now read alongside the v2 keys. Regression test
  `testParseClaimV1AssertionReferences`.
  ([`Sources/SwiftMediaMetadata/C2PA/C2PAReader.swift`](Sources/SwiftMediaMetadata/C2PA/C2PAReader.swift))

## [1.8.2] — 2026-06-02

### Added

- **`ImageMetadata.writeToDataWithWarnings()`** and **`write(to:)` /
  `write(to:options:)` now return non-fatal write warnings** (`[String]`,
  `@discardableResult` so existing call sites stay source-compatible). The
  warnings surface conditions a write recovered from rather than failed on —
  currently a relocated TIFF/DNG MakerNote whose manufacturer-specific
  internal offsets may no longer resolve (see below). The underlying
  `TIFFWriter.write(_:exif:iptc:xmp:iccProfile:)` gains a sibling overload
  taking a `warnings: inout [String]` out-parameter.
  ([`Sources/SwiftMediaMetadata/API/ImageMetadata.swift`](Sources/SwiftMediaMetadata/API/ImageMetadata.swift),
  [`Sources/SwiftMediaMetadata/TIFF/TIFFWriter.swift`](Sources/SwiftMediaMetadata/TIFF/TIFFWriter.swift))

### Fixed

- **AVIF/HEIF write path now stores EXIF and XMP as spec-conformant metadata
  items** (`iinf`/`infe` + `iloc` + `iref cdsc`, payload in `idat`) instead of
  as `iprp`/`ipco` properties, which spec-compliant readers (exiftool, Apple
  ImageIO, Preview, Lightroom) could not see. Growing the `meta` box shifts
  `mdat`, so construction-method-0 `iloc` offsets for the primary image item
  are patched by the size delta; large-size (64-bit) box headers are now
  preserved on write so those offsets stay valid for Apple/sips files. The
  AVIF read path passes `fileData` so the items round-trip.
  ([`Sources/SwiftMediaMetadata/Binary/ISOBMFFMetadata.swift`](Sources/SwiftMediaMetadata/Binary/ISOBMFFMetadata.swift),
  [`Sources/SwiftMediaMetadata/AVIF/AVIFParser.swift`](Sources/SwiftMediaMetadata/AVIF/AVIFParser.swift),
  [`Sources/SwiftMediaMetadata/Binary/ISOBMFFBox.swift`](Sources/SwiftMediaMetadata/Binary/ISOBMFFBox.swift))
- **`TIFFWriter` no longer drops strip/tile pixel data on write.** Previously
  it left `StripOffsets` pointing past EOF, so any photographic TIFF
  round-tripped through SwiftExif decoded black. It now relocates every block
  an IFD entry points at — strip/tile rasters, the old-style JPEG thumbnail,
  and every child IFD — copying the bytes and rewriting the offsets across the
  whole IFD chain. Exif sub-IFD values (ISO, LensModel, exposure) are now
  serialized into TIFF, and assigned IFD0 camera tags (Make/Model) are written
  while the destination's structural tags are preserved.
  ([`Sources/SwiftMediaMetadata/TIFF/TIFFWriter.swift`](Sources/SwiftMediaMetadata/TIFF/TIFFWriter.swift))
- **`TIFFWriter` now relocates SubIFDs (0x014A) and the Interoperability IFD
  (0xA005) too, not just Exif/GPS.** Child-IFD relocation is now generic:
  Exif (0x8769) and GPS (0x8825) still come from the assigned `exif` model so
  user edits apply, but every other pointer — the SubIFDs array that carries a
  DNG's full-resolution raw image, the Interop IFD nested inside Exif, and any
  pointer nested inside a child — is parsed from the source bytes and relocated
  recursively, with the child's own strips/tiles and nested pointers carried
  along. The 0x014A array is rewritten as new LONG offsets in order, fixing DNG
  raw-image loss on round-trip. Recursion is bounded (`maxIFDDepth = 32`) and
  every source offset is bounds-checked, so malformed input drops the offending
  pointer rather than crashing or emitting a dangling offset. New regression
  tests cover SubIFD-array + child-raster survival, a single inline SubIFD,
  Interop-inside-Exif round-trip, and malformed-pointer drop.
  ([`Sources/SwiftMediaMetadata/TIFF/TIFFWriter.swift`](Sources/SwiftMediaMetadata/TIFF/TIFFWriter.swift))

### Known limitations

- **Relocated TIFF/DNG MakerNote (0x927C) internal offsets are not fixed up.**
  A MakerNote is copied verbatim to its new file offset, but manufacturers
  store internal pointers inside it (some absolute from the TIFF start, some
  relative to the Exif-IFD/MakerNote start) that break when the containing IFD
  moves — exactly as in any rewriter without per-manufacturer fix-up logic.
  SwiftExif does not attempt that fix-up (unchanged from prior releases), but
  the write now surfaces a non-fatal warning via the new
  `writeToDataWithWarnings()` / `write(to:)` return value instead of silently
  emitting a possibly-corrupt note. A proper per-manufacturer fix-up is
  deferred to a future design change.
  ([`Sources/SwiftMediaMetadata/TIFF/TIFFWriter.swift`](Sources/SwiftMediaMetadata/TIFF/TIFFWriter.swift))

## [1.8.1] — 2026-05-15

### Changed

- **`FileHasher.hash(url:)` now streams the file in 1 MB chunks** instead of
  loading the whole file into memory via `Data(contentsOf:)`. Peak RSS for
  computing `File:MD5` + `File:SHA256` is now one chunk plus hasher state,
  independent of file size — previously a 60 GB video peaked at 60 GB
  resident (and doubled on the Linux PureCrypto path, which copied the
  buffer again via `[UInt8](data)`). On Apple the streaming path uses
  CryptoKit's incremental `Insecure.MD5()` / `SHA256()`; on non-Apple, new
  `PureMD5.Streaming` / `PureSHA256.Streaming` value types handle 64-byte
  block buffering and pad/length finalize. The one-shot `hash(_:Data)`
  entry points are now thin wrappers over the same streaming types, so the
  in-memory path also stops doing the extra `[UInt8](data)` copy.
  `MetadataExporter.buildDictionary` calls `FileHasher.hash(url:)` directly
  instead of pre-loading `Data(contentsOf:)`, removing the full-file
  allocation at the API boundary too. Covered by new block-boundary,
  streaming-parity, and end-to-end `hash(url:)` tests.
  ([`Sources/SwiftMediaMetadata/Binary/FileHasher.swift`](Sources/SwiftMediaMetadata/Binary/FileHasher.swift),
  [`Sources/SwiftMediaMetadata/Binary/PureCrypto.swift`](Sources/SwiftMediaMetadata/Binary/PureCrypto.swift),
  [`Sources/SwiftMediaMetadata/API/MetadataExporter.swift`](Sources/SwiftMediaMetadata/API/MetadataExporter.swift))

- **`ISO8601DateFormatter` instances hoisted out of hot paths.** Three call
  sites previously allocated a fresh formatter on every invocation —
  `VideoMetadataExporter.buildDictionary` (three per call), `GPXParser`'s
  per-trackpoint `parseISO8601`, and `NRTXMLParser`'s per-track
  `parseISO8601`. Each construction reconfigures locale and timezone
  tables, which dominated batch video export and GPX parsing runtime. The
  formatters are now `nonisolated(unsafe) static let` —
  `ISO8601DateFormatter` is documented thread-safe for read-only
  `string(from:)` / `date(from:)` but doesn't formally conform to
  `Sendable`, so the opt-out annotation is needed under strict concurrency.
  ([`Sources/SwiftMediaMetadata/API/VideoMetadataExporter.swift`](Sources/SwiftMediaMetadata/API/VideoMetadataExporter.swift),
  [`Sources/SwiftMediaMetadata/GPX/GPXParser.swift`](Sources/SwiftMediaMetadata/GPX/GPXParser.swift),
  [`Sources/SwiftMediaMetadata/Video/NRTXMLParser.swift`](Sources/SwiftMediaMetadata/Video/NRTXMLParser.swift))

- **`ImageMetadata.read`, `BRAWFrameReader`, `RTMDReader`,
  `AudioMetadata.read`, and `C2PAData.read(from: URL)` now memory-map
  the source file** with `.alwaysMapped` instead of allocating the whole
  file into RSS via `Data(contentsOf:)`. Each of these readers scatter-
  reads small payloads at offsets pulled from sample tables / chunk
  headers (slate boxes for BRAW, RTMD packets for MXF/XAVC, ID3/MP4
  tag chunks for audio, JUMBF superboxes for C2PA), so mapping is
  strictly cheaper than copying — peak RSS for a 60 GB BRAW slate read
  drops from 60 GB to a few KB of resolved pages. `.alwaysMapped` (not
  `.mappedIfSafe`) — the latter silently declines to map external
  drives and falls back to a full copy, defeating the win exactly on
  the volumes (USB-C SSDs, NAS, card readers) where it matters most.
  Mirrors the established pattern already in
  [`VideoMetadata.loadContainerData`](Sources/SwiftMediaMetadata/API/VideoMetadata.swift).
  ([`Sources/SwiftMediaMetadata/API/ImageMetadata.swift`](Sources/SwiftMediaMetadata/API/ImageMetadata.swift),
  [`Sources/SwiftMediaMetadata/API/AudioMetadata.swift`](Sources/SwiftMediaMetadata/API/AudioMetadata.swift),
  [`Sources/SwiftMediaMetadata/C2PA/C2PAData.swift`](Sources/SwiftMediaMetadata/C2PA/C2PAData.swift),
  [`Sources/SwiftMediaMetadata/Video/BRAWFrameReader.swift`](Sources/SwiftMediaMetadata/Video/BRAWFrameReader.swift),
  [`Sources/SwiftMediaMetadata/Video/RTMDReader.swift`](Sources/SwiftMediaMetadata/Video/RTMDReader.swift))

- **Recursive ISOBMFF `findBox` no longer descends into non-container
  box payloads.** `Binary/ISOBMFFMetadata.findBox` previously called
  `ISOBMFFBoxReader.parseBoxes` on every visited box's payload —
  including leaves like `Exif`, `mdat`, `iloc`, `ipma`, `ispe`, `colr`,
  and the `xml ` XMP box, none of which are box-formatted. The descent
  burned CPU re-parsing opaque bytes on every metadata extraction.
  Recursion is now gated on a 14-entry allowlist of true ISOBMFF
  container types (`moov`, `trak`, `mdia`, `minf`, `stbl`, `dinf`,
  `udta`, `edts`, `mvex`, `moof`, `traf`, `mfra`, `iprp`, `ipco`).
  `meta` (4-byte FullBox header), `stsd` (version + entry_count
  prefix), and `uuid` (16-byte UUID prefix) are intentionally excluded
  — they carry their own header prefix and are handled by dedicated
  paths (`parseMetaChildren`, `extractExifFromMeta`,
  `extractXMPFromMeta`, `CR3Parser`). Locked in by two new tests in
  [`Tests/SwiftMediaMetadataTests/Binary/ISOBMFFBoxTests.swift`](Tests/SwiftMediaMetadataTests/Binary/ISOBMFFBoxTests.swift)
  confirming that legitimate descent into `moov → udta → Exif` still
  resolves while a fake `Exif` hidden inside `mdat` is correctly
  ignored.
  ([`Sources/SwiftMediaMetadata/Binary/ISOBMFFMetadata.swift`](Sources/SwiftMediaMetadata/Binary/ISOBMFFMetadata.swift))

### Fixed

- **MP4/MOV `displayWidth` / `displayHeight` orientation consistency** —
  display dimensions on `VideoStream` now always reflect the final rendered
  shape, after both pixel-aspect correction (`pasp`) and `tkhd` rotation,
  matching ffprobe's `display_aspect_ratio` contract. Previously, MP4/MOV
  files with a `pasp` box surfaced coded (pre-rotation) dimensions while
  files without `pasp` but with a non-identity tkhd matrix surfaced
  post-rotation dimensions, so a downstream consumer that applied
  `rotation` to the display dims would double-rotate iPhone HEVC portrait
  clips back to landscape. The same path also fixes a latent
  `pixelAspectRatio` miscomputation for tkhd-derived rotated streams
  without a `pasp` box (an iPhone H.264 portrait clip would previously
  surface PAR `(81, 256)` instead of `(1, 1)`).
  ([`Sources/SwiftMediaMetadata/Video/MP4VisualSampleEntry.swift`](Sources/SwiftMediaMetadata/Video/MP4VisualSampleEntry.swift),
  [`Sources/SwiftMediaMetadata/Video/MP4Parser.swift`](Sources/SwiftMediaMetadata/Video/MP4Parser.swift))

### Security

- **GPMF recursive container range clamped to actual buffer length.** An
  attacker-declared `sampleSize × sampleCount` in a container KLV header
  could exceed the underlying buffer, and the recursive parse passed that
  unclamped upper bound straight through. The inner loop's
  `off + 8 <= range.upperBound` guard would then read past `data.endIndex`
  and trap on `Data` subscript bounds. The recursive walker now clamps the
  declared range to the buffer length before recursing. Locked in by a new
  malformed-GPMF regression fixture in
  [`Tests/SwiftMediaMetadataTests/Video/Phase25GPMFTests.swift`](Tests/SwiftMediaMetadataTests/Video/Phase25GPMFTests.swift).
  ([`Sources/SwiftMediaMetadata/Video/GPMFReader.swift`](Sources/SwiftMediaMetadata/Video/GPMFReader.swift))

- **GPMF container recursion capped at 32 levels.** Sibling fix to the
  range clamp above: each KLV container header is only 8 bytes, so a
  64 KB blob can declare ~8000 levels of nesting — one recursive call
  per level on the thread stack, deep enough to SIGSEGV. The recursive
  walker now threads a `depth` counter and stops descending once it hits
  `GPMFReader.maxRecursionDepth = 32` (real GoPro telemetry tops out at
  depth 2–3). Same graceful-degradation posture as the range clamp: the
  outermost entries are kept, deeper containers surface with empty
  `children`. Mirrors the existing `XMPReader.maxFrameDepth` convention.
  New deep-nesting regression fixture in
  [`Tests/SwiftMediaMetadataTests/Video/Phase25GPMFTests.swift`](Tests/SwiftMediaMetadataTests/Video/Phase25GPMFTests.swift).
  ([`Sources/SwiftMediaMetadata/Video/GPMFReader.swift`](Sources/SwiftMediaMetadata/Video/GPMFReader.swift))

- **`DateFormatter` race condition on swift-corelibs-foundation (Linux).**
  `ImageMetadata` previously held a `private static let exifDateFormatter`
  shared across all callers of the public `shiftExifDateString` /
  `shiftDateString` API — reachable concurrently from `TaskGroup`, batch
  operations, and library clients. `DateFormatter` is documented
  thread-unsafe and mutates internal state inside both `date(from:)` and
  `string(from:)`. Apple's Foundation masks the race with internal
  locking, but swift-corelibs-foundation (used in the Linux-musl build)
  does not — so concurrent callers on Linux could crash or return
  corrupted dates. The shared instance is replaced with a per-call
  `makeExifFormatter()` helper; allocation cost is microseconds, dwarfed
  by the surrounding I/O. While here, `MetadataRenamer.formatDateField`
  collapses three `DateFormatter` allocations per token into one by
  reusing `fmt` for both parse and format; `Locale` and `TimeZone` are
  hoisted into `static let`s (value types, safe to share), while the
  `DateFormatter` itself stays per-call to avoid reintroducing the race.
  A new smoke test fans out `shiftExifDateString` across 10k concurrent
  iterations with varied inputs to lock in a regression guard.
  ([`Sources/SwiftMediaMetadata/API/ImageMetadata.swift`](Sources/SwiftMediaMetadata/API/ImageMetadata.swift),
  [`Sources/SwiftMediaMetadata/API/MetadataRenamer.swift`](Sources/SwiftMediaMetadata/API/MetadataRenamer.swift))

## [1.8.0] — 2026-05-13

### Added

- **Content colour volume (SEI 147) and ambient viewing environment (SEI 148)** —
  HEVC SEI payload types 147 and 148 are now decoded into two new
  `VideoStream.hdr` sub-structs (`HDRContentColourVolume`,
  `HDRAmbientViewingEnvironment`). CCV describes the actual chromaticity /
  luminance bounds the *content* reaches (distinct from the *display* the
  content was mastered on, which is what `mdcv` records); AVE encodes the
  target viewing-room illuminance + white-point chromaticity. Both surface as
  `ContentColourVolume*` / `AmbientViewingEnvironment*` keys on the default
  flat exporter output and on the per-stream report.
  ([`Sources/SwiftMediaMetadata/Video/MPEGBitstream.swift`](Sources/SwiftMediaMetadata/Video/MPEGBitstream.swift),
  [`Sources/SwiftMediaMetadata/API/VideoStream.swift`](Sources/SwiftMediaMetadata/API/VideoStream.swift))

- **HDR static metadata on HEIF / AVIF stills** — `mdcv` and `clli` properties
  inside the `meta → iprp → ipco` hierarchy (iPhone Pro HDR HEIC, AOM HDR AVIF
  reference encoder) are now parsed via a new
  `ISOBMFFMetadata.extractHDRMetadata` that reuses the existing
  `MP4Parser.parseMDCVBox` / `parseCLLIBox` decoders. Exposed as
  `ImageMetadata.hdr` (typed as the same shared `HDRMetadata` used by the
  video side) and as `HDR:MasteringDisplay*` / `HDR:MaxCLL` / `HDR:MaxFALL`
  keys in the flat image exporter.
  ([`Sources/SwiftMediaMetadata/Binary/ISOBMFFMetadata.swift`](Sources/SwiftMediaMetadata/Binary/ISOBMFFMetadata.swift),
  [`Sources/SwiftMediaMetadata/API/ImageMetadata.swift`](Sources/SwiftMediaMetadata/API/ImageMetadata.swift))

- **Matroska HDR static metadata** — `MaxCLL` (0x55BC), `MaxFALL` (0x55BD), and
  the `MasteringMetadata` (0x55D0) element group inside the `Colour` master are
  now parsed in `MatroskaReader` and surfaced through the existing
  `VideoStream.hdr` (`HDRMasteringDisplay` / `HDRContentLightLevel`). This
  matches the MP4 `mdcv`/`clli` and HEVC SEI paths so MKV/WebM callers see the
  same shape regardless of container. Matroska stores chromaticities and
  luminance as IEEE floats in CIE 1931 xy units and cd/m² respectively, so no
  scaling is needed (unlike MP4's `mdcv` box which uses fixed-point u16/u32).
  ([`Sources/SwiftMediaMetadata/Video/MatroskaReader.swift`](Sources/SwiftMediaMetadata/Video/MatroskaReader.swift))

- **HDR extraction from HEVC parameter-set NAL arrays** — MakeMKV-style Blu-ray
  HDR10 remuxes carry MaxCLL / MaxFALL and the mastering-display volume in
  *prefix-SEI* NAL units inside the `HEVCDecoderConfigurationRecord` (the
  ISOBMFF `hvcC` box / Matroska `V_MPEGH/ISO/HEVC` `CodecPrivate`) rather than
  as parallel `mdcv` / `clli` container boxes. `parseHVCC` now walks those
  arrays via a new `MPEGBitstream.extractHEVCConfigurationBitstreams`, runs the
  existing `parseHEVCSPS` / `parseSEIMessages` decoders, and merges any
  recovered VUI color signalling and SMPTE ST 2086 / CTA-861.3 SEIs into
  `VideoStream.hdr`. Verified end-to-end against real HDR Blu-ray remuxes —
  values match `ffprobe` to four decimals.
  ([`Sources/SwiftMediaMetadata/Video/MPEGBitstream.swift`](Sources/SwiftMediaMetadata/Video/MPEGBitstream.swift),
  [`Sources/SwiftMediaMetadata/Video/MP4VisualSampleEntry.swift`](Sources/SwiftMediaMetadata/Video/MP4VisualSampleEntry.swift))

- **`MasteringDisplay*` / `MaxCLL` / `MaxFALL` keys exposed via the default
  `VideoMetadataExporter` dictionary** — until now, the flat `read` output
  only included `ColorPrimaries` / `TransferCharacteristics` etc. and
  consumers had to opt into `--streams` (or read `VideoStream.hdr` from the
  Swift API) to see the HDR side data. The top-level video dictionary now
  reports the same mastering-display chromaticities, luminance bounds, MaxCLL,
  MaxFALL, and Dolby Vision summary that the per-stream report carries.
  ([`Sources/SwiftMediaMetadata/API/VideoMetadataExporter.swift`](Sources/SwiftMediaMetadata/API/VideoMetadataExporter.swift))

- **`VideoStream.hdr` row in the README property table** — the per-stream
  `hdr` field is now documented alongside `colorInfo`, listing the container
  sources it draws from (ISOBMFF `mdcv` / `clli` / `dvcC` boxes, HEVC / H.264
  SEI payloads 137 and 144, and the new Matroska elements).
  ([`README.md`](README.md))

### Changed

- **Matroska HEVC `CodecPrivate` handler delegates to `MP4Parser.parseHVCC`** —
  the byte-offset reads for HEVC profile / bit-depth / chroma signalling used
  to be duplicated between `MatroskaReader.applyMatroskaCodecPrivate` and
  `MP4VisualSampleEntry.parseHVCC`. They are now consolidated: the MKV path
  defers to the MP4 parser (which also runs the new NAL-array bitstream walker
  above) and re-applies any fields the Matroska `Tracks` master had already
  populated, so the `Tracks` element wins on conflict.
  ([`Sources/SwiftMediaMetadata/Video/MatroskaReader.swift`](Sources/SwiftMediaMetadata/Video/MatroskaReader.swift))

### Fixed

- **HEVC SPS `scaling_list_data` skip was off-by-one for `sizeId == 3`** — the
  inner loop used `matrixCount = 2` instead of iterating `matrixId < 6` with
  step 3, so the 32×32 Inter-Y matrix `[3][3]` was silently dropped. On
  encoders that ship full 32×32 coefficients (every Blu-ray HDR HEVC remux,
  any MakeMKV output), the bit cursor landed ~450 bits short and
  `vui_parameters_present_flag` read as garbage — VUI color signalling
  (`color_primaries`, `transfer_characteristics`, `matrix_coefficients`,
  `chroma_location`) silently dropped to nil. The fix iterates per spec
  §7.3.4. Locked in by a real-world HDR10 SPS regression fixture in
  [`Tests/SwiftMediaMetadataTests/Video/MPEGReaderTests.swift`](Tests/SwiftMediaMetadataTests/Video/MPEGReaderTests.swift)
  asserting BT.2020 / SMPTE 2084 / BT.2020-NCL / topleft chroma — matching
  what ffprobe reports for the same file.
  ([`Sources/SwiftMediaMetadata/Video/MPEGBitstream.swift`](Sources/SwiftMediaMetadata/Video/MPEGBitstream.swift))

- **HEVC SPS `short_term_ref_pic_set()` bailed out on
  `inter_ref_pic_set_prediction_flag = 1`** — the loop used `return f` to abort
  rather than skip past the inter-RPS bits, dropping VUI for every SPS that
  uses inter-RPS prediction (common in Blu-ray HEVC tail-of-list sets). The
  replacement tracks `NumDeltaPocs[stRpsIdx]` for each parsed set and reads
  the correct number of `used_by_curr_pic_flag` / `use_delta_flag` pairs per
  spec §7.4.8.
  ([`Sources/SwiftMediaMetadata/Video/MPEGBitstream.swift`](Sources/SwiftMediaMetadata/Video/MPEGBitstream.swift))

- **HEVC SPS long-term reference pic POC LSB read used a hardcoded 4-bit
  width** — `lt_ref_pic_poc_lsb_sps[i]` is `log2_max_pic_order_cnt_lsb_minus4
  + 4` bits wide (typically 8 for Blu-ray). Any SPS with
  `long_term_ref_pics_present_flag = 1` and `log2_max > 0` would desync the
  cursor before reaching VUI. Fix: save `log2_max_pic_order_cnt_lsb_minus4`
  earlier in the SPS and use it for the long-term POC LSB read.
  ([`Sources/SwiftMediaMetadata/Video/MPEGBitstream.swift`](Sources/SwiftMediaMetadata/Video/MPEGBitstream.swift))

## [1.7.0] — 2026-05-13

### Fixed

- **XMP read failing on packets with trailing NUL padding** — Sony out-of-
  camera JPEGs, Capture One exports, and several other writers pad the XMP
  packet with NUL bytes (and sometimes other non-XML garbage) past the
  closing `<?xpacket end="..."?>` PI so the packet can be edited in place.
  NSXMLParser rejected the extra content as "extra content at end of
  document" and SwiftExif surfaced it as `MetadataError.invalidXMP`, which
  in turn appeared to callers as the unhelpful
  `"The operation couldn't be completed. (SwiftExif.MetadataError error 4.)"`
  via Foundation's default NSError-bridge description. `XMPReader.readFromXML`
  now trims everything past the closing `?>` of the `<?xpacket end=...?>` PI
  before handing data to the parser, and falls back to stripping trailing
  NULs when no xpacket PI is present (covers bare XMP in TIFF tag 0x02BC,
  PNG iTXt, JPEG XL `xml` boxes, AVIF). Regression tests in
  [`Tests/SwiftMediaMetadataTests/XMP/XMPReaderTests.swift`](Tests/SwiftMediaMetadataTests/XMP/XMPReaderTests.swift).

### Changed

- **`MetadataError` now conforms to `LocalizedError`** — `errorDescription`
  surfaces the same `.description` string the type already produces, so
  errors bridged to `NSError` no longer render as
  `"(SwiftExif.MetadataError error N.)"`. Additive on both Darwin and
  swift-corelibs-foundation. ([`Sources/SwiftMediaMetadata/API/MetadataError.swift`](Sources/SwiftMediaMetadata/API/MetadataError.swift))

### Removed

- **`MetadataError.segmentNotFound(UInt16)`** — case was declared but never
  thrown anywhere in the codebase. Source-breaking for any downstream code
  matching `MetadataError` exhaustively. If you need an equivalent error,
  use `MetadataError.unexpectedEndOfData` or a format-specific case.

### Added

- **Canon Cinema RAW Light (.CRM / .CRL)** — read clip-level metadata from
  Canon C200 / C300 III / C500 II / C70 / R5C cinema cameras. CRM is
  ISOBMFF with `ftyp crx ` and shares the Canon-metadata UUID
  (`85c0b687-820f-11e0-8111-f4ce462b6a48`) with CR3 still images, so the
  in-`moov` `CMT1..CMT4` TIFF IFDs are read via a shared `CanonUUIDExtractor`
  hoisted out of `CR3Parser`. The new `CRMReader` adds a CTMD trak walker
  for per-frame timed metadata. Surfaces:
  - `format = .crm` / `.crl` (master vs proxy) with long-names
    `"Canon Cinema RAW Light"` / `"Canon Cinema RAW Light Proxy"`,
    promoted from `.mp4` based on the `crx ` ftyp brand combined with a
    CNCV `"CanonCRM"` prefix probe (so CR3 still images written with the
    same UUID layout don't get mis-tagged as video).
  - `camera.deviceManufacturer`, `deviceModelName`, `deviceSerialNumber`,
    `lensModelName`, `creationDate`, `irisFNumber`, `shutterTimeMs`,
    `isoSensitivity`, `lensZoomActualFocalLengthMm` — populated from
    CMT1/CMT2/CMT3 with first-frame CTMD values overriding when present.
  - `camera.whiteBalanceCoefficients` — Canon `CanonColorData` R/G1/G2/B
    multipliers from CTMD record types 0x0007/0x0008/0x0009 (the
    embedded TIFF block under tag 0x4001).
  - `videoMetadata.cameraTimeline: [CRMReader.CTMDFrame]` — full
    per-frame metadata stream: timestamp (record type 0x0001, with
    hundredths-of-a-second when the camera writes them), focal length
    (0x0004), F-number / shutter / ISO (0x0005), and white-balance
    coefficients (0x0007/8/9). One entry per CTMD sample.
  - `videoMetadata.embeddedThumbnailJPEG` / `embeddedPreviewJPEG` —
    Canon's THMB (≈160×120) and PRVW (≈1620×1080) JPEGs from the
    Canon-metadata and preview UUID containers.
  - `FormatDetector.detectVideo` recognises ftyp `crx ` (returns `.crm`);
    `detectVideoFromExtension` routes both `.crm` and `.crl`.
  - Read-only — no CRM/CRL writer in this release.
  Verified against EOS C70 sample clips. Refactor: `CR3UUID` → shared
  `CanonUUID`; CR3-image-pipeline behaviour unchanged.
- **Sony X-OCN RAW metadata** — read clip-level metadata from Sony VENICE /
  VENICE 2 / BURANO / F55 / F65 cinema cameras shooting X-OCN to MXF
  (OP-1a). X-OCN files are valid MXF containers, so the existing MXF
  reader already handled the picture/sound essence, timecode, MCA audio
  labelling, and C2PA — this release deepens the Sony NRT (RDD-18)
  AcquisitionRecord harvest and adds a dedicated `format = .xocn`
  promotion. Surfaces:
  - `format = .xocn`, `formatLongName = "Sony X-OCN (MXF)"`, promoted
    from `.mxf` when the picture-essence UL matches the Sony cinema-RAW
    sub-registry (`060e2b34.0401.0106.0e06.0401.0206.06xx`) **or** the
    NRT `<VideoFrame videoCodec="…X-OCN…">` label is present.
  - `videoCodec = "xocn"` plus a per-stream `codecName` of
    `"Sony X-OCN LT"` / `"Sony X-OCN ST"` / `"Sony X-OCN XT"` resolved
    from byte 15 of the picture-essence UL (LT confirmed against F55
    samples; ST/XT inferred from the NRT label and Sony's published
    codec ladder).
  - `camera.videoCodecLabel` — raw NRT codec string
    (e.g. `"F55_X-OCN_LT_8.6K_3:2"`).
  - `camera.pixelAspect` — from `<VideoLayout pixelAspect="…">`.
  - **CameraUnitMetadataSet** typed fields:
    `exposureIndex`, `isoSensitivity`, `shutterAngle` (deg),
    `shutterTimeMs`, `ndFilter`, `whiteBalanceK`, `tintCorrection`,
    `autoExposureMode`, `autoWhiteBalanceMode`,
    `imageSensorReadoutMode`, `imageSensorEffectiveWidth/Height` (µm),
    `gammaForCDL`, `cameraMasterGainDb`,
    `electricalExtenderMagnification`, `cameraAttributes`.
  - **SonyF65CameraMetadataSet** typed fields (also written by F55 /
    VENICE / BURANO):
    `gammaForLook`, `colorForLook`, `monitoringBaseCurve`,
    `monitoringCharacteristics`, `monitoringColorPrimaries`,
    `monitoringCodingEquations`, `monitoringDescriptions`,
    `preCDLTransform`, `postCDLTransform`, `lookProcessBaked`,
    `rawBlackCodeValue`, `rawGrayCodeValue`, `rawWhiteCodeValue`,
    `effectiveMarkerCoverage`, `effectiveMarkerAspectRatio`,
    `activeAreaAspectRatio`, `imageOrientation`,
    `cameraProcessDiscriminationCode`.
  - **CameraPostureMetadataSet**: `cameraTiltAngle`, `cameraRollAngle`
    (signed degrees).
  - **ASC CDL** — `<ExtendedContents><cdl:ColorCorrectionCollection>`
    Slope/Offset/Power/Saturation parsed into a structured
    `ASCCDLValues`. Identity transforms (Sony's default when no on-set
    grade was applied) are suppressed so the field doesn't pollute every
    clip.
  - **Lens** typed fields (LensUnitMetadataSet — VENICE / BURANO / FX9
    with a smart lens populate these): `irisFNumber`, `irisTNumber`,
    `focusPositionMeters`, `lensZoom35mmEquivalentMm`,
    `lensZoomActualFocalLengthMm`, `lensAttributes` (Sony-private lens
    ID code; `"Unknown"` placeholder filtered out).
  - `videoFrameAspectRatio` from `<VideoLayout aspectRatio="…">`.
  - **Body identification fallback** for Sony cinema NRT v2.00 schema —
    VENICE / VENICE 2 / BURANO bodies omit the `<Device>` element and
    carry the body identity in `CameraUnitMetadataSet.CameraAttributes`
    (`"<MPC-CODE> <SERIAL> Version<X.YY>"`). When `<Device>` is absent,
    the leading MPC code is decoded into a friendly model name and
    `deviceManufacturer` / `deviceModelName` / `deviceSerialNumber` are
    back-filled. Mapping confirmed against on-set NRT samples:
    `MPC-3628` → VENICE, `MPC-3633` → VENICE 2, `MPC-2610` → BURANO.
    Explicit `<Device>` (FX9 / Alpha series) always wins.
  - **Catch-all** `acquisitionGroups: [String: [String: String]]` —
    every NRT `<Item>` keyed by its parent `<Group>`, so unknown future
    Sony items still surface even before they're hand-typed.
  - JSON / table exporters emit the typed fields under their NRT-native
    PascalCase names (e.g. `ExposureIndexOfPhotoMeter`,
    `RawWhiteCodeValue`, `GammaForLook`) plus a nested `ASCCDL` block
    and an `AcquisitionRecord` dictionary.

  Verified against Sony F55 X-OCN LT 8.6K 3:2 samples (24p, 4-channel
  PCM 24-bit 48 kHz, anamorphic 1.5:1) — the picture descriptor reads
  the same 8640×5760 / 13014×5784 display geometry ExifTool reports,
  and every NRT acquisition group decodes to typed fields plus a
  faithful catch-all. Implementation reuses the existing
  [`MXFReader`](Sources/SwiftMediaMetadata/Video/MXFReader.swift) and
  [`NRTXMLParser`](Sources/SwiftMediaMetadata/Video/NRTXMLParser.swift) — no new
  reader file.

- **RED RAW (.R3D) container metadata** — read clip-level metadata from
  RED KOMODO-X / V-RAPTOR / DSMC2 R3D files. Parses RED's own
  length-prefixed `RED2` (and `RED1`) clip-header atom, decodes the
  built-in image / audio / TLV records, and surfaces:
  - `format = .r3d`, `formatLongName = "RED RAW"`
  - `videoWidth` / `videoHeight` (from the `rdi` sub-atom, e.g.
    5760×3240 for KOMODO-X 6K, 7680×4320 for V-RAPTOR 8K)
  - `audioSampleRate` + an audio stream (from the `rda` sub-atom)
  - `frameRate` / `camera.captureFps` (from the `OriginalFrameRate`
    float32 TLV — 23.976/25/29.97/etc.)
  - `camera.deviceManufacturer = "RED"`, `camera.deviceModelName`
    (Brain), `camera.deviceSerialNumber`, `camera.lensModelName`,
    `camera.creationDate` (combined from DateCreated + TimeCreated)
  - Two `Timecode` entries tagged `.redR3D` (RecordTimecode +
    PlaybackTimecode), plus a third when ReelTimecode is present
  - 19 `red_*` slate fields in `camera.userMetaNames` /
    `userMetaContents`: reel number, take, firmware, color
    temperature, ISO, crop area, sensor, video format, quality,
    storage type / serial / model, original filename, focus
    distance, etc. — names track ExifTool's `Image::ExifTool::Red`
    tag table.

  CLI: `swift-exif read clip.R3D` (also surfaces in `--format json` and
  via `swift-exif copy` / `--fields camera.*`).

- **Nikon RAW Video (N-RAW) detection** — Nikon Z8 / Z9 (post-RED-
  acquisition) write a Nikon-specific MP4 with `ftyp niko` and codec
  FourCC `NR3D`, often labelled "RED RAW" in Nikon's marketing. The
  bitstream is N-RAW (Nikon's existing RAW codec), wholly unrelated
  to RED's REDCODE / R3D format. SwiftExif now promotes these from
  generic `.mp4` to a new `.nikonRaw` format with
  `formatLongName = "Nikon RAW"`, so callers can tell Nikon's RAW
  files apart from real RED clips even when both share the `.R3D`
  extension. Detection is codec-based (`NR3D` in any video stream's
  sample entry); the rest of the metadata (resolution, timecode,
  audio, color) flows through the standard MP4 path unchanged.

## [1.6.0] — 2026-05-02

### Added

- **Per-frame BRAW metadata export → CSV (`swift-exif braw-frames`)** —
  new CLI subcommand and public reader that walk every frame of a BRAW
  clip. Two streams:
  - **Attributes** (default): one row per video frame with the seven
    `bmdf` fields (shutter angle, aperture, focal length, focus
    distance, ISO, white-balance Kelvin, white-balance tint) plus
    `frame_index` and `timestamp_s`. Columns are emitted as numeric
    where possible (suffixes `°`, `f`, `mm` stripped) so the CSV
    graphs directly without a preprocess step.
  - **`gyroscope` / `accelerometer`**: per-sample IMU vec3 from the
    BMD `mebx` motion-data tracks. Decoded by reverse-engineering the
    20-byte sample format `[size BE][key id "mogy"/"moac"][3× float32 LE]`
    — the float payload is little-endian, a BMD-specific quirk inside
    an otherwise big-endian container. Sample rate ≈ 1 kHz; gravity is
    visible on the up-axis at record-start (e.g. ~9.89 m/s² on +Y for
    Cinema 6K samples).

  New public API:
  - `BRAWFrameAttribute`, `BRAWMotionSample`, `BRAWMotionStream` types.
  - `BRAWFrameReader.readAttributes(from:)` — `[BRAWFrameAttribute]`.
  - `BRAWFrameReader.readMotionSamples(from:stream:)` — `[BRAWMotionSample]`.

  CLI:
  ```
  swift-exif braw-frames clip.braw                       # attrs CSV → stdout
  swift-exif braw-frames -s gyroscope clip.braw -o g.csv # IMU CSV → file
  swift-exif braw-frames -s accelerometer clip.braw
  ```

  Implementation lives in
  [`Sources/SwiftMediaMetadata/Video/BRAWFrameReader.swift`](Sources/SwiftMediaMetadata/Video/BRAWFrameReader.swift)
  and [`Sources/CLI/BRAWFramesCommand.swift`](Sources/CLI/BRAWFramesCommand.swift).
  Reuses `MP4Parser`'s stbl walkers (`stcoOffsets` / `co64Offsets` /
  `sampleFileOffsets` / `sttsSampleStartTicks` / `stszSampleSizes` /
  `stscSamplesPerChunk`) — all promoted from `private` to `internal`.
  `parseBRAWFirstFrameAttributes` was refactored to delegate to a
  shared `decodeBRAWFrameHeader(_:)` so the slate path (frame 0 only)
  and the new full-walk path can't drift apart.

  Coverage: five new tests in
  [`Tests/SwiftMediaMetadataTests/Video/BRAWFrameReaderTests.swift`](Tests/SwiftMediaMetadataTests/Video/BRAWFrameReaderTests.swift)
  — multi-frame walk, non-BRAW-throws, gyroscope round-trip,
  accelerometer-absent (returns empty), and key-id-mismatch (partial
  read terminates cleanly). Verified against three real BRAW samples
  (Cinema 6K `brhq`, PYXIS 6K `brst`, PYXIS 12K `brlt`).

## [1.5.1] — 2026-05-01

### Added

- **Blackmagic RAW: extended metadata harvest** — `MP4Parser` now decodes
  the rest of the `moov.meta` slate, the BRAW-specific codec-config
  atoms inside the sample entry, and the per-frame `bmdf` interpretation
  header at the start of frame 0 in mdat. Verified against `brhq` (High
  Quality), `brst` (Standard), and `brlt` (Light) clips from Cinema
  Camera 6K, PYXIS 6K, and PYXIS 12K. New surfaces in
  `CameraMetadata.userMetaNames` / `userMetaContents`:
  - **First-frame interpretation** — read out of the `bmdf` header at
    the start of the first video chunk pointed to by stco / co64. Window
    is sized by the declared `bmdf` size (≤ 4 KiB) so we never spill
    into image data. Across the three test clips every frame's header
    carries the same values, so frame-0 yields the clip-level default —
    keeping us out of any per-frame iteration. Decoded atoms:
    - `shtv` → `shutter_angle` (UTF-8 padded, e.g. "180°")
    - `aptr` → `aperture` (e.g. "f2.7")
    - `fcln` → `focal_length` (e.g. "135mm")
    - `dsnc` → `focus_distance` (e.g. "2430mm")
    - `isoe` → `iso` (uint32)
    - `wkel` → `white_balance_kelvin` (uint32)
    - `wtin` → `white_balance_tint` (signed int16)

    The four lens strings are NUL-padded to 24 bytes; we trim at the
    first NUL and skip empty values (cameras emit empty strings on
    bodies without electronic lens contacts — sample 1's Sigma 135mm
    populates all four, samples 2/3 only have shutter angle).
  - **Codec config** — `braw_codec_bfdn`, `braw_codec_ctrn`,
    `braw_codec_bver` (uint32 from `bfdn` / `ctrn` / `bver` child boxes
    inside the BRAW visual sample entry — the parser walks any FourCC
    starting with `br`, not just `brhq`).
  - **Codec bitrate** — `braw_codec_bitrate` as an unsigned uint32; the
    `decodeMDTAInt` table now treats BMD type 77 as unsigned so high-bit-set
    byterates (e.g. 3.2 GB/s on PYXIS 12K 112 fps clips) round-trip
    positive instead of sign-extending into negatives.
  - **Lens corrections + sensor timing** — `lens_shading_enable`,
    `lens_distortion_correction_enable`,
    `lens_chromatic_aberration_correction_enable`, `ois_enable`,
    `sensor_line_time` (μs/scanline), `sensor_photosite_pitch_in_micrometres`,
    `analog_gain_is_constant`.
  - **Tone curve / image processing** — `tone_curve_contrast`,
    `tone_curve_saturation`, `tone_curve_midpoint`, `tone_curve_highlights`,
    `tone_curve_shadows`, `tone_curve_black_level`, `tone_curve_white_level`,
    `tone_curve_video_black_level`, `highlight_recovery`.
  - **Embedded LUT** — `post_3dlut_embedded_size` (cube edge, e.g. 33 →
    33×33×33), `post_3dlut_embedded_bmd_gamma`, plus a presence marker
    `post_3dlut_embedded_data` → `"<N> bytes"` for the ~432 KB binary
    blob (the bytes themselves stay out of the metadata dictionary; only
    the size is reported).
  - **Misc slate** — `encoder_device_manufacturer`, `time_lapse_interval`,
    `anamorphic`, `rotation`.
  - **Per-frame motion-data tracks** — when an `mebx` timed-metadata
    track declares the `com.blackmagicdesign.motiondata.gyroscope` /
    `…accelerometer` namespace, the parser appends
    `has_gyroscope_motion_data` / `has_accelerometer_motion_data` markers.
    Per-frame samples themselves are not decoded.

  Coverage in
  [Tests/SwiftMediaMetadataTests/Video/MP4ParserTests.swift](Tests/SwiftMediaMetadataTests/Video/MP4ParserTests.swift):
  the existing `testParseBlackmagicRAWClipMetadata` was extended with
  representative tone-curve / lens / rotation / bitrate / 3D-LUT entries
  (including a high-bit-set type-77 fixture to lock in the unsigned
  decode), plus new `testParseBlackmagicRAWCodecAtoms` and
  `testParseBlackmagicMotionDataTracksDetected`.

## [1.5.0] — 2026-05-01

### Added

- **MPEG-TS bitstream decoding** — `MPEGReader` now decodes inline H.264 and
  HEVC SPS NAL units, AAC ADTS frame headers, and PCR timestamps directly from
  Transport Stream packets, surfacing pixel format, profile/level, framerate,
  sample rate, channel layout, and timing on `.ts` / `.m2ts` files without
  ffprobe. New `MPEGBitstream.swift` houses the bit-readers (Exp-Golomb,
  NAL emulation-prevention unescaping, ADTS frame parsing). Real-world HEVC
  SPS fixture added under `Tests/SwiftMediaMetadataTests/Video/MPEGReaderTests.swift`.

- **SMPTE ST 377-4 MCA audio labels for MXF** — multichannel audio labeling
  per SMPTE ST 377-4 is now decoded out of MXF audio descriptors. New
  `MCAAudioLabeling`, `MCALabelsRenderer`, and `MXFMCAReader` types in
  `Sources/SwiftMediaMetadata/Video/`, surfaced through `VideoStream` /
  `VideoMetadata` and the JSON exporter. New CLI subcommand
  `swift-exif mxf-labels` emits a bmx-compatible `labels.txt` round-trip
  for production audio workflows. Covered by
  [Tests/SwiftMediaMetadataTests/Video/MXFMCALabelsTests.swift](Tests/SwiftMediaMetadataTests/Video/MXFMCALabelsTests.swift)
  and the broader `MXFReaderTests` bundle.

- **Apple ecosystem support (Phase 18)** — full delivery of the Apple stack:
  - `AppleMakerNote.swift` — parse iPhone MakerNote tags (lens model,
    ContentIdentifier, image stabilization, HDR mode, etc.).
  - `AAESidecar.swift` — read Apple `.aae` adjustment-sidecar XML produced
    by Photos.app edits.
  - `HEIFAuxiliaryImages.swift` — extract HEIF auxiliary images (depth maps,
    alpha mattes, HDR gain maps) via the shared ISOBMFF / iloc plumbing.
  - Live Photo `ContentIdentifier` surfaced from `MP4Parser` so still+motion
    pairs can be re-linked after copy/round-trip.

- **Pentax, Leica, and Sigma MakerNote parsers** — three additional vendor
  MakerNote implementations under `Sources/SwiftMediaMetadata/MakerNote/`, with
  matching writer support in `MakerNoteWriter.swift` and round-trip
  coverage in `MakerNoteReaderTests` / `MakerNoteWriterTests`.

- **Blackmagic RAW (`.braw`) container metadata** — new format support
  routed through `MP4Parser`. BRAW is an ISOBMFF derivative with the
  legacy QuickTime layout (`wide` + `mdat` at the head, `moov` tail-placed,
  no `ftyp`); the parser now tolerates the missing `ftyp` and defaults to
  a `.mov` container shape, with `VideoMetadata.read(from:)` promoting the
  format to `.braw` based on extension. Standard boxes give duration,
  project frame rate, resolution, audio, and timecode. The Blackmagic
  slate is decoded out of `moov.meta` using QuickTime's non-FullBox
  `mdta` layout — the parser sniffs the `meta` box header to pick the
  right shape, so existing ISOBMFF / iTunes paths are untouched, and the
  `mdta` value decoder grew handlers for BRAW's typed `data` payloads
  including the BMD-specific type 71 (float32-BE pair) used for the
  rectangle fields. Surfaces to `CameraMetadata`:
  - camera make / model, firmware, color science generation, viewing
    gamma + gamut, compression ratio, shutter type;
  - off-speed `captureFps` (distinct from the mvhd/stts-derived
    `frameRate` — a 24p clip captured at 112 fps reports `frameRate≈24`
    and `captureFps≈112`);
  - production slate keys: clip number, scene, take, reel, camera
    number, environment, day/night;
  - `sensor_area_captured`, `crop_origin` / `crop_size` / `safe_area`
    rectangles, `LUT used`, `post_3dlut_mode`, embedded LUT name/title,
    `frameguide_aspect_ratio`, `gamut_compression_enable`.

  Per-frame interpretation attributes (white point, tint, absolute ISO,
  shutter angle) live in proprietary `bfdn` / `ctrn` boxes inside the
  codec sample entry and remain unparsed. Verified against Pyxis 12K /
  6K and Cinema 6K samples; values match DaVinci Resolve.

- **ExifTool / ffprobe parity initiative** — `PARITY_PLAN.md` lays out the
  delta between swift-exif's output and ExifTool / ffprobe, and several
  phases of that plan have already landed under this release:
  - **HEIC parity (Phase 1)** — `infe`-driven `content_type` resolution,
    explicit `meta → iprp → ipco` walk to dodge the FullBox header
    stumble, and a top-level `colr` fallback for files where the property
    box is absent.
  - **JPEG XL parity (Phase 2)** — decode `SizeHeader` from the JXL
    codestream so `File:ImageWidth` / `ImageHeight` are populated.
  - **MP4 stream parity (Phase 3.1 / 3.2 / 3.5)** — preserve track
    declaration order in the `streams` array, surface data tracks
    explicitly, and hoist chapter tracks out of `streams` into a sibling
    `chapters` array (no longer inflating the stream count).
  - **MP3 / M4A streams (Phase 3.3)** — emit a single synthetic audio
    stream from `--streams` to match ffprobe's shape for audio files.
  - **MKV track order (Phase 3.4)** — preserve Matroska track-declaration
    order rather than relying on dictionary iteration.
  - **GPS / subtitle codec cosmetics (Phase 4)** — render GPS coordinates
    with degree signs, alias the `tx3g` FourCC to `mov_text` so
    consumers see the same `codec_id` ffmpeg uses.
  - **Convention alignment** — metadata export now matches ExifTool
    naming conventions in a number of small spots that were diverging.

### Changed

- **Format-level `duration` now matches ffprobe.** Previously
  `format.duration` was reported as `mvhd` verbatim; mvhd is spec-defined
  as the longest mdhd of *any* track, so files like
  ChapterMarkerDualSubtitle.mp4 wound up reporting 98.691 s while
  audio/video both ended at ~71.16 s. The MP4 reader now caps mvhd at
  `max(audio, video)` when subtitle/data tracks inflate it (matching
  ffmpeg/ffprobe), and keeps the smaller mvhd value untouched when
  edit-list trimming legitimately makes mvhd shorter than the longest
  essence stream.

- **Audio file `format.bit_rate` now matches ffprobe.** For MP3 / M4A /
  FLAC, the container `bit_rate` is now derived as
  `file_size × 8 / duration` (the whole-file rate including container
  overhead and AAC priming/postroll padding) instead of the audio
  stream's declared rate.

- **MXF and MPEG-TS per-stream `Duration`.** MXF essence descriptors and
  MPEG-TS streams don't carry per-track durations the way MP4 does. The
  format-level duration is now propagated to each video / audio /
  subtitle stream that doesn't already have one, matching ffprobe's
  behavior and surfacing a sensible value to JSON consumers.

- **GPMF SCAL divisor lookup** is now hoisted out of the per-sample GPS5
  loop in `GPMFReader` — pure refactor, behavior preserved, covered by
  the existing telemetry tests.

### Fixed

- **GIF parser sub-block handling** — regression tests added covering the
  earlier sub-block-overrun hardening (truncated extension blocks, malformed
  image descriptors, unterminated sub-block chains). See
  [Tests/SwiftMediaMetadataTests/GIF/GIFParserTests.swift](Tests/SwiftMediaMetadataTests/GIF/GIFParserTests.swift)
  and `GIFWriterTests`.

## [1.4.0] — 2026-04-29

### Added

- **NRW, SRW, and generic `.raw` extension support** — `RawFormat` now lists
  `nrw` (Nikon Coolpix), `srw` (Samsung), and `raw` alongside the existing
  TIFF-based RAWs. `FormatDetector.detectFromExtension` routes them through
  the shared `TIFFFileParser`, so they read **and** write the same metadata
  surfaces (Exif, IPTC, XMP, ICC) as NEF / ARW / ORF / PEF. Extension lookup
  in the CLI's `supportedImageExtensions` set is updated to match.
- **`ImageMetadata.extractC2PAThumbnails()`** — convenience accessor that
  walks every C2PA manifest, returns each `c2pa.thumbnail.claim.*` /
  `c2pa.thumbnail.ingredient.*` assertion as a `C2PAThumbnail` (label, raw
  Data bytes, format suffix). Mirrors the existing `extractThumbnail()`
  pattern for EXIF IFD1 thumbnails. Bytes are already preserved by the JUMBF
  parser; this just removes the pattern-match boilerplate at call sites.
- **Recursive `XMPValue` for nested structured schemas** — Adobe Camera Raw's
  `MaskGroupBasedCorrections` (rdf:Bag of corrections, each holding its own
  rdf:Bag of mask sub-structs), face regions in `mwg-rs`, and other recursive
  XMP shapes can now be expressed in the generic API instead of hand-rolled
  parsers. Both writer and reader recurse.

### Changed

- **Breaking** — `XMPValue.structure` payload is now `[String: XMPValue]` (was
  `[String: String]`), and `XMPValue.structuredArray` is `[[String: XMPValue]]`
  (was `[[String: String]]`). Direct consumers that pattern-matched on these
  cases must wrap field values as `.simple(...)` when constructing them, and
  unwrap when reading. The accessor return types `structureValue(...)` and
  `structuredArrayValue(...)` changed accordingly.

  Two new convenience accessors smooth the migration: `flatStructureValue`
  and `flatStructuredArrayValue` return the legacy `[String: String]` shape
  by dropping any non-`.simple` entries — useful for IPTC / xmpDM timecode /
  stRef schemas that only carry flat strings. `XMPData.flatten` and
  `XMPData.wrapSimple` round-trip between the two forms.
- **Build script drops macOS Intel** — `Scripts/build-release.sh` now ships
  macOS arm64 + Linux x86_64-musl + Linux aarch64-musl only.

## [1.3.1] — 2026-04-24

### Added

- **`VideoScanType` and `scanType` / `scanOrder` helpers** on `VideoMetadata`
  and `VideoStream` — derive MediaInfo-style "Scan Type" (progressive /
  interlaced / unknown) and "Scan Order" (TFF / BFF) UI columns without
  enumerating every `VideoFieldOrder` case. `fieldOrder` still encodes both
  values in one enum and remains the ground truth.
- **MXF `FieldDominance` parsing (0x3212)** — SMPTE 377-1 §G.2.51 tag now
  resolves TFF vs BFF for interlaced essence descriptors that carry it.

### Fixed

- **`fieldOrder` now resolves for every supported container.** Previously,
  MP4 / MOV without a `fiel` atom, Matroska / WebM without `FlagInterlaced`,
  and MXF with `FrameLayout=1` (separated fields) all returned `nil` or
  `.unknown`, leaving downstream "Scan Type" UIs blank for the majority of
  real-world files. New behaviour:
  - MP4 / MOV: absence of `fiel` defaults to `.progressive` (matches ffmpeg
    `mov` demuxer and iPhone / camera convention).
  - Matroska / WebM: absence of `FlagInterlaced` / `FieldOrder` defaults to
    `.progressive` for video essence (cover-art MJPEG tracks keep `nil`).
    VP8 / VP9 / AV1 have no interlaced coding mode; HEVC / H.264 writers
    only emit these elements for genuinely interlaced source.
  - MXF: `FrameLayout=1` (separated fields) and `FrameLayout=3` (mixed)
    now resolve to `.topFieldFirst` (the broadcast convention and what
    MediaInfo / ffprobe report for untagged interlaced essence).
    `FieldDominance=2` overrides to `.bottomFieldFirst`. Previously these
    returned `.unknown`.

### Security

- **Int overflow hardening** across binary parsers — malformed input can no
  longer trap the process via arithmetic overflow on 32-bit lengths,
  offsets, or sub-block sizes. Affected paths: ICC profile, IPTC IIM,
  MPF, XMP, PNG, PSD, and the shared `Data` slicing helpers.
- **MP4 chapter allocation cap** — `chpl` (Nero) and `udta > chap` readers
  now refuse chapter counts that would allocate more than a sane ceiling,
  stopping a malformed `count` field from triggering gigabyte-scale
  `Array.reserveCapacity` on import.
- **GIF sub-block overrun fix** — application-extension sub-block reader
  no longer walks past the declared data length when a truncated stream
  omits its terminator.
- **Video-read memory cap** — the MKV / WebM front-end now limits the
  aggregate bytes it will buffer for a single import, keeping multi-file
  scans (batch imports, folder-watch) well under 1 GB resident even when
  fed unusually large Matroska clusters.
- **CBOR decoder overflow guard** — string and byte-string readers reject
  lengths that would overflow `Int`, preventing a crafted C2PA manifest
  from crashing the CBOR front-end.
- **zlib deflate-bomb cap** — PNG / ICC / XMP inflate paths now stop
  producing output once a generous decompressed-size ceiling is reached,
  so a tiny deflate stream can no longer expand to gigabytes and exhaust
  memory.

## [1.3.0] — 2026-04-23

### Added

- **Chapter markers** across three container families:
  - MP4 / MOV / M4V: QuickTime text-track chapters (`tref > chap` pointing
    at a `text`/`subt` track whose stts-timed UTF-8 samples are the titles —
    written by DaVinci Resolve, Apple Compressor, iTunes, ffmpeg
    `-map_chapters`), with Nero `udta > chpl` as the fallback (x264, ffmpeg,
    MP4Box).
  - Matroska / WebM: top-level `Chapters` master element — every
    `EditionEntry` + `ChapterAtom`, honouring `EditionFlagHidden` and
    `ChapterFlagHidden`; supports both `ChapLanguage` and the newer
    `ChapLanguageBCP47`.
  - New `VideoChapter` struct (`index`, optional `id`, `startTime`,
    `endTime`, `title`, `language`, computed `duration`). Exposed via
    `VideoMetadata.chapters`.
- **Provenance-tagged `timecodes: [Timecode]`** on `VideoMetadata` —
  every independent clip-level source (`tmcdTrack`, `quicktimeUdta`, `xmpDM`,
  `xmpDMAlt`, `mxfMaterialPackage`, `mxfFilePackage`, `sonyNRT`) recorded
  separately with optional frame-rate companion. The scalar `timecode` stays
  in sync with the first recorded value for backward compatibility.
  `recordTimecode(value, source:)` helper dedupes entries and appends a
  `timecode mismatch: …` warning when two sources disagree.
- **XMP timecode parsing** — `XMPData.startTimecode` / `.altTimecode`
  decode `xmpDM:startTimeCode` / `xmpDM:altTimecode`, mapping `timeFormat`
  (`24Timecode`, `29.97Timecode`, `2997DropTimecode`, `50Timecode`, …) to a
  numeric fps.
- **MXF TimecodeComponent labelling** — the first-encountered component is
  tagged `.mxfMaterialPackage`, subsequent ones `.mxfFilePackage` (header
  metadata always puts MaterialPackage before SourcePackage).
- **Sony NRT LtcChangeTable** — `LtcChange@frameCount="0"` now feeds a
  `.sonyNRT` entry in `timecodes`, accepting both the hex-encoded SMPTE 12M
  LTC word (XDCAM professional bodies) and the already-formatted
  `HH:MM:SS:FF` string (Alpha consumer bodies).
- **CLI `--streams --format json`** now emits:
  - `format.Timecodes` — array of `{ value, source, frameRate }` entries.
  - `format.ChapterCount` / `ChapterStartTimes` / `ChapterEndTimes` /
    `ChapterDurations` / `ChapterTitles` / `ChapterLanguages`.
  - Per-chapter rows in the `streams` array with `StreamType="chapter"`,
    carrying `Index`, `ChapterUID`, `StartTime`, `EndTime`, `Duration`,
    `Title`, `Language` — mirrors ffprobe's `-show_chapters` layout.

### Changed

- **QuickTime text chapter tracks are no longer reported as subtitles.**
  Any track referenced via `tref > chap` (on *any* parent track — DaVinci
  writes it on every trak, ffmpeg's mov muxer writes it only on non-video
  traks) is now excluded from `VideoMetadata.subtitleStreams`, matching
  ffprobe's `-select_streams s` output exactly. Real user-facing
  subtitles (tx3g, stpp, wvtt, …) are unaffected.
- Per-stream timecode is only set when the video track explicitly
  cross-references a `tmcd` track via `tref > tmcd` — matches ffprobe's
  behaviour of leaving per-stream tags empty for tmcd tracks that are
  only advertised at the clip level (e.g. Atomos Ninja ProRes RAW).

### Fixed

- DaVinci Resolve and ffmpeg-muxed MP4/MOV files no longer inflate the
  subtitle count by including the hidden chapter-text track.

### Validation

Verified end-to-end against:
- DaVinci Resolve MP4 + MOV exports (with 0, 1, and 2 real subtitle
  tracks alongside the chapter text track).
- ffmpeg-remuxed MP4 with a second SRT-sourced subtitle track and
  chapters preserved via `-map_chapters`.
- 90 GB Harry Potter Matroska with 37 chapters (English).

## [1.2.0] — 2026-04-22

### Added

- **ffprobe parity pass** across MP4/MOV/MXF/MKV containers — seventeen
  test clips benchmarked; remaining diffs trimmed from 29 to 13.
- **MP4/MOV**: container BitRate fallback, `edts > elst` edited-duration
  parsing, AAC profile from ESDS DecoderSpecificInfo, PCM codec short
  names by bit depth + endianness, ProRes / APV / ProRes RAW profile +
  pix_fmt, minimal VVC `vvcC` parser, stts dominant-delta → rFrameRate.
- **MXF**: MaterialPackage/Track/Sequence Duration fallback (for Sony
  XDCAM clips where ContainerDuration is zero), expanded SMPTE ST 2019-1
  AVC-Intra profile coverage, interlaced FrameLayout frame-height
  doubling, `AspectRatio` tag 0x320E → authoritative DAR, BWF/AES-3
  sound descriptor defaults.
- **Matroska**: cluster walker parses first DTS / AC-3 / E-AC-3 frame
  headers for per-stream bit_rate (matches ffprobe's MakeMKV handling);
  Vorbis identification-header parsing in CodecPrivate; shared-stale
  BPS/NUMBER_OF_FRAMES invalidation.
- `VideoStream.isDefault` / `isForced` / `isAttachedPic` always emitted
  so JSON consumers see a stable shape.
- CLI test harness under `Tests/SwiftMediaMetadataCLITests` (gated behind
  `SWIFT_EXIF_RUN_CLI_TESTS=1`).
- Documented Homebrew CLI install path in README.

### Changed

- PCM audio bitrate computed exactly as `sample_rate × channels × bit_depth`
  (avoids rounding noise from stsz-over-duration).
- `format_long_name` returns `"QuickTime / MOV"` for all ISOBMFF brands
  (isom / mp42 / qt / M4V / …) to match ffprobe.

[2.0.0]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.9.10...HEAD
[1.9.10]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.9.9...1.9.10
[1.9.9]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.9.8...1.9.9
[1.9.8]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.9.7...1.9.8
[1.9.7]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.9.6...1.9.7
[1.9.6]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.9.5...1.9.6
[1.9.5]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.9.4...1.9.5
[1.9.4]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.9.3...1.9.4
[1.9.3]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.9.2...1.9.3
[1.9.2]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.9.1...1.9.2
[1.9.1]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.9.0...1.9.1
[1.9.0]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.8.2...1.9.0
[1.8.2]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.8.1...1.8.2
[1.8.1]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.8.0...1.8.1
[1.8.0]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.7.0...1.8.0
[1.7.0]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.6.0...1.7.0
[1.6.0]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.5.1...1.6.0
[1.5.1]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.5.0...1.5.1
[1.5.0]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.4.0...1.5.0
[1.4.0]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.3.1...1.4.0
[1.3.1]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.3.0...1.3.1
[1.3.0]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.2.0...1.3.0
[1.2.0]: https://github.com/aagedal/SwiftMediaMetadata/compare/1.1.0...1.2.0
