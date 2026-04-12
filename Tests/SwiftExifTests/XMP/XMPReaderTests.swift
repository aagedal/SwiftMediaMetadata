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
}
