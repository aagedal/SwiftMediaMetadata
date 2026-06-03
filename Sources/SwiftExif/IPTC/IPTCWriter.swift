import Foundation

/// Serialize IPTCData to binary format.
public struct IPTCWriter: Sendable {

    /// Serialize IPTCData to raw IPTC binary data.
    /// Always outputs UTF-8 encoded data, converting from legacy encodings if needed.
    /// Fields exceeding their IPTC spec max length are preserved as-is (any over-length
    /// warnings produced internally are discarded). Use the `warnings:` overload to
    /// surface them, or call `IPTCData.validate()` to reject them up front.
    public static func write(_ iptcData: IPTCData) throws -> Data {
        var warnings: [String] = []
        return try write(iptcData, warnings: &warnings)
    }

    /// Serialize IPTCData to raw IPTC binary data, collecting non-fatal warnings.
    /// Always outputs UTF-8 encoded data, converting from legacy encodings if needed.
    /// Over-length fields are written as-is and reported via `warnings` rather than
    /// throwing, so re-serializing an already-over-spec file does not fail.
    public static func write(_ iptcData: IPTCData, warnings: inout [String]) throws -> Data {
        // Convert to UTF-8 if the source data is in a legacy encoding
        let outputData: IPTCData
        if iptcData.encoding != .utf8 {
            outputData = try convertToUTF8(iptcData)
        } else {
            outputData = iptcData
        }

        warnings.append(contentsOf: outputData.maxLengthWarnings())

        var writer = BinaryWriter(capacity: 1024)

        // Determine if we need to write CodedCharacterSet (1:90)
        let needsCharsetTag = containsNonASCII(outputData)

        // Write Record 1:90 CodedCharacterSet for UTF-8
        if needsCharsetTag {
            // Only write if not already present in datasets
            if !outputData.datasets.contains(where: { $0.tag == .codedCharacterSet }) {
                writeDataSet(&writer, record: 1, dataSet: 90,
                             data: Data(IPTCReader.utf8EscapeSequence))
            }
        }

        // Write datasets in order
        for ds in outputData.datasets {
            // Skip any existing CodedCharacterSet that isn't UTF-8 (we wrote the correct one above)
            if ds.tag == .codedCharacterSet { continue }
            writeDataSet(&writer, record: ds.tag.record, dataSet: ds.tag.dataSet, data: ds.rawValue)
        }

        return writer.data
    }

    /// Convert IPTCData from a legacy encoding to UTF-8.
    private static func convertToUTF8(_ iptcData: IPTCData) throws -> IPTCData {
        let sourceEncoding = iptcData.encoding
        var converted: [IPTCDataSet] = []

        for ds in iptcData.datasets {
            if ds.tag == .codedCharacterSet {
                // Will be replaced with UTF-8 marker
                continue
            }

            if ds.tag.dataType == .string || ds.tag.dataType == .digits {
                // Decode from source encoding, re-encode as UTF-8
                guard let str = String(data: ds.rawValue, encoding: sourceEncoding) else {
                    throw MetadataError.encodingError(
                        "Cannot decode tag \(ds.tag.name) from \(sourceEncoding)")
                }
                guard let utf8Data = str.data(using: .utf8) else {
                    throw MetadataError.encodingError(
                        "Cannot re-encode tag \(ds.tag.name) value as UTF-8")
                }
                converted.append(IPTCDataSet(tag: ds.tag, rawValue: utf8Data))
            } else {
                // Binary data — keep as-is
                converted.append(ds)
            }
        }

        return IPTCData(datasets: converted, encoding: .utf8)
    }

    /// Write IPTCData into an APP13 segment payload.
    /// If existingAPP13 is provided, replaces the IPTC resource while preserving others.
    public static func writeToAPP13(_ iptcData: IPTCData, existingAPP13: Data? = nil) throws -> Data {
        var warnings: [String] = []
        return try writeToAPP13(iptcData, existingAPP13: existingAPP13, warnings: &warnings)
    }

    /// Write IPTCData into an APP13 segment payload, collecting non-fatal warnings.
    public static func writeToAPP13(_ iptcData: IPTCData, existingAPP13: Data? = nil,
                                    warnings: inout [String]) throws -> Data {
        let iptcBinary = try write(iptcData, warnings: &warnings)

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
