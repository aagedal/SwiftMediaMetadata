import XCTest
@testable import SwiftExif

final class GIFWriterTests: XCTestCase {

    func testRawPassThroughWhenNoXMPChange() throws {
        let original = TestFixtures.minimalGIF()
        let file = try GIFParser.parse(original)
        let written = GIFWriter.write(file, xmp: nil)

        XCTAssertEqual(written, original, "GIF without XMP should pass through unchanged")
    }

    func testInsertXMPWhenSourceHasNone() throws {
        let original = TestFixtures.minimalGIF()
        var file = try GIFParser.parse(original)

        var xmp = XMPData()
        xmp.headline = "Inserted Headline"
        xmp.city = "Stockholm"

        let written = GIFWriter.write(file, xmp: xmp)
        let reparsed = try GIFParser.parse(written)

        XCTAssertNotNil(reparsed.findXMPExtension(), "writer should insert XMP application extension")

        let extracted = try GIFParser.extractXMP(from: reparsed)
        XCTAssertEqual(extracted?.headline, "Inserted Headline")
        XCTAssertEqual(extracted?.city, "Stockholm")

        // No silent mutation of the input file struct.
        _ = file
    }

    func testReplaceExistingXMP() throws {
        let oldXML = makeXMPXML(headline: "Old Headline", city: "Helsinki")
        let original = TestFixtures.gifWithXMP(xml: oldXML)
        let file = try GIFParser.parse(original)

        var newXMP = XMPData()
        newXMP.headline = "New Headline"
        newXMP.city = "Reykjavík"

        let written = GIFWriter.write(file, xmp: newXMP)
        let reparsed = try GIFParser.parse(written)

        let extracted = try GIFParser.extractXMP(from: reparsed)
        XCTAssertEqual(extracted?.headline, "New Headline")
        XCTAssertEqual(extracted?.city, "Reykjavík")

        // Exactly one XMP application extension — no duplication.
        let xmpAppCount = reparsed.blocks.reduce(0) { acc, b in
            if case .applicationExtension(let id, _, _) = b.type, id == "XMP Data" { return acc + 1 }
            return acc
        }
        XCTAssertEqual(xmpAppCount, 1, "must not duplicate XMP extension on replace")
    }

    func testStripXMPWhenNil() throws {
        let xml = makeXMPXML(headline: "Will Be Removed", city: "Tromsø")
        let original = TestFixtures.gifWithXMP(xml: xml)
        let file = try GIFParser.parse(original)

        let written = GIFWriter.write(file, xmp: nil)
        let reparsed = try GIFParser.parse(written)

        XCTAssertNil(reparsed.findXMPExtension(), "XMP extension should be stripped when xmp is nil")
    }

    func testCommentExtensionPreservedOnReWrite() throws {
        let comment = "Comment that should survive a round trip"
        let original = TestFixtures.minimalGIF(extraBlocks: [TestFixtures.gifCommentBlock(comment)])
        let file = try GIFParser.parse(original)

        // Round-trip with an unrelated XMP edit so the writer rebuilds blocks.
        var xmp = XMPData()
        xmp.headline = "Trigger rebuild"
        let written = GIFWriter.write(file, xmp: xmp)
        let reparsed = try GIFParser.parse(written)

        XCTAssertEqual(reparsed.comments, [comment])
    }

    private func makeXMPXML(headline: String, city: String) -> String {
        """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                   xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
            <rdf:Description rdf:about=""
                             photoshop:Headline="\(headline)"
                             photoshop:City="\(city)"/>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }
}
