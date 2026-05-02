# SwiftExif

A native Swift library for reading and writing image and video metadata — Exif, IPTC (IIM), XMP, C2PA, MakerNotes, and ICC profiles — with no external dependencies.

## Supported Formats

| Format | Read | Write | Metadata Types |
|--------|------|-------|----------------|
| JPEG | Yes | Yes | Exif, IPTC, XMP, C2PA, ICC |
| TIFF | Yes | Yes | Exif, IPTC, XMP, C2PA, ICC |
| RAW (DNG, CR2, CR3, NEF, NRW, ARW, RAF, RW2, ORF, PEF, SRW, .raw, IIQ, 3FR, FFF, X3F, MRW) | Yes | Yes | Exif, IPTC, XMP, MakerNotes, ICC |
| JPEG XL (container) | Yes | Yes | Exif, XMP, C2PA, ICC |
| PNG | Yes | Yes | Exif, XMP, C2PA, ICC |
| AVIF | Yes | Yes | Exif, XMP, C2PA, ICC |
| HEIF / HEIC | Yes | Yes | Exif, XMP, C2PA, ICC |
| WebP | Yes | Yes | Exif, XMP, C2PA, ICC |
| GIF | Yes | — | XMP, C2PA |
| PDF | Yes | — | XMP, C2PA, document metadata |
| PSD (Photoshop) | Yes | Yes | Exif, IPTC, XMP, ICC |
| MP4 / MOV / M4V | Yes | — | Exif, XMP, GPS, C2PA, Sony NRT camera metadata, full stream info (codec, profile, fps, field order, bit depth, chroma subsampling, pixel format, color primaries/transfer/matrix/range, pixel aspect ratio, bit rate) + audio (codec, sample rate, channels, channel layout, bit depth, bit rate) + subtitle tracks (tx3g, WebVTT, TTML, CEA-608/708) with language, QuickTime `tmcd` timecode |
| Blackmagic RAW (.braw) | Yes | — | Container metadata via QuickTime layout (no `ftyp`, tail-placed `moov`): resolution, project frame rate, audio, timecode, plus the `moov.meta` slate — camera make/model, firmware, viewing gamma/gamut, color science, compression ratio, shutter type, sensor capture FPS (off-speed), production slate (clip number / scene / take / reel / camera / environment / day-night), sensor area, crop / safe-area rectangles, LUT used, post-3DLUT mode, frameguide aspect ratio, gamut compression. Per-frame interpretation attributes (white point, tint, absolute ISO) live in proprietary `bfdn`/`ctrn` boxes and remain unparsed |
| RED RAW (.R3D) | Yes | — | Clip-header metadata from RED's own length-prefixed `RED2`/`RED1` atom: resolution (from `rdi`), audio sample rate (from `rda`), original capture frame rate, plus the TLV slate — camera brain + sensor, body serial, lens model, firmware, ISO, color temperature (Kelvin), crop area (`WxH+X+Y`), record/playback timecodes, reel + take, video format ("8K 16:9"), quality preset, storage media + serial + format date/time, original camera filename, focus distance. Tag IDs match ExifTool's `Image::ExifTool::Red` table |
| Nikon RAW Video (N-RAW) | Yes | — | Detected by `ftyp niko` brand + `NR3D` codec FourCC. Nikon Z8/Z9 ship N-RAW with a `.R3D` extension as part of the post-acquisition "RED RAW" branding, but the bitstream is wholly unrelated to RED's REDCODE — promoted to `format = .nikonRaw` so callers can disambiguate. All standard MP4 metadata (resolution, timecode, audio, color) reads through the QuickTime path |
| MXF (SMPTE 377) | Yes | — | C2PA, Sony NonRealTimeMeta (RDD-18), picture/sound essence descriptors (resolution, frame rate, scan type, chroma, color) |
| Matroska (.mkv) | Yes | — | Stream info (codec, profile, fps, dimensions, bit depth, chroma, chroma location, color, pixel format) decoded from both `Tracks` and `CodecPrivate` (hvcC/av1C/avcC), Segment-level `COMMENT`/`DESCRIPTION` tags, audio tracks, subtitle tracks (SRT, ASS/SSA, WebVTT, PGS, VobSub) with language + default/forced/SDH flags |
| WebM (.webm) | Yes | — | Stream info (VP8/VP9/AV1) + audio (Vorbis/Opus) + subtitle tracks |
| AVI (RIFF) | Yes | — | Stream info (codec, fps, dimensions, bit depth) + audio (codec, sample rate, channels), INFO tags |
| MPEG-PS / MPEG-TS / M2TS | Yes | — | Sequence-header stream facts (resolution, fps, aspect, bit rate), PMT elementary-stream inventory (DVB subtitles / teletext / PGS with language), M2TS (Blu-ray BDAV, 192-byte packets) auto-detected |
| MP3 (ID3v1 / ID3v2) | Yes | Yes | Tags + codec, sample rate, channels, bit rate, duration; ID3v2 frame detail (TXXX/WXXX/PRIV/GEOB/CHAP/CTOC) |
| FLAC | Yes | Yes | Tags + sample rate, channels, bit depth, duration; SeekTable + CueSheet |
| M4A | Yes | Yes | Tags + codec, sample rate, channels, bit depth, channel layout, bit rate, duration |
| Ogg Opus (.opus) | Yes | — | Vorbis comments + channels, sample rate, channel layout, duration |
| Ogg Vorbis (.ogg / .oga) | Yes | — | Vorbis comments + channels, sample rate, bit rate, duration |
| WAV / BWF (RIFF) | Yes | Yes | LIST/INFO tags, Broadcast WAVE `bext` (v0/v1/v2), iXML, C2PA, sample rate, channels, bit depth |
| AIFF / AIFC | Yes | Yes | NAME/AUTH/(c)/ANNO/COMT chunks, COMM 80-bit sample rate, channels, bit depth |
| XMP sidecar (.xmp) | Yes | Yes | XMP |
| C2PA sidecar (.c2pa) | Yes | — | External JUMBF manifest store next to the asset |
| AAE sidecar (Apple Photos) | Yes | — | iPhone/iPad edit-decision sidecar |
| Sony NRT sidecar (.XML) | Yes | — | Camera metadata auto-probed next to MP4/MXF |

