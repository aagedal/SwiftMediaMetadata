import Foundation

/// Parse TIFF-based RAW camera files (DNG, CR2, NEF, ARW) for metadata.
/// All these formats use TIFF IFD structure; this parser validates format-specific
/// magic bytes and delegates to TIFFFileParser.
public struct RAWFileParser: Sendable {

    /// Validate that data looks like a specific RAW format.
    /// Returns the detected RAW format, or nil if not recognized.
    public static func detectRAWFormat(_ data: Data) -> ImageFormat.RawFormat? {
        guard data.count >= 12 else { return nil }

        let bytes = [UInt8](data.prefix(12))

        // Must have TIFF magic
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

        // NEF/ARW detection requires MakerNote analysis — use extension-based detection
        return nil
    }

    /// Parse a RAW file. Delegates to TIFFFileParser since all supported RAW
    /// formats use TIFF IFD structure.
    public static func parse(_ data: Data, format: ImageFormat.RawFormat) throws -> TIFFFile {
        // Validate basic TIFF structure
        let tiff = try TIFFFileParser.parse(data)

        // Format-specific validation
        switch format {
        case .cr2:
            // CR2 should have "CR" signature at offset 8
            if data.count >= 10 {
                let bytes = [UInt8](data.prefix(10))
                guard bytes[8] == 0x43 && bytes[9] == 0x52 else {
                    throw MetadataError.invalidRAW("Missing CR2 signature")
                }
            }
        case .dng, .nef, .arw:
            // These parse identically to TIFF
            break
        case .cr3:
            // CR3 is ISOBMFF-based, not TIFF — should not reach here
            throw MetadataError.invalidRAW("CR3 files should not be parsed as TIFF")
        }

        return tiff
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
