import XCTest
@testable import SwiftMediaMetadata

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

    /// XMP packets in real files (Sony JPEG out of camera, Capture One exports,
    /// some Lightroom writers) frequently end with `<?xpacket end="w"?>` followed
    /// by a NUL byte or non-whitespace garbage as padding. NSXMLParser rejects
    /// extra content past the root element, so the reader must trim it first.
    func testParsesXMPWithTrailingNullAfterXPacketEnd() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
         <rdf:Description rdf:about="" photoshop:Headline="Sony out-of-camera"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        // Producer pads with trailing NUL (and a stray space) after the closing PI.
        var payload = Data(JPEGSegment.xmpIdentifier)
        payload.append(Data(xml.utf8))
        payload.append(contentsOf: [0x20, 0x00, 0x00])

        let xmp = try XMPReader.read(from: payload)
        XCTAssertEqual(xmp.headline, "Sony out-of-camera")
    }

    /// Some XMP packets carry whitespace + NUL padding *between* the closing
    /// `</x:xmpmeta>` and `<?xpacket end="..."?>` (Adobe's in-place-edit padding
    /// region). The trimmer must not chop into that — it should only drop
    /// bytes past the closing `?>` of the xpacket end PI.
    func testParsesXMPWithPaddingBeforeXPacketEnd() throws {
        let padding = String(repeating: " ", count: 200)
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
         <rdf:Description rdf:about="" photoshop:Headline="With padding"/>
        </rdf:RDF>
        </x:xmpmeta>\(padding)
        <?xpacket end="w"?>
        """
        var payload = Data(JPEGSegment.xmpIdentifier)
        payload.append(Data(xml.utf8))
        payload.append(0x00)

        let xmp = try XMPReader.read(from: payload)
        XCTAssertEqual(xmp.headline, "With padding")
    }

    /// XMP packets without the optional `<?xpacket ...?>` wrapper (rare, but
    /// permitted by the spec for embedded XMP in things like JPEG XL `xml` boxes)
    /// must still parse when the producer trailed a NUL byte.
    func testParsesBareXMPWithTrailingNull() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
         <rdf:Description rdf:about="" photoshop:Headline="Bare"/>
        </rdf:RDF>
        </x:xmpmeta>
        """
        var data = Data(xml.utf8)
        data.append(contentsOf: [0x00, 0x00, 0x00])

        let xmp = try XMPReader.readFromXML(data)
        XCTAssertEqual(xmp.headline, "Bare")
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