## Requirements

- Swift 6.0+
- macOS 13+ / iOS 16+

## Installation

### CLI (Homebrew)

```sh
brew tap aagedal/tap
brew install swift-exif
```

### Swift Package

Add SwiftExif to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/SwiftExif.git", from: "0.1.0"),
]
```

Then add it as a dependency to your target:

```swift
.target(name: "YourApp", dependencies: ["SwiftExif"]),
```

## Usage

### Reading Metadata

```swift
import SwiftExif

// From a file URL
let metadata = try readMetadata(from: imageURL)

// From data in memory
let metadata = try readMetadata(from: imageData)
```

### Accessing IPTC Fields

```swift
let headline = metadata.iptc.value(for: .headline)
let keywords = metadata.iptc.values(for: .keywords)
let caption = metadata.iptc.value(for: .captionAbstract)
```

### Accessing Exif Fields

```swift
if let exif = metadata.exif {
    let camera = exif.value(for: .make)
    let model = exif.value(for: .model)
}
```

### Writing Metadata

Works for all supported image formats (JPEG, TIFF, RAW, JPEG XL, PNG, AVIF, HEIF, WebP):

```swift
var metadata = try readMetadata(from: imageURL)

metadata.iptc.setValue("Breaking news photo", for: .headline)
metadata.iptc.setValue("Jane Doe", for: .byline)
metadata.iptc.setValues(["news", "politics"], for: .keywords)

try metadata.write(to: outputURL)
```

### XMP Sidecar Files

Read and write `.xmp` sidecar files alongside image files:

```swift
// Write XMP sidecar for a RAW file
var metadata = try readMetadata(from: rawFileURL)
metadata.syncIPTCToXMP()
try metadata.writeSidecar(for: rawFileURL) // creates IMG_001.xmp

// Read XMP sidecar
let xmp = try readXMPSidecar(for: rawFileURL)
print(xmp.headline)
```

### IPTC / XMP Sync

```swift
// Copy IPTC values into XMP
metadata.syncIPTCToXMP()

