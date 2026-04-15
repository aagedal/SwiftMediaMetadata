import Foundation

/// Parse TIFF-based RAW camera files for metadata.
/// Most RAW formats use TIFF IFD structure; this parser validates format-specific
/// magic bytes and delegates to TIFFFileParser. RAF uses a custom header with
/// an embedded TIFF/Exif block.
public struct RAWFileParser: Sendable {

    /// Validate that data looks like a specific RAW format.
    /// Returns the detected RAW format, or nil if not recognized.
    public static func detectRAWFormat(_ data: Data) -> ImageFormat.RawFormat? {
        guard data.count >= 12 else { return nil }

        let bytes = [UInt8](data.prefix(12))

        // RAF: "FUJIFILMCCD-RAW" at offset 0
        if data.count >= 16,
           let prefix = String(data: data.prefix(15), encoding: .ascii),
           prefix == "FUJIFILMCCD-RAW" {
            return .raf
        }

        // RW2: TIFF-like with version 0x0055 instead of 0x002A
        let isRW2LE = bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x55 && bytes[3] == 0x00
        if isRW2LE {
            return .rw2
        }

        // Must have TIFF magic for remaining formats
        let isLE = bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00
        let isBE = bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A
        guard isLE || isBE else { return nil }

        // CR2: "CR" at offset 8-9
        if bytes[8] == 0x43 && bytes[9] == 0x52 {
            return .cr2
        }

        // DNG: scan IFD0 for DNGVersion tag (0xC612)
        if hasDNGVersionTag(data) {
            return .dng
        }

        // ORF/PEF/NEF/ARW detection requires MakerNote analysis — use extension-based detection
        return nil
    }

    /// Parse a RAW file. Delegates to TIFFFileParser since most supported RAW
    /// formats use TIFF IFD structure.
    public static func parse(_ data: Data, format: ImageFormat.RawFormat) throws -> TIFFFile {
        switch format {
        case .raf:
            return try parseRAF(data)
        case .rw2:
            return try parseRW2(data)
        case .cr3:
            // CR3 is ISOBMFF-based, not TIFF — should not reach here
            throw MetadataError.invalidRAW("CR3 files should not be parsed as TIFF")
        case .cr2:
            let tiff = try TIFFFileParser.parse(data)
            // CR2 should have "CR" signature at offset 8
            if data.count >= 10 {
                let bytes = [UInt8](data.prefix(10))
                guard bytes[8] == 0x43 && bytes[9] == 0x52 else {
                    throw MetadataError.invalidRAW("Missing CR2 signature")
                }
            }
            return tiff
        case .dng, .nef, .arw, .orf, .pef:
            // These all parse identically to TIFF
            return try TIFFFileParser.parse(data)
        }
    }

    // MARK: - RAF (Fujifilm)

    /// Parse Fujifilm RAF file. The RAF container has a proprietary header followed by
    /// an embedded JPEG preview and a TIFF/Exif metadata block.
    /// Header layout:
    ///   0-15: "FUJIFILMCCD-RAW " magic
    ///  16-19: format version
    ///  20-27: camera model ID
    ///  28-31: camera model string (padded)
    ///  84-87: JPEG offset (big-endian UInt32)
    ///  88-91: JPEG length (big-endian UInt32)
    /// 92-95: CFA header offset (or metadata offset)
    /// 96-99: CFA header length
    /// 100-103: CFA offset
    /// 104-107: CFA length
    private static func parseRAF(_ data: Data) throws -> TIFFFile {
        guard data.count >= 108 else {
            throw MetadataError.invalidRAW("RAF file too small")
        }

        // Verify magic
        guard let magic = String(data: data.prefix(15), encoding: .ascii),
              magic == "FUJIFILMCCD-RAW" else {
            throw MetadataError.invalidRAW("Missing FUJIFILMCCD-RAW magic")
        }

        // Read JPEG offset and length from header (big-endian at offsets 84-91)
        var reader = BinaryReader(data: data)
        try reader.seek(to: 84)
        let jpegOffset = Int(try reader.readUInt32BigEndian())
        let jpegLength = Int(try reader.readUInt32BigEndian())

        guard jpegOffset > 0 && jpegLength > 0 && jpegOffset + jpegLength <= data.count else {
            throw MetadataError.invalidRAW("Invalid RAF JPEG offset/length")
        }

        // The embedded JPEG contains the TIFF/Exif metadata in its APP1 segment.
        // Parse it as TIFF by extracting Exif data from the JPEG.
        let jpegData = data[data.startIndex + jpegOffset ..< data.startIndex + jpegOffset + jpegLength]

        // Find the Exif APP1 segment within the embedded JPEG
        if let exifOffset = findExifInJPEG(Data(jpegData)) {
            let start = jpegData.startIndex + exifOffset
            let tiffData = Data(jpegData[start ..< jpegData.endIndex])
            return try TIFFFileParser.parse(tiffData)
        }

        // Fallback: try to parse the whole embedded JPEG as if it has a TIFF structure
        throw MetadataError.invalidRAW("No Exif data found in RAF embedded JPEG")
    }

