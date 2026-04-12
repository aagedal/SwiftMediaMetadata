import XCTest
@testable import SwiftExif

final class RAWFileParserTests: XCTestCase {

    func testDetectCR2Format() {
        let cr2 = TestFixtures.minimalCR2()
        let format = RAWFileParser.detectRAWFormat(cr2)
        XCTAssertEqual(format, .cr2)
    }

    func testParseCR2() throws {
        let cr2 = TestFixtures.minimalCR2(make: "Canon")
        let tiff = try RAWFileParser.parse(cr2, format: .cr2)

        XCTAssertEqual(tiff.header.byteOrder, .littleEndian)
        XCTAssertFalse(tiff.ifds.isEmpty)
    }

    func testCR2ExifExtraction() throws {
        let cr2 = TestFixtures.minimalCR2(make: "Canon")
        let tiff = try RAWFileParser.parse(cr2, format: .cr2)
        let exif = try TIFFFileParser.extractExif(from: tiff, data: cr2)

        XCTAssertNotNil(exif)
        XCTAssertEqual(exif?.make, "Canon")
        XCTAssertEqual(exif?.model, "EOS R5")
    }

    func testReadMetadataFromCR2() throws {
        let cr2 = TestFixtures.minimalCR2(make: "Canon")
        let metadata = try ImageMetadata.read(from: cr2, format: .raw(.cr2))

        XCTAssertEqual(metadata.format, .raw(.cr2))
        XCTAssertEqual(metadata.exif?.make, "Canon")
    }

    func testDNGParsesAsTIFF() throws {
        // DNG is structurally identical to TIFF for metadata
        let tiffData = TestFixtures.tiffWithExif(make: "Adobe", model: "DNG Converter")
        let tiff = try RAWFileParser.parse(tiffData, format: .dng)

        let exif = try TIFFFileParser.extractExif(from: tiff, data: tiffData)
        XCTAssertEqual(exif?.make, "Adobe")
    }

    func testNEFParsesAsTIFF() throws {
        let tiffData = TestFixtures.tiffWithExif(make: "Nikon", model: "D850")
        let tiff = try RAWFileParser.parse(tiffData, format: .nef)

        let exif = try TIFFFileParser.extractExif(from: tiff, data: tiffData)
        XCTAssertEqual(exif?.make, "Nikon")
    }

    func testARWParsesAsTIFF() throws {
        let tiffData = TestFixtures.tiffWithExif(make: "Sony", model: "ILCE-7RM5")
        let tiff = try RAWFileParser.parse(tiffData, format: .arw)

        let exif = try TIFFFileParser.extractExif(from: tiff, data: tiffData)
        XCTAssertEqual(exif?.make, "Sony")
    }

    func testDetectNonRAW() {
        let tiffData = TestFixtures.minimalTIFF()
        XCTAssertNil(RAWFileParser.detectRAWFormat(tiffData))
    }

    func testDetectTooSmall() {
        XCTAssertNil(RAWFileParser.detectRAWFormat(Data([0x49, 0x49])))
    }
}