// Or the other way around
metadata.syncXMPToIPTC()
```

### Video Metadata

Read rich stream-level metadata from MP4, MOV, M4V, MXF, MKV, WebM, AVI, and
MPEG-PS/TS/M2TS files — enough to replace `ffprobe` in editorial and
media-pipeline tooling. Container essence (mdat / MXF KLV body / Matroska
clusters) is never fully materialised; parsers only touch the header
metadata, so reading a multi-gigabyte MXF or ProRes file is a sub-millisecond
operation on memory-mapped data.

```swift
let video = try VideoMetadata.read(from: videoURL)
```

Everything below is populated from the container header — no decoding,
no AVFoundation, no external dependencies.

#### Container-level facts

| Property | Type | Description |
|----------|------|-------------|
| `format` | `VideoFormat` | `.mp4`, `.mov`, `.m4v`, `.mxf`, `.mkv`, `.webm`, `.avi`, `.mpg` |
| `formatLongName` | `String?` | Human-readable container name (`"QuickTime / MOV"`, `"MP4 (MPEG-4 Part 14)"`, `"Matroska"`, `"WebM"`, …) — matches ffprobe `format_long_name` |
| `fileSize` | `Int64?` | File size in bytes |
| `duration` | `TimeInterval?` | Total playback duration in seconds |
| `creationDate` | `Date?` | Capture / mux time (ISOBMFF `mvhd`, Matroska `DateUTC`, etc.) |
| `modificationDate` | `Date?` | Last modification time |
| `bitRate` | `Int?` | Overall container bitrate in bits/second |
| `timecode` | `String?` | Clip start timecode `HH:MM:SS:FF` (or `HH:MM:SS;FF` for drop-frame) — the first source the container yields |
| `timecodes` | `[Timecode]` | Every timecode source the container carries, tagged with provenance — QuickTime `tmcd` track, `moov>udta ©TIM`, XMP `xmpDM:startTimeCode`/`altTimeCode`, MXF MaterialPackage vs FilePackage, Sony NRT LtcChangeTable. Mismatches trigger a `timecode mismatch:` entry in `warnings` |
| `chapters` | `[VideoChapter]` | Chapter markers ordered by start time — QuickTime `tref > chap` text tracks and Nero `udta > chpl` in MP4/MOV, `Chapters` master in Matroska / WebM |
| `title` / `artist` / `comment` | `String?` | QuickTime `©nam` / `©ART` / `©cmt`, Matroska Info/Title + Segment-level `COMMENT`/`DESCRIPTION`, RIFF INFO |
| `gpsLatitude` / `gpsLongitude` / `gpsAltitude` | `Double?` | QuickTime `©xyz` / ISO 6709 |
| `c2pa` | `C2PAData?` | Parsed C2PA manifest store (MP4/MOV uuid or top-level `jumb`, MXF SMPTE UL or Dark KLV) |
| `camera` | `CameraMetadata?` | Sony NonRealTimeMeta (RDD-18) from MXF header or sidecar XML |
| `xmp` | `XMPData?` | XMP packet embedded in uuid box or `xml ` meta |

#### Per-stream: video

`VideoMetadata.videoStreams: [VideoStream]` exposes one entry per video track,
plus convenience accessors that mirror the first video stream at the top level
(`videoWidth`, `videoHeight`, `videoCodec`, `frameRate`, `fieldOrder`,
`colorInfo`, `bitDepth`, `chromaSubsampling`, `pixelAspectRatio`,
`displayWidth`, `displayHeight`).

| `VideoStream` property | Description |
|------------------------|-------------|
| `index` | Track index within the container |
| `codec` | 4CC / ID — `"hvc1"`, `"av01"`, `"avc1"`, `"apch"`, `"V_VP9"`, `"V_MPEGH/ISO/HEVC"`, … |
| `codecName` | Human-readable — `"H.265 / HEVC"`, `"Apple ProRes"`, `"AV1"`, `"VP9"`, `"MPEG-2 Video"` |
| `profile` | Codec profile — `"Main"`, `"Main 10"`, `"High"`, `"Main 4:4:4 12"`, `"Professional"` — from `hvcC` / `av1C` / `avcC` or Matroska `CodecPrivate` |
| `width` / `height` | Coded luma dimensions |
| `displayWidth` / `displayHeight` | PAR-adjusted display dimensions (when advertised) |
| `pixelAspectRatio` | `(Int, Int)` — e.g. `(40, 33)` for anamorphic 1440×1080 |
| `bitDepth` | 8 / 10 / 12 from `hvcC` / `av1C` / CDCI / Matroska `BitsPerChannel` or `CodecPrivate` |
| `chromaSubsampling` | `"4:2:0"`, `"4:2:2"`, `"4:4:4"`, `"4:0:0"`, `"4:1:1"` |
| `chromaLocation` | `"left"`, `"center"`, `"topleft"`, `"top"`, `"bottomleft"`, `"bottom"` — matches ffprobe `chroma_location` |
| `pixelFormat` | ffprobe-style `pix_fmt` string — `"yuv420p"`, `"yuv420p10le"`, `"yuvj420p"`, `"yuv444p12le"`, `"gray10le"`, derived from codec + chroma + depth + range |
| `frameRate` | fps — from `stsz`/`stts` for ISOBMFF, Matroska `DefaultDuration`, MXF `SampleRate`, AVI `dwRate`/`dwScale`, MPEG-2 sequence header |
| `avgFrameRate` / `rFrameRate` | ffprobe-compatible pair — `avg_frame_rate` (average) and `r_frame_rate` (raw cadence) |
| `duration` | Per-track duration in seconds |
| `frameCount` | Container-advertised frame count (ISOBMFF `stsz`, AVI `dwLength`, Matroska `NUMBER_OF_FRAMES` tag) |
| `fieldOrder` | `.progressive`, `.topFieldFirst`, `.bottomFieldFirst`, `.mixed`, `.unknown` |
| `colorInfo` | `VideoColorInfo?` — primaries / transfer / matrix / range (H.273 codes) with readable `label` |
| `bitRate` | Per-stream bits/second (ISOBMFF `btrt`) |
| `timecode` | Per-stream timecode (when the track carries one) |
| `isAttachedPic` | `true` when the track is a cover-art / attached-picture track |

`VideoColorInfo.label` returns canonical names: `"bt709"`, `"bt601"`,
`"bt2020"`, `"bt2020-pq"` (HDR10 / SMPTE ST 2084), `"bt2020-hlg"` (Hybrid
Log-Gamma), … — the same vocabulary `ffprobe -show_streams` uses.

#### Timecodes (every source)

Broadcast workflows frequently carry the same timecode value in several
independent places — a QuickTime `tmcd` track plus an XMP `startTimeCode`
plus an MXF Material/File TimecodeComponent — and the three can disagree
after a partial round-trip. `VideoMetadata.timecodes` keeps each one with
its provenance rather than merging them silently:

```swift
for tc in video.timecodes {
    print(tc.source, tc.value, tc.frameRate ?? -1)
    // tc.source is .tmcdTrack, .quicktimeUdta, .xmpDM, .xmpDMAlt,
    // .mxfMaterialPackage, .mxfFilePackage, or .sonyNRT
}
if video.warnings.contains(where: { $0.hasPrefix("timecode mismatch:") }) {
    // two or more sources disagree — worth surfacing to the operator
}
```

The scalar `timecode` field stays in sync with the first recorded entry
for backward compatibility. `--streams` JSON output emits the full list at
`format.Timecodes` (array of `{ value, source, frameRate }`) plus per-stream
`Timecode` fields when the source is track-local.

#### Per-stream: audio

`VideoMetadata.audioStreams: [AudioStream]` plus top-level `audioCodec`,
`audioSampleRate`, `audioChannels`.

| `AudioStream` property | Description |
|------------------------|-------------|
| `codec` / `codecName` | `"mp4a"` / `"AAC"`, `"ac-3"` / `"Dolby Digital (AC-3)"`, `"A_OPUS"` / `"Opus"`, `"lpcm"` / `"Linear PCM"`, `"alac"` / `"ALAC"`, … |
| `profile` | Codec profile (`"LC"`, `"HE-AAC"`, `"HE-AACv2"`, …) where the container carries one |
| `sampleRate` | Hz |
| `channels` | Channel count |
| `channelLayout` | `"mono"`, `"stereo"`, `"stereo-headphones"`, `"5.1"`, `"7.1"`, … (from QuickTime `chan` box or synthesised from the channel count) |
| `bitDepth` | Bits per sample |
| `bitRate` | Bits/second (ISOBMFF `btrt` or MPEG-4 ES descriptor) |
| `duration` | Per-track duration |
| `language` | ISO 639-2/T code (`"eng"`, `"nor"`, `"swe"`, …) |
| `isDefault` | Default-track flag if the container signals one |

QuickTime Sound Description **V2** is handled correctly, so 24-bit LPCM and
Float64-sample-rate ProRes/APV audio tracks report accurate channels and
rate.

#### Per-stream: subtitles & closed captions

`VideoMetadata.subtitleStreams: [SubtitleStream]`:

```swift
for sub in video.subtitleStreams {
    print(sub.codecName)         // "SubRip (SRT)", "PGS (Blu-ray)", "3GPP Timed Text", "WebVTT"
    print(sub.language)          // "eng", "nor", "swe" — ISO 639-2/T
    print(sub.title)             // Matroska track name, when set
    print(sub.isDefault)         // Matroska FlagDefault
    print(sub.isForced)          // FlagForced — foreign-audio burn-in
    print(sub.isHearingImpaired) // SDH flag
}
```

Codec coverage:

- **MP4/MOV/M4V**: `tx3g` (3GPP Timed Text), `wvtt` (WebVTT), `stpp` (TTML),
  `c608` / `c708` (CEA-608/708 closed captions), `text` (QuickTime Text);
  handler types `subt`, `text`, `sbtl`, `clcp`.
- **Matroska / WebM**: `S_TEXT/UTF8` (SRT), `S_TEXT/ASS`, `S_TEXT/SSA`,
  `S_TEXT/WEBVTT`, `S_HDMV/PGS` (Blu-ray), `S_VOBSUB`, `S_HDMV/TEXTST`.
- **MPEG-TS**: DVB subtitles (stream type `0x06` + descriptor `0x59`),
  DVB teletext (descriptor `0x56`), Blu-ray PGS (stream type `0x82`).

#### Chapter markers

`VideoMetadata.chapters: [VideoChapter]` — start/end times in seconds from
presentation start, with optional title and language. Ordered by start time,
and re-indexed contiguously after hidden-atom suppression so `chapter.index`
always matches array position.

```swift
for ch in video.chapters {
    print(ch.index, ch.startTime, ch.endTime ?? -1,
          ch.title ?? "", ch.language ?? "")
    // duration is a computed property: endTime - startTime (or nil)
    if let d = ch.duration { print("lasts \(d)s") }
}
```

| `VideoChapter` property | Description |
|-------------------------|-------------|
| `index` | Position in the chapter list (0-based, contiguous) |
| `id` | Stable identifier where the container provides one (Matroska `ChapterUID`); nil for MP4 chap / chpl |
| `startTime` | Seconds from presentation start |
| `endTime` | Seconds from presentation start; nil when the source doesn't record one (Nero `chpl`, open-ended Matroska atoms) |
| `duration` | Computed `endTime − startTime`; nil when `endTime` is nil |
| `title` | Chapter title; UTF-8 |
| `language` | BCP-47 or ISO 639-2/T, when the container records one (Matroska `ChapLanguage` / `ChapLanguageBCP47`) |

Source coverage:

- **MP4 / MOV / M4V**: QuickTime text-track chapters — any trak's
  `tref > chap` points at a text/subt trak whose stts-timed UTF-8 samples
  carry the titles (DaVinci Resolve, Apple Compressor, iTunes, ffmpeg
  `-map_chapters`). Falls back to Nero `udta > chpl` (x264, ffmpeg,
  MP4Box) when no chap reference exists. The chap-referenced text track
  is filtered out of `subtitleStreams` to match ffprobe, which reclassifies
  those tracks as `codec_type=data` under `-select_streams s`.
- **Matroska / WebM**: top-level `Chapters` master — walks every
  `EditionEntry` + `ChapterAtom`, honouring `EditionFlagHidden` and
  `ChapterFlagHidden`; supports `ChapterDisplay > ChapString`, both
  `ChapLanguage` and the newer `ChapLanguageBCP47`.

#### Format-specific highlights

- **MP4 / MOV / M4V**: per-track `mdhd` timescale + language, visual sample
  entry walk (`fiel`, `pasp`, `colr` for `nclx`/`nclc`, `hvcC`, `av1C`,
  `avcC`, `btrt`) including codec profile extraction, QuickTime `chan`
  channel layouts, V0/V1/V2 Sound Description. QuickTime `tmcd` timecode
  tracks: frame counter read from `mdat` via `stco`/`co64`, formatted
  `HH:MM:SS:FF` with SMPTE 12M drop-frame arithmetic. Also: embedded XMP
  (uuid `BE7ACFCB-…`), GPS (`©xyz`), C2PA manifests, and Sony NRT sidecar
  auto-discovery.
- **Blackmagic RAW (`.braw`)**: ISOBMFF derivative with the legacy QuickTime
  layout — `wide` + `mdat` at the head, `moov` tail-placed, no `ftyp`.
  Standard boxes (`mvhd`, `tkhd`, `stsd`, `stts`, `mdhd`) yield duration,
  project frame rate (e.g. 24p), resolution, audio, and timecode. The
  Blackmagic slate is parsed out of `moov.meta` using QuickTime's
  non-FullBox `mdta` layout — a sniff at the box header disambiguates the
  ISOBMFF/iTunes FullBox shape from the QuickTime shape so existing MP4 /
  iTunes parsing stays untouched. The `mdta` decoder handles BRAW's typed
  payloads, including the BMD-specific type 71 (float32 BE pair) used for
  rectangle fields like `sensor_area_captured` and the BMD type 77
  (uint32) used for `braw_codec_bitrate`. Surfaces to `CameraMetadata`:
  - **Camera + lens** — make / model, firmware, lens model, color science
    generation, viewing gamma / gamut, shutter type, compression ratio,
    `analog_gain` and `_is_constant`, off-speed flag.
  - **Production slate** — clip number, scene, take, reel, camera number,
    operator, director, production name, environment, day/night, location,
    filters, frameguide aspect, anamorphic flag.
  - **Sensor / framing** — `sensor_area_captured`, `crop_origin` /
    `crop_size` / `safe_area`, `sensor_line_time` (rolling-shutter μs),
    `sensor_photosite_pitch_in_micrometres`, `rotation`, `time_lapse_interval`.
  - **Lens corrections + OIS** — `lens_shading_enable`,
    `lens_distortion_correction_enable`,
    `lens_chromatic_aberration_correction_enable`, `ois_enable`.
  - **Tone curve** — contrast, saturation, midpoint, highlights, shadows,
    black/white level, `video_black_level`, `highlight_recovery`,
    `gamut_compression_enable`.
  - **Embedded 3D LUT** — `post_3dlut_mode`, `_embedded_name`, `_embedded_title`,
    `_embedded_bmd_gamma`, `_embedded_size` (cube edge), and a
    `_embedded_data` size marker (the ~432 KB blob is not inlined).
  - **BRAW codec config** — `braw_codec_bfdn`, `braw_codec_ctrn`,
    `braw_codec_bver`, and `braw_codec_bitrate` are pulled from the BRAW
    sample entry's child boxes; works across the BRAW quality presets
    (`brhq` High Quality, `brst` Standard, `brlt` Light, …).
  - **Per-frame motion tracks** — `mebx` tracks declaring the
    `com.blackmagicdesign.motiondata.gyroscope` /
    `…accelerometer` namespaces are flagged with
    `has_gyroscope_motion_data` / `has_accelerometer_motion_data`. The
    per-frame vec3 samples themselves are not decoded.
  - **First-frame interpretation** — frame 0's `bmdf` header in mdat
    yields `shutter_angle` (`shtv` atom, UTF-8 padded — e.g. "180°"),
    `aperture` (`aptr` — e.g. "f2.7"), `focal_length` (`fcln` —
    e.g. "135mm"), `focus_distance` (`dsnc` — e.g. "2430mm"),
    `iso` (`isoe`), `white_balance_kelvin` (`wkel`), and
    `white_balance_tint` (`wtin`, signed int16). The per-frame header
    carries identical values across every frame in the clips we've
    tested, so frame 0 is sufficient for the clip-level default; we
    don't iterate over the rest. The four lens strings are skipped
    when empty (which the camera emits on bodies without electronic
    lens contacts). Other atoms in the same header (`srte`, `agpf`,
    `expo`, `shdp`, `dcp[ugrb]`, …) carry per-frame state we haven't
    yet mapped.

  Off-speed shoots populate `captureFps` distinct from `frameRate` — a 24p
  clip captured at 112 fps reports `frameRate=24` and `captureFps≈112`.

  **Per-frame export** — `swift-exif braw-frames <file.braw>` walks every
  frame's `bmdf` header (or every `mebx` IMU sample) and emits CSV for
  graphing. Three streams: `attributes` (default; one row per video
  frame with shutter / aperture / focal length / focus distance / ISO /
  WB Kelvin / tint), `gyroscope` (rad/s vec3 at ~1 kHz), and
  `accelerometer` (m/s² vec3, gravity observable on the up-axis).
  Numeric columns; opens directly in Excel / pandas / matplotlib /
  gnuplot. Public Swift API: `BRAWFrameReader.readAttributes(from:)`
  and `BRAWFrameReader.readMotionSamples(from:stream:)`.
- **RED RAW (`.R3D`)**: not ISOBMFF — RED uses its own length-prefixed
  container with a fixed 1202-byte `RED2` (or `RED1`, on older firmware)
  clip-header atom carrying every metadata field. The header packs three
  fixed-layout sub-atoms (`rdi` for image dimensions, `rda` for audio
  sample rate, two `rdx` markers) followed by a stream of TLV records.
  Each TLV is `[1-byte length][2-byte tag = class<<8 | id][value]`
  where the tag IDs match ExifTool's `Image::ExifTool::Red` table —
  `0x1006` SerialNumber, `0x101a` ReelNumber, `0x101b` Take, `0x1023`
  DateCreated, `0x1024` TimeCreated, `0x1025` FirmwareVersion,
  `0x1029` ReelTimecode, `0x102a` StorageType, `0x1056`
  OriginalFileName, `0x1070` LensModel, `0x1086` VideoFormat
  ("8K 16:9"), `0x10a0` Brain, `0x10a1` Sensor, `0x10be` Quality,
  `0x200d` ColorTemperature (float32 BE Kelvin), `0x2066`
  OriginalFrameRate (float32), `0x4037` CropArea (4× uint16
  origin/dims), `0x403b` ISO (uint16), `0x606c` FocusDistance
  (uint16 mm). Two non-ExifTool timecode strings (`0x10ad`,
  `0x10ae`) surface as additional `Timecode` entries tagged
  `.redR3D`. Records exceeding 64 bytes are skipped as a sanity
  cap (largest real TLV is the 28-byte original-filename string).
  `camera.deviceManufacturer` is set unconditionally to `"RED"`
  since the format doesn't include it as a TLV. Tested on KOMODO-X
  (RD4.15 firmware) and V-RAPTOR [X] (RD4.15) clips.
- **MXF (SMPTE 377-1)**: picture and sound essence descriptors parsed from
  header metadata — `StoredWidth`/`StoredHeight`, `DisplayWidth`/`DisplayHeight`,
  `FrameLayout` (scan type), `ComponentDepth`,
  `HorizontalSubsampling`/`VerticalSubsampling`, `SampleRate` (frame rate),
  `ContainerDuration`, colour ULs → H.273 codes. KLV essence is skipped by
  seek, so gigabyte files parse cheaply.
- **Matroska / WebM**: EBML/VINT walker over Segment `Info` + `Tracks` +
  `Tags`. Colour master element (primaries / transfer / matrix / range) +
  `ChromaSubsamplingHorz`/`Vert` + `ChromaSitingHorz`/`Vert` →
  `chroma_location`, `BitsPerChannel`, `DefaultDuration` → fps,
  `FlagInterlaced` + `FieldOrder`, subtitle `FlagDefault` / `FlagForced` /
  `FlagHearingImpaired`. `CodecPrivate` is decoded for HEVC / AV1 / AVC
  tracks (same layout as `hvcC` / `av1C` / `avcC`) to surface profile +
  bit depth even when the `Video` master doesn't. Segment-level
  `COMMENT` / `DESCRIPTION` / `TITLE` and per-track `BPS` /
  `NUMBER_OF_FRAMES` SimpleTags are surfaced as container / stream facts.
- **AVI**: RIFF/LIST walker, `avih` (width/height/microSecPerFrame) +
  `strl/strh/strf` (BITMAPINFOHEADER + WAVEFORMATEX), OpenDML `dmlh` for
  >4 GB frame counts, `INFO` tags (`INAM`/`IART`/`ICMT`).
- **MPEG-PS / MPEG-TS / M2TS**: MPEG-1/2 sequence header decode
  (resolution, fps, aspect ratio, bit rate), PAT → PMT walk for
  elementary-stream inventory, ES descriptor loop for language + subtitle
  type. M2TS (Blu-ray BDAV, 192-byte packets with `TP_extra_header`)
  auto-detected via magic-byte sniff.

#### Export

```swift
// Flat dictionary for CSV/table output
let dict = VideoMetadataExporter.buildDictionary(video)

