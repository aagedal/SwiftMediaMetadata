import XCTest
@testable import SwiftExif

final class MakerNoteWriterTests: XCTestCase {

    // MARK: - isDirty Flag

    func testIsDirtyDefaultsFalse() {
        let mn = MakerNoteData(manufacturer: .canon, tags: [:], rawData: Data())
        XCTAssertFalse(mn.isDirty)
    }

    func testSetTagMarksDirty() {
        var mn = MakerNoteData(manufacturer: .canon, tags: [:], rawData: Data())
        mn.setTag("SerialNumber", value: .string("NEW"))
        XCTAssertTrue(mn.isDirty)
    }

    func testRemoveTagMarksDirty() {
        var mn = MakerNoteData(manufacturer: .canon, tags: ["Foo": .string("bar")], rawData: Data())
        mn.removeTag("Foo")
        XCTAssertTrue(mn.isDirty)
    }

    func testNotDirtyReturnsRawData() {
        let raw = Data([0x01, 0x02, 0x03])
        let mn = MakerNoteData(manufacturer: .canon, tags: [:], rawData: raw)
        let written = MakerNoteWriter.write(mn, byteOrder: .bigEndian)
        XCTAssertEqual(written, raw)
    }

    func testUnknownManufacturerReturnsRawData() {
        var mn = MakerNoteData(manufacturer: .unknown, tags: [:], rawData: Data([0xFF]))
        mn.setTag("Test", value: .string("val"))
        let written = MakerNoteWriter.write(mn, byteOrder: .bigEndian)
        XCTAssertEqual(written, Data([0xFF]))
    }

    // MARK: - Canon Round-Trip

    func testCanonRoundTrip() {
        let rawData = buildCanonMakerNote(serialNumber: "ABC123", byteOrder: .bigEndian)
        let ifd = buildExifIFDWithMakerNote(rawData, byteOrder: .bigEndian)
        guard let parsed = MakerNoteReader.parse(from: ifd, make: "Canon", byteOrder: .bigEndian) else {
            XCTFail("Failed to parse Canon MakerNote"); return
        }

        // Modify serial number
        var modified = parsed
        modified.setTag("SerialNumber", value: .string("NEW456"))

        let written = MakerNoteWriter.write(modified, byteOrder: .bigEndian)

        // Re-parse written data
        let newIFD = buildExifIFDWithMakerNote(written, byteOrder: .bigEndian)
        let reparsed = MakerNoteReader.parse(from: newIFD, make: "Canon", byteOrder: .bigEndian)

        XCTAssertNotNil(reparsed)
        if case .string(let sn) = reparsed?.tags["SerialNumber"] {
            XCTAssertEqual(sn, "NEW456")
        } else {
            XCTFail("SerialNumber not found after round-trip")
        }
    }

    // MARK: - Nikon Round-Trip

    func testNikonRoundTrip() {
        let rawData = buildNikonMakerNote(serialNumber: "D850-12345")
        let ifd = buildExifIFDWithMakerNote(rawData, byteOrder: .bigEndian)
        guard let parsed = MakerNoteReader.parse(from: ifd, make: "NIKON CORPORATION", byteOrder: .bigEndian) else {
            XCTFail("Failed to parse Nikon MakerNote"); return
        }

        var modified = parsed
        modified.setTag("SerialNumber", value: .string("D850-99999"))

        let written = MakerNoteWriter.write(modified, byteOrder: .bigEndian)

        let newIFD = buildExifIFDWithMakerNote(written, byteOrder: .bigEndian)
        let reparsed = MakerNoteReader.parse(from: newIFD, make: "NIKON CORPORATION", byteOrder: .bigEndian)

        XCTAssertNotNil(reparsed)
        if case .string(let sn) = reparsed?.tags["SerialNumber"] {
            XCTAssertEqual(sn, "D850-99999")
        } else {
            XCTFail("SerialNumber not found after round-trip")
        }
    }

    // MARK: - Panasonic Round-Trip

