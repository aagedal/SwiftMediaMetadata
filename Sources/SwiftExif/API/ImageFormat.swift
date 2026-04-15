import Foundation

/// Supported image file formats.
public enum ImageFormat: Sendable, Equatable {
    case jpeg
    case tiff
    case raw(RawFormat)
    case jpegXL
    case png
    case avif
    case heif
    case webp

    /// RAW camera formats (all TIFF-based for metadata purposes).
    public enum RawFormat: String, Sendable, CaseIterable, Equatable {
        case dng, cr2, nef, arw
    }
}
