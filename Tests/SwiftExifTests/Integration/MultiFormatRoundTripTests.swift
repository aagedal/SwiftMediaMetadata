import XCTest
@testable import SwiftExif

final class MultiFormatRoundTripTests: XCTestCase {

    // MARK: - PNG Round Trip

    func testPNGExifXMPRoundTrip() throws {
        let original = TestFixtures.pngWithExif(make: "PNG Cam", model: "P-1")
        var metadata = try ImageMetadata.read(from: original)

        metadata.xmp = XMPData()
        metadata.xmp?.headline = "PNG Round Trip"
        metadata.xmp?.city = "Tromsø"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.format, .png)
        XCTAssertEqual(reparsed.exif?.make, "PNG Cam")
        XCTAssertEqual(reparsed.xmp?.headline, "PNG Round Trip")
        XCTAssertEqual(reparsed.xmp?.city, "Tromsø")
    }

    func testPNGMultipleModifications() throws {
        let original = TestFixtures.minimalPNG()

        // First modification
        var meta1 = try ImageMetadata.read(from: original)
        meta1.xmp = XMPData()
        meta1.xmp?.headline = "First"
        let written1 = try meta1.writeToData()

        // Second modification
        var meta2 = try ImageMetadata.read(from: written1)
        XCTAssertEqual(meta2.xmp?.headline, "First")
        meta2.xmp?.headline = "Second"
        meta2.xmp?.city = "Oslo"
        let written2 = try meta2.writeToData()

        let final = try ImageMetadata.read(from: written2)
        XCTAssertEqual(final.xmp?.headline, "Second")
        XCTAssertEqual(final.xmp?.city, "Oslo")
    }

    // MARK: - JPEG XL Round Trip

    func testJXLExifXMPRoundTrip() throws {
        let original = TestFixtures.jxlWithExif(make: "JXL Cam")
        var metadata = try ImageMetadata.read(from: original)

        metadata.xmp = XMPData()
        metadata.xmp?.headline = "JXL Round Trip"
        metadata.xmp?.subject = ["test", "jxl"]

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.format, .jpegXL)
        XCTAssertEqual(reparsed.exif?.make, "JXL Cam")
        XCTAssertEqual(reparsed.xmp?.headline, "JXL Round Trip")
        XCTAssertEqual(reparsed.xmp?.subject, ["test", "jxl"])
    }

    // MARK: - AVIF Round Trip

    func testAVIFExifXMPRoundTrip() throws {
        let original = TestFixtures.avifWithExif(make: "AVIF Cam")
        var metadata = try ImageMetadata.read(from: original)

        metadata.xmp = XMPData()
        metadata.xmp?.headline = "AVIF Round Trip"
        metadata.xmp?.rights = "© 2026 Photographer"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.format, .avif)
        XCTAssertEqual(reparsed.exif?.make, "AVIF Cam")
        XCTAssertEqual(reparsed.xmp?.headline, "AVIF Round Trip")
        XCTAssertEqual(reparsed.xmp?.rights, "© 2026 Photographer")
    }

    // MARK: - TIFF Round Trip

    func testTIFFFullMetadataRoundTrip() throws {
        let original = TestFixtures.tiffWithExif(make: "Canon", model: "R5")
        var metadata = try ImageMetadata.read(from: original)

        metadata.iptc.headline = "TIFF Round Trip"
        metadata.iptc.keywords = ["test", "tiff"]
        metadata.iptc.city = "Bergen"
        metadata.iptc.byline = "Fotografen"
        metadata.syncIPTCToXMP()

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.exif?.make, "Canon")
        XCTAssertEqual(reparsed.iptc.headline, "TIFF Round Trip")
        XCTAssertEqual(reparsed.iptc.keywords, ["test", "tiff"])
        XCTAssertEqual(reparsed.iptc.city, "Bergen")
        XCTAssertEqual(reparsed.xmp?.headline, "TIFF Round Trip")
        XCTAssertEqual(reparsed.xmp?.subject, ["test", "tiff"])
    }

    func testTIFFNordicCharacters() throws {
        let original = TestFixtures.minimalTIFF()
        var metadata = try ImageMetadata.read(from: original)

        metadata.iptc.headline = "Sterk nordavind i Tromsø"
        metadata.iptc.byline = "Bjørn Ødegård"
        metadata.iptc.city = "Tromsø"
        metadata.iptc.keywords = ["vær", "Tromsø", "bølger"]

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.iptc.headline, "Sterk nordavind i Tromsø")
        XCTAssertEqual(reparsed.iptc.byline, "Bjørn Ødegård")
        XCTAssertEqual(reparsed.iptc.city, "Tromsø")
        XCTAssertEqual(reparsed.iptc.keywords, ["vær", "Tromsø", "bølger"])
    }

    // MARK: - Write to File

    func testWritePNGToFile() throws {
        let original = TestFixtures.minimalPNG()
        var metadata = try ImageMetadata.read(from: original)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "File Test"

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try metadata.write(to: tempURL)
        let readBack = try ImageMetadata.read(from: tempURL)
        XCTAssertEqual(readBack.xmp?.headline, "File Test")
    }

    func testWriteTIFFToFile() throws {
        let original = TestFixtures.minimalTIFF()
        var metadata = try ImageMetadata.read(from: original)
        metadata.iptc.headline = "TIFF File Test"

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID()).tif")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try metadata.write(to: tempURL)
        let readBack = try ImageMetadata.read(from: tempURL)
        XCTAssertEqual(readBack.iptc.headline, "TIFF File Test")
    }
}
