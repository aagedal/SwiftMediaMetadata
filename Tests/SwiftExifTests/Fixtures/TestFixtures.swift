import Foundation
@testable import SwiftExif

/// Helpers for generating test data programmatically.
enum TestFixtures {

    // MARK: - Nordic Test Strings

    static let nordicStrings = [
        "Tromsø, Norge",
        "Ærø Kommune",
        "Østfold fylke",
        "Ålesund havn",
        "Björk Guðmundsdóttir",
        "Järvenpää, Suomi",
        "Malmö, Sverige",
        "Ísafjörður",
        "Søren Kierkegård",
        "Ångström",
    ]

    // MARK: - Minimal JPEG

    /// Generate a minimal valid JPEG: SOI + APP0 (JFIF) + minimal scan + EOI.
    static func minimalJPEG() -> Data {
        var writer = BinaryWriter(capacity: 128)

        // SOI
        writer.writeUInt16BigEndian(JPEGMarker.soi.rawValue)

        // Minimal APP0 (JFIF header)
        let jfifHeader = Data([
            0x4A, 0x46, 0x49, 0x46, 0x00,  // "JFIF\0"
            0x01, 0x01,                       // Version 1.1
            0x00,                             // Aspect ratio units: no units
            0x00, 0x01,                       // X density: 1
            0x00, 0x01,                       // Y density: 1
            0x00, 0x00,                       // Thumbnail: 0x0
        ])
        writer.writeUInt16BigEndian(JPEGMarker.app0.rawValue)
        writer.writeUInt16BigEndian(UInt16(jfifHeader.count + 2))
        writer.writeBytes(jfifHeader)

        // DQT (minimal quantization table)
        var dqtData = Data([0x00]) // Table 0, 8-bit precision
        dqtData.append(contentsOf: [UInt8](repeating: 1, count: 64))
        writer.writeUInt16BigEndian(JPEGMarker.dqt.rawValue)
        writer.writeUInt16BigEndian(UInt16(dqtData.count + 2))
        writer.writeBytes(dqtData)

        // SOF0 (1x1 pixel, 1 component, grayscale)
        let sofData = Data([
            0x08,       // Precision: 8 bits
            0x00, 0x01, // Height: 1
            0x00, 0x01, // Width: 1
            0x01,       // Components: 1
            0x01,       // Component ID: 1
            0x11,       // Sampling: 1x1
            0x00,       // Quantization table: 0
        ])
        writer.writeUInt16BigEndian(JPEGMarker.sof0.rawValue)
        writer.writeUInt16BigEndian(UInt16(sofData.count + 2))
        writer.writeBytes(sofData)

        // DHT (minimal Huffman table for DC)
        var dhtData = Data([0x00]) // Class 0 (DC), Table 0
        // Counts for code lengths 1-16 (one code of length 1)
        dhtData.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] as [UInt8])
        dhtData.append(0x00) // Value: 0
        writer.writeUInt16BigEndian(JPEGMarker.dht.rawValue)
        writer.writeUInt16BigEndian(UInt16(dhtData.count + 2))
        writer.writeBytes(dhtData)

        // SOS (Start of Scan)
        let sosHeader = Data([
            0x01,       // Components: 1
            0x01, 0x00, // Component 1, DC table 0, AC table 0
            0x00, 0x3F, // Spectral selection: 0-63
            0x00,       // Successive approximation
        ])
        writer.writeUInt16BigEndian(JPEGMarker.sos.rawValue)
        writer.writeUInt16BigEndian(UInt16(sosHeader.count + 2))
        writer.writeBytes(sosHeader)

        // Minimal entropy-coded data (one MCU: DC=0)
        writer.writeBytes([0x7F, 0xFF, 0xD9]) // Padded data + EOI

        return writer.data
    }

    // MARK: - JPEG with IPTC

    /// Generate a JPEG with a pre-built APP13 containing IPTC data.
    static func jpegWithIPTC(datasets: [IPTCDataSet]) -> Data {
        let iptcBinary = IPTCWriter.write(IPTCData(datasets: datasets))
        let app13Data = buildAPP13(iptcData: iptcBinary)
        return jpegWithSegment(marker: .app13, data: app13Data)
    }

    /// Build an APP13 segment payload (Photoshop 3.0 header + 8BIM IPTC resource).
    static func buildAPP13(iptcData: Data) -> Data {
        var writer = BinaryWriter(capacity: iptcData.count + 40)

        // Photoshop 3.0 header
        writer.writeString("Photoshop 3.0", encoding: .ascii)
        writer.writeUInt8(0x00) // Null terminator

        // 8BIM resource for IPTC (resource ID 0x0404)
        writer.writeBytes([0x38, 0x42, 0x49, 0x4D]) // "8BIM"
        writer.writeUInt16BigEndian(0x0404) // Resource ID: IPTC-IIM
        writer.writeUInt16BigEndian(0x0000) // Pascal string: empty (length 0 + pad)
        writer.writeUInt32BigEndian(UInt32(iptcData.count))
        writer.writeBytes(iptcData)
        writer.padToEven()

        return writer.data
    }

    /// Create a minimal JPEG with a single extra metadata segment inserted.
    static func jpegWithSegment(marker: JPEGMarker, data: Data) -> Data {
        let base = minimalJPEG()
        // Parse, insert, rewrite
        guard var file = try? JPEGParser.parse(base) else {
            fatalError("Failed to parse minimal JPEG")
        }
        let segment = JPEGSegment(marker: marker, data: data)
        // Insert after APP0
        if let app0Index = file.segments.firstIndex(where: { $0.rawMarker == JPEGMarker.app0.rawValue }) {
            file.segments.insert(segment, at: app0Index + 1)
        } else {
            file.segments.insert(segment, at: 0)
        }
        return JPEGWriter.write(file)
    }

    // MARK: - Raw IPTC Binary Data

    /// Generate raw IPTC binary data for testing the reader directly.
    static func iptcBinaryData(datasets: [IPTCDataSet], includeUTF8Charset: Bool = true) -> Data {
        var iptcData = IPTCData(datasets: datasets)
        if !includeUTF8Charset {
            iptcData.removeAll(for: .codedCharacterSet)
        }
        return IPTCWriter.write(iptcData)
    }

    // MARK: - Exif APP1 Data

    /// Generate an Exif APP1 segment payload with the given byte order.
    static func exifAPP1Data(byteOrder: ByteOrder, ifd0Entries: [(tag: UInt16, stringValue: String)] = []) -> Data {
        var writer = BinaryWriter(capacity: 256)

        // Exif header
        writer.writeBytes([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // "Exif\0\0"

        let tiffStart = writer.count

        // TIFF header
        switch byteOrder {
        case .bigEndian:
            writer.writeBytes([0x4D, 0x4D]) // "MM"
        case .littleEndian:
            writer.writeBytes([0x49, 0x49]) // "II"
        }
        writer.writeUInt16(42, endian: byteOrder)

        // Offset to first IFD (immediately after TIFF header = offset 8)
        writer.writeUInt32(8, endian: byteOrder)

        // IFD0
        let entryCount = UInt16(ifd0Entries.count)
        writer.writeUInt16(entryCount, endian: byteOrder)

        // For simplicity, write string entries with offsets after IFD
        let ifdEntriesSize = Int(entryCount) * 12 + 4 // entries + next IFD offset
        var stringOffset = 8 + 2 + ifdEntriesSize // relative to TIFF start
        var stringData = Data()

        for entry in ifd0Entries {
            let stringBytes = Data(entry.stringValue.utf8) + Data([0x00]) // null-terminated
            writer.writeUInt16(entry.tag, endian: byteOrder) // Tag
            writer.writeUInt16(2, endian: byteOrder)         // Type: ASCII
            writer.writeUInt32(UInt32(stringBytes.count), endian: byteOrder) // Count

            if stringBytes.count <= 4 {
                var padded = stringBytes
                while padded.count < 4 { padded.append(0x00) }
                writer.writeBytes(padded)
            } else {
                writer.writeUInt32(UInt32(stringOffset), endian: byteOrder)
                stringOffset += stringBytes.count
                stringData.append(stringBytes)
            }
        }

        // Next IFD offset: 0 (no more IFDs)
        writer.writeUInt32(0, endian: byteOrder)

        // Write string data
        writer.writeBytes(stringData)

        _ = tiffStart // suppress unused warning
        return writer.data
    }
}