// JSON string matching ffprobe's general shape
let json = VideoMetadataExporter.toJSONString(video)
```

The CLI surfaces all of the above:

```shell
$ swift-exif read --format json path/to/clip.mov
```

#### Example output

A 4K HEVC HLG clip straight out of an iPhone:

```json
{
  "FileFormat": "MOV",
  "FormatLongName": "QuickTime / MOV",
  "FileSize": 16309447,
  "VideoCodec": "hvc1",
  "VideoProfile": "Main 10",
  "VideoWidth": 3840,
  "VideoHeight": 2160,
  "FrameRate": 59.9568655643422,
  "AvgFrameRate": 59.9568655643422,
  "RFrameRate": 59.9568655643422,
  "BitDepth": 10,
  "ChromaSubsampling": "4:2:0",
  "PixelFormat": "yuv420p10le",
  "ColorSpace": "bt2020-hlg",
  "ColorPrimaries": 9,
  "TransferCharacteristics": 18,
  "MatrixCoefficients": 9,
  "Duration": 2.316666666666667,
  "AudioCodec": "mp4a",
  "AudioSampleRate": 48000,
  "AudioChannels": 2,
  "AudioChannelLayout": "stereo",
  "CreationDate": "2025-12-09T14:56:44Z"
}
```

A Blu-ray MKV remux with 31 PGS subtitle tracks and 14 audio streams
returns each track individually under `videoStreams` / `audioStreams` /
`subtitleStreams`, with language tags, flags, and codec IDs preserved.

### Audio Metadata

Standalone MP3, FLAC, M4A, Ogg Opus (.opus), Ogg Vorbis (.ogg/.oga),
RIFF WAV / Broadcast WAVE (.wav), and AIFF / AIFC (.aif / .aiff) files
expose codec, sample rate, channel count, channel layout, bit depth,
and bit rate alongside container-specific tags:

```swift
let audio = try AudioMetadata.read(from: mp3URL)
print(audio.codec, audio.codecName)  // "mp3", "MP3"
print(audio.sampleRate, audio.channels, audio.bitrate, audio.bitDepth)
print(audio.title, audio.artist, audio.album)
```

Format-specific detail:

- **MP3 (ID3v1 / ID3v2)**: full ID3v2 frame decode including `TXXX`
  user-defined text, `WXXX` user URL, `PRIV` private frames, `GEOB`
  general encapsulated objects, and `CHAP` / `CTOC` chapter/table-of-
  contents frames.
- **FLAC**: Vorbis comments plus `SEEKTABLE` (sample → byte offsets)
  and `CUESHEET` (track index points for CD-DA mastering).
- **WAV / BWF (RIFF)**: `LIST INFO` tags (`INAM`/`IART`/`ICMT`/`ICRD`/…),
  Broadcast WAVE `bext` v0 / v1 (UMID) / v2 (loudness fields), and
  iXML — read **and** write, with the `bext` chunk rewritten in place
  preserving the surrounding `data` / `LIST` chunks.
- **AIFF / AIFC**: `NAME` / `AUTH` / `(c) ` / `ANNO` / `COMT` chunks
  decoded from IFF, COMM 80-bit IEEE 754 sample-rate field handled
  natively — read and write.

#### Async video API

Convenience top-level functions parse on a detached task so callers can
`await` without blocking the main actor. Missing metadata returns `nil`
rather than throwing — reserve errors for I/O and hard parse failures.

```swift
import SwiftExif

