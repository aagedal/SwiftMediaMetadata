import Foundation

/// Parse raw IPTC binary data into an IPTCData collection.
public struct IPTCReader {
    /// The UTF-8 CodedCharacterSet escape sequence: ESC % G
    static let utf8EscapeSequence: [UInt8] = [0x1B, 0x25, 0x47]

    /// Parse raw IPTC binary data (the content of 8BIM resource 0x0404) into IPTCData.
    public static func read(from data: Data) throws -> IPTCData {
        var reader = BinaryReader(data: data)
        var datasets: [IPTCDataSet] = []
        var encoding: String.Encoding = .isoLatin1 // Default per IPTC spec

        while !reader.isAtEnd {
            // Each dataset starts with 0x1C tag marker
            let marker = try reader.readUInt8()
            guard marker == 0x1C else {
                throw MetadataError.invalidIPTCData("Expected 0x1C tag marker, got 0x\(String(marker, radix: 16))")
            }

            let record = try reader.readUInt8()
            let dataSet = try reader.readUInt8()

            // Read length (2 bytes, big-endian)
            let lengthRaw = try reader.readUInt16BigEndian()

            let length: Int
            if lengthRaw & 0x8000 != 0 {
                // Extended length: lower 15 bits = number of bytes encoding the actual length
                let extLengthBytes = Int(lengthRaw & 0x7FFF)
                if extLengthBytes == 4 {
                    length = Int(try reader.readUInt32BigEndian())
                } else if extLengthBytes == 2 {
                    length = Int(try reader.readUInt16BigEndian())
                } else {
                    throw MetadataError.invalidIPTCData("Unsupported extended length size: \(extLengthBytes)")
                }
            } else {
                length = Int(lengthRaw)
            }

            let valueData = try reader.readBytes(length)
            let tag = IPTCTag(record: record, dataSet: dataSet)

            // Check for CodedCharacterSet (1:90)
            if tag == .codedCharacterSet {
                if valueData.count >= 3,
                   valueData[valueData.startIndex] == 0x1B,
                   valueData[valueData.startIndex + 1] == 0x25,
                   valueData[valueData.startIndex + 2] == 0x47 {
                    encoding = .utf8
                }
            }

            datasets.append(IPTCDataSet(tag: tag, rawValue: valueData))
        }

        return IPTCData(datasets: datasets, encoding: encoding)
    }

    /// Read IPTC data from an APP13 segment payload.
    public static func readFromAPP13(_ app13Data: Data) throws -> IPTCData {
        guard let iptcData = try PhotoshopIRB.extractIPTCData(app13Data) else {
            return IPTCData() // No IPTC resource found
        }
        return try read(from: iptcData)
    }
}