    func testPanasonicRoundTrip() {
        let rawData = buildPanasonicMakerNote(serialNumber: "PAN-001")
        let ifd = buildExifIFDWithMakerNote(rawData, byteOrder: .bigEndian)
        guard let parsed = MakerNoteReader.parse(from: ifd, make: "Panasonic", byteOrder: .bigEndian) else {
            XCTFail("Failed to parse Panasonic MakerNote"); return
        }

        var modified = parsed
        modified.setTag("InternalSerialNumber", value: .string("PAN-999"))

        let written = MakerNoteWriter.write(modified, byteOrder: .bigEndian)

        let newIFD = buildExifIFDWithMakerNote(written, byteOrder: .bigEndian)
        let reparsed = MakerNoteReader.parse(from: newIFD, make: "Panasonic", byteOrder: .bigEndian)

        XCTAssertNotNil(reparsed)
        if case .string(let sn) = reparsed?.tags["InternalSerialNumber"] {
            XCTAssertEqual(sn, "PAN-999")
        } else {
            XCTFail("InternalSerialNumber not found after round-trip")
        }
    }

    // MARK: - Fujifilm Round-Trip

    func testFujifilmRoundTrip() {
        let rawData = buildFujifilmMakerNote(serialNumber: "FUJI-001")
        let ifd = buildExifIFDWithMakerNote(rawData, byteOrder: .bigEndian)
        guard let parsed = MakerNoteReader.parse(from: ifd, make: "FUJIFILM", byteOrder: .bigEndian) else {
            XCTFail("Failed to parse Fujifilm MakerNote"); return
        }

        var modified = parsed
        modified.setTag("SerialNumber", value: .string("FUJI-NEW"))

        let written = MakerNoteWriter.write(modified, byteOrder: .bigEndian)

        let newIFD = buildExifIFDWithMakerNote(written, byteOrder: .bigEndian)
        let reparsed = MakerNoteReader.parse(from: newIFD, make: "FUJIFILM", byteOrder: .bigEndian)

        XCTAssertNotNil(reparsed)
        if case .string(let sn) = reparsed?.tags["SerialNumber"] {
            XCTAssertEqual(sn, "FUJI-NEW")
        } else {
            XCTFail("SerialNumber not found after round-trip")
        }
    }

    // MARK: - ImageMetadata Convenience

    func testSetMakerNoteTagConvenience() {
        let rawData = buildCanonMakerNote(serialNumber: "ORIG", byteOrder: .bigEndian)
        let exifIFD = buildExifIFDWithMakerNote(rawData, byteOrder: .bigEndian)
        let parsed = MakerNoteReader.parse(from: exifIFD, make: "Canon", byteOrder: .bigEndian)

        var exif = ExifData(byteOrder: .bigEndian)
        exif.exifIFD = exifIFD
        exif.makerNote = parsed

        let jpeg = JPEGFile(segments: [], scanData: Data())
        var metadata = ImageMetadata(container: .jpeg(jpeg), format: .jpeg, iptc: IPTCData(), exif: exif)

        metadata.setMakerNoteTag("SerialNumber", value: .string("UPDATED"))

        XCTAssertTrue(metadata.exif?.makerNote?.isDirty ?? false)
        if case .string(let sn) = metadata.exif?.makerNote?.tags["SerialNumber"] {
            XCTAssertEqual(sn, "UPDATED")
        } else {
            XCTFail("Tag not updated")
        }
    }

    // MARK: - Helpers (same patterns as MakerNoteReaderTests)

    private func buildExifIFDWithMakerNote(_ data: Data, byteOrder: ByteOrder) -> IFD {
        let entry = IFDEntry(tag: ExifTag.makerNote, type: .undefined, count: UInt32(data.count), valueData: data)
        return IFD(entries: [entry], nextIFDOffset: 0)
    }

