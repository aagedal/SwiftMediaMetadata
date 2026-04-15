import XCTest
@testable import SwiftExif

final class WebPWriterTests: XCTestCase {

    func testExifRoundTrip() throws {
        let original = TestFixtures.webpWithExif(make: "Nikon", model: "Z9")
        let metadata = try ImageMetadata.read(from: original)

        XCTAssertEqual(metadata.exif?.make, "Nikon")

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.exif?.make, "Nikon")
        XCTAssertEqual(reparsed.exif?.model, "Z9")
    }

    func testXMPRoundTrip() throws {
        let original = TestFixtures.minimalWebP()
        var metadata = try ImageMetadata.read(from: original)

        metadata.xmp = XMPData()
        metadata.xmp?.headline = "WebP XMP Test"
        metadata.xmp?.city = "Trondheim"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.xmp?.headline, "WebP XMP Test")
        XCTAssertEqual(reparsed.xmp?.city, "Trondheim")
    }

    func testExifAndXMPTogether() throws {
        let original = TestFixtures.webpWithExif(make: "Fujifilm")
        var metadata = try ImageMetadata.read(from: original)

        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Combined"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.exif?.make, "Fujifilm")
        XCTAssertEqual(reparsed.xmp?.headline, "Combined")
    }

    func testAddExifToMinimalWebP() throws {
        let original = TestFixtures.minimalWebP()
        var metadata = try ImageMetadata.read(from: original)

        XCTAssertNil(metadata.exif)

        metadata.exif = ExifData(byteOrder: .bigEndian)
        metadata.exif?.ifd0 = IFD(entries: [
            IFDEntry(tag: ExifTag.make, type: .ascii, count: 6, valueData: Data("Canon\0".utf8)),
        ])

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.exif?.make, "Canon")
    }

    func testVP8XCreatedWhenAddingMetadata() throws {
        let original = TestFixtures.minimalWebP()
        let originalFile = try WebPParser.parse(original)
        XCTAssertNil(originalFile.findChunk("VP8X"))

        var metadata = try ImageMetadata.read(from: original)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Test"

        let written = try metadata.writeToData()
        let modifiedFile = try WebPParser.parse(written)

        XCTAssertNotNil(modifiedFile.findChunk("VP8X"))
    }

    func testVP8XFlagsUpdatedCorrectly() throws {
        let original = TestFixtures.webpWithExif(make: "Test")
        var metadata = try ImageMetadata.read(from: original)

        // Add XMP alongside existing Exif
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Flags Test"

        let written = try metadata.writeToData()
        let file = try WebPParser.parse(written)

        guard let vp8x = file.findChunk("VP8X"), vp8x.data.count >= 1 else {
            XCTFail("VP8X chunk missing"); return
        }

        let flags = vp8x.data[vp8x.data.startIndex]
        XCTAssertTrue(flags & (1 << 3) != 0, "Exif flag should be set")
        XCTAssertTrue(flags & (1 << 2) != 0, "XMP flag should be set")
    }

    func testRemoveAllMetadataDropsVP8X() throws {
        let original = TestFixtures.webpWithExif(make: "RemoveMe")
        var metadata = try ImageMetadata.read(from: original)

        metadata.exif = nil
        metadata.xmp = nil

        let written = try metadata.writeToData()
        let file = try WebPParser.parse(written)

        XCTAssertNil(file.findChunk("EXIF"))
        XCTAssertNil(file.findChunk("XMP "))
        XCTAssertNil(file.findChunk("VP8X"), "VP8X should be removed when no extended features remain")
    }

    func testRIFFHeaderCorrect() throws {
        let original = TestFixtures.webpWithExif(make: "Test")
        let written = try ImageMetadata.read(from: original).writeToData()

        XCTAssertTrue(written.count >= 12)
        let riff = String(data: written.prefix(4), encoding: .ascii)
        let webp = String(data: written[written.startIndex + 8 ..< written.startIndex + 12], encoding: .ascii)
        XCTAssertEqual(riff, "RIFF")
        XCTAssertEqual(webp, "WEBP")

        // File size field should be total size - 8
        let fileSize = UInt32(written[4]) | (UInt32(written[5]) << 8)
            | (UInt32(written[6]) << 16) | (UInt32(written[7]) << 24)
        XCTAssertEqual(Int(fileSize), written.count - 8)
    }

    func testImageDataPreserved() throws {
        let original = TestFixtures.webpWithExif(make: "Preserve")
        let originalFile = try WebPParser.parse(original)
        let originalVP8 = originalFile.findChunk("VP8 ")!.data

        var metadata = try ImageMetadata.read(from: original)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Added"

        let written = try metadata.writeToData()
        let modifiedFile = try WebPParser.parse(written)
        let modifiedVP8 = modifiedFile.findChunk("VP8 ")!.data

        XCTAssertEqual(originalVP8, modifiedVP8, "VP8 image data should be preserved")
    }

    func testWriteReadRoundTripOnDisk() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("test.webp")
        let original = TestFixtures.webpWithExif(make: "DiskTest")
        try original.write(to: fileURL)

        var metadata = try ImageMetadata.read(from: fileURL)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Disk Round Trip"
        try metadata.write(to: fileURL)

        let reparsed = try ImageMetadata.read(from: fileURL)
        XCTAssertEqual(reparsed.exif?.make, "DiskTest")
        XCTAssertEqual(reparsed.xmp?.headline, "Disk Round Trip")
    }
}
