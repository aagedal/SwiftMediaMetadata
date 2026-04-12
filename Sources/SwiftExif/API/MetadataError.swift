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
    case unsupportedFormat
    case invalidPNG(String)
    case invalidJPEGXL(String)
    case invalidAVIF(String)
    case invalidTIFFFile(String)
    case invalidRAW(String)
    case crcMismatch(expected: UInt32, actual: UInt32)
    case invalidCBOR(String)
    case invalidJUMBF(String)
    case invalidC2PA(String)
    case writeNotSupported(String)

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
        case .unsupportedFormat:
            return "Unsupported image format"
        case .invalidPNG(let detail):
            return "Invalid PNG: \(detail)"
        case .invalidJPEGXL(let detail):
            return "Invalid JPEG XL: \(detail)"
        case .invalidAVIF(let detail):
            return "Invalid AVIF: \(detail)"
        case .invalidTIFFFile(let detail):
            return "Invalid TIFF file: \(detail)"
        case .invalidRAW(let detail):
            return "Invalid RAW file: \(detail)"
        case .crcMismatch(let expected, let actual):
            return "CRC32 mismatch: expected 0x\(String(expected, radix: 16)), got 0x\(String(actual, radix: 16))"
        case .invalidCBOR(let detail):
            return "Invalid CBOR data: \(detail)"
        case .invalidJUMBF(let detail):
            return "Invalid JUMBF data: \(detail)"
        case .invalidC2PA(let detail):
            return "Invalid C2PA data: \(detail)"
        case .writeNotSupported(let detail):
            return "Write not supported: \(detail)"
        }
    }
}
