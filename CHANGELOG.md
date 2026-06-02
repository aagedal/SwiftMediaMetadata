# Changelog

All notable changes to swift-exif (CLI) and the SwiftExif library.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers follow [Semantic Versioning](https://semver.org/) and track
the CLI; the library target follows the same numbering.

## [Unreleased]

## [1.8.2] — 2026-06-02

### Fixed

- **AVIF/HEIF write path now stores EXIF and XMP as spec-conformant metadata
  items** (`iinf`/`infe` + `iloc` + `iref cdsc`, payload in `idat`) instead of
  as `iprp`/`ipco` properties, which spec-compliant readers (exiftool, Apple
  ImageIO, Preview, Lightroom) could not see. Growing the `meta` box shifts
  `mdat`, so construction-method-0 `iloc` offsets for the primary image item
  are patched by the size delta; large-size (64-bit) box headers are now
  preserved on write so those offsets stay valid for Apple/sips files. The
  AVIF read path passes `fileData` so the items round-trip.
  ([`Sources/SwiftExif/Binary/ISOBMFFMetadata.swift`](Sources/SwiftExif/Binary/ISOBMFFMetadata.swift),
  [`Sources/SwiftExif/AVIF/AVIFParser.swift`](Sources/SwiftExif/AVIF/AVIFParser.swift),
  [`Sources/SwiftExif/Binary/ISOBMFFBox.swift`](Sources/SwiftExif/Binary/ISOBMFFBox.swift))
- **`TIFFWriter` no longer drops strip/tile pixel data on write.** Previously
  it left `StripOffsets` pointing past EOF, so any photographic TIFF
  round-tripped through SwiftExif decoded black. It now relocates every block
  an IFD entry points at — strip/tile rasters, the old-style JPEG thumbnail,
  and the Exif/GPS sub-IFDs — copying the bytes and rewriting the offsets
  across the whole IFD chain. Exif sub-IFD values (ISO, LensModel, exposure)
  are now serialized into TIFF, and assigned IFD0 camera tags (Make/Model)
  are written while the destination's structural tags are preserved.
  ([`Sources/SwiftExif/TIFF/TIFFWriter.swift`](Sources/SwiftExif/TIFF/TIFFWriter.swift))

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
  ([`Sources/SwiftExif/Binary/FileHasher.swift`](Sources/SwiftExif/Binary/FileHasher.swift),
  [`Sources/SwiftExif/Binary/PureCrypto.swift`](Sources/SwiftExif/Binary/PureCrypto.swift),
  [`Sources/SwiftExif/API/MetadataExporter.swift`](Sources/SwiftExif/API/MetadataExporter.swift))

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
  ([`Sources/SwiftExif/API/VideoMetadataExporter.swift`](Sources/SwiftExif/API/VideoMetadataExporter.swift),
  [`Sources/SwiftExif/GPX/GPXParser.swift`](Sources/SwiftExif/GPX/GPXParser.swift),
  [`Sources/SwiftExif/Video/NRTXMLParser.swift`](Sources/SwiftExif/Video/NRTXMLParser.swift))

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
  [`VideoMetadata.loadContainerData`](Sources/SwiftExif/API/VideoMetadata.swift).
  ([`Sources/SwiftExif/API/ImageMetadata.swift`](Sources/SwiftExif/API/ImageMetadata.swift),
  [`Sources/SwiftExif/API/AudioMetadata.swift`](Sources/SwiftExif/API/AudioMetadata.swift),
  [`Sources/SwiftExif/C2PA/C2PAData.swift`](Sources/SwiftExif/C2PA/C2PAData.swift),
  [`Sources/SwiftExif/Video/BRAWFrameReader.swift`](Sources/SwiftExif/Video/BRAWFrameReader.swift),
  [`Sources/SwiftExif/Video/RTMDReader.swift`](Sources/SwiftExif/Video/RTMDReader.swift))

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
  [`Tests/SwiftExifTests/Binary/ISOBMFFBoxTests.swift`](Tests/SwiftExifTests/Binary/ISOBMFFBoxTests.swift)
  confirming that legitimate descent into `moov → udta → Exif` still
  resolves while a fake `Exif` hidden inside `mdat` is correctly
  ignored.
  ([`Sources/SwiftExif/Binary/ISOBMFFMetadata.swift`](Sources/SwiftExif/Binary/ISOBMFFMetadata.swift))

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
  ([`Sources/SwiftExif/Video/MP4VisualSampleEntry.swift`](Sources/SwiftExif/Video/MP4VisualSampleEntry.swift),
  [`Sources/SwiftExif/Video/MP4Parser.swift`](Sources/SwiftExif/Video/MP4Parser.swift))

### Security

- **GPMF recursive container range clamped to actual buffer length.** An
  attacker-declared `sampleSize × sampleCount` in a container KLV header
  could exceed the underlying buffer, and the recursive parse passed that
  unclamped upper bound straight through. The inner loop's
  `off + 8 <= range.upperBound` guard would then read past `data.endIndex`
  and trap on `Data` subscript bounds. The recursive walker now clamps the
  declared range to the buffer length before recursing. Locked in by a new
  malformed-GPMF regression fixture in
  [`Tests/SwiftExifTests/Video/Phase25GPMFTests.swift`](Tests/SwiftExifTests/Video/Phase25GPMFTests.swift).
  ([`Sources/SwiftExif/Video/GPMFReader.swift`](Sources/SwiftExif/Video/GPMFReader.swift))

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
  [`Tests/SwiftExifTests/Video/Phase25GPMFTests.swift`](Tests/SwiftExifTests/Video/Phase25GPMFTests.swift).
  ([`Sources/SwiftExif/Video/GPMFReader.swift`](Sources/SwiftExif/Video/GPMFReader.swift))

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
  ([`Sources/SwiftExif/API/ImageMetadata.swift`](Sources/SwiftExif/API/ImageMetadata.swift),
  [`Sources/SwiftExif/API/MetadataRenamer.swift`](Sources/SwiftExif/API/MetadataRenamer.swift))

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
  ([`Sources/SwiftExif/Video/MPEGBitstream.swift`](Sources/SwiftExif/Video/MPEGBitstream.swift),
  [`Sources/SwiftExif/API/VideoStream.swift`](Sources/SwiftExif/API/VideoStream.swift))

- **HDR static metadata on HEIF / AVIF stills** — `mdcv` and `clli` properties
  inside the `meta → iprp → ipco` hierarchy (iPhone Pro HDR HEIC, AOM HDR AVIF
  reference encoder) are now parsed via a new
  `ISOBMFFMetadata.extractHDRMetadata` that reuses the existing
  `MP4Parser.parseMDCVBox` / `parseCLLIBox` decoders. Exposed as
  `ImageMetadata.hdr` (typed as the same shared `HDRMetadata` used by the
  video side) and as `HDR:MasteringDisplay*` / `HDR:MaxCLL` / `HDR:MaxFALL`
  keys in the flat image exporter.
  ([`Sources/SwiftExif/Binary/ISOBMFFMetadata.swift`](Sources/SwiftExif/Binary/ISOBMFFMetadata.swift),
  [`Sources/SwiftExif/API/ImageMetadata.swift`](Sources/SwiftExif/API/ImageMetadata.swift))

- **Matroska HDR static metadata** — `MaxCLL` (0x55BC), `MaxFALL` (0x55BD), and
  the `MasteringMetadata` (0x55D0) element group inside the `Colour` master are
  now parsed in `MatroskaReader` and surfaced through the existing
  `VideoStream.hdr` (`HDRMasteringDisplay` / `HDRContentLightLevel`). This
  matches the MP4 `mdcv`/`clli` and HEVC SEI paths so MKV/WebM callers see the
  same shape regardless of container. Matroska stores chromaticities and
  luminance as IEEE floats in CIE 1931 xy units and cd/m² respectively, so no
  scaling is needed (unlike MP4's `mdcv` box which uses fixed-point u16/u32).
  ([`Sources/SwiftExif/Video/MatroskaReader.swift`](Sources/SwiftExif/Video/MatroskaReader.swift))

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
  ([`Sources/SwiftExif/Video/MPEGBitstream.swift`](Sources/SwiftExif/Video/MPEGBitstream.swift),
  [`Sources/SwiftExif/Video/MP4VisualSampleEntry.swift`](Sources/SwiftExif/Video/MP4VisualSampleEntry.swift))

- **`MasteringDisplay*` / `MaxCLL` / `MaxFALL` keys exposed via the default
  `VideoMetadataExporter` dictionary** — until now, the flat `read` output
  only included `ColorPrimaries` / `TransferCharacteristics` etc. and
  consumers had to opt into `--streams` (or read `VideoStream.hdr` from the
  Swift API) to see the HDR side data. The top-level video dictionary now
  reports the same mastering-display chromaticities, luminance bounds, MaxCLL,
  MaxFALL, and Dolby Vision summary that the per-stream report carries.
  ([`Sources/SwiftExif/API/VideoMetadataExporter.swift`](Sources/SwiftExif/API/VideoMetadataExporter.swift))

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
  ([`Sources/SwiftExif/Video/MatroskaReader.swift`](Sources/SwiftExif/Video/MatroskaReader.swift))

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
  [`Tests/SwiftExifTests/Video/MPEGReaderTests.swift`](Tests/SwiftExifTests/Video/MPEGReaderTests.swift)
  asserting BT.2020 / SMPTE 2084 / BT.2020-NCL / topleft chroma — matching
  what ffprobe reports for the same file.
  ([`Sources/SwiftExif/Video/MPEGBitstream.swift`](Sources/SwiftExif/Video/MPEGBitstream.swift))

- **HEVC SPS `short_term_ref_pic_set()` bailed out on
  `inter_ref_pic_set_prediction_flag = 1`** — the loop used `return f` to abort
  rather than skip past the inter-RPS bits, dropping VUI for every SPS that
  uses inter-RPS prediction (common in Blu-ray HEVC tail-of-list sets). The
  replacement tracks `NumDeltaPocs[stRpsIdx]` for each parsed set and reads
  the correct number of `used_by_curr_pic_flag` / `use_delta_flag` pairs per
  spec §7.4.8.
  ([`Sources/SwiftExif/Video/MPEGBitstream.swift`](Sources/SwiftExif/Video/MPEGBitstream.swift))

- **HEVC SPS long-term reference pic POC LSB read used a hardcoded 4-bit
  width** — `lt_ref_pic_poc_lsb_sps[i]` is `log2_max_pic_order_cnt_lsb_minus4
  + 4` bits wide (typically 8 for Blu-ray). Any SPS with
  `long_term_ref_pics_present_flag = 1` and `log2_max > 0` would desync the
  cursor before reaching VUI. Fix: save `log2_max_pic_order_cnt_lsb_minus4`
  earlier in the SPS and use it for the long-term POC LSB read.
  ([`Sources/SwiftExif/Video/MPEGBitstream.swift`](Sources/SwiftExif/Video/MPEGBitstream.swift))

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
  [`Tests/SwiftExifTests/XMP/XMPReaderTests.swift`](Tests/SwiftExifTests/XMP/XMPReaderTests.swift).

### Changed

- **`MetadataError` now conforms to `LocalizedError`** — `errorDescription`
  surfaces the same `.description` string the type already produces, so
  errors bridged to `NSError` no longer render as
  `"(SwiftExif.MetadataError error N.)"`. Additive on both Darwin and
  swift-corelibs-foundation. ([`Sources/SwiftExif/API/MetadataError.swift`](Sources/SwiftExif/API/MetadataError.swift))

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
  [`MXFReader`](Sources/SwiftExif/Video/MXFReader.swift) and
  [`NRTXMLParser`](Sources/SwiftExif/Video/NRTXMLParser.swift) — no new
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
  [`Sources/SwiftExif/Video/BRAWFrameReader.swift`](Sources/SwiftExif/Video/BRAWFrameReader.swift)
  and [`Sources/CLI/BRAWFramesCommand.swift`](Sources/CLI/BRAWFramesCommand.swift).
  Reuses `MP4Parser`'s stbl walkers (`stcoOffsets` / `co64Offsets` /
  `sampleFileOffsets` / `sttsSampleStartTicks` / `stszSampleSizes` /
  `stscSamplesPerChunk`) — all promoted from `private` to `internal`.
  `parseBRAWFirstFrameAttributes` was refactored to delegate to a
  shared `decodeBRAWFrameHeader(_:)` so the slate path (frame 0 only)
  and the new full-walk path can't drift apart.

  Coverage: five new tests in
  [`Tests/SwiftExifTests/Video/BRAWFrameReaderTests.swift`](Tests/SwiftExifTests/Video/BRAWFrameReaderTests.swift)
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
  [Tests/SwiftExifTests/Video/MP4ParserTests.swift](Tests/SwiftExifTests/Video/MP4ParserTests.swift):
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
  SPS fixture added under `Tests/SwiftExifTests/Video/MPEGReaderTests.swift`.

- **SMPTE ST 377-4 MCA audio labels for MXF** — multichannel audio labeling
  per SMPTE ST 377-4 is now decoded out of MXF audio descriptors. New
  `MCAAudioLabeling`, `MCALabelsRenderer`, and `MXFMCAReader` types in
  `Sources/SwiftExif/Video/`, surfaced through `VideoStream` /
  `VideoMetadata` and the JSON exporter. New CLI subcommand
  `swift-exif mxf-labels` emits a bmx-compatible `labels.txt` round-trip
  for production audio workflows. Covered by
  [Tests/SwiftExifTests/Video/MXFMCALabelsTests.swift](Tests/SwiftExifTests/Video/MXFMCALabelsTests.swift)
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
  MakerNote implementations under `Sources/SwiftExif/MakerNote/`, with
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
  [Tests/SwiftExifTests/GIF/GIFParserTests.swift](Tests/SwiftExifTests/GIF/GIFParserTests.swift)
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
- CLI test harness under `Tests/SwiftExifCLITests` (gated behind
  `SWIFT_EXIF_RUN_CLI_TESTS=1`).
- Documented Homebrew CLI install path in README.

### Changed

- PCM audio bitrate computed exactly as `sample_rate × channels × bit_depth`
  (avoids rounding noise from stsz-over-duration).
- `format_long_name` returns `"QuickTime / MOV"` for all ISOBMFF brands
  (isom / mp42 / qt / M4V / …) to match ffprobe.

[1.8.2]: https://github.com/aagedal/SwiftExif/compare/1.8.1...1.8.2
[1.8.1]: https://github.com/aagedal/SwiftExif/compare/1.8.0...1.8.1
[1.8.0]: https://github.com/aagedal/SwiftExif/compare/1.7.0...1.8.0
[1.7.0]: https://github.com/aagedal/SwiftExif/compare/1.6.0...1.7.0
[1.6.0]: https://github.com/aagedal/SwiftExif/compare/1.5.1...1.6.0
[1.5.1]: https://github.com/aagedal/SwiftExif/compare/1.5.0...1.5.1
[1.5.0]: https://github.com/aagedal/SwiftExif/compare/1.4.0...1.5.0
[1.4.0]: https://github.com/aagedal/SwiftExif/compare/1.3.1...1.4.0
[1.3.1]: https://github.com/aagedal/SwiftExif/compare/1.3.0...1.3.1
[1.3.0]: https://github.com/aagedal/SwiftExif/compare/1.2.0...1.3.0
[1.2.0]: https://github.com/aagedal/SwiftExif/compare/1.1.0...1.2.0
