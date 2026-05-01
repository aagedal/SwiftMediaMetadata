# ExifTool / ffprobe Parity Plan

Tracking the remaining real bugs found by comparing `swift-exif` output
against ExifTool (stills) and ffprobe (video) on the corpora at:

- Stills: `/Users/traag222/Development/Aagedal_Photo_Agent/TestImages/`
- Video:  `/Users/traag222/Movies/TestVideo/`

Generated 2026-05-01. Comparison harness lives in `/tmp/exif_compare/`
(`compare_stills.py`, `compare_video.py`).

## Status snapshot

After the 2026-05-01 round of fixes (XMP-dc capitalization, LensInfo
print conversion, body/lens serial numbers, JPEG SOF dimensions,
PixelXDimension fallback for File:ImageWidth/Height):

| Surface | Files | Files matching cleanly | Remaining issues |
|---|---|---|---|
| Stills | 21 | 16 | 18 (most cosmetic) |
| Video  | 27 |  5 | 107 |

Phases below are ordered by impact ÷ effort. Within a phase, items are
roughly independent — each can land as its own PR.

---

## Phase 1 — HEIC parity (4 bugs, all in one module)

All four HEIC stills issues land together. Test file:
`IMG_5543_upsideDownFaceThumbnailSource_1.heic`.

### 1.1 — HEIC GPSAltitude missing
- **Where**: `Sources/SwiftExif/Exif/ExifData.swift:173–179`
  (`gpsAltitude` accessor) + `Sources/SwiftExif/API/MetadataExporter.swift:348–349`
- **Diagnosis**: GPS IFD reaches HEIC ExifData (lat/lon work fine).
  Either the accessor isn't combining the altitude reference byte
  (0x0005, 0=above/1=below) with the rational value, or we never emit
  `GPSAltitude` to the dict.
- **Fix**: Verify accessor returns a signed Double. Add
  `if let alt = exif.gpsAltitude { dict["GPSAltitude"] = alt }` to
  `addExifFields`. Add `"X m"` print conversion.
- **Effort**: ~10 LOC.

### 1.2 — HEIC XMP-dc:Description not parsed
- **Where**: `Sources/SwiftExif/Binary/ISOBMFFMetadata.swift:34–242`
  (`extractXMP`, `extractXMPFromMeta`, `extractXMPViaItem`)
- **Diagnosis**: Exif item extraction works → item-finding plumbing is
  fine. XMP item extraction is separate and failing for Apple HEIC.
  Either the `mime` item type lookup misses (Apple uses
  `application/rdf+xml`, but iref linkage may differ) or the XMP is
  found but our XMPParser stumbles on Apple's lang-alt RDF shape.
- **Fix**: Add a probe to log what extractXMPFromMeta finds. Most
  likely a parser-path issue since the same XMP works in JPEGs.
- **Effort**: ~30–60 LOC.

### 1.3 — HEIC ICCProfile:Description not parsed
- **Where**: `Sources/SwiftExif/Binary/ISOBMFFMetadata.swift:52–61`
  (`extractICCProfile` exists) +
  `Sources/SwiftExif/API/ImageMetadata.swift` HEIF read path (mirror
  AVIF at line 1440).
- **Diagnosis**: `extractICCProfile` works for AVIF. HEIF read path
  just doesn't call it. ICC for HEIC is in `colr` box with type `prof`
  inside `iprp/ipco`.
- **Fix**: One line — call
  `ISOBMFFMetadata.extractICCProfile(from: heifFile.boxes)` in the
  HEIF read path and assign to `metadata.iccProfile`.
- **Effort**: ~5 LOC.

### 1.4 — ExposureProgram print conversion
- **Where**: `Sources/SwiftExif/API/PrintConverter.swift:28`
  (`exposureProgram`)
- **Diagnosis**: Value 2 ⇒ ExifTool prints `Program AE`, we print
  `Normal Program`. Table fix.
- **Effort**: 1 LOC.

**Phase 1 total**: ~50–80 LOC, one PR, one test file.

---

## Phase 2 — JXL dimensions (1 bug, contained)

### 2.1 — JXL `File:ImageWidth/Height`
- **Where**: `Sources/SwiftExif/JPEGXL/JXLParser.swift:18–36`,
  `Sources/SwiftExif/JPEGXL/JXLFile.swift`,
  `Sources/SwiftExif/API/MetadataExporter.swift` (where File:ImageWidth
  is emitted).
