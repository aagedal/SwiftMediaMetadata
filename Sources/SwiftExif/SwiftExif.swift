import Foundation

/// Read all metadata from an image file at the given URL.
/// Supports JPEG, TIFF, RAW (DNG, CR2, NEF, ARW), JPEG XL, PNG, and AVIF.
public func readMetadata(from url: URL) throws -> ImageMetadata {
    try ImageMetadata.read(from: url)
}

/// Read all metadata from image data in memory.
/// Format is automatically detected from magic bytes.
public func readMetadata(from data: Data) throws -> ImageMetadata {
    try ImageMetadata.read(from: data)
}
