import XCTest
@testable import SwiftMediaMetadata

/// Tests for the pure-Swift XML tokenizer that backs `XMPReader` (no libxml2). The broader XMP
/// suites already exercise nesting/prefixes/regions through it; these focus on the lexical
/// behavior the tokenizer is solely responsible for: entity decoding, CDATA, comments/PIs, and a
/// writer→reader round-trip with characters that must be escaped and decoded.
final class XMPPureTokenizerTests: XCTestCase {

    private func makeXMPData(xml: String) -> Data {
        var data = Data(JPEGSegment.xmpIdentifier)
        data.append(Data(xml.utf8))
        return data
    }

    func testDecodesEntitiesInAttributeAndText() throws {
        // Predefined entities and numeric refs (decimal + hex, incl. the &#xA; that writers emit
        // for newlines in attribute values) must decode in BOTH attribute and element-text positions.
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
                 xmlns:dc="http://purl.org/dc/elements/1.1/">
         <rdf:Description rdf:about="" photoshop:Headline="A &amp; B &lt; C&#xA;line2 &#169;">
          <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Tom &amp; Jerry &quot;quoted&quot;</rdf:li></rdf:Alt></dc:description>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        XCTAssertEqual(xmp.headline, "A & B < C\nline2 ©")
        XCTAssertEqual(xmp.description, "Tom & Jerry \"quoted\"")
    }

    func testCDATAIsLiteral() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:dc="http://purl.org/dc/elements/1.1/">
         <rdf:Description rdf:about="">
          <dc:description><rdf:Alt><rdf:li xml:lang="x-default"><![CDATA[a < b & c > d]]></rdf:li></rdf:Alt></dc:description>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        XCTAssertEqual(xmp.description, "a < b & c > d")
    }

    func testCommentsAndProcessingInstructionsSkipped() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <?xml-stylesheet type="text/xsl" href="x.xsl"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <!-- a comment with <tags> & entities that must be ignored -->
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
         <rdf:Description rdf:about="" photoshop:Headline="Kept"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        XCTAssertEqual(xmp.headline, "Kept")
    }

    func testWriterReaderRoundTripWithSpecialCharacters() throws {
        // Values that force escaping on write must decode back identically on read.
        var original = XMPData()
        original.headline = "Q&A: 5 < 6 \"really\""
        original.title = "Title & <Subtitle>"
        original.subject = ["a&b", "c<d", "normal"]

        let xml = XMPWriter.generateXML(original)
        let parsed = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertEqual(parsed.headline, "Q&A: 5 < 6 \"really\"")
        XCTAssertEqual(parsed.title, "Title & <Subtitle>")
        XCTAssertEqual(parsed.subject, ["a&b", "c<d", "normal"])
    }

    func testSelfClosingAndAttributeFormProperties() throws {
        // Attribute-form simple properties on a self-closing rdf:Description (how ACR / Capture One
        // write most crs fields) must parse, including the app-private aaphoto namespace.
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
                 xmlns:aaphoto="http://aagedal.me/ns/photo/1.0/">
         <rdf:Description rdf:about="" crs:Exposure2012="+0.50" crs:Temperature="5200" aaphoto:GlobalLayerIndex="2"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        XCTAssertEqual(xmp.simpleValue(namespace: "http://ns.adobe.com/camera-raw-settings/1.0/", property: "Exposure2012"), "+0.50")
        XCTAssertEqual(xmp.simpleValue(namespace: "http://ns.adobe.com/camera-raw-settings/1.0/", property: "Temperature"), "5200")
        XCTAssertEqual(xmp.simpleValue(namespace: "http://aagedal.me/ns/photo/1.0/", property: "GlobalLayerIndex"), "2")
    }
}
