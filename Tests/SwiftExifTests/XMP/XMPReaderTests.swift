import XCTest
@testable import SwiftExif

final class XMPReaderTests: XCTestCase {

    private func makeXMPData(xml: String) -> Data {
        var data = Data(JPEGSegment.xmpIdentifier)
        data.append(Data(xml.utf8))
        return data
    }

    func testParseSimpleProperty() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
         <rdf:Description rdf:about="" photoshop:Headline="Test Headline"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        XCTAssertEqual(xmp.headline, "Test Headline")
    }

    func testParseBag() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:dc="http://purl.org/dc/elements/1.1/">
         <rdf:Description rdf:about="">
          <dc:subject>
           <rdf:Bag>
            <rdf:li>news</rdf:li>
            <rdf:li>photo</rdf:li>
            <rdf:li>breaking</rdf:li>
           </rdf:Bag>
          </dc:subject>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        XCTAssertEqual(xmp.subject, ["news", "photo", "breaking"])
    }

    func testParseLangAlternative() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:dc="http://purl.org/dc/elements/1.1/">
         <rdf:Description rdf:about="">
          <dc:title>
           <rdf:Alt>
            <rdf:li xml:lang="x-default">Test Title</rdf:li>
           </rdf:Alt>
          </dc:title>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        XCTAssertEqual(xmp.title, "Test Title")
    }

    func testParseMultipleNamespaces() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:dc="http://purl.org/dc/elements/1.1/"
                 xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
         <rdf:Description rdf:about=""
            photoshop:Headline="Test"
            photoshop:City="Oslo"
            photoshop:Country="Norway"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        XCTAssertEqual(xmp.headline, "Test")
        XCTAssertEqual(xmp.city, "Oslo")
        XCTAssertEqual(xmp.country, "Norway")
    }

    func testInvalidXMPThrows() {
        let data = Data("Not XMP data".utf8)
        XCTAssertThrowsError(try XMPReader.read(from: data))
    }

    /// Frame-stack depth cap: a packet with deeply nested struct fields should
    /// abort cleanly with an `invalidXMP` error instead of unbounded growth or
    /// stack overflow.
    func testRejectsDeeplyNestedStructures() throws {
        let ns = "http://ns.adobe.com/camera-raw-settings/1.0/"
        let layers = XMPReader.maxFrameDepth + 20

        // Build {Field0: {Field1: {Field2: ... {FieldN: "leaf"}}}} programmatically.
        var current: XMPValue = .simple("leaf")
        for i in (0..<layers).reversed() {
            current = .structure(["\(ns)Field\(i)": current])
        }

        var xmp = XMPData()
        xmp.setValue(current, namespace: ns, property: "Top")

        let xml = XMPWriter.generateXML(xmp)
        XCTAssertThrowsError(try XMPReader.readFromXML(Data(xml.utf8))) { error in
            guard case MetadataError.invalidXMP = error else {
                XCTFail("Expected invalidXMP, got \(error)")
                return
            }
        }
    }
}
