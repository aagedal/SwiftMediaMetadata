# Changelog

All notable changes to swift-exif (CLI) and the SwiftExif library.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers follow [Semantic Versioning](https://semver.org/) and track
the CLI; the library target follows the same numbering.

## [1.3.1] — 2026-04-23

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

[1.3.0]: https://github.com/aagedal/SwiftExif/compare/1.2.0...1.3.0
[1.2.0]: https://github.com/aagedal/SwiftExif/compare/1.1.0...1.2.0
