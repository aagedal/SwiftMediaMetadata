import Foundation

public enum MetadataError: Error, CustomStringConvertible {
    case notAJPEG
    case unexpectedEndOfData
    case invalidSegmentLength
    case invalidMarker(UInt8)
    case segmentNotFound(UInt16)
    case invalidPhotoshopHeader
    case invalid8BIMBlock
    case invalidIPTCData(String)
    case invalidTIFFHeader
    case invalidIFDEntry
    case unsupportedExifType(UInt16)
    case invalidXMP(String)
    case encodingError(String)
    case fileNotFound(String)
    case fileWriteError(String)
    case dataExceedsMaxLength(tag: String, max: Int, actual: Int)

    public var description: String {
        switch self {
        case .notAJPEG:
            return "Not a valid JPEG file (missing SOI marker)"
        case .unexpectedEndOfData:
            return "Unexpected end of data"
        case .invalidSegmentLength:
            return "Invalid JPEG segment length"
        case .invalidMarker(let byte):
            return "Invalid JPEG marker: 0x\(String(byte, radix: 16, uppercase: true))"
        case .segmentNotFound(let marker):
            return "Segment not found: 0x\(String(marker, radix: 16, uppercase: true))"
        case .invalidPhotoshopHeader:
            return "Invalid Photoshop 3.0 header in APP13"
        case .invalid8BIMBlock:
            return "Invalid 8BIM resource block"
        case .invalidIPTCData(let detail):
            return "Invalid IPTC data: \(detail)"
        case .invalidTIFFHeader:
            return "Invalid TIFF header"
        case .invalidIFDEntry:
            return "Invalid IFD entry"
        case .unsupportedExifType(let type):
            return "Unsupported Exif data type: \(type)"
        case .invalidXMP(let detail):
            return "Invalid XMP data: \(detail)"
        case .encodingError(let detail):
            return "Encoding error: \(detail)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .fileWriteError(let detail):
            return "File write error: \(detail)"
        case .dataExceedsMaxLength(let tag, let max, let actual):
            return "Data for \(tag) exceeds max length (\(actual) > \(max))"
        }
    }
}
