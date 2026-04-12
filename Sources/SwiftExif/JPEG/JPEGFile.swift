import Foundation

/// Represents a parsed JPEG file: metadata segments + opaque scan data.
public struct JPEGFile: Sendable {
    /// All segments before SOS (metadata, quantization tables, etc.).
    public var segments: [JPEGSegment]

    /// Raw bytes from SOS marker through EOI (inclusive).
    /// This is preserved verbatim to maintain image data integrity.
    public var scanData: Data

    public init(segments: [JPEGSegment] = [], scanData: Data = Data()) {
        self.segments = segments
        self.scanData = scanData
    }

    // MARK: - Segment Lookup

    /// Find the first segment with the given marker.
    public func findSegment(_ marker: JPEGMarker) -> JPEGSegment? {
        segments.first { $0.rawMarker == marker.rawValue }
    }

    /// Find all segments with the given marker.
    public func findSegments(_ marker: JPEGMarker) -> [JPEGSegment] {
        segments.filter { $0.rawMarker == marker.rawValue }
    }

    /// Find the Exif APP1 segment (identified by "Exif\0\0" prefix).
    public func exifSegment() -> JPEGSegment? {
        segments.first { $0.isExif }
    }

    /// Find the XMP APP1 segment (identified by XMP namespace prefix).
    public func xmpSegment() -> JPEGSegment? {
        segments.first { $0.isXMP }
    }

    /// Find the Photoshop/IPTC APP13 segment.
    public func iptcSegment() -> JPEGSegment? {
        segments.first { $0.isPhotoshop }
    }

    // MARK: - Segment Mutation

    /// Replace the first segment matching the marker with a new segment.
    public mutating func replaceSegment(_ marker: JPEGMarker, with segment: JPEGSegment) {
        if let index = segments.firstIndex(where: { $0.rawMarker == marker.rawValue }) {
            segments[index] = segment
        }
    }

    /// Replace or add a Photoshop/IPTC APP13 segment.
    public mutating func replaceOrAddIPTCSegment(_ segment: JPEGSegment) {
        if let index = segments.firstIndex(where: { $0.isPhotoshop }) {
            segments[index] = segment
        } else {
            insertSegment(segment, after: .app1)
        }
    }

    /// Replace or add an Exif APP1 segment.
    public mutating func replaceOrAddExifSegment(_ segment: JPEGSegment) {
        if let index = segments.firstIndex(where: { $0.isExif }) {
            segments[index] = segment
        } else {
            // Insert after APP0 if present, otherwise at the beginning
            if let app0Index = segments.firstIndex(where: { $0.rawMarker == JPEGMarker.app0.rawValue }) {
                segments.insert(segment, at: app0Index + 1)
            } else {
                segments.insert(segment, at: 0)
            }
        }
    }

    /// Replace or add an XMP APP1 segment.
    public mutating func replaceOrAddXMPSegment(_ segment: JPEGSegment) {
        if let index = segments.firstIndex(where: { $0.isXMP }) {
            segments[index] = segment
        } else {
            // Insert after Exif APP1 if present
            if let exifIndex = segments.firstIndex(where: { $0.isExif }) {
                segments.insert(segment, at: exifIndex + 1)
            } else {
                insertSegment(segment, after: .app0)
            }
        }
    }

    /// Insert a segment after the last occurrence of the given marker.
    /// If the marker is not found, appends to the end.
    public mutating func insertSegment(_ segment: JPEGSegment, after marker: JPEGMarker) {
        if let index = segments.lastIndex(where: { $0.rawMarker == marker.rawValue }) {
            segments.insert(segment, at: index + 1)
        } else {
            segments.append(segment)
        }
    }

    /// Remove all segments with the given marker.
    public mutating func removeSegments(_ marker: JPEGMarker) {
        segments.removeAll { $0.rawMarker == marker.rawValue }
    }
}
