# Changelog

All notable changes to swift-exif (CLI) and the SwiftExif library.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers follow [Semantic Versioning](https://semver.org/) and track
the CLI; the library target follows the same numbering.

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

[1.5.0]: https://github.com/aagedal/SwiftExif/compare/1.4.0...1.5.0
[1.4.0]: https://github.com/aagedal/SwiftExif/compare/1.3.1...1.4.0
[1.3.1]: https://github.com/aagedal/SwiftExif/compare/1.3.0...1.3.1
[1.3.0]: https://github.com/aagedal/SwiftExif/compare/1.2.0...1.3.0
[1.2.0]: https://github.com/aagedal/SwiftExif/compare/1.1.0...1.2.0
