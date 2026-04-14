import XCTest
@testable import SwiftExif

final class HEIFParserTests: XCTestCase {

    func testParseMinimalHEIF() throws {
        let heif = TestFixtures.minimalHEIF()
        let file = try HEIFParser.parse(heif)

        XCTAssertEqual(file.brand, "heic")
        XCTAssertFalse(file.boxes.isEmpty)
    }

    func testHEIFBrandDetection() throws {
        let heif = TestFixtures.minimalHEIF()
        let format = FormatDetector.detect(heif)
        XCTAssertEqual(format, .heif)
    }

    func testHEIFExtensionDetection() {
        XCTAssertEqual(FormatDetector.detectFromExtension("heic"), .heif)
        XCTAssertEqual(FormatDetector.detectFromExtension("heif"), .heif)
        XCTAssertEqual(FormatDetector.detectFromExtension("HEIC"), .heif)
    }

    func testHEIFWithExif() throws {
        let heif = TestFixtures.heifWithExif(make: "Apple", model: "iPhone 16 Pro")
        let metadata = try ImageMetadata.read(from: heif)

        XCTAssertEqual(metadata.format, .heif)
        XCTAssertNotNil(metadata.exif)
        XCTAssertEqual(metadata.exif?.make, "Apple")
        XCTAssertEqual(metadata.exif?.model, "iPhone 16 Pro")
    }

    func testHEIFWithoutMetadata() throws {
        let heif = TestFixtures.minimalHEIF(exifTIFFData: nil)
        let metadata = try ImageMetadata.read(from: heif)

        XCTAssertEqual(metadata.format, .heif)
        XCTAssertNil(metadata.exif)
        XCTAssertNil(metadata.xmp)
    }

    func testInvalidHEIFThrows() {
        let garbage = Data(repeating: 0xCC, count: 20)
        XCTAssertThrowsError(try HEIFParser.parse(garbage))
    }

    func testHEIFTooSmallThrows() {
        XCTAssertThrowsError(try HEIFParser.parse(Data([0x00, 0x00])))
    }

    func testMif1BrandDetectedAsHEIF() throws {
        // Build a minimal ISOBMFF file with mif1 brand
        var writer = BinaryWriter(capacity: 64)
        let ftypPayload = Data("mif1".utf8) + Data([0x00, 0x00, 0x00, 0x00])
        writer.writeUInt32BigEndian(UInt32(8 + ftypPayload.count))
        writer.writeString("ftyp", encoding: .ascii)
        writer.writeBytes(ftypPayload)

        let format = FormatDetector.detect(writer.data)
        XCTAssertEqual(format, .heif)
    }

    func testRealHEICFileIfAvailable() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HEIF/
            .deletingLastPathComponent() // SwiftExifTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // project root
        let url = projectRoot.appendingPathComponent("TestImages/IMG_5543_upsideDownFaceThumbnailSource_1.heic")

        guard FileManager.default.fileExists(atPath: url.path) else {
            // Skip if test image not available
            return
        }

        let data = try Data(contentsOf: url)
        let heifFile = try HEIFParser.parse(data)
        XCTAssertEqual(FormatDetector.detect(data), .heif)

        // Verify iloc extraction works with raw data
        let exif = try HEIFParser.extractExif(from: heifFile, fileData: data)
        XCTAssertNotNil(exif, "Expected Exif from real HEIC file via iloc extraction")

        // Also test through the full ImageMetadata API
        let metadata = try ImageMetadata.read(from: url)
        XCTAssertEqual(metadata.format, .heif)
        XCTAssertNotNil(metadata.exif)
    }
}
