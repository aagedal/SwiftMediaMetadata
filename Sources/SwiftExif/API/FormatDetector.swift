import Foundation

/// Detect image format from file data using magic bytes.
public struct FormatDetector: Sendable {

    /// Detect the image format from the first bytes of data.
    /// Returns nil if the format is not recognized.
    public static func detect(_ data: Data) -> ImageFormat? {
        guard data.count >= 12 else { return nil }

        let bytes = [UInt8](data.prefix(12))

        // PSD: 8BPS
        if bytes[0] == 0x38 && bytes[1] == 0x42 && bytes[2] == 0x50 && bytes[3] == 0x53 {
            return .psd
        }

        // PDF: %PDF-
        if bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46 && bytes[4] == 0x2D {
            return .pdf
        }

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

        // Fujifilm RAF: starts with "FUJIFILMCCD-RAW"
        if data.count >= 16 {
            let rafMagic = "FUJIFILMCCD-RAW"
            if let prefix = String(data: data.prefix(15), encoding: .ascii), prefix == rafMagic {
                return .raw(.raf)
            }
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

        // GIF: GIF87a or GIF89a
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 &&
           (bytes[4] == 0x37 || bytes[4] == 0x39) && bytes[5] == 0x61 {
            return .gif
        }

        // BMP: BM (0x42, 0x4D)
        if bytes[0] == 0x42 && bytes[1] == 0x4D {
            return .bmp
        }

        // RW2 (Panasonic): TIFF-like but uses version 0x0055 instead of 0x002A
        if data.count >= 4 {
            let isRW2LE = bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x55 && bytes[3] == 0x00
            if isRW2LE {
                return .raw(.rw2)
            }
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
        case "raf":
            return .raw(.raf)
        case "rw2":
            return .raw(.rw2)
        case "orf":
            return .raw(.orf)
        case "pef":
            return .raw(.pef)
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
        case "pdf":
            return .pdf
        case "psd", "psb":
            return .psd
        case "gif":
            return .gif
        case "bmp", "dib":
            return .bmp
        case "svg", "svgz":
            return .svg
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
        // Quick scan IFD0 tags for format-specific indicators
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
            var makeString: String?

            for i in 0..<maxEntries {
                let entryOffset = ifdOffset + 2 + (i * 12)
                guard entryOffset + 12 <= data.count else { break }
                try reader.seek(to: entryOffset)
                let tag = try reader.readUInt16(endian: endian)

                // DNGVersion tag
                if tag == 0xC612 {
                    return .raw(.dng)
                }

                // Read Make tag (0x010F) to help distinguish formats
                if tag == 0x010F {
                    let type = try reader.readUInt16(endian: endian)
                    let count = try reader.readUInt32(endian: endian)
                    if type == 2 { // ASCII
                        let valueOffset: Int
                        if count <= 4 {
                            valueOffset = entryOffset + 8
                        } else {
                            valueOffset = Int(try reader.readUInt32(endian: endian))
                        }
                        if valueOffset + Int(count) <= data.count {
                            let strData = data[data.startIndex + valueOffset ..< data.startIndex + valueOffset + Int(count)]
                            makeString = String(data: strData, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters)
                        }
                    }
                }
            }

            // Use Make to distinguish ORF (Olympus) and PEF (Pentax)
            if let make = makeString?.uppercased() {
                if make.contains("OLYMPUS") {
                    return .raw(.orf)
                }
                if make.contains("PENTAX") || make.contains("RICOH") {
                    return .raw(.pef)
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

        // MXF Partition Pack key: 06 0E 2B 34 02 05 01 01 0D 01 02 …
        if MXFReader.isMXF(data) {
            return .mxf
        }

        // Matroska / WebM: EBML header 1A 45 DF A3 + DocType "matroska" or "webm".
        if MatroskaReader.isMatroska(data) {
            if let doctypeRange = data.range(of: Data("webm".utf8), in: 0..<min(data.count, 64)) {
                _ = doctypeRange
                return .webm
            }
            return .mkv
        }

        // AVI: RIFF … AVI
        if AVIReader.isAVI(data) {
            return .avi
        }

        // MPEG PS/TS
        if MPEGReader.isMPEG(data) {
            return .mpg
        }

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
        case "mxf":  return .mxf
        case "mkv":  return .mkv
        case "webm": return .webm
        case "avi":  return .avi
        case "mpg", "mpeg", "vob", "ts", "m2ts", "mts": return .mpg
        default:     return nil
        }
    }

    // MARK: - Audio Detection

    /// Detect audio format from the first bytes of data.
    public static func detectAudio(_ data: Data) -> AudioFormat? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(4))

        // MP3 with ID3v2 tag: "ID3" (0x49, 0x44, 0x33)
        if bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 {
            return .mp3
        }

        // MP3 MPEG frame sync: 0xFF followed by 0xE0+ (11 sync bits set)
        if bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 {
            return .mp3
        }

        // FLAC: "fLaC" (0x66, 0x4C, 0x61, 0x43)
        if bytes[0] == 0x66 && bytes[1] == 0x4C && bytes[2] == 0x61 && bytes[3] == 0x43 {
            return .flac
        }

        // Ogg container — inspect the first page to pick Opus vs Vorbis.
        // Any codec we can't identify is rejected here (Theora, Speex, FLAC-
        // in-Ogg, chained streams …) so the caller can fall through to the
        // extension probe or surface an unsupported-format error.
        if bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53 {
            if let codec = OggReader.detectOggCodec(data) { return codec }
        }

        // M4A: ISOBMFF with "M4A " brand (check via existing infrastructure)
        if data.count >= 12 {
            let b = [UInt8](data.prefix(12))
            if b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 {
                if let brand = detectISOBMFFBrand(data), brand == "M4A " {
                    return .m4a
                }
            }
        }

        return nil
    }

    /// Detect audio format from file extension.
    public static func detectAudioFromExtension(_ pathExtension: String) -> AudioFormat? {
        switch pathExtension.lowercased() {
        case "mp3": return .mp3
        case "flac": return .flac
        case "m4a": return .m4a
        case "opus": return .opus
        case "ogg", "oga": return .oggVorbis
        default: return nil
        }
    }
}
