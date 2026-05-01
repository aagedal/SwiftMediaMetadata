import XCTest
@testable import SwiftExif

final class JXLParserTests: XCTestCase {

    func testParseContainerJXL() throws {
        let jxl = TestFixtures.minimalJXL()
        let file = try JXLParser.parse(jxl)

        XCTAssertTrue(file.isContainer)
    }

    func testParseBareCodestream() throws {
        let jxl = TestFixtures.bareJXLCodestream()
        let file = try JXLParser.parse(jxl)

        XCTAssertFalse(file.isContainer)
        XCTAssertTrue(file.boxes.isEmpty)
    }

    func testJXLWithExifBox() throws {
        let jxl = TestFixtures.jxlWithExif(make: "Leica", model: "Q3")
        let file = try JXLParser.parse(jxl)

        XCTAssertTrue(file.isContainer)
        let exifBox = file.findBox("Exif")
        XCTAssertNotNil(exifBox)
    }

    func testExtractExifFromJXL() throws {
        let jxl = TestFixtures.jxlWithExif(make: "Leica", model: "Q3")
        let metadata = try ImageMetadata.read(from: jxl)

        XCTAssertEqual(metadata.format, .jpegXL)
        XCTAssertNotNil(metadata.exif)
        XCTAssertEqual(metadata.exif?.make, "Leica")
        XCTAssertEqual(metadata.exif?.model, "Q3")
    }

    func testJXLWithXMPBox() throws {
        let xmpXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            photoshop:Headline="JXL XMP Test"/>
        </rdf:RDF>
        </x:xmpmeta>
        """
        let jxl = TestFixtures.minimalJXL(boxes: [(type: "xml ", data: Data(xmpXML.utf8))])
        let metadata = try ImageMetadata.read(from: jxl)

        XCTAssertEqual(metadata.format, .jpegXL)
        XCTAssertNotNil(metadata.xmp)
        XCTAssertEqual(metadata.xmp?.headline, "JXL XMP Test")
    }

    func testJXLWithExifAndXMP() throws {
        let xmpXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            photoshop:Headline="Both"/>
        </rdf:RDF>
        </x:xmpmeta>
        """
        var exifPayload = Data([0x00, 0x00, 0x00, 0x00])
        exifPayload.append(TestFixtures.tiffWithExif(make: "Canon", model: "R6"))

        let jxl = TestFixtures.minimalJXL(boxes: [
            (type: "Exif", data: exifPayload),
            (type: "xml ", data: Data(xmpXML.utf8)),
        ])
        let metadata = try ImageMetadata.read(from: jxl)

        XCTAssertEqual(metadata.exif?.make, "Canon")
        XCTAssertEqual(metadata.xmp?.headline, "Both")
    }

    func testBareCodestreamHasNoMetadata() throws {
        let jxl = TestFixtures.bareJXLCodestream()
        let metadata = try ImageMetadata.read(from: jxl)

        XCTAssertNil(metadata.exif)
        XCTAssertNil(metadata.xmp)
    }

    func testInvalidJXLThrows() {
        let garbage = Data(repeating: 0xBB, count: 20)
        XCTAssertThrowsError(try JXLParser.parse(garbage))
    }

    // MARK: - SizeHeader decoding

    /// Real bytes from a 3840×2160 bare-codestream JXL: after the
    /// `FF 0A` signature, the next bytes encode small_picture=0,
    /// y_selector=1 (13 bits), ysize=2160, ratio=5 (16:9). Verifies
    /// the LSB-first bit-reader and the aspect-ratio table.
    func testSizeHeaderBareCodestream3840x2160() {
        let payload = Data([0x7A, 0x43, 0x15])
        let dims = JXLParser.decodeSizeHeader(payload)
        XCTAssertEqual(dims?.width, 3840)
        XCTAssertEqual(dims?.height, 2160)
    }

    /// Real bytes from an 8640×5760 jxlp-container JXL (3:2 aspect).
    func testSizeHeaderContainer8640x5760() {
        let payload = Data([0xFA, 0xB3, 0x14])
        let dims = JXLParser.decodeSizeHeader(payload)
        XCTAssertEqual(dims?.width, 8640)
        XCTAssertEqual(dims?.height, 5760)
    }

    /// Real bytes from a 4000×2667 jxlp-container JXL (3:2 aspect with
    /// integer-division rounding: 2667*3/2 floors to 4000).
    func testSizeHeaderContainer4000x2667() {
        let payload = Data([0x52, 0x53, 0x14])
        let dims = JXLParser.decodeSizeHeader(payload)
        XCTAssertEqual(dims?.width, 4000)
        XCTAssertEqual(dims?.height, 2667)
    }

    /// End-to-end: a real bare-codestream JXL header should round-trip
    /// to (3840, 2160) through `JXLParser.parse`.
    func testParseBareCodestreamPopulatesDimensions() throws {
        let jxl = Data([0xFF, 0x0A, 0x7A, 0x43, 0x15])
        let file = try JXLParser.parse(jxl)
        XCTAssertEqual(file.imageDimensions?.width, 3840)
        XCTAssertEqual(file.imageDimensions?.height, 2160)
    }
}
