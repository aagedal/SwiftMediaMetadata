# SwiftExif

A native Swift library for reading and writing image and video metadata — Exif, IPTC (IIM), XMP, C2PA, MakerNotes, and ICC profiles — with no external dependencies.

## Supported Formats

| Format | Read | Write | Metadata Types |
|--------|------|-------|----------------|
| JPEG | Yes | Yes | Exif, IPTC, XMP, C2PA, ICC |
| TIFF | Yes | Yes | Exif, IPTC, XMP, ICC |
| RAW (DNG, CR2, NEF, ARW) | Yes | Yes | Exif, IPTC, XMP, MakerNotes, ICC |
| JPEG XL (container) | Yes | Yes | Exif, XMP, ICC |
| PNG | Yes | Yes | Exif, XMP, ICC |
| AVIF | Yes | Yes | Exif, XMP, C2PA, ICC |
| HEIF / HEIC | Yes | Yes | Exif, XMP, C2PA, ICC |
| WebP | Yes | Yes | Exif, XMP, ICC |
| MP4 / MOV / M4V | Yes | — | Exif, XMP, GPS, C2PA, Sony NRT camera metadata, full stream info (codec, fps, field order, bit depth, chroma subsampling, color primaries/transfer/matrix/range, pixel aspect ratio, bit rate) + audio (codec, sample rate, channels, channel layout, bit depth, bit rate) + subtitle tracks (tx3g, WebVTT, TTML, CEA-608/708) with language |
| MXF (SMPTE 377) | Yes | — | C2PA, Sony NonRealTimeMeta (RDD-18), picture/sound essence descriptors (resolution, frame rate, scan type, chroma, color) |
| Matroska (.mkv) | Yes | — | Stream info (codec, fps, dimensions, bit depth, chroma, color), audio tracks, subtitle tracks (SRT, ASS/SSA, WebVTT, PGS, VobSub) with language + default/forced/SDH flags |
| WebM (.webm) | Yes | — | Stream info (VP8/VP9/AV1) + audio (Vorbis/Opus) + subtitle tracks |
| AVI (RIFF) | Yes | — | Stream info (codec, fps, dimensions, bit depth) + audio (codec, sample rate, channels), INFO tags |
| MPEG-PS / MPEG-TS / M2TS | Yes | — | Sequence-header stream facts (resolution, fps, aspect, bit rate), PMT elementary-stream inventory (DVB subtitles / teletext / PGS with language), M2TS (Blu-ray BDAV, 192-byte packets) auto-detected |
| MP3 (ID3v1 / ID3v2) | Yes | Yes | Tags + codec, sample rate, channels, bit rate, duration |
| FLAC | Yes | Yes | Tags + sample rate, channels, bit depth, duration |
| M4A | Yes | Yes | Tags + codec, sample rate, channels, bit depth, channel layout, bit rate, duration |
| Ogg Opus (.opus) | Yes | — | Vorbis comments + channels, sample rate, channel layout, duration |
| Ogg Vorbis (.ogg / .oga) | Yes | — | Vorbis comments + channels, sample rate, bit rate, duration |
| XMP sidecar (.xmp) | Yes | Yes | XMP |
| Sony NRT sidecar (.XML) | Yes | — | Camera metadata auto-probed next to MP4/MXF |

## Requirements

- Swift 6.0+
- macOS 13+ / iOS 16+

## Installation

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
MPEG-PS/TS files — enough to replace `ffprobe` in editorial/pipeline tooling:

