import XCTest
@testable import SwiftExif

final class TIFFWriterTests: XCTestCase {

    func testExifPreserved() throws {
        let original = TestFixtures.tiffWithExif(make: "Nikon", model: "D850")
        var metadata = try ImageMetadata.read(from: original)

        XCTAssertEqual(metadata.exif?.make, "Nikon")
        XCTAssertEqual(metadata.exif?.model, "D850")

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.exif?.make, "Nikon")
        XCTAssertEqual(reparsed.exif?.model, "D850")
    }

    func testXMPRoundTrip() throws {
        let original = TestFixtures.minimalTIFF()
        var metadata = try ImageMetadata.read(from: original)

        metadata.xmp = XMPData()
        metadata.xmp?.headline = "TIFF Headline"
        metadata.xmp?.city = "Stavanger"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.xmp?.headline, "TIFF Headline")
        XCTAssertEqual(reparsed.xmp?.city, "Stavanger")
    }

    func testIPTCRoundTrip() throws {
        let original = TestFixtures.minimalTIFF()
        var metadata = try ImageMetadata.read(from: original)

        metadata.iptc.headline = "TIFF IPTC"
        metadata.iptc.keywords = ["test", "tiff"]
        metadata.iptc.city = "Tromsø"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.iptc.headline, "TIFF IPTC")
        XCTAssertEqual(reparsed.iptc.keywords, ["test", "tiff"])
        XCTAssertEqual(reparsed.iptc.city, "Tromsø")
    }

    func testXMPExistingPreserved() throws {
        let xmpXML = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
         <rdf:Description rdf:about=""
           photoshop:Headline="Existing"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let original = TestFixtures.tiffWithXMP(xml: xmpXML)
        var metadata = try ImageMetadata.read(from: original)

        XCTAssertEqual(metadata.xmp?.headline, "Existing")

        // Add IPTC and re-write
        metadata.iptc.headline = "New Headline"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.iptc.headline, "New Headline")
        // XMP should be overwritten with current value
        XCTAssertEqual(reparsed.xmp?.headline, "Existing")
    }

    func testByteOrderPreserved() throws {
        // Test with big-endian TIFF
        let original = TestFixtures.tiffWithExif(make: "Canon", model: "R5", byteOrder: .bigEndian)
        var metadata = try ImageMetadata.read(from: original)

        metadata.iptc.headline = "Big Endian"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.iptc.headline, "Big Endian")
        XCTAssertEqual(reparsed.exif?.make, "Canon")
    }

    func testAllMetadataTogether() throws {
        let original = TestFixtures.tiffWithExif(make: "Sony", model: "A7")
        var metadata = try ImageMetadata.read(from: original)

        metadata.iptc.headline = "Combined Test"
        metadata.iptc.keywords = ["sony", "test"]
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "XMP Headline"
        metadata.xmp?.city = "Tokyo"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.exif?.make, "Sony")
        XCTAssertEqual(reparsed.iptc.headline, "Combined Test")
        XCTAssertEqual(reparsed.iptc.keywords, ["sony", "test"])
        XCTAssertEqual(reparsed.xmp?.headline, "XMP Headline")
        XCTAssertEqual(reparsed.xmp?.city, "Tokyo")
    }
}
