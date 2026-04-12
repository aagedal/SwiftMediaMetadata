import XCTest
@testable import SwiftExif

final class AVIFWriterTests: XCTestCase {

    func testExifRoundTrip() throws {
        let original = TestFixtures.avifWithExif(make: "AVIF Cam", model: "A-1")
        var metadata = try ImageMetadata.read(from: original)

        XCTAssertEqual(metadata.exif?.make, "AVIF Cam")

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.exif?.make, "AVIF Cam")
        XCTAssertEqual(reparsed.exif?.model, "A-1")
    }

    func testXMPRoundTrip() throws {
        let original = TestFixtures.minimalAVIF()
        var metadata = try ImageMetadata.read(from: original)

        metadata.xmp = XMPData()
        metadata.xmp?.headline = "AVIF Test"
        metadata.xmp?.city = "Bergen"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.xmp?.headline, "AVIF Test")
        XCTAssertEqual(reparsed.xmp?.city, "Bergen")
    }

    func testExifAndXMPTogether() throws {
        let original = TestFixtures.avifWithExif(make: "TestCam")
        var metadata = try ImageMetadata.read(from: original)

        // Add XMP alongside existing Exif
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Combined Test"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.exif?.make, "TestCam")
        XCTAssertEqual(reparsed.xmp?.headline, "Combined Test")
    }

    func testFtypBoxPreserved() throws {
        let original = TestFixtures.minimalAVIF()
        let originalFile = try AVIFParser.parse(original)

        var metadata = try ImageMetadata.read(from: original)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Test"

        let written = try metadata.writeToData()
        let modifiedFile = try AVIFParser.parse(written)

        XCTAssertEqual(originalFile.brand, modifiedFile.brand)
    }

    func testAddMetadataToMinimalAVIF() throws {
        let original = TestFixtures.minimalAVIF()
        var metadata = try ImageMetadata.read(from: original)

        // Should have no metadata initially
        XCTAssertNil(metadata.exif)
        XCTAssertNil(metadata.xmp)

        // Add both Exif and XMP
        metadata.exif = ExifData(byteOrder: .bigEndian)
        metadata.exif?.ifd0 = IFD(entries: [
            IFDEntry(tag: ExifTag.make, type: .ascii, count: 5, valueData: Data("Test\0".utf8)),
        ])
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "New Headline"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.exif?.make, "Test")
        XCTAssertEqual(reparsed.xmp?.headline, "New Headline")
    }
}