```swift
let video = try VideoMetadata.read(from: videoURL)

// Container-level facts
print(video.format)          // .mp4, .mov, .m4v, .mxf, .mkv, .webm, .avi, .mpg
print(video.duration)        // TimeInterval?
print(video.bitRate)         // Int? — overall container bitrate in bps

// Primary video stream
print(video.videoWidth)      // 3840
print(video.videoHeight)     // 2160
print(video.videoCodec)      // "hvc1"
print(video.frameRate)       // 59.94
print(video.fieldOrder)      // .progressive / .topFieldFirst / .bottomFieldFirst
print(video.bitDepth)        // 10
print(video.chromaSubsampling) // "4:2:0"
print(video.colorInfo?.label) // "bt2020-hlg" / "bt2020-pq" / "bt709" …
print(video.pixelAspectRatio)   // (1, 1)
print(video.displayWidth / displayHeight)

// Primary audio stream
print(video.audioCodec)      // "mp4a"
print(video.audioSampleRate) // 48000
print(video.audioChannels)   // 6
print(video.audioStreams.first?.channelLayout) // "5.1"

// Per-track details for multi-track files
for stream in video.videoStreams { … }
for stream in video.audioStreams { … }

// Subtitle / closed-caption tracks with language + flags
for sub in video.subtitleStreams {
    print(sub.codecName, sub.language, sub.title, sub.isForced, sub.isHearingImpaired)
}

// Export as JSON
let json = VideoMetadataExporter.toJSONString(video)
```

### Audio Metadata

Standalone MP3, FLAC, M4A, Ogg Opus (.opus) and Ogg Vorbis (.ogg/.oga) files
expose codec, sample rate, channel count, channel layout, bit depth, and bit
rate alongside ID3/Vorbis tags:

```swift
let audio = try AudioMetadata.read(from: mp3URL)
print(audio.codec, audio.codecName)  // "mp3", "MP3"
print(audio.sampleRate, audio.channels, audio.bitrate, audio.bitDepth)
print(audio.title, audio.artist, audio.album)
```

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

// Sony NonRealTimeMeta (RDD-18) camera metadata — embedded or sidecar .XML.
if let cam = try await readVideoCameraMetadata(from: videoURL) {
    print(cam.deviceManufacturer)    // "Sony"
    print(cam.deviceModelName)       // "PXW-FX9"
    print(cam.lensModelName)         // "Sony FE 24-70mm F2.8 GM"
    print(cam.captureFps)            // 23.98
    print(cam.captureGammaEquation)  // "SLog3"
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

Access embedded C2PA manifests for content authenticity — works across
JPEG (APP11), PNG (caBX), JPEG XL, AVIF, HEIF, MP4/MOV (uuid or
top-level jumb), and MXF (SMPTE UL or Dark KLV):

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

### MakerNotes

Camera-specific manufacturer metadata (Canon, Nikon, Sony, Fujifilm, Olympus, Panasonic):

```swift
if let makerNote = metadata.exif?.makerNote {
    print(makerNote.manufacturer)  // .canon, .nikon, .sony, etc.
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
│                   #   MetadataExporter, CSVExporter, PrintConverter, MetadataRenamer
├── Binary/         # Low-level binary readers/writers, CRC32, ISO BMFF
├── Exif/           # Exif IFD parsing and writing
├── IPTC/           # IPTC IIM reader/writer, Photoshop IRB
├── XMP/            # XMP reader/writer with namespace mapping
├── C2PA/           # C2PA manifest/claim/signature parsing
├── CBOR/           # CBOR decoder for C2PA payloads
├── MakerNote/      # Camera-specific MakerNote parsers
├── Composite/      # Computed/derived tag calculator
├── GPX/            # GPX track parser and geotagging
├── Geolocation/    # Offline reverse geocoder (GeoNames + k-d tree)
├── ICC/            # ICC color profile reader
├── JPEG/           # JPEG segment parser and writer
├── TIFF/           # TIFF/RAW file parser and writer
├── RAW/            # Camera RAW format support
├── PNG/            # PNG chunk parser and writer
├── JPEGXL/         # JPEG XL box parser and writer
├── AVIF/           # AVIF (ISOBMFF) parser and writer
├── HEIF/           # HEIF/HEIC parser and writer
├── WebP/           # WebP (RIFF container) parser and writer
└── Video/          # MP4/MOV/M4V metadata parser, MXF KLV reader,
                    #   Sony NonRealTimeMeta (NRT / RDD-18) XML parser
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