// C2PA manifests embedded in MP4/MOV (same JUMBF path as AVIF/HEIF).
if let c2pa = try await readVideoC2PAMetadata(from: videoURL) {
    let claim = c2pa.activeManifest?.claim
    print(claim?.claimGenerator)             // "Adobe Premiere Pro 24.0"
    print(claim?.claimGeneratorInfo?.name)   // "Adobe Premiere Pro"
    for assertion in c2pa.activeManifest?.assertions ?? [] {
        print(assertion.label)               // "c2pa.actions", "c2pa.hash.data", …
    }
}

// Camera metadata — Sony NonRealTimeMeta (RDD-18) embedded or sidecar .XML,
// or Blackmagic RAW slate from `moov.meta`.
if let cam = try await readVideoCameraMetadata(from: videoURL) {
    print(cam.deviceManufacturer)    // "Sony" / "Blackmagic Design"
    print(cam.deviceModelName)       // "PXW-FX9" / "Pyxis 12K"
    print(cam.lensModelName)         // "Sony FE 24-70mm F2.8 GM"
    print(cam.captureFps)            // 23.98 (off-speed FPS for BRAW)
    print(cam.captureGammaEquation)  // "SLog3" / "Blackmagic Film Gen 5"
}

// Both in one pass (cheaper than calling the two above separately).
let video = try await readVideoMetadata(from: videoURL)
```

#### Sidecar auto-discovery

When reading `CLIP.MP4` or `CLIP.MXF`, SwiftExif automatically probes for
a Sony NonRealTimeMeta sidecar (`CLIP.XML`, `CLIP.xml`, `CLIP.M01`) next
to the clip. If found, its parsed contents populate `camera`.

```swift
// Given: /path/CLIP.MXF next to /path/CLIP.XML
let video = try VideoMetadata.read(from: mxfURL)
video.camera?.deviceManufacturer   // pulled from the sidecar
```

### C2PA Content Provenance

Access embedded C2PA manifests for content authenticity. Coverage:
JPEG (APP11), TIFF (Exif sub-IFD or DNG private tag), PNG (caBX),
JPEG XL, AVIF, HEIF, WebP (C2PA RIFF chunk), GIF (Application
Extension), PDF (catalog `/Metadata`), MP4 / MOV (uuid or top-level
`jumb`), MXF (SMPTE UL or Dark KLV), Broadcast WAVE (`C2PA` LIST
chunk), and external `.c2pa` sidecars. Hash bindings and ECDSA
signatures are verified against the embedded certificate chain:

```swift
if let c2pa = metadata.c2pa {
    for manifest in c2pa.manifests {
        print(manifest.claim.claimGenerator)           // "SONY_CAMERA"
        print(manifest.claim.claimGeneratorInfo?.name) // "SONY_CAMERA"
        print(manifest.claim.title)                    // "20251212_TRA_MOV_0224.MP4"
        print(manifest.signature.algorithm)            // ES256
        print(manifest.signature.certificateChain.count)

        for assertion in manifest.assertions {
            print(assertion.label)   // "c2pa.actions.v2", "c2pa.hash.bmff.v3", …
            if case .actions(let actions) = assertion.content {
                for action in actions.actions {
                    print(action.action)              // "c2pa.created"
                    print(action.digitalSourceType)   // IPTC URL
                }
            }
        }
    }
}
```

The JSON exporter surfaces the same fields under `HasContentCredentials`,
`HasSignature`, `ClaimGenerator`, `ClaimGeneratorInfoName`, `ClaimTitle`,
`ManifestLabel`, `SignatureAlgorithm`, `SignatureCertificateCount`,
`Assertions`, `ActionsAction`, `ActionsDigitalSourceType`,
`ActionsSoftwareAgent` — matching the field set consumed by downstream
apps that previously shelled out to ExifTool.

Each assertion is decoded into a typed payload (`c2pa.actions(.v2)`,
`c2pa.hash.data` / `c2pa.hash.bmff(.v3)`, `c2pa.training-mining`,
`c2pa.thumbnail.*`, `stds.exif`, `stds.iptc`, `stds.schema-org.*`)
rather than left as opaque CBOR. Hash assertions are verified against
the asset bytes; signature assertions are verified with ECDSA over the
embedded certificate chain — failures are surfaced via
`c2pa.verification` rather than thrown.

### MakerNotes

Camera-specific manufacturer metadata for Canon, Nikon, Sony, Fujifilm,
Olympus, Panasonic, Apple (iPhone / iPad), DJI, Samsung, Pentax, Leica,
and Sigma. Canon and Sony parsers extract array-tag depth (Canon
CameraSettings / ShotInfo / AFInfo2 / FileInfo / SensorInfo, Sony
0x01xx / 0x2xxx / 0xB0xx blocks) — including a curated FE-mount lens
ID table for Sony — alongside basic identifiers (serial, firmware,
lens model). Apple iPhone surfaces Live Photo `ContentIdentifier`,
HDR image type, burst UUID, and acceleration vector.

```swift
if let makerNote = metadata.exif?.makerNote {
    print(makerNote.manufacturer)  // .canon, .nikon, .sony, .apple, .dji, …
    for (name, value) in makerNote.tags {
        print("\(name): \(value)")
    }
}
```

### ICC Color Profiles

```swift
// Read
if let icc = metadata.iccProfile {
    print(icc.colorSpace)               // "RGB ", "CMYK", etc.
    print(icc.profileDescription)       // "sRGB IEC61966-2.1"
}

