import XCTest
@testable import SwiftExif

final class PNGWriterTests: XCTestCase {

    func testRoundTripPreservesChunks() throws {
        let original = TestFixtures.minimalPNG()
        let file = try PNGParser.parse(original)
        let written = PNGWriter.write(file)
        let reparsed = try PNGParser.parse(written)

        XCTAssertEqual(file.chunks.count, reparsed.chunks.count)
        for (a, b) in zip(file.chunks, reparsed.chunks) {
            XCTAssertEqual(a.type, b.type)
            XCTAssertEqual(a.data, b.data)
        }
    }

    func testExifRoundTrip() throws {
        let original = TestFixtures.pngWithExif(make: "TestCam", model: "PNG-1")
        var metadata = try ImageMetadata.read(from: original)

        XCTAssertEqual(metadata.exif?.make, "TestCam")

        // Write back
        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.exif?.make, "TestCam")
        XCTAssertEqual(reparsed.exif?.model, "PNG-1")
    }

    func testXMPRoundTrip() throws {
        let original = TestFixtures.minimalPNG()
        var metadata = try ImageMetadata.read(from: original)

        // Add XMP data
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Test PNG Headline"
        metadata.xmp?.city = "Tromsø"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.xmp?.headline, "Test PNG Headline")
        XCTAssertEqual(reparsed.xmp?.city, "Tromsø")
    }

    func testImageDataPreserved() throws {
        let original = TestFixtures.minimalPNG()
        let originalFile = try PNGParser.parse(original)
        let originalIDAT = originalFile.findChunk("IDAT")?.data

        var metadata = try ImageMetadata.read(from: original)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Added metadata"

        let written = try metadata.writeToData()
        let modifiedFile = try PNGParser.parse(written)
        let modifiedIDAT = modifiedFile.findChunk("IDAT")?.data

        XCTAssertEqual(originalIDAT, modifiedIDAT, "IDAT chunk data must be preserved")
    }

    func testAddAndReplaceExif() throws {
        // Start with no Exif
        let original = TestFixtures.minimalPNG()
        var metadata = try ImageMetadata.read(from: original)
        XCTAssertNil(metadata.exif)

        // Add Exif
        metadata.exif = ExifData(byteOrder: .littleEndian)
        metadata.exif?.ifd0 = IFD(entries: [
            IFDEntry(tag: ExifTag.make, type: .ascii, count: 5, valueData: Data("Test\0".utf8)),
        ])

        let written1 = try metadata.writeToData()
        var reparsed1 = try ImageMetadata.read(from: written1)
        XCTAssertEqual(reparsed1.exif?.make, "Test")

        // Replace Exif
        reparsed1.exif?.ifd0 = IFD(entries: [
            IFDEntry(tag: ExifTag.make, type: .ascii, count: 9, valueData: Data("Replaced\0".utf8)),
        ])

        let written2 = try reparsed1.writeToData()
        let reparsed2 = try ImageMetadata.read(from: written2)
        XCTAssertEqual(reparsed2.exif?.make, "Replaced")
    }
}
