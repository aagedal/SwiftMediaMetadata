import XCTest
@testable import SwiftExif

final class TIFFFileParserTests: XCTestCase {

    func testParseMinimalTIFF_LE() throws {
        let data = TestFixtures.minimalTIFF(byteOrder: .littleEndian)
        let tiff = try TIFFFileParser.parse(data)

        XCTAssertEqual(tiff.header.byteOrder, .littleEndian)
        XCTAssertEqual(tiff.header.magic, 42)
        XCTAssertFalse(tiff.ifds.isEmpty)
    }

    func testParseMinimalTIFF_BE() throws {
        let data = TestFixtures.minimalTIFF(byteOrder: .bigEndian)
        let tiff = try TIFFFileParser.parse(data)

        XCTAssertEqual(tiff.header.byteOrder, .bigEndian)
    }

    func testExtractExifFromTIFF() throws {
        let data = TestFixtures.tiffWithExif(make: "Nikon", model: "D850")
        let tiff = try TIFFFileParser.parse(data)

        let exif = try TIFFFileParser.extractExif(from: tiff, data: data)
        XCTAssertNotNil(exif)
        XCTAssertEqual(exif?.make, "Nikon")
        XCTAssertEqual(exif?.model, "D850")
    }

    func testExtractXMPFromTIFF() throws {
        let xmpXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            photoshop:Headline="TIFF XMP Test"/>
        </rdf:RDF>
        </x:xmpmeta>
        """
        let data = TestFixtures.tiffWithXMP(xml: xmpXML)
        let tiff = try TIFFFileParser.parse(data)

        let xmp = try TIFFFileParser.extractXMP(from: tiff)
        XCTAssertNotNil(xmp)
        XCTAssertEqual(xmp?.headline, "TIFF XMP Test")
    }

    func testParseEmptyTIFF() throws {
        let data = TestFixtures.minimalTIFF(entries: [])
        let tiff = try TIFFFileParser.parse(data)

        XCTAssertEqual(tiff.ifds.count, 1) // IFD0 with 0 entries
        XCTAssertTrue(tiff.ifd0!.entries.isEmpty)
    }

    func testReadMetadataFromTIFFData() throws {
        let data = TestFixtures.tiffWithExif(make: "Sony", model: "A7R V")
        let metadata = try ImageMetadata.read(from: data, format: .tiff)

        XCTAssertEqual(metadata.format, .tiff)
        XCTAssertEqual(metadata.exif?.make, "Sony")
        XCTAssertEqual(metadata.exif?.model, "A7R V")
    }

    func testTIFFByteOrderPreserved() throws {
        let beTIFF = TestFixtures.tiffWithExif(byteOrder: .bigEndian)
        let tiff = try TIFFFileParser.parse(beTIFF)
        XCTAssertEqual(tiff.header.byteOrder, .bigEndian)

        let exif = try TIFFFileParser.extractExif(from: tiff, data: beTIFF)
        XCTAssertEqual(exif?.byteOrder, .bigEndian)
    }

    func testInvalidTIFFThrows() {
        let garbage = Data(repeating: 0xAA, count: 20)
        XCTAssertThrowsError(try TIFFFileParser.parse(garbage))
    }
}