// Copy ICC profile to another image
var dest = try readMetadata(from: destURL)
dest.iccProfile = metadata.iccProfile
try dest.write(to: destURL)
```

### Composite Tags

Derived values calculated from raw Exif data:

```swift
let composites = CompositeTagCalculator.calculate(from: metadata.exif!)

composites["Megapixels"]     // 24.2
composites["LightValue"]     // 10.5
composites["FieldOfView"]    // 63.7
composites["LensID"]         // "EF 24-70mm f/2.8L II USM"
composites["GPSPosition"]    // "59.9139 N, 10.7522 E"
```

### GPX Geotagging

Apply GPS coordinates from a GPX track to images based on capture time:

```swift
let track = try GPXParser.parse(from: gpxFileURL)

var metadata = try readMetadata(from: imageURL)
let matched = metadata.applyGPX(track, maxOffset: 60)
if matched {
    try metadata.write(to: imageURL)
}
```

### Reverse Geocoding

Convert GPS coordinates to city, region, and country names **offline** —
no network access, no API key. Uses an embedded GeoNames database
(~33,500 cities with population ≥ 15,000) behind a k-d tree for
O(log n) nearest-neighbor lookup.

```swift
// Standalone lookup
let geocoder = ReverseGeocoder.shared
if let location = geocoder.lookup(latitude: 59.9139, longitude: 10.7522) {
    print(location.city)        // "Oslo"
    print(location.region)      // "Oslo"
    print(location.country)     // "Norway"
    print(location.countryCode) // "NOR" (ISO 3166-1 alpha-3)
    print(location.timezone)    // "Europe/Oslo"
    print(location.population)  // 580000
    print(location.distance)    // 0.3 (km from query point)
}