    /// Find the offset of TIFF data within JPEG Exif APP1 segment.
    private static func findExifInJPEG(_ data: Data) -> Int? {
        guard data.count >= 12 else { return nil }
        var offset = 2 // Skip SOI (FF D8)

        while offset + 4 < data.count {
            guard data[data.startIndex + offset] == 0xFF else { return nil }
            let marker = data[data.startIndex + offset + 1]

            // APP1 = 0xE1
            if marker == 0xE1 {
                let segLen = Int(data[data.startIndex + offset + 2]) << 8 | Int(data[data.startIndex + offset + 3])
                // Check for "Exif\0\0" header
                let headerStart = offset + 4
                if headerStart + 6 <= data.count {
                    let exifHeader = data[data.startIndex + headerStart ..< data.startIndex + headerStart + 6]
                    if exifHeader == Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) {
                        return headerStart + 6 // TIFF data starts after "Exif\0\0"
                    }
                }
                offset += 2 + segLen
            } else if marker == 0xDA || marker == 0xD9 {
                break // SOS or EOI — stop scanning
            } else {
                let segLen = Int(data[data.startIndex + offset + 2]) << 8 | Int(data[data.startIndex + offset + 3])
                offset += 2 + segLen
            }
        }
        return nil
    }

    // MARK: - RW2 (Panasonic)

    /// Parse Panasonic RW2 file. RW2 uses a TIFF-like structure but with version
    /// byte 0x55 instead of 0x2A. We patch the version to standard TIFF for parsing.
    private static func parseRW2(_ data: Data) throws -> TIFFFile {
        guard data.count >= 8 else {
            throw MetadataError.invalidRAW("RW2 file too small")
        }

        // Verify RW2 magic: "II" + 0x55 0x00
        guard data[data.startIndex] == 0x49 && data[data.startIndex + 1] == 0x49 &&
              data[data.startIndex + 2] == 0x55 && data[data.startIndex + 3] == 0x00 else {
            throw MetadataError.invalidRAW("Missing RW2 magic bytes")
        }

        // Patch version byte from 0x55 to standard TIFF 0x2A so TIFFFileParser can handle it
        var patched = data
        patched[patched.startIndex + 2] = 0x2A
        return try TIFFFileParser.parse(patched)
    }

    // MARK: - Private

    private static func hasDNGVersionTag(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }

        var reader = BinaryReader(data: data)
        guard let header = try? TIFFHeader.parse(from: &reader) else { return false }

        let endian = header.byteOrder
        let ifdOffset = Int(header.ifdOffset)
        guard ifdOffset + 2 <= data.count else { return false }

        do {
            try reader.seek(to: ifdOffset)
            let entryCount = try reader.readUInt16(endian: endian)
            let maxEntries = min(Int(entryCount), (data.count - ifdOffset - 2) / 12)

            for i in 0..<maxEntries {
                let entryOffset = ifdOffset + 2 + (i * 12)
                guard entryOffset + 2 <= data.count else { break }
                try reader.seek(to: entryOffset)
                let tag = try reader.readUInt16(endian: endian)
                if tag == 0xC612 { return true }
            }
        } catch {
            return false
        }

        return false
    }
}
