import Foundation

/// An ISO Base Media File Format box (used by JPEG XL and AVIF).
public struct ISOBMFFBox: Sendable, Equatable {
    /// 4-character ASCII box type (e.g. "Exif", "xml ", "ftyp").
    public let type: String
    /// Box payload data (not including the size + type header).
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// Serialize ISOBMFF boxes.
public struct ISOBMFFBoxWriter {

    /// Write a single box (size + type + payload).
    public static func writeBox(_ writer: inout BinaryWriter, box: ISOBMFFBox) {
        let boxSize = UInt32(8 + box.data.count)
        writer.writeUInt32BigEndian(boxSize)
        writer.writeString(box.type, encoding: .ascii)
        writer.writeBytes(box.data)
    }

    /// Write a sequence of boxes.
    public static func writeBoxes(_ writer: inout BinaryWriter, boxes: [ISOBMFFBox]) {
        for box in boxes {
            writeBox(&writer, box: box)
        }
    }

    /// Serialize a sequence of boxes to Data.
    public static func serialize(boxes: [ISOBMFFBox]) -> Data {
        var writer = BinaryWriter(capacity: boxes.reduce(0) { $0 + 8 + $1.data.count })
        writeBoxes(&writer, boxes: boxes)
        return writer.data
    }
}

/// Parse ISOBMFF box sequences.
public struct ISOBMFFBoxReader {

    /// Parse a flat sequence of top-level boxes from the given data.
    public static func parseBoxes(from data: Data) throws -> [ISOBMFFBox] {
        var reader = BinaryReader(data: data)
        return try parseBoxes(from: &reader, limit: data.count)
    }

    /// Parse boxes from a BinaryReader up to the given byte limit.
    public static func parseBoxes(from reader: inout BinaryReader, limit: Int) throws -> [ISOBMFFBox] {
        var boxes: [ISOBMFFBox] = []
        let endOffset = reader.offset + limit

        while reader.offset < endOffset && !reader.isAtEnd {
            let boxStart = reader.offset
            guard reader.remainingCount >= 8 else { break }

            let size32 = try reader.readUInt32BigEndian()
            let typeBytes = try reader.readBytes(4)
            guard let type = String(data: typeBytes, encoding: .ascii) else {
                break
            }

            let payloadSize: Int
            if size32 == 1 {
                // Extended size (UInt64)
                let size64 = try reader.readUInt64BigEndian()
                guard size64 >= 16 else { break } // Header is 16 bytes minimum
                payloadSize = Int(size64) - 16 // 16 = 4 (size32) + 4 (type) + 8 (size64)
            } else if size32 == 0 {
                // Box extends to end of data
                payloadSize = endOffset - reader.offset
            } else {
                guard size32 >= 8 else { break } // Header is 8 bytes minimum
                payloadSize = Int(size32) - 8 // 8 = 4 (size32) + 4 (type)
            }

            guard payloadSize >= 0 && reader.offset + payloadSize <= endOffset else {
                break
            }

            let payload = try reader.readBytes(payloadSize)
            boxes.append(ISOBMFFBox(type: type, data: payload))

            // Ensure we advance past the box (handles padding)
            if size32 > 0 && size32 != 1 {
                let expectedEnd = boxStart + Int(size32)
                if expectedEnd > reader.offset && expectedEnd <= endOffset {
                    try reader.seek(to: expectedEnd)
                }
            }
        }

        return boxes
    }
}
