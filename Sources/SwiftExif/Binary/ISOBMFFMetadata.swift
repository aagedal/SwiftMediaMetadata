import Foundation

/// Shared metadata extraction and writing logic for ISOBMFF-based formats (AVIF, HEIF, CR3).
/// Operates on the `meta → iprp → ipco` box hierarchy common to all these formats.
public struct ISOBMFFMetadata: Sendable {

    // MARK: - Reading

    /// Extract Exif data from ISOBMFF boxes.
    /// Tries ipco properties first, then iloc item-based extraction using `fileData`.
    public static func extractExif(from boxes: [ISOBMFFBox], fileData: Data? = nil) throws -> ExifData? {
        // Search for Exif box in top-level and nested boxes
        if let exifBox = findBox(type: "Exif", in: boxes) {
            return try parseExifBox(exifBox)
        }

        // Check inside meta → iprp → ipco container hierarchy
        if let metaBox = boxes.first(where: { $0.type == "meta" }) {
            if let exif = try extractExifFromMeta(metaBox) {
                return exif
            }

            // Fall back to iloc item-based extraction (real HEIF files)
            if let fileData {
                if let exif = try extractExifViaItem(metaBox: metaBox, fileData: fileData) {
                    return exif
                }
            }
        }

        return nil
    }

    /// Extract XMP data from ISOBMFF boxes.
    /// Tries ipco properties first, then iloc item-based extraction using `fileData`.
    public static func extractXMP(from boxes: [ISOBMFFBox], fileData: Data? = nil) throws -> XMPData? {
        if let metaBox = boxes.first(where: { $0.type == "meta" }) {
            if let xmp = try extractXMPFromMeta(metaBox) {
                return xmp
            }

            // Fall back to iloc item-based extraction
            if let fileData {
                if let xmp = try extractXMPViaItem(metaBox: metaBox, fileData: fileData) {
                    return xmp
                }
            }
        }
        return nil
    }

    /// Recursively find a box of the given type.
    public static func findBox(type: String, in boxes: [ISOBMFFBox]) -> ISOBMFFBox? {
        for box in boxes {
            if box.type == type { return box }
            if let children = try? ISOBMFFBoxReader.parseBoxes(from: box.data) {
                if let found = findBox(type: type, in: children) {
                    return found
                }
            }
        }
        return nil
    }

    // MARK: - Writing

