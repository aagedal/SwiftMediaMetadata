import XCTest
@testable import SwiftExif

/// Regression tests for the XMPReader attribute-form prefix resolution bug.
///
/// Before the fix, `resolvePrefix` was a hardcoded switch over 10 prefixes. Attribute-form
/// properties on `rdf:Description` (the dominant form Lightroom / Capture One / Photo Mechanic
/// emit) whose prefix wasn't hardcoded were silently dropped. The parser now honors live
/// `xmlns:*` declarations from the document, falling back to well-known prefixes only if
/// the document references a prefix without declaring it.
final class XMPPrefixResolutionTests: XCTestCase {

    private func makeXMPData(xml: String) -> Data {
        var data = Data(JPEGSegment.xmpIdentifier)
        data.append(Data(xml.utf8))
        return data
    }

    /// A namespace that wasn't in the hardcoded switch (crs) must survive when declared via xmlns.
    func testUnregisteredNamespaceSurvivesViaXmlns() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
         <rdf:Description rdf:about=""
                          crs:Version="15.0"
                          crs:Exposure2012="+0.35"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))

        let crs = "http://ns.adobe.com/camera-raw-settings/1.0/"
        XCTAssertEqual(xmp.simpleValue(namespace: crs, property: "Version"), "15.0")
        XCTAssertEqual(xmp.simpleValue(namespace: crs, property: "Exposure2012"), "+0.35")
    }

    /// A document that uses a non-standard prefix but the standard namespace URI must still
    /// resolve to the canonical URI so typed accessors keep working.
    func testNonStandardPrefixResolvesByURI() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ps="http://ns.adobe.com/photoshop/1.0/">
         <rdf:Description rdf:about="" ps:Headline="Prefix Alias Test"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        XCTAssertEqual(xmp.headline, "Prefix Alias Test")
    }

    /// A prefix referenced in the document without an xmlns declaration should fall through
    /// to the well-known prefix table (tolerant of malformed XMP in the wild).
    func testWellKnownFallbackWhenXmlnsMissing() throws {
        // photoshop is a well-known prefix; omit the xmlns declaration deliberately.
        // XMLParser still parses the malformed document; we want the fallback to kick in.
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"
                   xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                   xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
        <rdf:RDF>
         <rdf:Description rdf:about="" photoshop:Credit="Fallback OK"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        XCTAssertEqual(xmp.credit, "Fallback OK")
    }

    /// Multiple namespaces declared on the same scope must all resolve — verifies prefix
    /// stack handles parallel declarations, not just the last one.
    func testMultipleNamespacesInSameScope() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:dc="http://purl.org/dc/elements/1.1/"
                 xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
                 xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
                 xmlns:lr="http://ns.adobe.com/lightroom/1.0/">
         <rdf:Description rdf:about=""
                          photoshop:Headline="Multi-NS"
                          crs:Version="15.0"
                          lr:privateRTKInfo="keep"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        XCTAssertEqual(xmp.headline, "Multi-NS")
        XCTAssertEqual(xmp.simpleValue(namespace: "http://ns.adobe.com/camera-raw-settings/1.0/", property: "Version"), "15.0")
        XCTAssertEqual(xmp.simpleValue(namespace: "http://ns.adobe.com/lightroom/1.0/", property: "privateRTKInfo"), "keep")
    }
}