// Nearest N cities — useful for disambiguating near borders
let nearby = geocoder.nearest(latitude: 59.9139, longitude: 10.7522, count: 5)
```

Populate IPTC/XMP location fields directly from an image's embedded GPS:

```swift
var metadata = try readMetadata(from: imageURL)

// Fills IPTC City / Province-State / Country-Name / Country-PrimaryLocationCode
// and the matching XMP fields. Skips fields that are already set unless
// overwrite: true is passed.
if let location = metadata.fillLocationFromGPS() {
    print("Matched \(location)")
    try metadata.write(to: imageURL)
}
```

Both APIs accept a `maxDistance:` parameter (km) to reject matches that
are too far away — defaults are 50 km for `lookup`, 100 km for `nearest`.

### Copy Metadata Between Files

```swift
var dest = try readMetadata(from: destURL)
let source = try readMetadata(from: sourceURL)

// Copy all metadata
dest.copyMetadata(from: source)

// Or selective groups
dest.copyMetadata(from: source, groups: [.exif, .iptc])

try dest.write(to: destURL)
```

### Metadata Diff

```swift
let a = try readMetadata(from: fileA)
let b = try readMetadata(from: fileB)

let diff = a.diff(against: b)
for change in diff.changes {
    print("\(change.type): \(change.key) — \(change.oldValue ?? "nil") → \(change.newValue ?? "nil")")
}
```

### Thumbnail Extraction

```swift
if let jpegData = metadata.extractThumbnail() {
    try jpegData.write(to: thumbnailURL)
}
```

### Metadata Stripping

```swift
var metadata = try readMetadata(from: imageURL)

metadata.stripAllMetadata()   // Remove everything
metadata.stripGPS()           // Remove GPS only
metadata.stripExif()          // Remove Exif only
metadata.stripIPTC()          // Remove IPTC only
metadata.stripXMP()           // Remove XMP only
metadata.stripC2PA()          // Remove C2PA only
metadata.stripICCProfile()    // Remove ICC profile only

try metadata.write(to: outputURL)
```

### Date Shifting

```swift
var metadata = try readMetadata(from: imageURL)
metadata.shiftDates(by: 3600)  // Shift all dates forward by 1 hour
try metadata.write(to: imageURL)
```

### Conditional Batch Processing

Process files that match specific conditions:

```swift
let condition: MetadataCondition = .and([
    .equals(field: "IPTC:City", value: "Oslo"),
    .greaterThan(field: "Exif:FocalLength", value: 50)
])

let result = try BatchProcessor.processDirectory(
    at: directoryURL,
    where: condition,
    recursive: true
) { metadata in
    metadata.iptc.setValue("© 2026 Agency", for: .copyrightNotice)
}
```

### File Renaming

Rename files using metadata-driven templates:

```swift
let renamer = MetadataRenamer(
    template: "%{DateTimeOriginal:yyyyMMdd}_%{IPTC:City}_%c",
    counterDigits: 3
)

