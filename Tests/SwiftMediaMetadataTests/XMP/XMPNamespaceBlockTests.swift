import XCTest
@testable import SwiftMediaMetadata

/// Namespace-block APIs: properties(in:), removeAll(namespace:), replaceAll(namespace:from:).
/// The motivating use case is crs block replacement — swapping a file's entire
/// Camera Raw settings block for another file's.
final class XMPNamespaceBlockTests: XCTestCase {

    private let crs = XMPNamespace.crs

    func testPropertiesInNamespaceKeyedByLocalName() {
        var xmp = XMPData()
        xmp.setValue(.simple("50"), namespace: crs, property: "Contrast2012")
        xmp.setValue(.simple("+0.5"), namespace: crs, property: "Exposure2012")
        xmp.title = "Unrelated"

        let block = xmp.properties(in: crs)
        XCTAssertEqual(block.count, 2)
        XCTAssertEqual(block["Contrast2012"], .simple("50"))
        XCTAssertEqual(block["Exposure2012"], .simple("+0.5"))
    }

    func testRemoveAllRemovesOnlyTargetNamespace() {
        var xmp = XMPData()
        xmp.setValue(.simple("50"), namespace: crs, property: "Contrast2012")
        xmp.setValue(.array(["a", "b"]), namespace: crs, property: "ToneCurve")
        xmp.title = "Keep me"
        xmp.subject = ["keep"]

        xmp.removeAll(namespace: crs)

        XCTAssertTrue(xmp.properties(in: crs).isEmpty)
        XCTAssertEqual(xmp.title, "Keep me")
        XCTAssertEqual(xmp.subject, ["keep"])
    }

    func testRemoveAllIsNamespaceExact() {
        // Adobe URIs nest: xmpRights/xmpMM/stEvt all start with the xmp URI.
        // Removing the xmp block must not touch them.
        var xmp = XMPData()
        xmp.setValue(.simple("5"), namespace: XMPNamespace.xmp, property: "Rating")
        xmp.setValue(.simple("True"), namespace: XMPNamespace.xmpRights, property: "Marked")
        xmp.setValue(.simple("uuid:1"), namespace: XMPNamespace.xmpMM, property: "DocumentID")

        xmp.removeAll(namespace: XMPNamespace.xmp)

        XCTAssertNil(xmp.value(namespace: XMPNamespace.xmp, property: "Rating"))
        XCTAssertEqual(xmp.simpleValue(namespace: XMPNamespace.xmpRights, property: "Marked"), "True")
        XCTAssertEqual(xmp.simpleValue(namespace: XMPNamespace.xmpMM, property: "DocumentID"), "uuid:1")
    }

    func testReplaceAllSwapsCrsBlock() {
        var target = XMPData()
        target.setValue(.simple("10"), namespace: crs, property: "Saturation")
        target.setValue(.simple("old"), namespace: crs, property: "LookName")
        target.title = "Untouched"

        var source = XMPData()
        source.setValue(.simple("50"), namespace: crs, property: "Contrast2012")
        source.creator = ["Source Author"] // outside the block — must not leak

        target.replaceAll(namespace: crs, from: source)

        let block = target.properties(in: crs)
        XCTAssertEqual(block, ["Contrast2012": .simple("50")])
        XCTAssertEqual(target.title, "Untouched")
        XCTAssertEqual(target.creator, [], "dc must not leak from the source")
    }

    func testReplaceAllCarriesObservedArrayForm() throws {
        // The source's parsed rdf container form must travel with the block so the
        // next write keeps the original Bag/Seq shape (vendor namespace — not
        // covered by the writer's spec table).
        let sourceXML = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:digiKam="http://www.digikam.org/ns/1.0/">
          <digiKam:TagsList>
           <rdf:Seq>
            <rdf:li>People/Family</rdf:li>
           </rdf:Seq>
          </digiKam:TagsList>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        """
        let source = try XMPReader.readFromXML(Data(sourceXML.utf8))
        let digiKam = "http://www.digikam.org/ns/1.0/"

        var target = XMPData()
        target.headline = "Existing"
        target.replaceAll(namespace: digiKam, from: source)

        XCTAssertEqual(target.arrayValue(namespace: digiKam, property: "TagsList"), ["People/Family"])
        let xml = XMPWriter.generateXML(target)
        XCTAssertTrue(xml.contains("<rdf:Seq>"), "observed Seq form must survive the block copy")
    }

    func testRemoveAllClearsObservedArrayForms() throws {
        // After removing a block, re-adding an array under the same key must not
        // resurrect the old container form.
        let sourceXML = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:digiKam="http://www.digikam.org/ns/1.0/">
          <digiKam:TagsList>
           <rdf:Seq>
            <rdf:li>People/Family</rdf:li>
           </rdf:Seq>
          </digiKam:TagsList>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        """
        var xmp = try XMPReader.readFromXML(Data(sourceXML.utf8))
        let digiKam = "http://www.digikam.org/ns/1.0/"

        xmp.removeAll(namespace: digiKam)
        xmp.setValue(.array(["fresh"]), namespace: digiKam, property: "TagsList")

        let xml = XMPWriter.generateXML(xmp)
        XCTAssertTrue(xml.contains("<rdf:Bag>"), "form record should have been cleared with the block")
        XCTAssertFalse(xml.contains("<rdf:Seq>"))
    }
}
