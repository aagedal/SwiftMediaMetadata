import Foundation

/// Parse AVIF files for metadata.
public struct AVIFParser {

    /// Parse an AVIF file from raw data.
    public static func parse(_ data: Data) throws -> AVIFFile {
        guard data.count >= 12 else {
            throw MetadataError.invalidAVIF("File too small")
        }

        // Parse the ftyp box to verify this is AVIF
        let boxes = try ISOBMFFBoxReader.parseBoxes(from: data)
        guard let ftypBox = boxes.first(where: { $0.type == "ftyp" }) else {
            throw MetadataError.invalidAVIF("Missing ftyp box")
        }

        // Extract major brand (first 4 bytes of ftyp payload)
        guard ftypBox.data.count >= 4 else {
            throw MetadataError.invalidAVIF("Invalid ftyp box")
        }
        let brand = String(data: ftypBox.data.prefix(4), encoding: .ascii) ?? "????"

        return AVIFFile(boxes: boxes, brand: brand)
    }

    /// Extract Exif data by recursively searching for an "Exif" box.
    public static func extractExif(from avifFile: AVIFFile) throws -> ExifData? {
        // Search for Exif box in top-level and nested boxes
        if let exifBox = findBox(type: "Exif", in: avifFile.boxes) {
            return try parseExifBox(exifBox)
        }

        // Also check inside meta → iprp → ipco container hierarchy
        if let metaBox = avifFile.boxes.first(where: { $0.type == "meta" }) {
            if let exif = try extractExifFromMeta(metaBox) {
                return exif
            }
        }

        return nil
    }

    /// Extract XMP data by recursively searching for a "mime" box with XMP content type.
    public static func extractXMP(from avifFile: AVIFFile) throws -> XMPData? {
        // Check inside meta box hierarchy
        if let metaBox = avifFile.boxes.first(where: { $0.type == "meta" }) {
            if let xmp = try extractXMPFromMeta(metaBox) {
                return xmp
            }
        }
        return nil
    }

    // MARK: - Private

    private static func findBox(type: String, in boxes: [ISOBMFFBox]) -> ISOBMFFBox? {
        for box in boxes {
            if box.type == type { return box }
            // Try parsing children for container boxes
            if let children = try? ISOBMFFBoxReader.parseBoxes(from: box.data) {
                if let found = findBox(type: type, in: children) {
                    return found
                }
            }
        }
        return nil
    }

    private static func parseExifBox(_ box: ISOBMFFBox) throws -> ExifData? {
        // Exif box: 4-byte offset prefix + TIFF data
        guard box.data.count > 4 else { return nil }

        var reader = BinaryReader(data: box.data)
        let offset = try reader.readUInt32BigEndian()

        if offset > 0 {
            try reader.skip(Int(offset))
        }

        let tiffData = Data(box.data.suffix(from: box.data.startIndex + reader.offset))
        guard !tiffData.isEmpty else { return nil }

        return try ExifReader.readFromTIFF(data: tiffData)
    }

    private static func extractExifFromMeta(_ metaBox: ISOBMFFBox) throws -> ExifData? {
        // meta box may have a 4-byte version/flags prefix (FullBox)
        let metaChildren = try parseMetaChildren(metaBox.data)

        // Look in iprp → ipco for Exif property
        if let iprpBox = metaChildren.first(where: { $0.type == "iprp" }) {
            let iprpChildren = try ISOBMFFBoxReader.parseBoxes(from: iprpBox.data)
            if let ipcoBox = iprpChildren.first(where: { $0.type == "ipco" }) {
                let properties = try ISOBMFFBoxReader.parseBoxes(from: ipcoBox.data)
                if let exifBox = properties.first(where: { $0.type == "Exif" }) {
                    return try parseExifBox(exifBox)
                }
            }
        }

        return nil
    }

    private static func extractXMPFromMeta(_ metaBox: ISOBMFFBox) throws -> XMPData? {
        let metaChildren = try parseMetaChildren(metaBox.data)

        if let iprpBox = metaChildren.first(where: { $0.type == "iprp" }) {
            let iprpChildren = try ISOBMFFBoxReader.parseBoxes(from: iprpBox.data)
            if let ipcoBox = iprpChildren.first(where: { $0.type == "ipco" }) {
                let properties = try ISOBMFFBoxReader.parseBoxes(from: ipcoBox.data)
                for prop in properties {
                    if prop.type == "mime" {
                        if let xmp = try parseMimeBoxForXMP(prop) {
                            return xmp
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Parse meta box children, skipping the 4-byte FullBox header if present.
    private static func parseMetaChildren(_ data: Data) throws -> [ISOBMFFBox] {
        // meta is a FullBox: 4 bytes version + flags before child boxes
        guard data.count > 4 else { return [] }

        // Try parsing with 4-byte skip first (FullBox), fall back to direct parse
        let skippedData = Data(data.suffix(from: data.startIndex + 4))
        if let boxes = try? ISOBMFFBoxReader.parseBoxes(from: skippedData), !boxes.isEmpty {
            return boxes
        }

        // Fall back to direct parse (no FullBox header)
        return try ISOBMFFBoxReader.parseBoxes(from: data)
    }

    /// Parse a "mime" property box for XMP content.
    /// Format: null-terminated content_type string + payload
    private static func parseMimeBoxForXMP(_ box: ISOBMFFBox) throws -> XMPData? {
        let bytes = [UInt8](box.data)
        guard let nullIndex = bytes.firstIndex(of: 0) else { return nil }

        let contentType = String(bytes: bytes[0..<nullIndex], encoding: .utf8)
        guard contentType == "application/rdf+xml" else { return nil }

        let xmpData = Data(bytes[(nullIndex + 1)...])
        guard !xmpData.isEmpty else { return nil }

        return try XMPReader.readFromXML(xmpData)
    }
}
