import Foundation

/// Serialize modified MakerNote data back to binary format.
/// Each manufacturer has a specific header and IFD layout that must be reconstructed.
public struct MakerNoteWriter: Sendable {

    /// Write a MakerNote back to binary data.
    /// If not dirty, returns the original rawData unchanged.
    public static func write(_ makerNote: MakerNoteData, byteOrder: ByteOrder) -> Data {
        guard makerNote.isDirty else { return makerNote.rawData }

        switch makerNote.manufacturer {
        case .canon:
            return writeCanon(makerNote, byteOrder: byteOrder)
        case .nikon:
            return writeNikon(makerNote, byteOrder: byteOrder)
        case .sony:
            return writeSony(makerNote, byteOrder: byteOrder)
        case .fujifilm:
            return writeFujifilm(makerNote)
        case .olympus:
            return writeOlympus(makerNote, byteOrder: byteOrder)
        case .panasonic:
            return writePanasonic(makerNote, byteOrder: byteOrder)
        case .unknown:
            return makerNote.rawData
        }
    }

    // MARK: - Canon

    /// Canon: Direct IFD at offset 0, parent byte order, offsets from MakerNote start.
    private static func writeCanon(_ makerNote: MakerNoteData, byteOrder: ByteOrder) -> Data {
        guard let entries = reparse(makerNote.rawData, tiffStart: 0, ifdOffset: 0, endian: byteOrder) else {
            return makerNote.rawData
        }
        let updated = applyTagChanges(entries: entries, tags: makerNote.tags, endian: byteOrder, tagMap: canonTagMap)
        return serializeIFD(entries: updated, endian: byteOrder, headerData: Data(), tiffStart: 0)
    }

    // MARK: - Nikon

    /// Nikon: "Nikon\0" (6B) + version (2B) + embedded TIFF header (8B) + IFD.
    private static func writeNikon(_ makerNote: MakerNoteData, byteOrder: ByteOrder) -> Data {
        let rawData = makerNote.rawData
        guard rawData.count > 18 else { return rawData }

        let tiffStart = 10

        // Read embedded byte order
        let bom0 = rawData[rawData.startIndex + tiffStart]
        let bom1 = rawData[rawData.startIndex + tiffStart + 1]
        let endian: ByteOrder
        if bom0 == 0x4D && bom1 == 0x4D {
            endian = .bigEndian
        } else {
            endian = .littleEndian
        }

        // Read IFD offset from embedded TIFF header
        var reader = BinaryReader(data: rawData)
        guard (try? reader.seek(to: tiffStart + 4)) != nil,
              let ifdOffset = try? reader.readUInt32(endian: endian) else { return rawData }

        let absoluteIFDOffset = tiffStart + Int(ifdOffset)
        guard let entries = reparse(rawData, tiffStart: tiffStart, ifdOffset: absoluteIFDOffset, endian: endian) else {
            return rawData
        }
        let updated = applyTagChanges(entries: entries, tags: makerNote.tags, endian: endian, tagMap: nikonTagMap)

        // Build full header: Nikon prefix (10B) + embedded TIFF header (8B) = 18B
        var fullHeader = BinaryWriter(capacity: 18)
        fullHeader.writeBytes(rawData.prefix(10)) // "Nikon\0" + version + padding
        if endian == .bigEndian {
            fullHeader.writeBytes([0x4D, 0x4D])
        } else {
            fullHeader.writeBytes([0x49, 0x49])
        }
        fullHeader.writeUInt16(0x002A, endian: endian)
        fullHeader.writeUInt32(8, endian: endian) // IFD at offset 8 from TIFF header

        return serializeIFD(entries: updated, endian: endian, headerData: fullHeader.data, tiffStart: tiffStart)
    }

    // MARK: - Sony

    /// Sony: optional 12-byte prefix + IFD.
    private static func writeSony(_ makerNote: MakerNoteData, byteOrder: ByteOrder) -> Data {
        let rawData = makerNote.rawData
        let prefixes = [
            Data([0x53, 0x4F, 0x4E, 0x59, 0x20, 0x44, 0x53, 0x43, 0x20, 0x00, 0x00, 0x00]), // "SONY DSC \0\0\0"
            Data([0x53, 0x4F, 0x4E, 0x59, 0x20, 0x43, 0x41, 0x4D, 0x20, 0x00, 0x00, 0x00]), // "SONY CAM \0\0\0"
        ]

        var header = Data()
        var ifdStart = 0
        for prefix in prefixes {
            if rawData.count > prefix.count && rawData.prefix(prefix.count) == prefix {
                header = Data(rawData.prefix(prefix.count))
                ifdStart = prefix.count
                break
            }
        }

        guard let entries = reparse(rawData, tiffStart: 0, ifdOffset: ifdStart, endian: byteOrder) else {
            return rawData
        }
        let updated = applyTagChanges(entries: entries, tags: makerNote.tags, endian: byteOrder, tagMap: sonyTagMap)
        return serializeIFD(entries: updated, endian: byteOrder, headerData: header, tiffStart: 0)
    }

