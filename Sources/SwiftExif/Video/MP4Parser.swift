import Foundation

/// Parses MP4/MOV/M4V video files to extract metadata.
/// Reuses ISOBMFFBoxReader for box-level parsing.
public struct MP4Parser: Sendable {

    // Seconds between 1904-01-01 and 1970-01-01 (QuickTime epoch to Unix epoch)
    private static let epochOffset: TimeInterval = 2082844800

    // XMP UUID prefix: BE7ACFCB-97A9-42E8-9C71-999491E3AFAC
    private static let xmpUUID = Data([
        0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8,
        0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC,
    ])

    /// Parse video metadata from data.
    public static func parse(_ data: Data) throws -> VideoMetadata {
        // Parse top-level boxes, but skip mdat payload to save memory
        let boxes = try parseTopLevelBoxes(data)

        // Determine format from ftyp
        guard let ftyp = boxes.first(where: { $0.type == "ftyp" }) else {
            throw MetadataError.invalidVideo("Missing ftyp box")
        }
        let format = detectFormat(from: ftyp)

        var metadata = VideoMetadata(format: format)

        // Find moov box
        guard let moov = boxes.first(where: { $0.type == "moov" }) else {
            throw MetadataError.invalidVideo("Missing moov box")
        }
        let moovChildren = try ISOBMFFBoxReader.parseBoxes(from: moov.data)

        // Parse mvhd (movie header)
        if let mvhd = moovChildren.first(where: { $0.type == "mvhd" }) {
            parseMVHD(mvhd.data, into: &metadata)
        }

        // Parse tracks
        for trak in moovChildren.filter({ $0.type == "trak" }) {
            parseTrak(trak.data, into: &metadata)
        }

        // Parse udta -> meta -> ilst (QuickTime metadata)
        if let udta = moovChildren.first(where: { $0.type == "udta" }) {
            parseUDTA(udta.data, into: &metadata)
        }

        // Check for top-level meta box (some files put XMP here)
        if let meta = boxes.first(where: { $0.type == "meta" }) {
            parseMetaBox(meta.data, into: &metadata)
        }

        // Check for XMP in uuid boxes
        for uuid in boxes.filter({ $0.type == "uuid" }) {
            parseUUIDBox(uuid.data, into: &metadata)
        }

        // Parse C2PA manifest store if present (top-level jumb or uuid-wrapped JUMBF).
        if let jumbfData = C2PAReader.extractJUMBFFromISOBMFF(boxes) {
            do {
                if let c2pa = try C2PAReader.parseManifestStore(from: jumbfData) {
                    metadata.c2pa = c2pa
                }
            } catch {
                metadata.warnings.append("C2PA parse error: \(error)")
            }
        }

        return metadata
    }

    // MARK: - Top-Level Parsing (skips mdat)

    private static func parseTopLevelBoxes(_ data: Data) throws -> [ISOBMFFBox] {
        var reader = BinaryReader(data: data)
        var boxes: [ISOBMFFBox] = []

        while !reader.isAtEnd && reader.remainingCount >= 8 {
            let boxStart = reader.offset
            let size32 = try reader.readUInt32BigEndian()
            let typeBytes = try reader.readBytes(4)
            guard let type = String(data: typeBytes, encoding: .isoLatin1) else { break }

            let boxSize: Int
            if size32 == 1 {
                guard reader.remainingCount >= 8 else { break }
                let size64 = try reader.readUInt64BigEndian()
                boxSize = Int(size64)
            } else if size32 == 0 {
                boxSize = data.count - boxStart
            } else {
                boxSize = Int(size32)
            }

            let headerSize = (size32 == 1) ? 16 : 8
            let payloadSize = boxSize - headerSize
            guard payloadSize >= 0 else { break }

            if type == "mdat" {
                // Skip mdat payload — can be gigabytes of media data
                let endPos = boxStart + boxSize
                if endPos <= data.count {
                    try reader.seek(to: endPos)
                } else {
                    break // mdat extends to EOF
                }
                boxes.append(ISOBMFFBox(type: "mdat", data: Data()))
            } else {
                guard reader.offset + payloadSize <= data.count else { break }
                let payload = try reader.readBytes(payloadSize)
                boxes.append(ISOBMFFBox(type: type, data: payload))
            }
        }

        return boxes
    }

