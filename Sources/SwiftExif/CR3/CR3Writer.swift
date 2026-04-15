import Foundation

/// Writes modified metadata back to CR3 files.
public struct CR3Writer: Sendable {

    /// Rebuild a CR3 file with updated Exif and XMP metadata.
    /// Preserves all non-metadata boxes (ftyp, mdat, etc.) and rebuilds moov with updated CMT boxes.
    public static func write(
        _ file: CR3File,
        exif: ExifData?,
        xmp: XMPData?,
        originalData: Data
    ) throws -> Data {
        // Re-parse top-level boxes from original data to get full content (including mdat)
        var writer = BinaryWriter(capacity: originalData.count)
        var originalReader = BinaryReader(data: originalData)

        while !originalReader.isAtEnd && originalReader.remainingCount >= 8 {
            let boxStart = originalReader.offset
            let size32 = try originalReader.readUInt32BigEndian()
            let typeBytes = try originalReader.readBytes(4)
            guard let type = String(data: typeBytes, encoding: .isoLatin1) else { break }

            let payloadSize: Int
            let headerSize: Int
            if size32 == 1 {
                let size64 = try originalReader.readUInt64BigEndian()
                guard size64 >= 16 else { break }
                payloadSize = Int(size64) - 16
                headerSize = 16
            } else if size32 == 0 {
                payloadSize = originalData.count - originalReader.offset
                headerSize = 8
            } else {
                guard size32 >= 8 else { break }
                payloadSize = Int(size32) - 8
                headerSize = 8
            }

            guard payloadSize >= 0 && originalReader.offset + payloadSize <= originalData.count else { break }

            switch type {
            case "moov":
                // Rebuild moov with updated metadata
                let originalMoovPayload = try originalReader.readBytes(payloadSize)
                let updatedMoov = try rebuildMoov(Data(originalMoovPayload), exif: exif)
                ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: "moov", data: updatedMoov))

            case "uuid":
                // Check if this is the XMP UUID box
                let payload = try originalReader.readBytes(payloadSize)
                if payload.count >= 16 && Data(payload.prefix(16)) == CR3UUID.xmpUUID && xmp != nil {
                    // Replace XMP
                    let xmpXML = XMPWriter.generateXML(xmp!)
                    var xmpPayload = Data(CR3UUID.xmpUUID)
                    xmpPayload.append(Data(xmpXML.utf8))
                    ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: "uuid", data: xmpPayload))
                } else {
                    // Preserve other uuid boxes
                    ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: "uuid", data: payload))
                }

            default:
                // Copy box verbatim (ftyp, mdat, etc.)
                let payload = try originalReader.readBytes(payloadSize)
                if size32 == 1 {
                    // Extended size box
                    writer.writeUInt32BigEndian(1)
                    writer.writeBytes(typeBytes)
                    writer.writeUInt64BigEndian(UInt64(16 + payload.count))
                    writer.writeBytes(payload)
                } else {
                    writer.writeUInt32BigEndian(UInt32(8 + payload.count))
                    writer.writeBytes(typeBytes)
                    writer.writeBytes(payload)
                }
            }

            // Advance if needed
            let expectedEnd = boxStart + headerSize + payloadSize
            if expectedEnd > originalReader.offset {
                try originalReader.seek(to: min(expectedEnd, originalData.count))
            }
        }

        // If XMP didn't exist before but now does, append new XMP uuid box
        if let xmp, !file.boxes.contains(where: { box in
            box.type == "uuid" && box.data.count >= 16 && Data(box.data.prefix(16)) == CR3UUID.xmpUUID
        }) {
            let xmpXML = XMPWriter.generateXML(xmp)
            var xmpPayload = Data(CR3UUID.xmpUUID)
            xmpPayload.append(Data(xmpXML.utf8))
            ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: "uuid", data: xmpPayload))
        }

        return writer.data
    }

    // MARK: - Private

    /// Rebuild moov box with updated CMT1-4 metadata.
    private static func rebuildMoov(_ moovData: Data, exif: ExifData?) throws -> Data {
        let children = try ISOBMFFBoxReader.parseBoxes(from: moovData)
        var outputWriter = BinaryWriter(capacity: moovData.count)

        for child in children {
            if child.type == "uuid" && child.data.count >= 16 {
                let uuid = child.data.prefix(16)
                if uuid == CR3UUID.canonMetadata, let exif {
                    // Rebuild Canon metadata container with updated CMT boxes
                    let updatedPayload = try rebuildCanonMetadata(Data(child.data.dropFirst(16)), exif: exif)
                    var uuidPayload = Data(CR3UUID.canonMetadata)
                    uuidPayload.append(updatedPayload)
                    ISOBMFFBoxWriter.writeBox(&outputWriter, box: ISOBMFFBox(type: "uuid", data: uuidPayload))
                } else {
                    // Preserve other uuid boxes (e.g., preview container)
                    ISOBMFFBoxWriter.writeBox(&outputWriter, box: child)
                }
            } else {
                // Preserve non-uuid moov children (trak, mvhd, etc.)
                ISOBMFFBoxWriter.writeBox(&outputWriter, box: child)
            }
        }

        return outputWriter.data
    }

    /// Rebuild Canon metadata container with updated CMT1-4 boxes.
    private static func rebuildCanonMetadata(_ data: Data, exif: ExifData) throws -> Data {
        let children = try ISOBMFFBoxReader.parseBoxes(from: data)
        var outputWriter = BinaryWriter(capacity: data.count)
        var wroteGPS = false

        for child in children {
            switch child.type {
            case "CMT1":
                if let ifd0 = exif.ifd0 {
                    let tiffData = ExifWriter.writeTIFF(ExifData.withIFD(ifd0, byteOrder: exif.byteOrder))
                    ISOBMFFBoxWriter.writeBox(&outputWriter, box: ISOBMFFBox(type: "CMT1", data: tiffData))
                } else {
                    ISOBMFFBoxWriter.writeBox(&outputWriter, box: child)
                }
            case "CMT2":
                if let exifIFD = exif.exifIFD {
                    let tiffData = ExifWriter.writeTIFF(ExifData.withIFD(exifIFD, byteOrder: exif.byteOrder))
                    ISOBMFFBoxWriter.writeBox(&outputWriter, box: ISOBMFFBox(type: "CMT2", data: tiffData))
                } else {
                    ISOBMFFBoxWriter.writeBox(&outputWriter, box: child)
                }
            case "CMT4":
                wroteGPS = true
                if let gpsIFD = exif.gpsIFD {
                    let tiffData = ExifWriter.writeTIFF(ExifData.withIFD(gpsIFD, byteOrder: exif.byteOrder))
                    ISOBMFFBoxWriter.writeBox(&outputWriter, box: ISOBMFFBox(type: "CMT4", data: tiffData))
                } else {
                    ISOBMFFBoxWriter.writeBox(&outputWriter, box: child)
                }
            default:
                // Preserve CMT3 (MakerNotes), CNCV, CCTP, CTBO, THMB, etc.
                ISOBMFFBoxWriter.writeBox(&outputWriter, box: child)
            }
        }

        // Add CMT4 if GPS was added but didn't exist in original
        if !wroteGPS, let gpsIFD = exif.gpsIFD {
            let tiffData = ExifWriter.writeTIFF(ExifData.withIFD(gpsIFD, byteOrder: exif.byteOrder))
            ISOBMFFBoxWriter.writeBox(&outputWriter, box: ISOBMFFBox(type: "CMT4", data: tiffData))
        }

        return outputWriter.data
    }
}

// MARK: - ExifData Helper

extension ExifData {
    /// Create a minimal ExifData with a single IFD as ifd0 for writing to a CMT box.
    static func withIFD(_ ifd: IFD, byteOrder: ByteOrder) -> ExifData {
        var data = ExifData(byteOrder: byteOrder)
        data.ifd0 = ifd
        return data
    }
}
