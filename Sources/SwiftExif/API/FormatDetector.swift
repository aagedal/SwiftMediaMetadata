import Foundation

/// Detect image format from file data using magic bytes.
public struct FormatDetector: Sendable {

    /// Detect the image format from the first bytes of data.
    /// Returns nil if the format is not recognized.
    public static func detect(_ data: Data) -> ImageFormat? {
        guard data.count >= 12 else { return nil }

        let bytes = [UInt8](data.prefix(12))

        // JPEG: FF D8
        if bytes[0] == 0xFF && bytes[1] == 0xD8 {
            return .jpeg
        }

        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if data.count >= 8 &&
           bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 &&
           bytes[4] == 0x0D && bytes[5] == 0x0A && bytes[6] == 0x1A && bytes[7] == 0x0A {
            return .png
        }

        // JPEG XL container: 00 00 00 0C 4A 58 4C 20 0D 0A 87 0A
        if bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0x00 && bytes[3] == 0x0C &&
           bytes[4] == 0x4A && bytes[5] == 0x58 && bytes[6] == 0x4C && bytes[7] == 0x20 {
            return .jpegXL
        }

        // JPEG XL bare codestream: FF 0A
        if bytes[0] == 0xFF && bytes[1] == 0x0A {
            return .jpegXL
        }

        // WebP: RIFF xxxx WEBP
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
           bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 {
            return .webp
        }

        // AVIF/HEIF: check for ftyp box at offset 4
        if bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
            // Read brand (4 bytes at offset 8)
            if let brand = detectISOBMFFBrand(data) {
                if brand == "avif" || brand == "avis" {
                    return .avif
                }
                if brand == "heic" || brand == "heix" || brand == "hevc" || brand == "hevx" || brand == "mif1" {
                    return .heif
                }
                if brand == "crx " {
                    return .raw(.cr3)
                }
            }
        }

        // TIFF-based formats (must check more specific formats first)
        if isTIFFMagic(bytes) {
            return detectTIFFVariant(data)
        }

        return nil
    }

    /// Detect format from file extension as a fallback.
    public static func detectFromExtension(_ pathExtension: String) -> ImageFormat? {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg":
            return .jpeg
        case "tif", "tiff":
            return .tiff
        case "dng":
            return .raw(.dng)
        case "cr2":
            return .raw(.cr2)
        case "nef":
            return .raw(.nef)
        case "arw":
            return .raw(.arw)
        case "cr3":
            return .raw(.cr3)
        case "jxl":
            return .jpegXL
        case "png":
            return .png
        case "avif":
            return .avif
        case "heic", "heif":
            return .heif
        case "webp":
            return .webp
        default:
            return nil
        }
    }

    // MARK: - Private

    private static func isTIFFMagic(_ bytes: [UInt8]) -> Bool {
        // Little-endian: 49 49 2A 00
        if bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00 {
            return true
        }
        // Big-endian: 4D 4D 00 2A
        if bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A {
            return true
        }
        return false
    }

    private static func detectTIFFVariant(_ data: Data) -> ImageFormat {
        // CR2: TIFF header + "CR" at offset 8-9
        if data.count >= 10 {
            let bytes = [UInt8](data.prefix(10))
            if bytes[8] == 0x43 && bytes[9] == 0x52 { // "CR"
                return .raw(.cr2)
            }
        }

        // For DNG/NEF/ARW: need to scan IFD0 for distinguishing tags.
        // This is a quick heuristic scan, not a full IFD parse.
        if let format = detectRAWFromIFD(data) {
            return format
        }

        return .tiff
    }

    private static func detectRAWFromIFD(_ data: Data) -> ImageFormat? {
        // Quick scan for DNG: look for DNGVersion tag (0xC612) in IFD0
        guard data.count >= 16 else { return nil }

        var reader = BinaryReader(data: data)
        guard let header = try? TIFFHeader.parse(from: &reader) else { return nil }

        let endian = header.byteOrder
        let ifdOffset = Int(header.ifdOffset)
        guard ifdOffset + 2 <= data.count else { return nil }

        do {
            try reader.seek(to: ifdOffset)
            let entryCount = try reader.readUInt16(endian: endian)

            // Scan tag IDs (first 2 bytes of each 12-byte entry)
            let maxEntries = min(Int(entryCount), (data.count - ifdOffset - 2) / 12)
            for i in 0..<maxEntries {
                let entryOffset = ifdOffset + 2 + (i * 12)
                guard entryOffset + 2 <= data.count else { break }
                try reader.seek(to: entryOffset)
                let tag = try reader.readUInt16(endian: endian)

                // DNGVersion tag
                if tag == 0xC612 {
                    return .raw(.dng)
                }
            }
        } catch {
            return nil
        }

        // NEF and ARW are harder to distinguish from plain TIFF without parsing MakerNotes.
        // Fall back to extension-based detection for these.
        return nil
    }

    private static func detectISOBMFFBrand(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let brandBytes = data[data.startIndex + 8 ..< data.startIndex + 12]
        return String(data: brandBytes, encoding: .ascii)
    }

    // MARK: - Video Detection

    /// Detect video format from the first bytes of data.
    public static func detectVideo(_ data: Data) -> VideoFormat? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))

        // ISOBMFF: check for ftyp box at offset 4
        guard bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 else {
            return nil
        }

        guard let brand = detectISOBMFFBrand(data) else { return nil }

        switch brand {
        case "mp41", "mp42", "isom", "iso2", "dash", "M4A ":
            return .mp4
        case "qt  ":
            return .mov
        case "M4V ", "M4VH", "M4VP":
            return .m4v
        default:
            return nil
        }
    }

    /// Detect video format from file extension.
    public static func detectVideoFromExtension(_ pathExtension: String) -> VideoFormat? {
        switch pathExtension.lowercased() {
        case "mp4":  return .mp4
        case "mov":  return .mov
        case "m4v":  return .m4v
        default:     return nil
        }
    }
}