    // MARK: - Format Detection

    private static func detectFormat(from ftyp: ISOBMFFBox) -> VideoFormat {
        guard ftyp.data.count >= 4 else { return .mp4 }
        let brand = String(data: ftyp.data.prefix(4), encoding: .ascii) ?? ""
        switch brand {
        case "qt  ": return .mov
        case "M4V ", "M4VH", "M4VP": return .m4v
        default: return .mp4
        }
    }

    // MARK: - mvhd (Movie Header)

    private static func parseMVHD(_ data: Data, into metadata: inout VideoMetadata) {
        guard data.count >= 4 else { return }
        var reader = BinaryReader(data: data)

        // FullBox: version (1 byte) + flags (3 bytes)
        guard let version = try? reader.readUInt8() else { return }
        _ = try? reader.readBytes(3) // flags

        if version == 0 {
            // Version 0: 32-bit fields
            guard data.count >= 20 else { return }
            guard let creationTime = try? reader.readUInt32BigEndian(),
                  let modTime = try? reader.readUInt32BigEndian(),
                  let timescale = try? reader.readUInt32BigEndian(),
                  let duration = try? reader.readUInt32BigEndian() else { return }

            if creationTime > 0 {
                metadata.creationDate = Date(timeIntervalSince1970: Double(creationTime) - epochOffset)
            }
            if modTime > 0 {
                metadata.modificationDate = Date(timeIntervalSince1970: Double(modTime) - epochOffset)
            }
            if timescale > 0 {
                metadata.duration = Double(duration) / Double(timescale)
            }
        } else {
            // Version 1: 64-bit fields
            guard data.count >= 32 else { return }
            guard let creationTime = try? reader.readUInt64BigEndian(),
                  let modTime = try? reader.readUInt64BigEndian(),
                  let timescale = try? reader.readUInt32BigEndian(),
                  let duration = try? reader.readUInt64BigEndian() else { return }

            if creationTime > 0 {
                metadata.creationDate = Date(timeIntervalSince1970: Double(creationTime) - epochOffset)
            }
            if modTime > 0 {
                metadata.modificationDate = Date(timeIntervalSince1970: Double(modTime) - epochOffset)
            }
            if timescale > 0 {
                metadata.duration = Double(duration) / Double(timescale)
            }
        }
    }

    // MARK: - Track Parsing

    private static func parseTrak(_ data: Data, into metadata: inout VideoMetadata) {
        guard let children = try? ISOBMFFBoxReader.parseBoxes(from: data) else { return }

        // Parse tkhd for dimensions
        if let tkhd = children.first(where: { $0.type == "tkhd" }) {
            parseTKHD(tkhd.data, into: &metadata)
        }

        // Parse mdia for handler type and codec
        if let mdia = children.first(where: { $0.type == "mdia" }) {
            parseMDIA(mdia.data, into: &metadata)
        }
    }

