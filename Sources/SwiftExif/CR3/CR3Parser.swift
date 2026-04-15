import Foundation

/// Parses Canon CR3 files (ISOBMFF-based RAW format).
public struct CR3Parser: Sendable {

    /// Parse a CR3 file and extract metadata.
    /// - Returns: Tuple of (CR3File, ExifData?, XMPData?, IPTCData)
    public static func parse(_ data: Data) throws -> (file: CR3File, exif: ExifData?, xmp: XMPData?, iptc: IPTCData) {
        // Parse top-level boxes (skip mdat payload for efficiency)
        let topBoxes = try parseTopLevelBoxes(data)

        var exif: ExifData?
        var xmp: XMPData?
        var thumbnailData: Data?
        var previewData: Data?

        // Process moov box — contains Canon metadata uuid containers
        if let moovBox = topBoxes.first(where: { $0.type == "moov" }) {
            let moovChildren = try ISOBMFFBoxReader.parseBoxes(from: moovBox.data)

            for child in moovChildren {
                if child.type == "uuid" && child.data.count >= 16 {
                    let uuid = child.data.prefix(16)
                    let payload = child.data.dropFirst(16)

                    if uuid == CR3UUID.canonMetadata {
                        // Parse Canon metadata container (CMT1-4, THMB)
                        let result = try parseCanonMetadata(Data(payload))
                        exif = result.exif
                        thumbnailData = result.thumbnail
                    } else if uuid == CR3UUID.canonPreview {
                        // Parse preview container (PRVW)
                        previewData = try parsePreviewContainer(Data(payload))
                    }
                }
            }
        }

        // Process top-level uuid boxes for XMP
        for box in topBoxes where box.type == "uuid" && box.data.count >= 16 {
            let uuid = box.data.prefix(16)
            if uuid == CR3UUID.xmpUUID {
                let xmpData = Data(box.data.dropFirst(16))
                xmp = try? XMPReader.readFromXML(xmpData)
            }
        }

        let file = CR3File(boxes: topBoxes, thumbnailData: thumbnailData, previewData: previewData, originalData: data)
        return (file, exif, xmp, IPTCData())
    }

    // MARK: - Canon Metadata Container

    /// Parse the Canon metadata UUID container containing CMT1-4 and THMB boxes.
    private static func parseCanonMetadata(_ data: Data) throws -> (exif: ExifData?, thumbnail: Data?) {
        let children = try ISOBMFFBoxReader.parseBoxes(from: data)

        var ifd0: IFD?
        var exifIFD: IFD?
        var makerNoteIFD: IFD?
        var gpsIFD: IFD?
        var byteOrder: ByteOrder = .littleEndian
        var thumbnail: Data?

        for child in children {
            switch child.type {
            case "CMT1":
                // IFD0 — camera make, model, orientation, etc.
                if let parsed = try? ExifReader.readFromTIFF(data: child.data) {
                    ifd0 = parsed.ifd0
                    byteOrder = parsed.byteOrder
                }
            case "CMT2":
                // ExifIFD — exposure, ISO, date, etc.
                if let parsed = try? ExifReader.readFromTIFF(data: child.data) {
                    exifIFD = parsed.ifd0 // CMT2's IFD0 IS the Exif sub-IFD
                }
            case "CMT3":
                // Canon MakerNotes as standalone TIFF
                if let parsed = try? ExifReader.readFromTIFF(data: child.data) {
                    makerNoteIFD = parsed.ifd0
                }
            case "CMT4":
                // GPS IFD
                if let parsed = try? ExifReader.readFromTIFF(data: child.data) {
                    gpsIFD = parsed.ifd0
                }
            case "THMB":
                // Thumbnail: version(4) + width(2) + height(2) + jpegSize(4) + padding(2) + JPEG data
                thumbnail = extractImageData(from: child.data)
            default:
                break // CNCV, CCTP, CTBO, etc. — not needed for metadata
            }
        }

        guard ifd0 != nil || exifIFD != nil else { return (nil, thumbnail) }

        var exifData = ExifData(byteOrder: byteOrder)
        exifData.ifd0 = ifd0
        exifData.exifIFD = exifIFD
        exifData.gpsIFD = gpsIFD

        // Attach MakerNotes as raw data to ExifIFD if available
        if let makerNote = makerNoteIFD {
            // Store MakerNote IFD entries in exifIFD would lose structure;
            // instead, we keep a reference that the MakerNote reader can access
            exifData.makerNoteIFD = makerNote
        }

        return (exifData, thumbnail)
    }

    // MARK: - Preview Container

    /// Parse the Canon preview UUID container containing PRVW box.
    private static func parsePreviewContainer(_ data: Data) throws -> Data? {
        let children = try ISOBMFFBoxReader.parseBoxes(from: data)
        guard let prvw = children.first(where: { $0.type == "PRVW" }) else { return nil }
        return extractImageData(from: prvw.data)
    }

    /// Extract JPEG data from a THMB or PRVW box payload.
    /// Format: version(4) + width(2) + height(2) + jpegSize(4) + padding(2) + JPEG data
    private static func extractImageData(from data: Data) -> Data? {
        guard data.count > 14 else { return nil }
        var reader = BinaryReader(data: data)
        do {
            _ = try reader.readUInt32BigEndian() // version
            _ = try reader.readUInt16BigEndian() // width
            _ = try reader.readUInt16BigEndian() // height
            let jpegSize = try reader.readUInt32BigEndian()
            _ = try reader.readUInt16BigEndian() // padding
            guard Int(jpegSize) > 0 && reader.offset + Int(jpegSize) <= data.count else { return nil }
            return try reader.readBytes(Int(jpegSize))
        } catch {
            return nil
        }
    }

    // MARK: - Top-Level Box Parsing (skip mdat)

    /// Parse top-level boxes, skipping mdat payload to avoid loading gigabytes of image data.
    private static func parseTopLevelBoxes(_ data: Data) throws -> [ISOBMFFBox] {
        var reader = BinaryReader(data: data)
        var boxes: [ISOBMFFBox] = []

        while !reader.isAtEnd && reader.remainingCount >= 8 {
            let boxStart = reader.offset
            let size32 = try reader.readUInt32BigEndian()
            let typeBytes = try reader.readBytes(4)
            guard let type = String(data: typeBytes, encoding: .isoLatin1) else { break }

            let payloadSize: Int
            let headerSize: Int
            if size32 == 1 {
                let size64 = try reader.readUInt64BigEndian()
                guard size64 >= 16 else { break }
                payloadSize = Int(size64) - 16
                headerSize = 16
            } else if size32 == 0 {
                payloadSize = data.count - reader.offset
                headerSize = 8
            } else {
                guard size32 >= 8 else { break }
                payloadSize = Int(size32) - 8
                headerSize = 8
            }

            guard payloadSize >= 0 && reader.offset + payloadSize <= data.count else { break }

            if type == "mdat" {
                // Skip mdat payload — can be gigabytes of raw image data
                boxes.append(ISOBMFFBox(type: "mdat", data: Data()))
                try reader.seek(to: reader.offset + payloadSize)
            } else {
                let payload = try reader.readBytes(payloadSize)
                boxes.append(ISOBMFFBox(type: type, data: payload))
            }

            // Ensure we advance
            let expectedEnd = boxStart + headerSize + payloadSize
            if expectedEnd > reader.offset {
                try reader.seek(to: min(expectedEnd, data.count))
            }
        }

        return boxes
    }
}
