import XCTest
@testable import SwiftExif

final class HEIFWriterTests: XCTestCase {

    func testRoundTripExif() throws {
        let heif = TestFixtures.heifWithExif(make: "Apple", model: "iPhone 16 Pro")
        let metadata = try ImageMetadata.read(from: heif)

        // Write it back out
        let written = try metadata.writeToData()

        // Re-read and verify
        let reread = try ImageMetadata.read(from: written)
        XCTAssertEqual(reread.format, .heif)
        XCTAssertEqual(reread.exif?.make, "Apple")
        XCTAssertEqual(reread.exif?.model, "iPhone 16 Pro")
    }

    func testRoundTripModifyExif() throws {
        let heif = TestFixtures.heifWithExif(make: "Apple", model: "iPhone 16 Pro")
        var metadata = try ImageMetadata.read(from: heif)

        // Replace IFD0 Make entry
        let newMake = Data("Sony\0".utf8)
        var entries = metadata.exif?.ifd0?.entries.filter { $0.tag != ExifTag.make } ?? []
        entries.append(IFDEntry(tag: ExifTag.make, type: .ascii, count: UInt32(newMake.count), valueData: newMake))
        metadata.exif?.ifd0 = IFD(entries: entries)

        let written = try metadata.writeToData()
        let reread = try ImageMetadata.read(from: written)
        XCTAssertEqual(reread.exif?.make, "Sony")
    }

    func testWriteWithXMP() throws {
        let heif = TestFixtures.minimalHEIF()
        var metadata = try ImageMetadata.read(from: heif)

        // Add XMP
        metadata.xmp = XMPData()
        metadata.xmp?.setValue(.simple("Test Creator"), namespace: XMPNamespace.dc, property: "creator")

        let written = try metadata.writeToData()
        let reread = try ImageMetadata.read(from: written)
        XCTAssertNotNil(reread.xmp)
        XCTAssertEqual(reread.xmp?.simpleValue(namespace: XMPNamespace.dc, property: "creator"), "Test Creator")
    }

    func testWriteWithNordicCharacters() throws {
        let heif = TestFixtures.minimalHEIF()
        var metadata = try ImageMetadata.read(from: heif)

        metadata.xmp = XMPData()
        metadata.xmp?.setValue(.simple("Tromsø, Norge"), namespace: XMPNamespace.dc, property: "description")

        let written = try metadata.writeToData()
        let reread = try ImageMetadata.read(from: written)
        XCTAssertEqual(reread.xmp?.simpleValue(namespace: XMPNamespace.dc, property: "description"), "Tromsø, Norge")
    }

    func testStripAllMetadata() throws {
        let heif = TestFixtures.heifWithExif(make: "Apple", model: "iPhone 16 Pro")
        var metadata = try ImageMetadata.read(from: heif)
        XCTAssertNotNil(metadata.exif)

        metadata.stripAllMetadata()
        let written = try metadata.writeToData()
        let reread = try ImageMetadata.read(from: written)
        XCTAssertNil(reread.exif)
        XCTAssertNil(reread.xmp)
    }

    func testBrandPreserved() throws {
        let heif = TestFixtures.heifWithExif()
        let metadata = try ImageMetadata.read(from: heif)

        let written = try metadata.writeToData()
        let file = try HEIFParser.parse(written)
        XCTAssertEqual(file.brand, "heic")
    }
}
