# Changelog

All notable changes to SwiftExif. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased] — 2026-04-21

Changes since `6b18914` (initial subtitle-detection drop). The theme is bringing video-metadata output up to full `ffprobe -show_streams` parity and making Linux a first-class target.

### Added

**ffprobe-compatible stream fields** (MP4/MOV/M4V, MXF, MKV/WebM, AVI, MPEG-PS/TS)

- `VideoMetadata.formatLongName` — human-readable container name (`"QuickTime / MOV"`, `"MP4 (MPEG-4 Part 14)"`, `"Matroska"`, …).
- `VideoMetadata.fileSize` — file size in bytes.
- `VideoMetadata.timecode` — clip start timecode `HH:MM:SS:FF` (or `HH:MM:SS;FF` for drop-frame), decoded from QuickTime `tmcd` tracks by walking `stco`/`co64` into `mdat` and applying SMPTE 12M drop-frame arithmetic.
- `VideoStream.profile` — codec profile (`"Main"`, `"Main 10"`, `"High"`, `"Main 4:4:4 12"`, `"Professional"`, …) decoded from `hvcC` / `av1C` / `avcC` boxes in MP4 and from Matroska `CodecPrivate` (same bytes).
- `VideoStream.pixelFormat` — ffprobe-style `pix_fmt` strings (`yuv420p`, `yuv420p10le`, `yuvj420p`, `yuv444p12le`, `gray10le`) derived from codec + chroma + bit depth + color range via a new `PixelFormatDerivation` helper.
- `VideoStream.avgFrameRate` / `rFrameRate` — ffprobe's `avg_frame_rate` / `r_frame_rate` pair.
- `VideoStream.chromaLocation` — `"left"`, `"center"`, `"topleft"`, `"top"`, `"bottomleft"`, `"bottom"`, sourced from Matroska `ChromaSitingHorz` / `ChromaSitingVert`.
- `VideoStream.timecode` / `VideoStream.isAttachedPic` — per-stream timecode and cover-art disposition flag.
- `AudioStream.profile` — codec profile (`"LC"`, `"HE-AAC"`, …).
- `AudioStream.isDefault` — default-track flag when the container signals one.

**Matroska / WebM**

- `CodecPrivate` (0x63A2) now decoded for HEVC / AV1 / AVC tracks so profile and bit depth surface even when the `Video` master doesn't carry them (e.g. 10-bit HEVC PQ remuxes).
- `BitsPerChannel` (0x55B2), `ChromaSitingHorz` (0x55B7), `ChromaSitingVert` (0x55B8) parsed.
- Segment-level `COMMENT` / `COMMENTS` / `DESCRIPTION` / `TITLE` / `ARTIST` SimpleTags lifted into `VideoMetadata.comment` / `title` / `artist`.
- Per-track `NUMBER_OF_FRAMES` SimpleTag surfaced as `VideoStream.frameCount`.
- Per-track `BPS` SimpleTags now populate `VideoStream.bitRate` / `AudioStream.bitRate` — previously nil on all MKV/WebM streams because FFmpeg and mkvtoolnix store bit rate only in the `Tags` block, not in `TrackEntry`.
- `VideoStream.title` / `AudioStream.title` populated from the EBML `Name` element (previously only subtitles surfaced the track name, even though the spec makes `Name` valid on any `TrackEntry`).

**MPEG-TS**

- Per-stream bit rate extracted from `maximum_bitrate_descriptor` (tag 0x0E) in the PMT, so AAC, AC-3, MP3, E-AC-3, H.264, H.265 now expose `bitRate` instead of always reporting nil.
- DVB subtitle `subtitling_type` (descriptor 0x59) and `teletext_type` (0x56) parsed to set `SubtitleStream.isHearingImpaired` for hard-of-hearing and sign-language variants.

**AVI**

- Subtitle tracks from `txts` streams (DXSB / UTF8, …) now surfaced via `SubtitleStream` — previously silently dropped.
- Audio bit rate extracted from `WAVEFORMATEX.nAvgBytesPerSec` (was present in the bytes we already parsed but not read).

**MP4 / MOV**

- Subtitle disposition flags (`isDefault`, `isForced`, `isHearingImpaired`) decoded from `trak.udta.kind` against the DASH Role scheme (`urn:mpeg:dash:role:2011`) and from `tx3g` `displayFlags` per 3GPP TS 26.245 §5.16. TV-Anytime AudioPurpose code 4 also maps to SDH.

**CLI**

- `swift-exif read --streams` emits per-stream rows (one per video / audio / subtitle track) in ffprobe style alongside the flat summary.
- `isSupportedFile` now covers MKV, WebM, AVI, MPEG-PS/TS, M2TS, MXF, Ogg, Opus, OGA — directory walks pick them up.

**Linux / cross-compilation**

- Static musl Linux binaries for x86_64 and aarch64, produced by `Scripts/build-release.sh`. UPX-compressed to ~23–25 MB.
- `#if canImport(FoundationXML)` guards around `XMLParser` / `XMLParserDelegate` in `XMPReader`, `GPXParser`, `NRTXMLParser`.
- In-tree `ZlibInflate` over a new `CZlib` systemLibrary module replaces Apple-only `NSData.compressed(using:.zlib)` / `decompressed(using:.zlib)` on PNG IDAT, iCCP ICC, and PDF FlateDecode paths.
- Pure-Swift MD5 + SHA-256 (`PureCrypto.swift`) swaps in for `CryptoKit` on non-Apple platforms, byte-verified against `sha256sum` / `md5`.
- `Date().timeIntervalSinceReferenceDate` replaces `CFAbsoluteTimeGetCurrent()` in the Benchmark target.

**Documentation**

- README gains a container-level facts table, per-stream tables for video / audio / subtitle, format-specific highlights for each container, and a worked JSON example for an iPhone HEVC HLG clip updated with the new fields.
- Exporter emits `FormatLongName`, `FileSize`, `Timecode`, `VideoProfile`, `AudioProfile`, `AvgFrameRate`, `RFrameRate`, `ChromaLocation`, `PixelFormat`, plus the existing subtitle disposition-flag arrays.

### Fixed

- MPEG-TS video publish loop wrote `info.bitRate` onto `metadata.bitRate` but forgot to set `stream.bitRate`; fixed and wired through to the audio publish loop as well.

### Changed

- macOS universal (`lipo`) build step dropped — native arm64 and x86_64 are distributed separately to halve download size.
- Linux builds use `-Xswiftc -Onone`; the open-source swift-6.3.1 musl cross-compiler hangs indefinitely under whole-module-optimization on the 78k-LOC module. Native macOS builds are unaffected.

[Unreleased]: https://github.com/aagedal/SwiftExif/compare/6b18914...HEAD