- **Diagnosis**: JXL has two container forms — bare codestream
  (`FF 0A` magic) and ISOBMFF box format. Dimensions are encoded in a
  short variable-length bit stream right after the magic, or inside
  the `jxlc`/`jxlp` box payload. Current parser reads neither.
- **Fix**: Add `imageDimensions` accessor on `JXLFile`:
  - **Bare codestream**: skip 2-byte signature, decode the SizeHeader
    bit-stream per libjxl §9.3 — 2-bit y-div selector, variable-length
    y bit-stream, aspect-ratio selector, x derived.
  - **ISOBMFF JXL**: locate `jxlc` (or `jxlp`) box, strip 2-byte
    signature, decode same as above.
- **Wire**: Add a `case .jpegXL(let f)` block in MetadataExporter to
  set `File:ImageWidth/Height`, mirroring the JPEG SOF block.
- **Effort**: ~80–120 LOC including bit-reader.

---

## Phase 3 — Video parity

### 3.1 — MOV stream order (ProRes RAW swap, more)
- **Where**: `Sources/SwiftExif/Video/MP4Parser.swift:423–510`
  (`parseTrak`); the merge into output streams (find `videoStreams +
  audioStreams`).
- **Diagnosis**: `parseTrak` appends to separate `videoStreams` and
  `audioStreams` arrays. Exporter concatenates `[video..., audio...,
  subtitle...]`, so any MOV with audio-trak first physically (e.g.
  a7s III ProRes RAW HQ) appears swapped. ffprobe preserves trak order.
- **Fix**: Single `metadata.streams: [Stream]` in trak iteration order
  with `kind` discriminator. Keep typed accessors (`videoStreams`
  etc.) as filtered views for downstream compat. Update exporter to
  iterate the unified list.
- **Effort**: ~80–150 LOC plus consumer audit.
- **Side effect**: also fixes ordering for chapter/data tracks.

### 3.2 — Chapter test files (10–12 streams vs 4–6)
- **Where**: `Sources/SwiftExif/Video/MP4Parser.swift:121–137`
  (`parseChapterTracks` / `parseCHPL`).
- **Diagnosis**: Line 666 already excludes the chapter text track from
  `subtitleStreams`. Yet swift reports way more streams than ffprobe,
  so chapters are leaking into the streams output via another path —
  either each chapter entry from `chpl` is being added as a stream,
  or the `tref:chap`-referenced track is emitted twice.
- **Fix**: Confirm `metadata.chapters` is its own field. Find the leak
  and drop chapter entries from `streams`.
- **Effort**: ~20–40 LOC after diagnosis.

### 3.3 — MP3 / M4A return zero streams in `--streams` mode
- **Where**: `Sources/SwiftExif/Audio/ID3Parser.swift`,
  `Sources/SwiftExif/API/AudioMetadata.swift:98–122`, plus the format
  dispatch in `--streams` output (likely `ReadCommand.swift`).
- **Diagnosis**: M4A parses via the MP4 reader internally but
  `audioStreams` doesn't surface in the audio path. MP3 has no MPEG
  frame parser to emit a stream descriptor.
- **Fix**:
  - **M4A**: surface `VideoMetadata.audioStreams` as `streams` in the
    audio path. ~10–20 LOC of plumbing.
  - **MP3**: parse first MPEG audio frame header (version, layer,
    bitrate, samplerate, mode); estimate duration from file size /
    Xing-VBR header. Emit one audio stream. ~80–120 LOC.
- **Effort**: M4A ~20 LOC, MP3 ~100 LOC. Independent.

### 3.4 — MKV stream classification (Interstellar bug)
- **Where**: `Sources/SwiftExif/Video/MatroskaReader.swift:602–701`
  (track type dispatch) + `1875–1903` (codec name table).
- **Diagnosis**: The pattern of swaps in our Interstellar report
  (stream[3] dts↔ac3, [4] ac3↔dts, [8] dts↔ac3, [15] audio/ac3 ↔
  subtitle/pgs, [46] subtitle/pgs ↔ video/mjpeg) looks like our
  streams array is **shifted** relative to ffprobe's. Codec data is
  correct but attached to the wrong index. Likely we drop or insert
  one stream where ffprobe doesn't (or vice versa).
