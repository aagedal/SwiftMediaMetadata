import XCTest
@testable import SwiftExif

final class ExifReaderTests: XCTestCase {

    func testParseBigEndianExif() throws {
        let data = TestFixtures.exifAPP1Data(byteOrder: .bigEndian, ifd0Entries: [
            (tag: ExifTag.make, stringValue: "TestCamera"),
        ])
        let exif = try ExifReader.read(from: data)

        XCTAssertEqual(exif.byteOrder, .bigEndian)
        XCTAssertNotNil(exif.ifd0)
        XCTAssertEqual(exif.make, "TestCamera")
    }

    func testParseLittleEndianExif() throws {
        let data = TestFixtures.exifAPP1Data(byteOrder: .littleEndian, ifd0Entries: [
            (tag: ExifTag.make, stringValue: "TestCamera"),
        ])
        let exif = try ExifReader.read(from: data)

        XCTAssertEqual(exif.byteOrder, .littleEndian)
        XCTAssertNotNil(exif.ifd0)
        XCTAssertEqual(exif.make, "TestCamera")
    }

    func testReadMultipleIFD0Entries() throws {
        let data = TestFixtures.exifAPP1Data(byteOrder: .bigEndian, ifd0Entries: [
            (tag: ExifTag.make, stringValue: "Nikon"),
            (tag: ExifTag.model, stringValue: "D850"),
            (tag: ExifTag.software, stringValue: "SwiftExif 1.0"),
        ])
        let exif = try ExifReader.read(from: data)

        XCTAssertEqual(exif.make, "Nikon")
        XCTAssertEqual(exif.model, "D850")
        XCTAssertEqual(exif.software, "SwiftExif 1.0")
    }

    func testInlineValues() throws {
        // Short strings (<=3 chars + null) fit inline
        let data = TestFixtures.exifAPP1Data(byteOrder: .bigEndian, ifd0Entries: [
            (tag: ExifTag.make, stringValue: "Hi"), // 3 bytes with null, fits inline
        ])
        let exif = try ExifReader.read(from: data)
        XCTAssertEqual(exif.make, "Hi")
    }

    func testEmptyIFD() throws {
        let data = TestFixtures.exifAPP1Data(byteOrder: .bigEndian, ifd0Entries: [])
        let exif = try ExifReader.read(from: data)
        XCTAssertNotNil(exif.ifd0)
        XCTAssertEqual(exif.ifd0?.entries.count, 0)
    }

    func testInvalidExifHeader() {
        let data = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        XCTAssertThrowsError(try ExifReader.read(from: data))
    }
}
