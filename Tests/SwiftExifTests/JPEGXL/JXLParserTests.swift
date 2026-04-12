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
}