- **Fix**: Dump our streams with their original Matroska TrackNumber
  alongside our index, compare to ffprobe's `index`. The misalignment
  reveals the culprit (skipped disabled track? attachments?).
- **Effort**: ~30 min diagnosis, then 10–30 LOC of fix.

### 3.5 — HDR_MultiAudioTrack missing data track (5 vs 6)
- **Where**: `Sources/SwiftExif/Video/MP4Parser.swift:684–696`
  (handler dispatch).
- **Diagnosis**: ffprobe sees `[video, audio, audio, audio, audio,
  data]`. Swift sees 5 — `data`/`meta`/`tmcd` handlers have no match
  and fall through silently.
- **Fix**: Add a `data`/`meta` classification path that produces a
  `data`-typed stream.
- **Effort**: ~20–40 LOC. Best combined with 3.1.

---

## Phase 4 — Cosmetic / low-priority

| Issue | Plan | Status |
|---|---|---|
| GPS `°` vs ` deg` separator | Replace `°` with ` deg` in `formatGPSCoordinate` (`PrintConverter.swift:56–63`). 1 LOC. | Done 2026-05-01 |
| Subtitle codec `tx3g` vs `mov_text` | Add alias in `ffprobeShortSubtitleCodec` (`ReadCommand.swift:420–431`). 1 LOC. | Done 2026-05-01 |
| H.265 `Main 4:2:2 10` vs ffprobe `Rext` | Both correct. Leave. | — |

---

## Phase 5 — Green-field

### 5.1 — Blackmagic RAW (`.braw`)
- **Status (2026-05-01)**: container metadata working. BRAW is an
  ISOBMFF derivative with the legacy QuickTime layout (`wide` + `mdat`
  + tail-placed `moov`, no `ftyp`). Wiring it up needed only:
  - Add `.braw` to `VideoFormat` and `supportedVideoExtensions`
  - Tolerate a missing `ftyp` in `MP4Parser.parse` (default to `.mov`)
  - Promote `metadata.format` to `.braw` in `VideoMetadata.read(from:url:)`
    based on the path extension
- **What we extract today**: duration, project frame rate (from stts),
  width/height (8K verified on Pyxis 12K samples), audio stream
  details, codec FourCC (`brlt`/`brhq`/`brst` for the BRAW quality
  presets), creation date, timecode.
- **What we don't extract**: BMD's proprietary clip metadata —
  off-speed sensor FPS (e.g. 112 fps when project rate is 24), ISO,
  white point, tint, lens info, color science generation, gamma /
  LUT. These live in custom boxes inside `moov`/`udta`. Adding them
  would need a small BRAW-specific parser; defer unless a concrete
  user need lands.
- **Codec long-name table**: not added. The FourCCs surface as-is
  (`brlt`, `brhq`, `brst`); BMD's official mapping isn't documented
  publicly enough to commit to friendly names without verification.

---

## Suggested PR sequencing

1. **PR 1**: Phase 1 — HEIC parity (~50–80 LOC). Cheapest, biggest
   immediate value.
2. **PR 2**: Phase 2 — JXL dimensions (~80–120 LOC). Self-contained.
3. **PR 3**: Phase 4 cosmetic — GPS deg + tx3g alias (~5 LOC).
4. **PR 4**: Phase 3.1 + 3.2 + 3.5 — MOV stream order + chapter leak +
   data tracks (~150–250 LOC). One coherent MP4Parser refactor.
5. **PR 5**: Phase 3.3 — MP3 / M4A streams (~120 LOC).
6. **PR 6**: Phase 3.4 — MKV diagnosis + fix (~30 LOC after triage).
7. **Defer**: Phase 5 (BRAW).

After PRs 1–3, all stills bugs are closed except BRAW. After PRs 4–6,
all video bugs are closed except BRAW.

---

## Cosmetic-but-keep-in-mind diffs

- swift-exif date format `2026-03-19T10:16:47.93+01:00` (ISO 8601) vs
  ExifTool `2026:03:19 10:16:47`. Both unambiguous; not flagged as a
  bug. Most Apple ecosystem consumers accept ISO 8601; ExifTool keeps
  the legacy colon-date for compatibility with Photoshop. The
  comparison harness already normalizes between the two.
- LensInfo precision: we use `%.10g` so iPhone's
  `2.690000057mm f/1.9` round-trips without truncation.
