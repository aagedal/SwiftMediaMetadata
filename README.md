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
| MP4 / MOV / M4V | Yes | — | Exif, XMP, GPS, C2PA, Sony NRT camera metadata |
| MXF (SMPTE 377) | Yes | — | C2PA, Sony NonRealTimeMeta (RDD-18) camera metadata |
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

Read metadata from MP4, MOV, M4V, and MXF files:

```swift
let video = try VideoMetadata.read(from: videoURL)

print(video.duration)       // TimeInterval?
print(video.creationDate)   // Date?
print(video.videoWidth)     // Int?
print(video.videoHeight)    // Int?
print(video.videoCodec)     // String?
print(video.gpsLatitude)    // Double?

// Export as JSON
let json = VideoMetadataExporter.toJSONString(video)
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

Access embedded C2PA manifests for content authenticity:

```swift
if let c2pa = metadata.c2pa {
    for manifest in c2pa.manifests {
        print(manifest.claim.claimGenerator)
        print(manifest.claim.title)
        for assertion in manifest.assertions {
            print(assertion.label)
        }
    }
}
```

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

## Acknowledgements

- **GeoNames** (https://www.geonames.org/) — The reverse geocoding database is built from GeoNames geographical data, licensed under [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/). The embedded city database contains ~33,500 cities with population >= 15,000.
- **ExifTool** by Phil Harvey (https://exiftool.org/) — The reference implementation for image metadata processing. SwiftExif aims to provide equivalent functionality as a native Swift library.

## License

GPL-3.0 — see [LICENSE](LICENSE) for details.
