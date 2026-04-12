# SwiftExif

A native Swift library for reading and writing image metadata — Exif, IPTC (IIM), and XMP — with no external dependencies.

## Supported Formats

| Format | Read | Write |
|--------|------|-------|
| JPEG | Yes | Yes |
| TIFF | Yes | — |
| RAW (DNG, CR2, NEF, ARW) | Yes | — |
| JPEG XL | Yes | — |
| PNG | Yes | — |
| AVIF | Yes | — |

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

```swift
var metadata = try readMetadata(from: imageURL)

metadata.iptc.setValue("Breaking news photo", for: .headline)
metadata.iptc.setValue("Jane Doe", for: .byline)
metadata.iptc.setValues(["news", "politics"], for: .keywords)

try metadata.write(to: outputURL)
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
├── TIFF/           # TIFF/RAW file parser
├── RAW/            # Camera RAW format support
├── PNG/            # PNG chunk parser
├── JPEGXL/         # JPEG XL box parser
└── AVIF/           # AVIF (ISOBMFF) parser
```

## License

GPL-3.0 — see [LICENSE](LICENSE) for details.
