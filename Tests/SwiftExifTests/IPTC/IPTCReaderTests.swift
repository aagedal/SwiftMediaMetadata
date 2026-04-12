import XCTest
@testable import SwiftExif

final class IPTCReaderTests: XCTestCase {

    func testReadMinimalIPTC() throws {
        // Minimal: just record version 2:00 = 4
        var writer = BinaryWriter()
        writer.writeUInt8(0x1C)
        writer.writeUInt8(2)   // Record 2
        writer.writeUInt8(0)   // Dataset 0 (ApplicationRecordVersion)
        writer.writeUInt16BigEndian(2) // Length: 2 bytes
        writer.writeUInt16BigEndian(4) // Value: version 4

        let iptc = try IPTCReader.read(from: writer.data)
        XCTAssertEqual(iptc.datasets.count, 1)
        XCTAssertEqual(iptc.datasets[0].tag, .applicationRecordVersion)
        XCTAssertEqual(iptc.datasets[0].uint16Value(), 4)
    }

    func testReadSingleKeyword() throws {
        var writer = BinaryWriter()
        let keyword = "TestKeyword"
        let keywordBytes = Data(keyword.utf8)

        writer.writeUInt8(0x1C)
        writer.writeUInt8(2)
        writer.writeUInt8(25) // Keywords
        writer.writeUInt16BigEndian(UInt16(keywordBytes.count))
        writer.writeBytes(keywordBytes)

        let iptc = try IPTCReader.read(from: writer.data)
        XCTAssertEqual(iptc.values(for: .keywords), ["TestKeyword"])
    }

    func testReadMultipleKeywords() throws {
        var writer = BinaryWriter()

        for keyword in ["Photo", "News", "Tromsø"] {
            let bytes = Data(keyword.utf8)
            writer.writeUInt8(0x1C)
            writer.writeUInt8(2)
            writer.writeUInt8(25)
            writer.writeUInt16BigEndian(UInt16(bytes.count))
            writer.writeBytes(bytes)
        }

        let iptc = try IPTCReader.read(from: writer.data)
        // Note: default encoding is isoLatin1 when no 1:90 present
        // "Tromsø" in UTF-8 read as isoLatin1 will produce garbled text
        // But the raw bytes are preserved
        XCTAssertEqual(iptc.datasets.filter { $0.tag == .keywords }.count, 3)
    }

    func testReadWithUTF8CharacterSet() throws {
        var writer = BinaryWriter()

        // Write 1:90 CodedCharacterSet = ESC % G (UTF-8)
        writer.writeUInt8(0x1C)
        writer.writeUInt8(1)
        writer.writeUInt8(90)
        writer.writeUInt16BigEndian(3)
        writer.writeBytes([0x1B, 0x25, 0x47])

        // Write a headline with Nordic chars
        let headline = "Tromsø havn"
        let headlineBytes = Data(headline.utf8)
        writer.writeUInt8(0x1C)
        writer.writeUInt8(2)
        writer.writeUInt8(105) // Headline
        writer.writeUInt16BigEndian(UInt16(headlineBytes.count))
        writer.writeBytes(headlineBytes)

        let iptc = try IPTCReader.read(from: writer.data)
        XCTAssertTrue(iptc.isUTF8)
        XCTAssertEqual(iptc.value(for: .headline), "Tromsø havn")
    }

    func testReadAllJournalismFields() throws {
        var writer = BinaryWriter()

        // CodedCharacterSet
        writer.writeUInt8(0x1C); writer.writeUInt8(1); writer.writeUInt8(90)
        writer.writeUInt16BigEndian(3); writer.writeBytes([0x1B, 0x25, 0x47])

        let fields: [(UInt8, String)] = [
            (5, "Test Title"),
            (25, "keyword1"),
            (25, "keyword2"),
            (40, "Special instructions"),
            (55, "20260412"),
            (60, "143000+0200"),
            (80, "Photographer Name"),
            (85, "Staff"),
            (90, "Oslo"),
            (92, "Sentrum"),
            (95, "Oslo"),
            (100, "NOR"),
            (101, "Norway"),
            (105, "Breaking News Headline"),
            (110, "Agency Credit"),
            (115, "Photo Source"),
            (116, "© 2026 Agency"),
            (120, "This is a caption about the photo"),
            (122, "Editor Name"),
        ]

        for (dataSet, value) in fields {
            let bytes = Data(value.utf8)
            writer.writeUInt8(0x1C)
            writer.writeUInt8(2)
            writer.writeUInt8(dataSet)
            writer.writeUInt16BigEndian(UInt16(bytes.count))
            writer.writeBytes(bytes)
        }

        let iptc = try IPTCReader.read(from: writer.data)
        XCTAssertEqual(iptc.objectName, "Test Title")
        XCTAssertEqual(iptc.keywords, ["keyword1", "keyword2"])
        XCTAssertEqual(iptc.specialInstructions, "Special instructions")
        XCTAssertEqual(iptc.dateCreated, "20260412")
        XCTAssertEqual(iptc.timeCreated, "143000+0200")
        XCTAssertEqual(iptc.byline, "Photographer Name")
        XCTAssertEqual(iptc.city, "Oslo")
        XCTAssertEqual(iptc.sublocation, "Sentrum")
        XCTAssertEqual(iptc.provinceState, "Oslo")
        XCTAssertEqual(iptc.countryCode, "NOR")
        XCTAssertEqual(iptc.countryName, "Norway")
        XCTAssertEqual(iptc.headline, "Breaking News Headline")
        XCTAssertEqual(iptc.credit, "Agency Credit")
        XCTAssertEqual(iptc.source, "Photo Source")
        XCTAssertEqual(iptc.copyright, "© 2026 Agency")
        XCTAssertEqual(iptc.caption, "This is a caption about the photo")
        XCTAssertEqual(iptc.writerEditor, "Editor Name")
    }

    func testInvalidTagMarker() {
        // Non-zero, non-0x1C byte should throw
        let data = Data([0xFF, 0x02, 0x19, 0x00, 0x04, 0x54, 0x65, 0x73, 0x74])
        XCTAssertThrowsError(try IPTCReader.read(from: data))
    }

    func testNullPaddingTolerated() throws {
        // 0x00 at the start is treated as padding (common in real-world files)
        let data = Data([0x00, 0x02, 0x19, 0x00, 0x04, 0x54, 0x65, 0x73, 0x74])
        let iptc = try IPTCReader.read(from: data)
        XCTAssertTrue(iptc.datasets.isEmpty)
    }

    func testTruncatedData() {
        // Just a tag marker, no record/dataset/length
        let data = Data([0x1C])
        XCTAssertThrowsError(try IPTCReader.read(from: data))
    }

    func testEmptyData() throws {
        let iptc = try IPTCReader.read(from: Data())
        XCTAssertTrue(iptc.datasets.isEmpty)
    }
}