    // MARK: - Fujifilm

    /// Fujifilm: "FUJIFILM" (8B) + LE 4-byte IFD offset, always little-endian.
    private static func writeFujifilm(_ makerNote: MakerNoteData) -> Data {
        let rawData = makerNote.rawData
        let endian = ByteOrder.littleEndian
        guard rawData.count > 12 else { return rawData }

        var reader = BinaryReader(data: rawData)
        guard (try? reader.seek(to: 8)) != nil,
              let ifdOffset = try? reader.readUInt32(endian: endian) else { return rawData }

        guard let entries = reparse(rawData, tiffStart: 0, ifdOffset: Int(ifdOffset), endian: endian) else {
            return rawData
        }
        let updated = applyTagChanges(entries: entries, tags: makerNote.tags, endian: endian, tagMap: fujifilmTagMap)

        // Build header: "FUJIFILM" (8B) + LE IFD offset (4B) = 12B
        var fullHeader = BinaryWriter(capacity: 12)
        fullHeader.writeBytes(rawData.prefix(8)) // "FUJIFILM"
        fullHeader.writeUInt32(12, endian: endian) // IFD at offset 12

        return serializeIFD(entries: updated, endian: endian, headerData: fullHeader.data, tiffStart: 0)
    }

    // MARK: - Olympus

    /// Olympus: "OLYMP\0" (6B) + version (2B), or "OLYMPUS\0" (8B) + byte order + version.
    private static func writeOlympus(_ makerNote: MakerNoteData, byteOrder: ByteOrder) -> Data {
        let rawData = makerNote.rawData
        let olympNew = Data([0x4F, 0x4C, 0x59, 0x4D, 0x50, 0x55, 0x53, 0x00]) // "OLYMPUS\0"
        let olympOld = Data([0x4F, 0x4C, 0x59, 0x4D, 0x50, 0x00])             // "OLYMP\0"

        var header: Data
        var endian = byteOrder
        var ifdStart: Int

        if rawData.count > 12 && rawData.prefix(8) == olympNew {
            // New format: "OLYMPUS\0" + 2-byte byte order + 2-byte version
            header = Data(rawData.prefix(12))
            let bom0 = rawData[rawData.startIndex + 8]
            if bom0 == 0x49 { endian = .littleEndian } else { endian = .bigEndian }
            ifdStart = 12
        } else if rawData.count > 8 && rawData.prefix(6) == olympOld {
            // Old format: "OLYMP\0" + 2 version bytes
            header = Data(rawData.prefix(8))
            ifdStart = 8
        } else {
            return rawData
        }

        guard let entries = reparse(rawData, tiffStart: 0, ifdOffset: ifdStart, endian: endian) else {
            return rawData
        }
        let updated = applyTagChanges(entries: entries, tags: makerNote.tags, endian: endian, tagMap: olympusTagMap)
        return serializeIFD(entries: updated, endian: endian, headerData: header, tiffStart: 0)
    }

    // MARK: - Panasonic

    /// Panasonic: "Panasonic\0\0\0" (12B) + IFD.
    private static func writePanasonic(_ makerNote: MakerNoteData, byteOrder: ByteOrder) -> Data {
        let rawData = makerNote.rawData
        let prefix = Data([0x50, 0x61, 0x6E, 0x61, 0x73, 0x6F, 0x6E, 0x69, 0x63, 0x00, 0x00, 0x00])

        guard rawData.count > prefix.count && rawData.prefix(prefix.count) == prefix else {
            return rawData
        }

        let header = Data(rawData.prefix(prefix.count))
        guard let entries = reparse(rawData, tiffStart: 0, ifdOffset: prefix.count, endian: byteOrder) else {
            return rawData
        }
        let updated = applyTagChanges(entries: entries, tags: makerNote.tags, endian: byteOrder, tagMap: panasonicTagMap)
        return serializeIFD(entries: updated, endian: byteOrder, headerData: header, tiffStart: 0)
    }

    // MARK: - Shared Helpers

    /// Re-parse the raw MakerNote data to recover the full IFD entries.
    private static func reparse(_ data: Data, tiffStart: Int, ifdOffset: Int, endian: ByteOrder) -> [IFDEntry]? {
        guard let (ifd, _) = try? IFDParser.parseIFD(data: data, tiffStart: tiffStart, offset: ifdOffset, endian: endian) else {
            return nil
        }
        return ifd.entries
    }