    private func buildCanonMakerNote(serialNumber: String, byteOrder: ByteOrder) -> Data {
        var entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)] = []
        let snBytes = Data(serialNumber.utf8) + Data([0x00])
        entries.append((0x0006, .ascii, UInt32(snBytes.count), snBytes))
        entries.sort { $0.tag < $1.tag }
        return buildMiniIFD(entries: entries, byteOrder: byteOrder)
    }

    private func buildNikonMakerNote(serialNumber: String) -> Data {
        var entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)] = []
        let snBytes = Data(serialNumber.utf8) + Data([0x00])
        entries.append((0x001D, .ascii, UInt32(snBytes.count), snBytes))
        entries.sort { $0.tag < $1.tag }

        var writer = BinaryWriter(capacity: 256)
        writer.writeBytes([0x4E, 0x69, 0x6B, 0x6F, 0x6E, 0x00]) // "Nikon\0"
        writer.writeBytes([0x02, 0x10]) // Version
        writer.writeBytes([0x00, 0x00]) // Padding
        writer.writeBytes([0x4D, 0x4D]) // Big-endian
        writer.writeUInt16BigEndian(42)
        writer.writeUInt32BigEndian(8) // IFD at offset 8 from embedded TIFF header
        writer.writeBytes(buildMiniIFD(entries: entries, byteOrder: .bigEndian, offsetBase: 8))
        return writer.data
    }

    private func buildPanasonicMakerNote(serialNumber: String) -> Data {
        var entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)] = []
        let snBytes = Data(serialNumber.utf8) + Data([0x00])
        entries.append((0x0025, .ascii, UInt32(snBytes.count), snBytes))
        entries.sort { $0.tag < $1.tag }

        var writer = BinaryWriter(capacity: 256)
        writer.writeBytes(Data("Panasonic\0\0\0".utf8))
        writer.writeBytes(buildMiniIFD(entries: entries, byteOrder: .bigEndian, offsetBase: 12))
        return writer.data
    }

    private func buildFujifilmMakerNote(serialNumber: String) -> Data {
        var entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)] = []
        let snBytes = Data(serialNumber.utf8) + Data([0x00])
        entries.append((0x0010, .ascii, UInt32(snBytes.count), snBytes))
        entries.sort { $0.tag < $1.tag }

        var writer = BinaryWriter(capacity: 256)
        writer.writeBytes(Data([0x46, 0x55, 0x4A, 0x49, 0x46, 0x49, 0x4C, 0x4D])) // "FUJIFILM"
        writer.writeUInt32(12, endian: .littleEndian) // IFD offset
        writer.writeBytes(buildMiniIFD(entries: entries, byteOrder: .littleEndian, offsetBase: 12))
        return writer.data
    }

    private func buildMiniIFD(entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)], byteOrder: ByteOrder, offsetBase: Int = 0) -> Data {
        var writer = BinaryWriter(capacity: 256)
        writer.writeUInt16(UInt16(entries.count), endian: byteOrder)
        let ifdDirectorySize = 2 + entries.count * 12 + 4
        var externalOffset = offsetBase + ifdDirectorySize
        var externalData = Data()

        for entry in entries {
            writer.writeUInt16(entry.tag, endian: byteOrder)
            writer.writeUInt16(entry.type.rawValue, endian: byteOrder)
            writer.writeUInt32(entry.count, endian: byteOrder)

            let totalSize = Int(entry.count) * entry.type.unitSize
            if totalSize <= 4 {
                var padded = entry.data
                while padded.count < 4 { padded.append(0x00) }
                writer.writeBytes(padded.prefix(4))
            } else {
                writer.writeUInt32(UInt32(externalOffset), endian: byteOrder)
                externalData.append(entry.data)
                if entry.data.count % 2 != 0 { externalData.append(0x00) }
                externalOffset += entry.data.count
                if entry.data.count % 2 != 0 { externalOffset += 1 }
            }
        }

        writer.writeUInt32(0, endian: byteOrder)
        writer.writeBytes(externalData)
        return writer.data
    }
}
