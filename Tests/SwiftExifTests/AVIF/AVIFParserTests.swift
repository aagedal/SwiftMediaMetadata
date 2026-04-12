import XCTest
@testable import SwiftExif

final class AVIFParserTests: XCTestCase {

    func testParseMinimalAVIF() throws {
        let avif = TestFixtures.minimalAVIF()
        let file = try AVIFParser.parse(avif)

        XCTAssertEqual(file.brand, "avif")
        XCTAssertFalse(file.boxes.isEmpty)
    }

    func testAVIFBrandDetection() throws {
        let avif = TestFixtures.minimalAVIF()
        let file = try AVIFParser.parse(avif)
        XCTAssertEqual(file.brand, "avif")
    }

    func testAVIFWithExif() throws {
        let avif = TestFixtures.avifWithExif(make: "Apple", model: "iPhone 16 Pro")
        let metadata = try ImageMetadata.read(from: avif)

        XCTAssertEqual(metadata.format, .avif)
        XCTAssertNotNil(metadata.exif)
        XCTAssertEqual(metadata.exif?.make, "Apple")
        XCTAssertEqual(metadata.exif?.model, "iPhone 16 Pro")
    }

    func testAVIFWithoutMetadata() throws {
        let avif = TestFixtures.minimalAVIF(exifTIFFData: nil)
        let metadata = try ImageMetadata.read(from: avif)

        XCTAssertEqual(metadata.format, .avif)
        XCTAssertNil(metadata.exif)
        XCTAssertNil(metadata.xmp)
    }

    func testInvalidAVIFThrows() {
        let garbage = Data(repeating: 0xCC, count: 20)
        XCTAssertThrowsError(try AVIFParser.parse(garbage))
    }

    func testAVIFTooSmallThrows() {
        XCTAssertThrowsError(try AVIFParser.parse(Data([0x00, 0x00])))
    }
}
