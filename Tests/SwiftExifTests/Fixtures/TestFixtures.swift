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
        let iptcBinary = try! IPTCWriter.write(IPTCData(datasets: datasets))
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
        return try! JPEGWriter.write(file)
    }

    // MARK: - Minimal TIFF

    /// Generate a minimal valid TIFF file with the given IFD0 entries.
    static func minimalTIFF(byteOrder: ByteOrder = .littleEndian, entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, valueData: Data)] = []) -> Data {
        var writer = BinaryWriter(capacity: 256)

        // TIFF header
        switch byteOrder {
        case .bigEndian: writer.writeBytes([0x4D, 0x4D])
        case .littleEndian: writer.writeBytes([0x49, 0x49])
        }
        writer.writeUInt16(42, endian: byteOrder)
        writer.writeUInt32(8, endian: byteOrder) // IFD0 at offset 8

        // IFD0
        writer.writeUInt16(UInt16(entries.count), endian: byteOrder)

        // Calculate where external data will go
        let ifdEntriesEnd = 8 + 2 + (entries.count * 12) + 4 // header + count + entries + next IFD
        var externalOffset = ifdEntriesEnd
        var externalData = Data()

        for entry in entries {
            writer.writeUInt16(entry.tag, endian: byteOrder)
            writer.writeUInt16(entry.type.rawValue, endian: byteOrder)
            writer.writeUInt32(entry.count, endian: byteOrder)

            let totalSize = Int(entry.count) * entry.type.unitSize
            if totalSize <= 4 {
                var padded = entry.valueData
                while padded.count < 4 { padded.append(0x00) }
                writer.writeBytes(padded.prefix(4))
            } else {
                writer.writeUInt32(UInt32(externalOffset), endian: byteOrder)
                externalData.append(entry.valueData)
                externalOffset += entry.valueData.count
            }
        }

        // Next IFD offset = 0
        writer.writeUInt32(0, endian: byteOrder)

        // External data
        writer.writeBytes(externalData)

        return writer.data
    }

    /// Generate a TIFF with embedded EXIF (Make/Model in IFD0).
    static func tiffWithExif(make: String = "TestCamera", model: String = "Model X", byteOrder: ByteOrder = .littleEndian) -> Data {
        let makeBytes = Data(make.utf8) + Data([0x00])
        let modelBytes = Data(model.utf8) + Data([0x00])
        return minimalTIFF(byteOrder: byteOrder, entries: [
            (tag: ExifTag.make, type: .ascii, count: UInt32(makeBytes.count), valueData: makeBytes),
            (tag: ExifTag.model, type: .ascii, count: UInt32(modelBytes.count), valueData: modelBytes),
        ])
    }

    /// Generate a TIFF with embedded XMP (tag 0x02BC).
    static func tiffWithXMP(xml: String, byteOrder: ByteOrder = .littleEndian) -> Data {
        let xmpData = Data(xml.utf8)
        return minimalTIFF(byteOrder: byteOrder, entries: [
            (tag: ExifTag.xmpTag, type: .undefined, count: UInt32(xmpData.count), valueData: xmpData),
        ])
    }

    // MARK: - Minimal PNG

    /// Generate a minimal valid PNG with given extra chunks.
    static func minimalPNG(extraChunks: [(type: String, data: Data)] = []) -> Data {
        var writer = BinaryWriter(capacity: 256)

        // Signature
        writer.writeBytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        // IHDR chunk (1x1 pixel, 8-bit grayscale)
        let ihdrData = Data([
            0x00, 0x00, 0x00, 0x01, // Width: 1
            0x00, 0x00, 0x00, 0x01, // Height: 1
            0x08,                    // Bit depth: 8
            0x00,                    // Color type: Grayscale
            0x00,                    // Compression: deflate
            0x00,                    // Filter: adaptive
            0x00,                    // Interlace: none
        ])
        writePNGChunk(&writer, type: "IHDR", data: ihdrData)

        // Extra chunks (eXIf, iTXt, etc.)
        for chunk in extraChunks {
            writePNGChunk(&writer, type: chunk.type, data: chunk.data)
        }

        // IDAT (minimal image data — zlib compressed single row)
        let idatData = Data([0x78, 0x01, 0x62, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01])
        writePNGChunk(&writer, type: "IDAT", data: idatData)

        // IEND
        writePNGChunk(&writer, type: "IEND", data: Data())

        return writer.data
    }

    /// Generate a PNG with an eXIf chunk containing TIFF/Exif data.
    static func pngWithExif(make: String = "TestCamera", model: String = "Model X") -> Data {
        // Build raw TIFF data for the eXIf chunk (no "Exif\0\0" prefix)
        let tiffData = tiffWithExif(make: make, model: model)
        return minimalPNG(extraChunks: [(type: "eXIf", data: tiffData)])
    }

    private static func writePNGChunk(_ writer: inout BinaryWriter, type: String, data: Data) {
        writer.writeUInt32BigEndian(UInt32(data.count))
        writer.writeString(type, encoding: .ascii)
        writer.writeBytes(data)
        let crc = CRC32.compute(type: type, data: data)
        writer.writeUInt32BigEndian(crc)
    }

    // MARK: - Minimal JPEG XL (Container)

    /// Generate a minimal JPEG XL container with optional Exif/XMP boxes.
    static func minimalJXL(boxes: [(type: String, data: Data)] = []) -> Data {
        var writer = BinaryWriter(capacity: 256)

        // JXL file type box (12 bytes)
        writer.writeBytes([0x00, 0x00, 0x00, 0x0C]) // size
        writer.writeString("JXL ", encoding: .ascii)  // type
        writer.writeBytes([0x0D, 0x0A, 0x87, 0x0A]) // magic

        // Additional boxes
        for box in boxes {
            let payload = box.data
            let boxSize = UInt32(8 + payload.count)
            writer.writeUInt32BigEndian(boxSize)
            writer.writeString(box.type, encoding: .ascii)
            writer.writeBytes(payload)
        }

        return writer.data
    }

    /// Generate a JPEG XL with an Exif box.
    static func jxlWithExif(make: String = "TestCamera", model: String = "Model X") -> Data {
        // Exif box: 4-byte offset prefix (0) + TIFF data
        var exifPayload = Data([0x00, 0x00, 0x00, 0x00]) // offset prefix = 0
        exifPayload.append(tiffWithExif(make: make, model: model))
        return minimalJXL(boxes: [(type: "Exif", data: exifPayload)])
    }

    /// Generate a bare JXL codestream (no metadata boxes).
    static func bareJXLCodestream() -> Data {
        // Just the codestream signature + minimal padding
        return Data([0xFF, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    // MARK: - Minimal AVIF

    /// Generate a minimal AVIF file with ftyp + optional meta box.
    static func minimalAVIF(exifTIFFData: Data? = nil) -> Data {
        var writer = BinaryWriter(capacity: 512)

        // ftyp box
        let ftypPayload = Data("avif".utf8) + Data([0x00, 0x00, 0x00, 0x00]) // brand + minor version
        writeISOBMFFBox(&writer, type: "ftyp", data: ftypPayload)

        // If exif data provided, build meta → iprp → ipco → Exif hierarchy
        if let exifData = exifTIFFData {
            var exifBoxPayload = Data([0x00, 0x00, 0x00, 0x00]) // 4-byte offset prefix
            exifBoxPayload.append(exifData)

            // Build ipco containing Exif box
            var ipcoWriter = BinaryWriter(capacity: 256)
            writeISOBMFFBox(&ipcoWriter, type: "Exif", data: exifBoxPayload)

            // Build iprp containing ipco
            var iprpWriter = BinaryWriter(capacity: 256)
            writeISOBMFFBox(&iprpWriter, type: "ipco", data: ipcoWriter.data)

            // Build meta (FullBox: 4 bytes version+flags, then iprp child)
            var metaPayload = Data([0x00, 0x00, 0x00, 0x00]) // version + flags
            var metaChildrenWriter = BinaryWriter(capacity: 256)
            writeISOBMFFBox(&metaChildrenWriter, type: "iprp", data: iprpWriter.data)
            metaPayload.append(metaChildrenWriter.data)

            writeISOBMFFBox(&writer, type: "meta", data: metaPayload)
        }

        return writer.data
    }

    /// Generate an AVIF with Exif containing Make/Model.
    static func avifWithExif(make: String = "TestCamera", model: String = "Model X") -> Data {
        let tiffData = tiffWithExif(make: make, model: model)
        return minimalAVIF(exifTIFFData: tiffData)
    }

    // MARK: - Minimal HEIF

    /// Generate a minimal HEIF/HEIC file with ftyp + optional meta box.
    static func minimalHEIF(exifTIFFData: Data? = nil) -> Data {
        var writer = BinaryWriter(capacity: 512)

        // ftyp box with heic brand
        let ftypPayload = Data("heic".utf8) + Data([0x00, 0x00, 0x00, 0x00]) // brand + minor version
        writeISOBMFFBox(&writer, type: "ftyp", data: ftypPayload)

        // If exif data provided, build meta → iprp → ipco → Exif hierarchy
        if let exifData = exifTIFFData {
            var exifBoxPayload = Data([0x00, 0x00, 0x00, 0x00]) // 4-byte offset prefix
            exifBoxPayload.append(exifData)

            var ipcoWriter = BinaryWriter(capacity: 256)
            writeISOBMFFBox(&ipcoWriter, type: "Exif", data: exifBoxPayload)

            var iprpWriter = BinaryWriter(capacity: 256)
            writeISOBMFFBox(&iprpWriter, type: "ipco", data: ipcoWriter.data)

            var metaPayload = Data([0x00, 0x00, 0x00, 0x00]) // version + flags
            var metaChildrenWriter = BinaryWriter(capacity: 256)
            writeISOBMFFBox(&metaChildrenWriter, type: "iprp", data: iprpWriter.data)
            metaPayload.append(metaChildrenWriter.data)

            writeISOBMFFBox(&writer, type: "meta", data: metaPayload)
        }

        return writer.data
    }

    /// Generate a HEIF with Exif containing Make/Model.
    static func heifWithExif(make: String = "TestCamera", model: String = "Model X") -> Data {
        let tiffData = tiffWithExif(make: make, model: model)
        return minimalHEIF(exifTIFFData: tiffData)
    }

    private static func writeISOBMFFBox(_ writer: inout BinaryWriter, type: String, data: Data) {
        let boxSize = UInt32(8 + data.count)
        writer.writeUInt32BigEndian(boxSize)
        writer.writeString(type, encoding: .ascii)
        writer.writeBytes(data)
    }

    // MARK: - Minimal CR2 (RAW)

    /// Generate a minimal CR2-like file (TIFF with CR signature at offset 8).
    static func minimalCR2(make: String = "Canon") -> Data {
        // CR2 is TIFF with "CR" at offset 8-9 and version at 10-11.
        // We manually construct a CR2-like header.
        var writer = BinaryWriter(capacity: 256)
        writer.writeBytes([0x49, 0x49]) // Little-endian
        writer.writeUInt16(42, endian: .littleEndian) // Magic
        writer.writeUInt32(16, endian: .littleEndian) // IFD0 offset (after CR2 header)
        writer.writeBytes([0x43, 0x52]) // "CR" at offset 8
        writer.writeBytes([0x02, 0x00]) // CR2 version 2.0
        writer.writeUInt32(0, endian: .littleEndian) // RAW IFD offset (unused)

        // IFD0 at offset 16
        let makeBytes = Data(make.utf8) + Data([0x00])
        let modelBytes = Data("EOS R5".utf8) + Data([0x00])

        writer.writeUInt16(2, endian: .littleEndian) // 2 entries
        // Make entry
        writer.writeUInt16(ExifTag.make, endian: .littleEndian)
        writer.writeUInt16(TIFFDataType.ascii.rawValue, endian: .littleEndian)
        writer.writeUInt32(UInt32(makeBytes.count), endian: .littleEndian)
        if makeBytes.count <= 4 {
            var padded = makeBytes; while padded.count < 4 { padded.append(0) }
            writer.writeBytes(padded.prefix(4))
        } else {
            let makeOffset = 16 + 2 + 24 + 4 // after IFD
            writer.writeUInt32(UInt32(makeOffset), endian: .littleEndian)
        }
        // Model entry
        writer.writeUInt16(ExifTag.model, endian: .littleEndian)
        writer.writeUInt16(TIFFDataType.ascii.rawValue, endian: .littleEndian)
        writer.writeUInt32(UInt32(modelBytes.count), endian: .littleEndian)
        if modelBytes.count <= 4 {
            var padded = modelBytes; while padded.count < 4 { padded.append(0) }
            writer.writeBytes(padded.prefix(4))
        } else {
            let modelOffset = 16 + 2 + 24 + 4 + makeBytes.count
            writer.writeUInt32(UInt32(modelOffset), endian: .littleEndian)
        }

        // Next IFD offset = 0
        writer.writeUInt32(0, endian: .littleEndian)

        // External string data
        if makeBytes.count > 4 { writer.writeBytes(makeBytes) }
        if modelBytes.count > 4 { writer.writeBytes(modelBytes) }

        return writer.data
    }

    // MARK: - Minimal RAF (Fujifilm)

    /// Generate a minimal Fujifilm RAF file with embedded JPEG containing Exif.
    static func minimalRAF(make: String = "FUJIFILM", model: String = "X-T5") -> Data {
        var writer = BinaryWriter(capacity: 512)

        // RAF header: "FUJIFILMCCD-RAW " (16 bytes, space-padded)
        writer.writeString("FUJIFILMCCD-RAW ", encoding: .ascii)

        // Format version (4 bytes)
        writer.writeString("0201", encoding: .ascii)

        // Camera model ID (8 bytes, padded)
        var modelID = Data(model.prefix(8).utf8)
        while modelID.count < 8 { modelID.append(0x00) }
        writer.writeBytes(modelID)

        // Camera model string (32 bytes, padded)
        var modelStr = Data(model.utf8)
        while modelStr.count < 32 { modelStr.append(0x00) }
        writer.writeBytes(modelStr)

        // Padding to offset 84 (currently at 60, need 24 more bytes)
        writer.writeBytes(Data(repeating: 0, count: 24))

        // Build the embedded JPEG with Exif data
        let exifAPP1 = exifAPP1Data(byteOrder: .bigEndian, ifd0Entries: [
            (tag: ExifTag.make, stringValue: make),
            (tag: ExifTag.model, stringValue: model),
        ])
        let embeddedJPEG = jpegWithSegment(marker: .app1, data: exifAPP1)

        // Write JPEG offset and length at offsets 84-91 (big-endian)
        let jpegOffset = UInt32(108) // Start of JPEG data (after header fields)
        let jpegLength = UInt32(embeddedJPEG.count)
        writer.writeUInt32BigEndian(jpegOffset)
        writer.writeUInt32BigEndian(jpegLength)

        // CFA header offset/length + CFA offset/length (placeholder zeros)
        writer.writeBytes(Data(repeating: 0, count: 16)) // offsets 92-107

        // Embedded JPEG at offset 108
        writer.writeBytes(embeddedJPEG)

        return writer.data
    }

    // MARK: - Minimal RW2 (Panasonic)

    /// Generate a minimal Panasonic RW2 file. RW2 is TIFF-like with version 0x55.
    static func minimalRW2(make: String = "Panasonic", model: String = "DC-GH6") -> Data {
        // Build a standard TIFF, then patch version byte to 0x55
        let makeBytes = Data(make.utf8) + Data([0x00])
        let modelBytes = Data(model.utf8) + Data([0x00])
        var tiffData = minimalTIFF(byteOrder: .littleEndian, entries: [
            (tag: ExifTag.make, type: .ascii, count: UInt32(makeBytes.count), valueData: makeBytes),
            (tag: ExifTag.model, type: .ascii, count: UInt32(modelBytes.count), valueData: modelBytes),
        ])
        // Patch version from 0x2A to 0x55 (offset 2 for little-endian)
        tiffData[tiffData.startIndex + 2] = 0x55
        return tiffData
    }

    // MARK: - Raw IPTC Binary Data

    /// Generate raw IPTC binary data for testing the reader directly.
    static func iptcBinaryData(datasets: [IPTCDataSet], includeUTF8Charset: Bool = true) -> Data {
        var iptcData = IPTCData(datasets: datasets)
        if !includeUTF8Charset {
            iptcData.removeAll(for: .codedCharacterSet)
        }
        return try! IPTCWriter.write(iptcData)
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

    // MARK: - Minimal WebP

    /// Generate a minimal WebP file with VP8 (lossy) image data and optional metadata chunks.
    static func minimalWebP(exifTIFFData: Data? = nil, xmpData: Data? = nil) -> Data {
        var chunks = Data()

        // VP8X chunk (extended header) — needed if any metadata chunk present
        let hasExif = exifTIFFData != nil
        let hasXMP = xmpData != nil
        let needsVP8X = hasExif || hasXMP

        if needsVP8X {
            var flags: UInt8 = 0
            if hasExif { flags |= (1 << 3) }
            if hasXMP  { flags |= (1 << 2) }

            var vp8xPayload = Data(count: 10)
            vp8xPayload[0] = flags
            // Canvas: 1x1 (width-1=0, height-1=0) — already zeroed
            appendRIFFChunk(&chunks, fourCC: "VP8X", payload: vp8xPayload)
        }

        // Minimal VP8 bitstream (1x1 pixel, lossy)
        // This is the smallest valid VP8 keyframe: frame tag + sync code + dimensions + partition
        let vp8Payload = Data([
            0x30, 0x01, 0x00, // Frame tag: keyframe, version 0, show frame, partition length
            0x9D, 0x01, 0x2A, // VP8 sync code
            0x01, 0x00,       // width = 1 (14 bits) + scale = 0
            0x01, 0x00,       // height = 1 (14 bits) + scale = 0
            0x01, 0x40,       // minimal partition data
        ])
        appendRIFFChunk(&chunks, fourCC: "VP8 ", payload: vp8Payload)

        // EXIF chunk
        if let exifData = exifTIFFData {
            appendRIFFChunk(&chunks, fourCC: "EXIF", payload: exifData)
        }

        // XMP chunk
        if let xmp = xmpData {
            appendRIFFChunk(&chunks, fourCC: "XMP ", payload: xmp)
        }

        // RIFF header
        var riff = Data()
        riff.append(contentsOf: "RIFF".utf8)
        appendUInt32LE(&riff, UInt32(4 + chunks.count)) // file size minus 8
        riff.append(contentsOf: "WEBP".utf8)
        riff.append(chunks)

        return riff
    }

    /// Generate a WebP with Exif containing Make/Model.
    static func webpWithExif(make: String = "TestCamera", model: String = "Model X") -> Data {
        let tiffData = tiffWithExif(make: make, model: model)
        return minimalWebP(exifTIFFData: tiffData)
    }

    private static func appendRIFFChunk(_ data: inout Data, fourCC: String, payload: Data) {
        data.append(contentsOf: fourCC.utf8)
        appendUInt32LE(&data, UInt32(payload.count))
        data.append(payload)
        // Pad to even boundary
        if payload.count & 1 != 0 {
            data.append(0)
        }
    }

    private static func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