    /// Update or create the meta box in a list of top-level boxes with new Exif/XMP data.
    /// When exif or xmp is nil, existing boxes for those types are removed.
    public static func updateMetadata(in boxes: inout [ISOBMFFBox], exif: ExifData?, xmp: XMPData?) throws {
        let exifBoxData: Data? = exif.map {
            var data = Data([0x00, 0x00, 0x00, 0x00]) // offset prefix
            data.append(ExifWriter.writeTIFF($0))
            return data
        }

        let xmpBoxData: Data? = xmp.map {
            var data = Data("application/rdf+xml".utf8)
            data.append(0x00) // null terminator
            data.append(Data(XMPWriter.generateXML($0).utf8))
            return data
        }

        if let metaIndex = boxes.firstIndex(where: { $0.type == "meta" }) {
            let newMetaData = try rebuildMetaBox(boxes[metaIndex].data, exifBoxData: exifBoxData, xmpBoxData: xmpBoxData, removeExif: exif == nil, removeXMP: xmp == nil)
            boxes[metaIndex] = ISOBMFFBox(type: "meta", data: newMetaData)
        } else if exifBoxData != nil || xmpBoxData != nil {
            let metaData = buildNewMetaBox(exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
            boxes.append(ISOBMFFBox(type: "meta", data: metaData))
        }
    }

    // MARK: - Private (Reading)

    private static func parseExifBox(_ box: ISOBMFFBox) throws -> ExifData? {
        try ExifReader.readFromExifBox(data: box.data)
    }

    private static func extractExifFromMeta(_ metaBox: ISOBMFFBox) throws -> ExifData? {
        let metaChildren = try parseMetaChildren(metaBox.data)

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
    static func parseMetaChildren(_ data: Data) throws -> [ISOBMFFBox] {
        guard data.count > 4 else { return [] }

        let skippedData = Data(data.suffix(from: data.startIndex + 4))
        if let boxes = try? ISOBMFFBoxReader.parseBoxes(from: skippedData), !boxes.isEmpty {
            return boxes
        }

        return try ISOBMFFBoxReader.parseBoxes(from: data)
    }

    /// Parse a "mime" property box for XMP content.
    private static func parseMimeBoxForXMP(_ box: ISOBMFFBox) throws -> XMPData? {
        let bytes = [UInt8](box.data)
        guard let nullIndex = bytes.firstIndex(of: 0) else { return nil }

        let contentType = String(bytes: bytes[0..<nullIndex], encoding: .utf8)
        guard contentType == "application/rdf+xml" else { return nil }

        let xmpData = Data(bytes[(nullIndex + 1)...])
        guard !xmpData.isEmpty else { return nil }

        return try XMPReader.readFromXML(xmpData)
    }

    // MARK: - Item-Based Extraction (iloc/iinf)

    /// Represents an item entry from the iinf box.
    private struct ItemInfo {
        let itemID: UInt32
        let itemType: String // 4-char type code
    }

    /// Represents an item's location from the iloc box.
    private struct ItemLocation {
        let itemID: UInt32
        let constructionMethod: UInt8 // 0 = file offset, 1 = idat offset
        let baseOffset: UInt64
        let extents: [(offset: UInt64, length: UInt64)]
    }

    /// Extract Exif by finding an "Exif" item in iinf and reading its data via iloc.
    private static func extractExifViaItem(metaBox: ISOBMFFBox, fileData: Data) throws -> ExifData? {
        let metaChildren = try parseMetaChildren(metaBox.data)
        let items = parseItemInfo(from: metaChildren)
        let locations = parseItemLocations(from: metaChildren)

        guard let exifItem = items.first(where: { $0.itemType == "Exif" }),
              let exifLoc = locations.first(where: { $0.itemID == exifItem.itemID }) else {
            return nil
        }

        let itemData: Data
        if exifLoc.constructionMethod == 1 {
            // idat-based: read from the idat box payload
            guard let idatBox = metaChildren.first(where: { $0.type == "idat" }) else { return nil }
            itemData = readExtents(from: idatBox.data, location: exifLoc)
        } else {
            // File offset-based
            itemData = readExtents(from: fileData, location: exifLoc)
        }

        guard !itemData.isEmpty else { return nil }
        return try ExifReader.readFromExifBox(data: itemData)
    }

    /// Extract XMP by finding a "mime" item with XMP content type via iloc.
    private static func extractXMPViaItem(metaBox: ISOBMFFBox, fileData: Data) throws -> XMPData? {
        let metaChildren = try parseMetaChildren(metaBox.data)
        let items = parseItemInfo(from: metaChildren)
        let locations = parseItemLocations(from: metaChildren)

        // Look for items with type "mime" — these may contain XMP
        for item in items where item.itemType == "mime" {
            guard let loc = locations.first(where: { $0.itemID == item.itemID }) else { continue }

            let itemData: Data
            if loc.constructionMethod == 1 {
                guard let idatBox = metaChildren.first(where: { $0.type == "idat" }) else { continue }
                itemData = readExtents(from: idatBox.data, location: loc)
            } else {
                itemData = readExtents(from: fileData, location: loc)
            }

            // Check if this mime item contains XMP (starts with content type)
            let bytes = [UInt8](itemData)
            guard let nullIndex = bytes.firstIndex(of: 0) else { continue }
            let contentType = String(bytes: bytes[0..<nullIndex], encoding: .utf8)
            guard contentType == "application/rdf+xml" else { continue }

            let xmpData = Data(bytes[(nullIndex + 1)...])
            guard !xmpData.isEmpty else { continue }
            return try XMPReader.readFromXML(xmpData)
        }

        return nil
    }

    /// Read concatenated extent data from a source buffer.
    private static func readExtents(from source: Data, location: ItemLocation) -> Data {
        var result = Data()
        for extent in location.extents {
            let offset = Int(location.baseOffset + extent.offset)
            let length = Int(extent.length)
            guard offset >= 0, offset + length <= source.count else { continue }
            result.append(source[source.startIndex + offset ..< source.startIndex + offset + length])
        }
        return result
    }

    /// Parse item info entries from the iinf box within meta children.
    private static func parseItemInfo(from metaChildren: [ISOBMFFBox]) -> [ItemInfo] {
        guard let iinfBox = metaChildren.first(where: { $0.type == "iinf" }) else { return [] }
        guard iinfBox.data.count >= 6 else { return [] }

        var reader = BinaryReader(data: iinfBox.data)
        var items: [ItemInfo] = []

        do {
            let versionFlags = try reader.readUInt32BigEndian()
            let version = versionFlags >> 24

            let entryCount: Int
            if version == 0 {
                entryCount = Int(try reader.readUInt16BigEndian())
            } else {
                entryCount = Int(try reader.readUInt32BigEndian())
            }

            // Each entry is an infe box
            for _ in 0..<entryCount {
                guard reader.remainingCount >= 8 else { break }
                let boxSize = try reader.readUInt32BigEndian()
                let boxType = try reader.readBytes(4)
                guard String(data: boxType, encoding: .ascii) == "infe" else {
                    // Skip unknown box
                    if boxSize > 8 { try reader.skip(Int(boxSize) - 8) }
                    continue
                }

                let payloadSize = Int(boxSize) - 8
                guard payloadSize > 4, reader.remainingCount >= payloadSize else { break }
                let payload = try reader.readBytes(payloadSize)
                var payloadReader = BinaryReader(data: payload)

                let infeVersionFlags = try payloadReader.readUInt32BigEndian()
                let infeVersion = infeVersionFlags >> 24

                let itemID: UInt32
                if infeVersion < 2 {
                    itemID = UInt32(try payloadReader.readUInt16BigEndian())
                    try payloadReader.skip(2) // protection_index
                    // v0/v1: no item_type field
                    continue
                } else if infeVersion == 2 {
                    itemID = UInt32(try payloadReader.readUInt16BigEndian())
                } else {
                    // v3+: 32-bit item_ID
                    itemID = try payloadReader.readUInt32BigEndian()
                }
                try payloadReader.skip(2) // protection_index
                guard payloadReader.remainingCount >= 4 else { continue }
                let typeData = try payloadReader.readBytes(4)
                let itemType = String(data: typeData, encoding: .ascii) ?? "????"
                items.append(ItemInfo(itemID: itemID, itemType: itemType))
            }
        } catch {
            // Best-effort parsing
        }

        return items
    }

    /// Parse item locations from the iloc box within meta children.
    private static func parseItemLocations(from metaChildren: [ISOBMFFBox]) -> [ItemLocation] {
        guard let ilocBox = metaChildren.first(where: { $0.type == "iloc" }) else { return [] }
        guard ilocBox.data.count >= 8 else { return [] }

        var reader = BinaryReader(data: ilocBox.data)
        var locations: [ItemLocation] = []

        do {
            let versionFlags = try reader.readUInt32BigEndian()
            let version = versionFlags >> 24

            // Size fields (packed into 2 bytes)
            let sizeByte1 = try reader.readUInt8()
            let sizeByte2 = try reader.readUInt8()
            let offsetSize = Int(sizeByte1 >> 4)
            let lengthSize = Int(sizeByte1 & 0x0F)
            let baseOffsetSize = Int(sizeByte2 >> 4)
            let indexSize = (version == 1 || version == 2) ? Int(sizeByte2 & 0x0F) : 0

            let itemCount: Int
            if version < 2 {
                itemCount = Int(try reader.readUInt16BigEndian())
            } else {
                itemCount = Int(try reader.readUInt32BigEndian())
            }

            for _ in 0..<itemCount {
                let itemID: UInt32
                if version < 2 {
                    itemID = UInt32(try reader.readUInt16BigEndian())
                } else {
                    itemID = try reader.readUInt32BigEndian()
                }

                let constructionMethod: UInt8
                if version == 1 || version == 2 {
                    let cm = try reader.readUInt16BigEndian()
                    constructionMethod = UInt8(cm & 0x0F)
                } else {
                    constructionMethod = 0
                }

                try reader.skip(2) // data_reference_index

                let baseOffset = try readSizedUInt(&reader, size: baseOffsetSize)

                let extentCount = Int(try reader.readUInt16BigEndian())
                var extents: [(offset: UInt64, length: UInt64)] = []

                for _ in 0..<extentCount {
                    if indexSize > 0 {
                        _ = try readSizedUInt(&reader, size: indexSize)
                    }
                    let extentOffset = try readSizedUInt(&reader, size: offsetSize)
                    let extentLength = try readSizedUInt(&reader, size: lengthSize)
                    extents.append((offset: extentOffset, length: extentLength))
                }

                locations.append(ItemLocation(
                    itemID: itemID,
                    constructionMethod: constructionMethod,
                    baseOffset: baseOffset,
                    extents: extents
                ))
            }
        } catch {
            // Best-effort parsing
        }

        return locations
    }

    /// Read a variable-sized unsigned integer (0, 2, 4, or 8 bytes).
    private static func readSizedUInt(_ reader: inout BinaryReader, size: Int) throws -> UInt64 {
        switch size {
        case 0: return 0
        case 2: return UInt64(try reader.readUInt16BigEndian())
        case 4: return UInt64(try reader.readUInt32BigEndian())
        case 8: return try reader.readUInt64BigEndian()
        default: return 0
        }
    }

    // MARK: - Private (Writing)

    private static func rebuildMetaBox(_ data: Data, exifBoxData: Data?, xmpBoxData: Data?, removeExif: Bool = false, removeXMP: Bool = false) throws -> Data {
        guard data.count > 4 else {
            return buildNewMetaBox(exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
        }

        let fullBoxHeader = Data(data.prefix(4))
        let childData = Data(data.suffix(from: data.startIndex + 4))

        var children: [ISOBMFFBox]
        if let parsed = try? ISOBMFFBoxReader.parseBoxes(from: childData), !parsed.isEmpty {
            children = parsed
        } else {
            children = (try? ISOBMFFBoxReader.parseBoxes(from: data)) ?? []
            let result = rebuildIprpInChildren(&children, exifBoxData: exifBoxData, xmpBoxData: xmpBoxData, removeExif: removeExif, removeXMP: removeXMP)
            return ISOBMFFBoxWriter.serialize(boxes: result)
        }

        var result = children
        rebuildIprpInChildren(&result, exifBoxData: exifBoxData, xmpBoxData: xmpBoxData, removeExif: removeExif, removeXMP: removeXMP)

        var writer = BinaryWriter(capacity: data.count + 256)
        writer.writeBytes(fullBoxHeader)
        ISOBMFFBoxWriter.writeBoxes(&writer, boxes: result)
        return writer.data
    }

    @discardableResult
    private static func rebuildIprpInChildren(_ children: inout [ISOBMFFBox], exifBoxData: Data?, xmpBoxData: Data?, removeExif: Bool = false, removeXMP: Bool = false) -> [ISOBMFFBox] {
        if let iprpIndex = children.firstIndex(where: { $0.type == "iprp" }) {
            let newIprpData = rebuildIprpBox(children[iprpIndex].data, exifBoxData: exifBoxData, xmpBoxData: xmpBoxData, removeExif: removeExif, removeXMP: removeXMP)
            children[iprpIndex] = ISOBMFFBox(type: "iprp", data: newIprpData)
        } else if exifBoxData != nil || xmpBoxData != nil {
            let ipcoData = buildIpcoBox(exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
            let iprpData = ISOBMFFBoxWriter.serialize(boxes: [ISOBMFFBox(type: "ipco", data: ipcoData)])
            children.append(ISOBMFFBox(type: "iprp", data: iprpData))
        }
        return children
    }

    private static func rebuildIprpBox(_ data: Data, exifBoxData: Data?, xmpBoxData: Data?, removeExif: Bool = false, removeXMP: Bool = false) -> Data {
        guard var iprpChildren = try? ISOBMFFBoxReader.parseBoxes(from: data) else {
            let ipcoData = buildIpcoBox(exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
            return ISOBMFFBoxWriter.serialize(boxes: [ISOBMFFBox(type: "ipco", data: ipcoData)])
        }

        if let ipcoIndex = iprpChildren.firstIndex(where: { $0.type == "ipco" }) {
            let newIpcoData = rebuildIpcoBox(iprpChildren[ipcoIndex].data, exifBoxData: exifBoxData, xmpBoxData: xmpBoxData, removeExif: removeExif, removeXMP: removeXMP)
            iprpChildren[ipcoIndex] = ISOBMFFBox(type: "ipco", data: newIpcoData)
        } else if exifBoxData != nil || xmpBoxData != nil {
            let ipcoData = buildIpcoBox(exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
            iprpChildren.insert(ISOBMFFBox(type: "ipco", data: ipcoData), at: 0)
        }

        return ISOBMFFBoxWriter.serialize(boxes: iprpChildren)
    }

    private static func rebuildIpcoBox(_ data: Data, exifBoxData: Data?, xmpBoxData: Data?, removeExif: Bool = false, removeXMP: Bool = false) -> Data {
        guard var properties = try? ISOBMFFBoxReader.parseBoxes(from: data) else {
            return buildIpcoBox(exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
        }

        if let exifData = exifBoxData {
            if let index = properties.firstIndex(where: { $0.type == "Exif" }) {
                properties[index] = ISOBMFFBox(type: "Exif", data: exifData)
            } else {
                properties.append(ISOBMFFBox(type: "Exif", data: exifData))
            }
        } else if removeExif {
            properties.removeAll { $0.type == "Exif" }
        }

        if let xmpData = xmpBoxData {
            if let index = properties.firstIndex(where: { $0.type == "mime" && isMimeXMP($0) }) {
                properties[index] = ISOBMFFBox(type: "mime", data: xmpData)
            } else {
                properties.append(ISOBMFFBox(type: "mime", data: xmpData))
            }
        } else if removeXMP {
            properties.removeAll { $0.type == "mime" && isMimeXMP($0) }
        }

        return ISOBMFFBoxWriter.serialize(boxes: properties)
    }

    private static func buildIpcoBox(exifBoxData: Data?, xmpBoxData: Data?) -> Data {
        var properties: [ISOBMFFBox] = []
        if let exifData = exifBoxData {
            properties.append(ISOBMFFBox(type: "Exif", data: exifData))
        }
        if let xmpData = xmpBoxData {
            properties.append(ISOBMFFBox(type: "mime", data: xmpData))
        }
        return ISOBMFFBoxWriter.serialize(boxes: properties)
    }

    private static func buildNewMetaBox(exifBoxData: Data?, xmpBoxData: Data?) -> Data {
        var writer = BinaryWriter(capacity: 256)
        // FullBox header: version 0, flags 0
        writer.writeUInt32BigEndian(0x00000000)
        // iprp -> ipco
        let ipcoData = buildIpcoBox(exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
        let iprpData = ISOBMFFBoxWriter.serialize(boxes: [ISOBMFFBox(type: "ipco", data: ipcoData)])
        ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: "iprp", data: iprpData))
        return writer.data
    }

    private static func isMimeXMP(_ box: ISOBMFFBox) -> Bool {
        let contentType = "application/rdf+xml"
        guard box.data.count > contentType.utf8.count else { return false }
        return box.data.prefix(contentType.utf8.count) == Data(contentType.utf8)
    }
}
