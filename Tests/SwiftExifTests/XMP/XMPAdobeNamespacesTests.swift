import XCTest
@testable import SwiftExif

/// Phase C coverage: xmpMM (Adobe CC change tracking), pdf (PDF metadata), crs (Camera Raw).
///
/// xmpMM typed accessors cover the scalars only. History and DerivedFrom ride the existing
/// generic `.structure` / `.structuredArray` API — this file verifies that route round-trips.
/// crs: is prefix-registered only (no typed accessors); it must survive round-trip via the
/// generic XMPValue path.
final class XMPAdobeNamespacesTests: XCTestCase {

    private func makeXMPData(xml: String) -> Data {
        var data = Data(JPEGSegment.xmpIdentifier)
        data.append(Data(xml.utf8))
        return data
    }

    // MARK: - xmpMM:

    func testXmpMMScalarAccessorsRoundTrip() throws {
        var xmp = XMPData()
        xmp.documentID = "xmp.did:D1"
        xmp.instanceID = "xmp.iid:I1"
        xmp.originalDocumentID = "xmp.did:OD1"
        xmp.renditionClass = "default"
        xmp.versionID = "1"

        let data = XMPWriter.write(xmp)
        let decoded = try XMPReader.read(from: data)

        XCTAssertEqual(decoded.documentID, "xmp.did:D1")
        XCTAssertEqual(decoded.instanceID, "xmp.iid:I1")
        XCTAssertEqual(decoded.originalDocumentID, "xmp.did:OD1")
        XCTAssertEqual(decoded.renditionClass, "default")
        XCTAssertEqual(decoded.versionID, "1")
    }

    /// xmpMM:DerivedFrom is a stRef structure. Verify the generic structure API handles it
    /// without typed support — this is the promised fallback behavior.
    func testXmpMMDerivedFromRidesGenericAPI() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
                 xmlns:stRef="http://ns.adobe.com/xap/1.0/sType/ResourceRef#">
         <rdf:Description rdf:about="">
          <xmpMM:DerivedFrom rdf:parseType="Resource">
           <stRef:documentID>xmp.did:PARENT</stRef:documentID>
           <stRef:instanceID>xmp.iid:PARENT</stRef:instanceID>
           <stRef:renditionClass>default</stRef:renditionClass>
          </xmpMM:DerivedFrom>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        let fields = xmp.structureValue(namespace: XMPNamespace.xmpMM, property: "DerivedFrom")
        XCTAssertNotNil(fields)
        XCTAssertEqual(fields?["\(XMPNamespace.stRef)documentID"], "xmp.did:PARENT")
        XCTAssertEqual(fields?["\(XMPNamespace.stRef)instanceID"], "xmp.iid:PARENT")
        XCTAssertEqual(fields?["\(XMPNamespace.stRef)renditionClass"], "default")
    }

    // MARK: - pdf:

    func testPDFAccessorsRoundTrip() throws {
        var xmp = XMPData()
        xmp.pdfProducer = "SwiftExif"
        xmp.pdfKeywords = "news; photo; breaking"
        xmp.pdfVersion = "1.7"
        xmp.pdfTrapped = "False"

        let data = XMPWriter.write(xmp)
        let decoded = try XMPReader.read(from: data)

        XCTAssertEqual(decoded.pdfProducer, "SwiftExif")
        XCTAssertEqual(decoded.pdfKeywords, "news; photo; breaking")
        XCTAssertEqual(decoded.pdfVersion, "1.7")
        XCTAssertEqual(decoded.pdfTrapped, "False")
    }

    // MARK: - crs:

    /// crs: is prefix-registered only (no typed accessors). A Lightroom-authored document with
    /// crs:* properties must round-trip via the generic XMPData API — callers edit via
    /// `setValue(_:namespace:property:)`.
    func testCrsRoundTripViaGenericAPI() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
         <rdf:Description rdf:about=""
                          crs:Version="15.0"
                          crs:Exposure2012="+0.35"
                          crs:Contrast2012="+10"
                          crs:Highlights2012="-25"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        XCTAssertEqual(xmp.simpleValue(namespace: XMPNamespace.crs, property: "Version"), "15.0")
        XCTAssertEqual(xmp.simpleValue(namespace: XMPNamespace.crs, property: "Exposure2012"), "+0.35")
        XCTAssertEqual(xmp.simpleValue(namespace: XMPNamespace.crs, property: "Contrast2012"), "+10")
        XCTAssertEqual(xmp.simpleValue(namespace: XMPNamespace.crs, property: "Highlights2012"), "-25")

        // Now write and re-read — prefix registration makes it survive serialization.
        var edited = xmp
        edited.setValue(.simple("+0.50"), namespace: XMPNamespace.crs, property: "Exposure2012")

        let roundTripped = try XMPReader.read(from: XMPWriter.write(edited))
        XCTAssertEqual(roundTripped.simpleValue(namespace: XMPNamespace.crs, property: "Exposure2012"), "+0.50")
        XCTAssertEqual(roundTripped.simpleValue(namespace: XMPNamespace.crs, property: "Version"), "15.0")
    }

    func testCrsPrefixIsRegistered() {
        XCTAssertEqual(XMPNamespace.namespace(for: "crs"), XMPNamespace.crs)
        XCTAssertEqual(XMPNamespace.prefixes[XMPNamespace.crs], "crs")
    }
}
