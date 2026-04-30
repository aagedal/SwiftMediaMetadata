import XCTest
@testable import SwiftExif

/// Round-trip coverage for the namespaces added in Phase 19c:
/// - Google Spatial / MotionPhoto (GPano, GCamera, GAudio, GImage, GDepth, GFocus)
/// - Adobe Lightroom (lr — hierarchical keywords)
/// - Creative Commons (cc)
/// - PRISM (publishing wire-service metadata)
/// - C2PA-XMP (provenance that survives JUMBF strip)
///
/// Reading was already generic for any namespace declared in `xmlns:` — the
/// gap was the writer, which only emitted prefixes for namespaces it knew
/// about, so round-tripping silently dropped these properties.
final class XMPGoogleSpatialNamespacesTests: XCTestCase {

    // MARK: - Lightroom hierarchicalSubject

    func testLightroomHierarchicalSubjectRoundTrip() throws {
        var xmp = XMPData()
        xmp.hierarchicalSubject = [
            "Family|Vacation|Beach",
            "Locations|Norway|Oslo",
            "People|Photographer",
        ]

        let xml = XMPWriter.generateXML(xmp)
        XCTAssertTrue(xml.contains("xmlns:lr=\"\(XMPNamespace.lr)\""),
                      "writer must declare the lr: prefix")

        let decoded = try XMPReader.read(from: XMPWriter.write(xmp))
        XCTAssertEqual(decoded.hierarchicalSubject, [
            "Family|Vacation|Beach",
            "Locations|Norway|Oslo",
            "People|Photographer",
        ])
    }

    func testLightroomNamespaceParsesFromExternalXML() throws {
        // External XMP that uses the lr: namespace declared with a non-default
        // prefix mapping. The reader stores by URI, so the prefix is irrelevant.
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="\(XMPNamespace.rdf)" xmlns:lr="\(XMPNamespace.lr)">
         <rdf:Description rdf:about="">
          <lr:hierarchicalSubject>
           <rdf:Bag>
            <rdf:li>Pets|Cats|Tabby</rdf:li>
           </rdf:Bag>
          </lr:hierarchicalSubject>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let xmp = try XMPReader.readFromXML(Data(xml.utf8))
        XCTAssertEqual(xmp.hierarchicalSubject, ["Pets|Cats|Tabby"])
    }

    // MARK: - Creative Commons

    func testCreativeCommonsRoundTrip() throws {
        var xmp = XMPData()
        xmp.creativeCommonsLicense = "https://creativecommons.org/licenses/by-sa/4.0/"
        xmp.creativeCommonsAttributionURL = "https://aagedal.me/photo/123"

        let xml = XMPWriter.generateXML(xmp)
        XCTAssertTrue(xml.contains("xmlns:cc=\"\(XMPNamespace.cc)\""))

        let decoded = try XMPReader.read(from: XMPWriter.write(xmp))
        XCTAssertEqual(decoded.creativeCommonsLicense,
                       "https://creativecommons.org/licenses/by-sa/4.0/")
        XCTAssertEqual(decoded.creativeCommonsAttributionURL,
                       "https://aagedal.me/photo/123")
    }

    // MARK: - Google MotionPhoto / GPano

    func testGoogleMotionPhotoFlag() throws {
        var xmp = XMPData()
        xmp.setValue(.simple("1"), namespace: XMPNamespace.gCamera, property: "MotionPhoto")
        xmp.setValue(.simple("123456"), namespace: XMPNamespace.gCamera, property: "MicroVideoOffset")

        let xml = XMPWriter.generateXML(xmp)
        XCTAssertTrue(xml.contains("xmlns:GCamera=\"\(XMPNamespace.gCamera)\""))

        let decoded = try XMPReader.read(from: XMPWriter.write(xmp))
        XCTAssertTrue(decoded.isGoogleMotionPhoto)
        XCTAssertEqual(decoded.googleMicroVideoOffset, 123_456)
    }

    func testGooglePanoramaProperties() throws {
        var xmp = XMPData()
        xmp.setValue(.simple("equirectangular"),
                     namespace: XMPNamespace.gPano, property: "ProjectionType")
        xmp.setValue(.simple("8192"),
                     namespace: XMPNamespace.gPano, property: "FullPanoWidthPixels")
        xmp.setValue(.simple("4096"),
                     namespace: XMPNamespace.gPano, property: "FullPanoHeightPixels")

        let xml = XMPWriter.generateXML(xmp)
        XCTAssertTrue(xml.contains("xmlns:GPano=\"\(XMPNamespace.gPano)\""))

        let decoded = try XMPReader.read(from: XMPWriter.write(xmp))
        XCTAssertEqual(decoded.panoramaProjectionType, "equirectangular")
        XCTAssertEqual(decoded.panoramaFullWidth, 8192)
        XCTAssertEqual(decoded.panoramaFullHeight, 4096)
    }

    // MARK: - Generic namespace coverage

    func testNewlyRegisteredNamespacePrefixesResolve() {
        XCTAssertEqual(XMPNamespace.prefixes[XMPNamespace.lr], "lr")
        XCTAssertEqual(XMPNamespace.prefixes[XMPNamespace.cc], "cc")
        XCTAssertEqual(XMPNamespace.prefixes[XMPNamespace.prism], "prism")
        XCTAssertEqual(XMPNamespace.prefixes[XMPNamespace.c2pa], "c2pa")
        XCTAssertEqual(XMPNamespace.prefixes[XMPNamespace.gPano], "GPano")
        XCTAssertEqual(XMPNamespace.prefixes[XMPNamespace.gCamera], "GCamera")
        XCTAssertEqual(XMPNamespace.prefixes[XMPNamespace.gAudio], "GAudio")
        XCTAssertEqual(XMPNamespace.prefixes[XMPNamespace.gImage], "GImage")
        XCTAssertEqual(XMPNamespace.prefixes[XMPNamespace.gDepth], "GDepth")
        XCTAssertEqual(XMPNamespace.prefixes[XMPNamespace.gFocus], "GFocus")
    }

    func testGenericReadOfPrismProperty() throws {
        // Wire-service-style PRISM property: prism:publicationName.
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="\(XMPNamespace.rdf)" xmlns:prism="\(XMPNamespace.prism)">
         <rdf:Description rdf:about="" prism:publicationName="NRK Aftenposten"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let xmp = try XMPReader.readFromXML(Data(xml.utf8))
        XCTAssertEqual(
            xmp.simpleValue(namespace: XMPNamespace.prism, property: "publicationName"),
            "NRK Aftenposten"
        )
    }

    func testHierarchicalSubjectRemovalClearsValue() {
        var xmp = XMPData()
        xmp.hierarchicalSubject = ["A|B"]
        XCTAssertEqual(xmp.hierarchicalSubject, ["A|B"])
        xmp.hierarchicalSubject = []
        XCTAssertEqual(xmp.hierarchicalSubject, [])
        XCTAssertNil(xmp.value(namespace: XMPNamespace.lr, property: "hierarchicalSubject"))
    }
}
