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

/// Read XMP metadata from a sidecar file (.xmp) alongside the given image URL.
public func readXMPSidecar(for imageURL: URL) throws -> XMPData {
    try XMPSidecar.read(from: XMPSidecar.sidecarURL(for: imageURL))
}

/// Read XMP metadata from a sidecar file at the given URL.
public func readXMPSidecar(from url: URL) throws -> XMPData {
    try XMPSidecar.read(from: url)
}