// Preview before renaming
let preview = renamer.dryRun(files: imageURLs)
for (from, to) in preview {
    print("\(from.lastPathComponent) → \(to.lastPathComponent)")
}

// Perform rename
let result = renamer.rename(files: imageURLs)
print("\(result.renamed.count) files renamed")
```

### Export

```swift
// JSON
let json = MetadataExporter.toJSONString(metadata)

// Human-readable JSON with print conversions
let readable = MetadataExporter.toReadableJSON(metadata)

// XML
let xml = MetadataExporter.toXML(metadata)

// CSV (multiple files)
let csv = CSVExporter.toCSV(metadataArray, fields: ["IPTC:Headline", "Exif:Make"])
```

### Print Conversion

Convert raw numeric values to human-readable strings:

```swift
let readable = PrintConverter.buildReadableDictionary(metadata)
// "Orientation" → "Rotate 90 CW" (instead of 6)
// "ExposureTime" → "1/250" (instead of rational)
// "Flash" → "Fired, Return detected" (instead of 15)
```

### Batch Processing

```swift
let result = try BatchProcessor.processDirectory(at: directoryURL, recursive: true) { metadata in
    metadata.iptc.setValue("© 2026 Agency", for: .copyrightNotice)
}

print("\(result.succeeded) files updated, \(result.failed.count) errors")
```

## Architecture

```
Sources/SwiftExif/
├── API/            # Public API: ImageMetadata, BatchProcessor, FormatDetector,
│                   #   MetadataExporter, CSVExporter, PrintConverter,
│                   #   MetadataRenamer, CompositeTagCalculator
├── Binary/         # Low-level binary readers/writers, CRC32, ISO BMFF
├── Exif/           # Exif IFD parsing and writing
├── IPTC/           # IPTC IIM reader/writer (Records 1/2/3/6/7/8 + PLUS), Photoshop IRB
├── XMP/            # XMP reader/writer with namespace mapping
├── C2PA/           # C2PA manifest/claim/signature parsing + ECDSA verification
├── CBOR/           # CBOR decoder for C2PA payloads
├── MakerNote/      # Camera-specific MakerNote parsers (12 manufacturers)
├── GPX/            # GPX track parser and geotagging
├── Geolocation/    # Offline reverse geocoder (GeoNames + k-d tree)
├── ICC/            # ICC color profile reader (TRC, primaries, A2B/B2A LUTs, chad)
├── JPEG/           # JPEG segment parser and writer (incl. CIPA DC-007 MPF)
├── TIFF/           # TIFF/RAW file parser and writer
├── RAW/            # Camera RAW format support (DNG, CR2/CR3, NEF, ARW, RAF,
│                   #   RW2, ORF, PEF, IIQ, 3FR, FFF, X3F, MRW, …)
├── CR3/            # Canon CR3 (ISOBMFF) parser and writer
├── PNG/            # PNG chunk parser and writer
├── JPEGXL/         # JPEG XL box parser and writer
├── AVIF/           # AVIF (ISOBMFF) parser and writer
├── HEIF/           # HEIF/HEIC parser and writer with auxiliary image walk
├── WebP/           # WebP (RIFF container) parser and writer
├── GIF/            # GIF parser (XMP + C2PA Application Extension)
├── BMP/            # BMP / DIB header reader
├── SVG/            # SVG metadata reader
├── PDF/            # PDF document metadata + catalog `/Metadata` XMP
├── PSD/            # Photoshop document parser and writer
├── Apple/          # AAE sidecar parser (Apple Photos edit decisions)
├── Audio/          # MP3/FLAC/M4A/Ogg/WAV/AIFF tag and codec readers + writers
└── Video/          # MP4/MOV/M4V/MXF/MKV/WebM/AVI/MPEG-TS metadata parsers,
                    #   Sony NonRealTimeMeta (NRT / RDD-18) XML parser, GoPro GPMF
```

## Benchmark

Measured with `Sources/Benchmark/main.swift` (release build) against a 382 KB JPEG sample, writing 8 IPTC fields + 8 XMP fields, and reading all of IPTC/XMP/EXIF. C2PA and MP4 parse benchmarks use synthetic JUMBF manifest stores.

**Write / Read (100 files)**

| Operation | exiftool batch | exiftool sequential | SwiftExif sequential | SwiftExif batch |
|-----------|---------------:|--------------------:|---------------------:|----------------:|
| Write     | 18.0 ms/file   | 267.7 ms/file       | 8.2 ms/file          | **2.8 ms/file** |
| Read      | 22.6 ms/file   | —                   | 4.5 ms/file          | **2.8 ms/file** |

SwiftExif batch write is ~6× faster than exiftool batch and ~95× faster than exiftool sequential. Read is ~8× faster than exiftool batch.

**C2PA JUMBF parse (1 000 iterations)**

| Payload | Size    | Per parse |
|---------|--------:|----------:|
| Small (1 manifest, 2 assertions)   | 1.2 KB  | 29.0 µs  |
| Medium (3 manifests, 5 assertions) | 5.3 KB  | 120.0 µs |
| Large (10 manifests, 10 assertions)| 27.4 KB | 590.3 µs |

**MP4 container + C2PA parse (1 000 iterations)** — full `MP4Parser.parse` pass over a synthetic `ftyp` / `moov` / `uuid` container with embedded JUMBF.

| Payload | Container | Per parse |
|---------|----------:|----------:|
| Small   | 1.3 KB    | 31.9 µs   |
| Medium  | 5.4 KB    | 122.7 µs  |
| Large   | 27.5 KB   | 604.0 µs  |

<sup>Tested 2026-04-19 on macOS 26.4.1 (Apple M1 Max, 10 cores). SwiftExif @ `c84bfee` (main). ExifTool 13.55 via Homebrew.</sup>

## Acknowledgements

- **GeoNames** (https://www.geonames.org/) — The reverse geocoding database is built from GeoNames geographical data, licensed under [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/). The embedded city database contains ~33,500 cities with population >= 15,000.
- **ExifTool** by Phil Harvey (https://exiftool.org/) — The reference implementation for image metadata processing. SwiftExif aims to provide equivalent functionality as a native Swift library.

## License

GPL-3.0 — see [LICENSE](LICENSE) for details.
