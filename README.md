# SwiftExif

A native Swift library for reading and writing image metadata — Exif, IPTC (IIM), and XMP — with no external dependencies.

## Supported Formats

| Format | Read | Write | Metadata Types |
|--------|------|-------|----------------|
| JPEG | Yes | Yes | Exif, IPTC, XMP |
| TIFF | Yes | Yes | Exif, IPTC, XMP |
| RAW (DNG, CR2, NEF, ARW) | Yes | Yes | Exif, IPTC, XMP |
| JPEG XL (container) | Yes | Yes | Exif, XMP |
| PNG | Yes | Yes | Exif, XMP |
| AVIF | Yes | Yes | Exif, XMP |
| XMP sidecar (.xmp) | Yes | Yes | XMP |

## Requirements

- Swift 5.9+
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

Works for all supported formats (JPEG, TIFF, RAW, JPEG XL, PNG, AVIF):

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
├── API/            # Public API: ImageMetadata, BatchProcessor, FormatDetector
├── Binary/         # Low-level binary readers/writers, CRC32, ISO BMFF
├── Exif/           # Exif IFD parsing and writing
├── IPTC/           # IPTC IIM reader/writer, Photoshop IRB
├── XMP/            # XMP reader/writer with namespace mapping
├── JPEG/           # JPEG segment parser and writer
├── TIFF/           # TIFF/RAW file parser and writer
├── RAW/            # Camera RAW format support
├── PNG/            # PNG chunk parser and writer
├── JPEGXL/         # JPEG XL box parser and writer
└── AVIF/           # AVIF (ISOBMFF) parser and writer
```

## License

GPL-3.0 — see [LICENSE](LICENSE) for details.