    private static func parseTKHD(_ data: Data, into metadata: inout VideoMetadata) {
        guard data.count >= 4 else { return }
        var reader = BinaryReader(data: data)

        guard let version = try? reader.readUInt8() else { return }
        _ = try? reader.readBytes(3) // flags

        // Skip to width/height (last 8 bytes of tkhd, which are fixed-point 16.16)
        let dimensionOffset: Int
        if version == 0 {
            // Version 0: creation(4) + mod(4) + trackID(4) + reserved(4) + duration(4) +
            // reserved(8) + layer(2) + altGroup(2) + volume(2) + reserved(2) + matrix(36) = 76
            dimensionOffset = 4 + 76
        } else {
            // Version 1: creation(8) + mod(8) + trackID(4) + reserved(4) + duration(8) +
            // reserved(8) + layer(2) + altGroup(2) + volume(2) + reserved(2) + matrix(36) = 88
            dimensionOffset = 4 + 88
        }

        guard data.count >= dimensionOffset + 8 else { return }
        guard (try? reader.seek(to: dimensionOffset)) != nil else { return }
        guard let widthFP = try? reader.readUInt32BigEndian(),
              let heightFP = try? reader.readUInt32BigEndian() else { return }

        let width = Int(widthFP >> 16)
        let height = Int(heightFP >> 16)

        if width > 0 && height > 0 && metadata.videoWidth == nil {
            metadata.videoWidth = width
            metadata.videoHeight = height
        }
    }

    private static func parseMDIA(_ data: Data, into metadata: inout VideoMetadata) {
        guard let children = try? ISOBMFFBoxReader.parseBoxes(from: data) else { return }

        // Check handler type
        var handlerType = ""
        if let hdlr = children.first(where: { $0.type == "hdlr" }) {
            // FullBox header (4 bytes) + pre_defined (4 bytes) + handler_type (4 bytes)
            if hdlr.data.count >= 12 {
                handlerType = String(data: hdlr.data[hdlr.data.startIndex + 8 ..< hdlr.data.startIndex + 12], encoding: .ascii) ?? ""
            }
        }

        // Parse minf -> stbl -> stsd for codec
        if let minf = children.first(where: { $0.type == "minf" }),
           let minfChildren = try? ISOBMFFBoxReader.parseBoxes(from: minf.data),
           let stbl = minfChildren.first(where: { $0.type == "stbl" }),
           let stblChildren = try? ISOBMFFBoxReader.parseBoxes(from: stbl.data),
           let stsd = stblChildren.first(where: { $0.type == "stsd" }) {
            parseSTSD(stsd.data, handlerType: handlerType, into: &metadata)
        }
    }

    private static func parseSTSD(_ data: Data, handlerType: String, into metadata: inout VideoMetadata) {
        // FullBox header (4 bytes) + entry_count (4 bytes) + first entry: size(4) + type(4)
        guard data.count >= 16 else { return }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4) // FullBox header
        _ = try? reader.readUInt32BigEndian() // entry count

        guard reader.remainingCount >= 8 else { return }
        _ = try? reader.readUInt32BigEndian() // entry size
        guard let codecBytes = try? reader.readBytes(4),
              let codec = String(data: codecBytes, encoding: .ascii) else { return }