    /// Apply tag modifications to the IFD entries.
    private static func applyTagChanges(
        entries: [IFDEntry],
        tags: [String: MakerNoteValue],
        endian: ByteOrder,
        tagMap: [String: UInt16]
    ) -> [IFDEntry] {
        var result = entries
        for (name, value) in tags {
            guard let tagId = tagMap[name] else { continue }

            // Build new value data
            let (newData, type, count) = encodeValue(value, endian: endian)

            // Find and replace existing entry
            if let idx = result.firstIndex(where: { $0.tag == tagId }) {
                result[idx] = IFDEntry(tag: tagId, type: type, count: count, valueData: newData)
            }
            // Note: we don't add new entries that didn't exist in the original IFD
        }
        return result
    }

    /// Encode a MakerNoteValue into binary data for an IFD entry.
    private static func encodeValue(_ value: MakerNoteValue, endian: ByteOrder) -> (Data, TIFFDataType, UInt32) {
        switch value {
        case .string(let s):
            var data = Data(s.utf8)
            data.append(0x00) // null terminator
            return (data, .ascii, UInt32(data.count))
        case .int(let i):
            if i >= 0 && i <= UInt16.max {
                var w = BinaryWriter(capacity: 2)
                w.writeUInt16(UInt16(i), endian: endian)
                return (w.data, .short, 1)
            } else {
                var w = BinaryWriter(capacity: 4)
                w.writeUInt32(UInt32(bitPattern: Int32(i)), endian: endian)
                return (w.data, .long, 1)
            }
        case .uint(let u):
            if u <= UInt16.max {
                var w = BinaryWriter(capacity: 2)
                w.writeUInt16(UInt16(u), endian: endian)
                return (w.data, .short, 1)
            } else {
                var w = BinaryWriter(capacity: 4)
                w.writeUInt32(UInt32(u), endian: endian)
                return (w.data, .long, 1)
            }
        case .double:
            // Store as string representation
            return encodeValue(.string(String(format: "%.6f", 0)), endian: endian)
        case .data(let d):
            return (d, .undefined, UInt32(d.count))
        case .intArray(let arr):
            var w = BinaryWriter(capacity: arr.count * 2)
            for v in arr {
                w.writeUInt16(UInt16(clamping: v), endian: endian)
            }
            return (w.data, .short, UInt32(arr.count))
        }
    }

    /// Serialize IFD entries to binary, prefixed by optional header data.
    /// `tiffStart` is the position within the output where the TIFF header lives.
    /// IFD entry offsets are relative to `tiffStart` (the parser adds tiffStart to resolve).
    private static func serializeIFD(entries: [IFDEntry], endian: ByteOrder, headerData: Data, tiffStart: Int) -> Data {
        var writer = BinaryWriter(capacity: headerData.count + 256)
        writer.writeBytes(headerData)

        // dataOffset must be relative to tiffStart, since the parser resolves: tiffStart + offset
        let absoluteDataPos = headerData.count + 2 + entries.count * 12 + 4
        let dataOffset = absoluteDataPos - tiffStart
        ExifWriter.writeIFD(&writer, entries: entries.sorted { $0.tag < $1.tag },
                            endian: endian, dataOffset: dataOffset, nextIFDOffset: 0, tiffStart: tiffStart)

        return writer.data
    }

    // MARK: - Tag Name → ID Maps

    private static let canonTagMap: [String: UInt16] = [
        "SerialNumber": 0x0006,
        "FirmwareVersion": 0x0007,
        "LensModel": 0x0095,
        "ModelID": 0x0010,
    ]

    private static let nikonTagMap: [String: UInt16] = [
        "SerialNumber": 0x001D,
        "ShutterCount": 0x00A7,
        "LensType": 0x0083,
        "InternalSerialNumber": 0x00D0,
    ]

    private static let sonyTagMap: [String: UInt16] = [
        "SerialNumber": 0x00B0,
        "LensType": 0x00B1,
        "Quality": 0x0102,
    ]

    private static let fujifilmTagMap: [String: UInt16] = [
        "SerialNumber": 0x0010,
        "Quality": 0x1000,
        "Sharpness": 0x1001,
        "FilmMode": 0x1401,
    ]

    private static let olympusTagMap: [String: UInt16] = [
        "CameraID": 0x0209,
        "Quality": 0x0201,
    ]

    private static let panasonicTagMap: [String: UInt16] = [
        "InternalSerialNumber": 0x0025,
        "LensSerialNumber": 0x0052,
        "LensType": 0x0051,
    ]
}
