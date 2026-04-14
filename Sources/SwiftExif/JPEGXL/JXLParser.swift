import Foundation

/// Parse JPEG XL files for metadata.
public struct JXLParser: Sendable {

    /// JPEG XL container signature: the first 12 bytes of a JXL container file.
    /// This is actually the JXL file type box: size=12, type="JXL ".
    static let containerSignature: [UInt8] = [
        0x00, 0x00, 0x00, 0x0C,  // box size = 12
        0x4A, 0x58, 0x4C, 0x20,  // "JXL "
        0x0D, 0x0A, 0x87, 0x0A,  // line feed magic
    ]

    /// Bare codestream signature.
    static let codestreamSignature: [UInt8] = [0xFF, 0x0A]

    /// Parse a JPEG XL file from raw data.
    public static func parse(_ data: Data) throws -> JXLFile {
        guard data.count >= 2 else {
            throw MetadataError.invalidJPEGXL("File too small")
        }

        let bytes = [UInt8](data.prefix(12))

        // Check for container format
        if data.count >= 12 && bytes.elementsEqual(containerSignature) {
            return try parseContainer(data)
        }

        // Check for bare codestream
        if bytes[0] == codestreamSignature[0] && bytes[1] == codestreamSignature[1] {
            return JXLFile(isContainer: false)
        }

        throw MetadataError.invalidJPEGXL("Not a valid JPEG XL file")
    }

    /// Extract Exif data from a JPEG XL Exif box.
    public static func extractExif(from exifBox: ISOBMFFBox) throws -> ExifData? {
        try ExifReader.readFromExifBox(data: exifBox.data)
    }

    // MARK: - Private

    private static func parseContainer(_ data: Data) throws -> JXLFile {
        // Skip the 12-byte file type box
        let boxData = Data(data.suffix(from: data.startIndex + 12))
        let boxes = try ISOBMFFBoxReader.parseBoxes(from: boxData)
        return JXLFile(isContainer: true, boxes: boxes)
    }
}