        if handlerType == "vide" && metadata.videoCodec == nil {
            metadata.videoCodec = codec
        } else if handlerType == "soun" && metadata.audioCodec == nil {
            metadata.audioCodec = codec
        }
    }

    // MARK: - User Data (udta -> meta -> ilst)

    private static func parseUDTA(_ data: Data, into metadata: inout VideoMetadata) {
        guard let children = try? ISOBMFFBoxReader.parseBoxes(from: data) else { return }

        if let meta = children.first(where: { $0.type == "meta" }) {
            parseMetaBox(meta.data, into: &metadata)
        }
    }

    private static func parseMetaBox(_ data: Data, into metadata: inout VideoMetadata) {
        // meta is a FullBox — skip 4-byte version/flags header
        guard data.count > 4 else { return }
        let metaPayload = data.suffix(from: data.startIndex + 4)
        guard let children = try? ISOBMFFBoxReader.parseBoxes(from: Data(metaPayload)) else { return }

        if let ilst = children.first(where: { $0.type == "ilst" }) {
            parseILST(ilst.data, into: &metadata)
        }

        // Check for xml box (XMP)
        if let xml = children.first(where: { $0.type == "xml " }) {
            if let xmpData = try? XMPReader.readFromXML(xml.data) {
                metadata.xmp = xmpData
            }
        }
    }

    private static func parseILST(_ data: Data, into metadata: inout VideoMetadata) {
        guard let items = try? ISOBMFFBoxReader.parseBoxes(from: data) else { return }

        for item in items {
            // Each item contains a "data" sub-box
            guard let dataBox = (try? ISOBMFFBoxReader.parseBoxes(from: item.data))?.first(where: { $0.type == "data" }) else {
                continue
            }

            // data box: type_indicator (4 bytes) + locale (4 bytes) + payload
            guard dataBox.data.count > 8 else { continue }
            let payload = dataBox.data.suffix(from: dataBox.data.startIndex + 8)

            // Get type indicator (first 4 bytes, big-endian UInt32)
            var typeReader = BinaryReader(data: dataBox.data)
            let typeIndicator = (try? typeReader.readUInt32BigEndian()) ?? 0

            // Map item type to metadata field
            let rawType = item.type

            // QuickTime keys use byte 0xA9 (©) which maps to \u{00A9} in isoLatin1
            let key: String
            if rawType.count == 4 && rawType.unicodeScalars.first?.value == 0xA9 {
                key = String(rawType.dropFirst())
            } else {
                key = rawType
            }

            switch key {
            case "nam":
                if typeIndicator == 1, let s = String(data: payload, encoding: .utf8) {
                    metadata.title = s
                }
            case "ART":
                if typeIndicator == 1, let s = String(data: payload, encoding: .utf8) {
                    metadata.artist = s
                }
            case "cmt":
                if typeIndicator == 1, let s = String(data: payload, encoding: .utf8) {
                    metadata.comment = s
                }
            case "day":
                // Date — just store as-is in comment for now
                break
            case "xyz":
                // GPS: "+DD.DDDD+DDD.DDDD/" or "+DD.DDDD+DDD.DDDD+AAAA.AA/"
                if let s = String(data: payload, encoding: .utf8) {
                    parseGPSXYZ(s, into: &metadata)
                }
            default:
                break
            }
        }
    }

    // MARK: - GPS from ©xyz

    static func parseGPSXYZ(_ string: String, into metadata: inout VideoMetadata) {
        // Format: "+DD.DDDD+DDD.DDDD/" or "+DD.DDDD-DDD.DDDD+AAAA.AA/"
        var cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("/") { cleaned = String(cleaned.dropLast()) }
        guard !cleaned.isEmpty else { return }

        // Split on +/- boundaries, keeping the sign
        var components: [String] = []
        var current = ""
        for char in cleaned {
            if (char == "+" || char == "-") && !current.isEmpty {
                components.append(current)
                current = String(char)
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { components.append(current) }

        if components.count >= 2 {
            metadata.gpsLatitude = Double(components[0])
            metadata.gpsLongitude = Double(components[1])
        }
        if components.count >= 3 {
            metadata.gpsAltitude = Double(components[2])
        }
    }

    // MARK: - UUID (XMP / embedded XML)

    private static func parseUUIDBox(_ data: Data, into metadata: inout VideoMetadata) {
        guard data.count > 16 else { return }
        let uuid = data.prefix(16)
        let payload = Data(data.suffix(from: data.startIndex + 16))

        if uuid == xmpUUID {
            if let xmpData = try? XMPReader.readFromXML(payload) {
                metadata.xmp = xmpData
            }
            return
        }

        // Some Sony MP4 cameras embed NonRealTimeMeta inside a uuid box.
        // The user-type UUID varies between firmware versions, so content-sniff
        // instead of matching a fixed UUID.
        if looksLikeNRT(payload) {
            if let cam = try? NRTXMLParser.parse(payload) {
                metadata.camera = cam
            }
        }
    }

    private static func looksLikeNRT(_ data: Data) -> Bool {
        guard data.count > 16 else { return false }
        let scanLimit = min(data.count, 4096)
        guard let head = String(data: data.prefix(scanLimit), encoding: .utf8) else {
            return false
        }
        return head.contains("NonRealTimeMeta")
    }
}
