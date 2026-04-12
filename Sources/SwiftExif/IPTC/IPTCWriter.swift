import Foundation

/// Serialize IPTCData to binary format.
public struct IPTCWriter {

    /// Serialize IPTCData to raw IPTC binary data.
    public static func write(_ iptcData: IPTCData) -> Data {
        var writer = BinaryWriter(capacity: 1024)
        let encoding = iptcData.encoding

        // Determine if we need to write CodedCharacterSet (1:90)
        let needsCharsetTag = containsNonASCII(iptcData) && encoding == .utf8

        // Write Record 1:90 CodedCharacterSet if needed
        if needsCharsetTag {
            // Only write if not already present in datasets
            if !iptcData.datasets.contains(where: { $0.tag == .codedCharacterSet }) {
                writeDataSet(&writer, record: 1, dataSet: 90,
                             data: Data(IPTCReader.utf8EscapeSequence))
            }
        }

        // Write datasets in order
        for ds in iptcData.datasets {
            writeDataSet(&writer, record: ds.tag.record, dataSet: ds.tag.dataSet, data: ds.rawValue)
        }

        return writer.data
    }

    /// Write IPTCData into an APP13 segment payload.
    /// If existingAPP13 is provided, replaces the IPTC resource while preserving others.
    public static func writeToAPP13(_ iptcData: IPTCData, existingAPP13: Data? = nil) throws -> Data {
        let iptcBinary = write(iptcData)

        if let existing = existingAPP13 {
            return try PhotoshopIRB.replaceIPTCData(in: existing, with: iptcBinary)
        } else {
            // Build new APP13 from scratch
            return PhotoshopIRB.write(blocks: [
                IRBBlock(resourceID: PhotoshopIRB.iptcResourceID, data: iptcBinary)
            ])
        }
    }

    // MARK: - Private

    private static func writeDataSet(_ writer: inout BinaryWriter, record: UInt8, dataSet: UInt8, data: Data) {
        writer.writeUInt8(0x1C) // Tag marker
        writer.writeUInt8(record)
        writer.writeUInt8(dataSet)

        if data.count > 32767 {
            // Extended length: set bit 15, then 4 bytes for actual length
            writer.writeUInt16BigEndian(0x8004)
            writer.writeUInt32BigEndian(UInt32(data.count))
        } else {
            writer.writeUInt16BigEndian(UInt16(data.count))
        }

        writer.writeBytes(data)
    }

    private static func containsNonASCII(_ iptcData: IPTCData) -> Bool {
        for ds in iptcData.datasets {
            if ds.tag.dataType == .string || ds.tag.dataType == .digits {
                for byte in ds.rawValue {
                    if byte > 127 { return true }
                }
            }
        }
        return false
    }
}
