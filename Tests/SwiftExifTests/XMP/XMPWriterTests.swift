import XCTest
@testable import SwiftExif

final class XMPWriterTests: XCTestCase {

    func testWriteSimpleProperty() {
        var xmp = XMPData()
        xmp.headline = "Test Headline"

        let xml = XMPWriter.generateXML(xmp)
        XCTAssertTrue(xml.contains("photoshop:Headline=\"Test Headline\""))
        XCTAssertTrue(xml.contains("xmlns:photoshop"))
        XCTAssertTrue(xml.contains("<?xpacket begin"))
        XCTAssertTrue(xml.contains("<?xpacket end"))
    }

    func testWriteBag() {
        var xmp = XMPData()
        xmp.subject = ["news", "photo", "breaking"]

        let xml = XMPWriter.generateXML(xmp)
        XCTAssertTrue(xml.contains("rdf:Bag"))
        XCTAssertTrue(xml.contains("<rdf:li>news</rdf:li>"))
        XCTAssertTrue(xml.contains("<rdf:li>photo</rdf:li>"))
        XCTAssertTrue(xml.contains("<rdf:li>breaking</rdf:li>"))
    }

    func testWriteLangAlternative() {
        var xmp = XMPData()
        xmp.title = "Test Title"

        let xml = XMPWriter.generateXML(xmp)
        XCTAssertTrue(xml.contains("rdf:Alt"))
        XCTAssertTrue(xml.contains("xml:lang=\"x-default\""))
        XCTAssertTrue(xml.contains("Test Title"))
    }

    func testWriteIncludesPadding() {
        var xmp = XMPData()
        xmp.headline = "Short"

        let data = XMPWriter.write(xmp)
        // Should be significantly larger than the actual content due to padding
        XCTAssertGreaterThan(data.count, 2048)
    }

    func testWriteXMLEscaping() {
        var xmp = XMPData()
        xmp.headline = "Test & <special> \"chars\""

        let xml = XMPWriter.generateXML(xmp)
        XCTAssertTrue(xml.contains("&amp;"))
        XCTAssertTrue(xml.contains("&lt;"))
        XCTAssertTrue(xml.contains("&gt;"))
        XCTAssertTrue(xml.contains("&quot;"))
    }

    func testWriteNordicCharacters() {
        var xmp = XMPData()
        xmp.headline = "Tromsø havn"
        xmp.city = "Tromsø"

        let xml = XMPWriter.generateXML(xmp)
        XCTAssertTrue(xml.contains("Tromsø"))
    }

    // MARK: - xmp: Basic namespace round-trips (Phase A2)

    func testXMPBasicRoundTrip() throws {
        var xmp = XMPData()
        xmp.rating = 4
        xmp.label = "Red"
        xmp.createDate = "2026-04-18T12:34:56+02:00"
        xmp.modifyDate = "2026-04-18T13:00:00+02:00"
        xmp.metadataDate = "2026-04-18T13:00:00+02:00"
        xmp.creatorTool = "SwiftExif"
        xmp.identifier = ["uuid:abc", "doi:10.0000/x"]
        xmp.nickname = "Banner"

        let data = XMPWriter.write(xmp)
        let decoded = try XMPReader.read(from: data)

        XCTAssertEqual(decoded.rating, 4)
        XCTAssertEqual(decoded.label, "Red")
        XCTAssertEqual(decoded.createDate, "2026-04-18T12:34:56+02:00")
        XCTAssertEqual(decoded.modifyDate, "2026-04-18T13:00:00+02:00")
        XCTAssertEqual(decoded.metadataDate, "2026-04-18T13:00:00+02:00")
        XCTAssertEqual(decoded.creatorTool, "SwiftExif")
        XCTAssertEqual(decoded.identifier, ["uuid:abc", "doi:10.0000/x"])
        XCTAssertEqual(decoded.nickname, "Banner")
    }

    func testRatingHalfStarIsPreserved() throws {
        var xmp = XMPData()
        xmp.rating = 3.5

        let data = XMPWriter.write(xmp)
        let decoded = try XMPReader.read(from: data)
        XCTAssertEqual(decoded.rating, 3.5)
    }

    func testRatingClampsOutOfRange() {
        var xmp = XMPData()
        xmp.rating = 7.0
        XCTAssertEqual(xmp.rating, 5.0)

        xmp.rating = -1.0
        XCTAssertEqual(xmp.rating, 0.0)
    }

    func testRatingRemoval() {
        var xmp = XMPData()
        xmp.rating = 3
        xmp.rating = nil
        XCTAssertNil(xmp.rating)
    }

    // MARK: - Round-trip fidelity

    func testUnknownNamespacePropertySurvivesRewrite() throws {
        // digiKam's namespace is not in XMPNamespace.prefixes — the reader stores it
        // (it honors the document's live xmlns declarations), so the writer must not
        // silently drop it on rewrite.
        let source = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about=""
            xmlns:digiKam="http://www.digikam.org/ns/1.0/"
            digiKam:ColorLabel="3">
          <digiKam:TagsList>
           <rdf:Seq>
            <rdf:li>People/Family</rdf:li>
            <rdf:li>Places/Norway</rdf:li>
           </rdf:Seq>
          </digiKam:TagsList>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        """
        let parsed = try XMPReader.readFromXML(Data(source.utf8))
        let ns = "http://www.digikam.org/ns/1.0/"
        XCTAssertEqual(parsed.simpleValue(namespace: ns, property: "ColorLabel"), "3")
        XCTAssertEqual(parsed.arrayValue(namespace: ns, property: "TagsList"), ["People/Family", "Places/Norway"])

        let rewritten = XMPWriter.generateXML(parsed)
        let reparsed = try XMPReader.readFromXML(Data(rewritten.utf8))
        XCTAssertEqual(reparsed.simpleValue(namespace: ns, property: "ColorLabel"), "3")
        XCTAssertEqual(reparsed.arrayValue(namespace: ns, property: "TagsList"), ["People/Family", "Places/Norway"])
    }

    func testNewlinesAndTabsSurviveRoundTrip() throws {
        // Simple values are serialized as XML attributes; raw newlines/tabs in attribute
        // values are normalized to spaces by every conforming XML parser, so the writer
        // must emit them as character references.
        var xmp = XMPData()
        xmp.setValue(.simple("line one\nline two\ttabbed\r\nend"),
                     namespace: XMPNamespace.photoshop, property: "Instructions")

        let xml = XMPWriter.generateXML(xmp)
        let decoded = try XMPReader.readFromXML(Data(xml.utf8))
        XCTAssertEqual(
            decoded.simpleValue(namespace: XMPNamespace.photoshop, property: "Instructions"),
            "line one\nline two\ttabbed\r\nend"
        )
    }

    func testControlCharactersAreStripped() throws {
        // Chars below U+0020 (other than tab/LF/CR) are illegal in XML 1.0 even as
        // character references — emitting them raw makes the packet unparseable.
        var xmp = XMPData()
        xmp.headline = "bad\u{01}\u{0B}value"

        let xml = XMPWriter.generateXML(xmp)
        let decoded = try XMPReader.readFromXML(Data(xml.utf8))
        XCTAssertEqual(decoded.headline, "badvalue")
    }

    // MARK: - rdf:Bag vs rdf:Seq container parity (ExifTool behavior)

    func testCreatorWrittenAsSeq() {
        // dc:creator is spec-defined as an ordered rdf:Seq; ExifTool always writes it
        // as Seq, so a programmatically set value must normalize even though
        // XMPValue.array carries no container form.
        var xmp = XMPData()
        xmp.creator = ["Ansel Adams"]

        let xml = XMPWriter.generateXML(xmp)
        XCTAssertTrue(xml.contains("<rdf:Seq>"))
        XCTAssertFalse(xml.contains("<rdf:Bag>"))
    }

    func testSubjectStaysBag() {
        var xmp = XMPData()
        xmp.subject = ["news"]

        let xml = XMPWriter.generateXML(xmp)
        XCTAssertTrue(xml.contains("<rdf:Bag>"))
        XCTAssertFalse(xml.contains("<rdf:Seq>"))
    }

    func testVendorSeqContainerSurvivesRewrite() throws {
        // For arrays outside the spec table, the container form observed at parse
        // time must round-trip (digiKam writes TagsList as rdf:Seq).
        let source = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:digiKam="http://www.digikam.org/ns/1.0/">
          <digiKam:TagsList>
           <rdf:Seq>
            <rdf:li>People/Family</rdf:li>
           </rdf:Seq>
          </digiKam:TagsList>
          <digiKam:PickLabel>
           <rdf:Bag>
            <rdf:li>2</rdf:li>
           </rdf:Bag>
          </digiKam:PickLabel>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        """
        let parsed = try XMPReader.readFromXML(Data(source.utf8))
        let rewritten = XMPWriter.generateXML(parsed)

        XCTAssertNotNil(rewritten.range(of: "<digiKam:TagsList>\\s*<rdf:Seq>", options: .regularExpression)
            ?? rewritten.range(of: "<ns1:TagsList>\\s*<rdf:Seq>", options: .regularExpression))
        XCTAssertNotNil(rewritten.range(of: "<ns1:PickLabel>\\s*<rdf:Bag>", options: .regularExpression))
    }

    func testACRMaskCorrectionsRewrittenAsSeq() throws {
        // crs:MaskGroupBasedCorrections and the nested crs:CorrectionMasks are both
        // spec'd as rdf:Seq — the writer must not flatten them to Bag on rewrite.
        let crsNS = "http://ns.adobe.com/camera-raw-settings/1.0/"
        let source = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:crs="\(crsNS)">
           <crs:MaskGroupBasedCorrections>
            <rdf:Seq>
             <rdf:li>
              <rdf:Description crs:What="Correction" crs:CorrectionName="Mask 1">
               <crs:CorrectionMasks>
                <rdf:Seq>
                 <rdf:li crs:What="Mask/CircularGradient" crs:MaskName="Radial Gradient 1"/>
                </rdf:Seq>
               </crs:CorrectionMasks>
              </rdf:Description>
             </rdf:li>
            </rdf:Seq>
           </crs:MaskGroupBasedCorrections>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let parsed = try XMPReader.readFromXML(Data(source.utf8))
        let rewritten = XMPWriter.generateXML(parsed)
        XCTAssertFalse(rewritten.contains("<rdf:Bag>"))
        XCTAssertEqual(rewritten.components(separatedBy: "<rdf:Seq>").count - 1, 2)

        // And the reparse still carries the full nested shape.
        let reparsed = try XMPReader.readFromXML(Data(rewritten.utf8))
        let outer = reparsed.structuredArrayValue(namespace: crsNS, property: "MaskGroupBasedCorrections")
        XCTAssertEqual(outer?.count, 1)
        guard case .structuredArray(let masks)? = outer?[0]["\(crsNS)CorrectionMasks"] else {
            XCTFail("nested CorrectionMasks lost on rewrite")
            return
        }
        XCTAssertEqual(masks.first?["\(crsNS)MaskName"], .simple("Radial Gradient 1"))
    }

    func testACRBrushMaskNestedSeqContainersRewritten() throws {
        // A brush mask nests one more level than a radial: the Mask/Aggregate carries a
        // crs:Masks Seq of Mask/Paint sub-masks, each with a crs:Dabs Seq of stroke records.
        // ACR writes crs:Masks and crs:Dabs as rdf:Seq — the writer must emit Seq (not Bag)
        // for these too, and must not lose the nested shape on rewrite.
        let crsNS = "http://ns.adobe.com/camera-raw-settings/1.0/"
        let source = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:crs="\(crsNS)">
           <crs:MaskGroupBasedCorrections>
            <rdf:Seq>
             <rdf:li>
              <rdf:Description crs:What="Correction" crs:CorrectionName="Mask 1">
               <crs:CorrectionMasks>
                <rdf:Seq>
                 <rdf:li>
                  <rdf:Description crs:What="Mask/Aggregate" crs:MaskName="Brush 1">
                   <crs:Masks>
                    <rdf:Seq>
                     <rdf:li>
                      <rdf:Description crs:What="Mask/Paint" crs:Radius="0.4">
                       <crs:Dabs>
                        <rdf:Seq>
                         <rdf:li>f 0.5000</rdf:li>
                         <rdf:li>d 0.5 0.5</rdf:li>
                        </rdf:Seq>
                       </crs:Dabs>
                      </rdf:Description>
                     </rdf:li>
                    </rdf:Seq>
                   </crs:Masks>
                  </rdf:Description>
                 </rdf:li>
                </rdf:Seq>
               </crs:CorrectionMasks>
              </rdf:Description>
             </rdf:li>
            </rdf:Seq>
           </crs:MaskGroupBasedCorrections>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let parsed = try XMPReader.readFromXML(Data(source.utf8))
        let rewritten = XMPWriter.generateXML(parsed)
        // All four nested containers are Seq; none flattened to Bag.
        XCTAssertFalse(rewritten.contains("<rdf:Bag>"))
        XCTAssertEqual(rewritten.components(separatedBy: "<rdf:Seq>").count - 1, 4)

        // The nested Mask/Aggregate → Masks → Mask/Paint → Dabs shape survives the rewrite.
        let reparsed = try XMPReader.readFromXML(Data(rewritten.utf8))
        let outer = reparsed.structuredArrayValue(namespace: crsNS, property: "MaskGroupBasedCorrections")
        guard case .structuredArray(let correctionMasks)? = outer?[0]["\(crsNS)CorrectionMasks"],
              case .structuredArray(let paintMasks)? = correctionMasks.first?["\(crsNS)Masks"],
              case .array(let dabs)? = paintMasks.first?["\(crsNS)Dabs"] else {
            XCTFail("nested brush-mask shape lost on rewrite")
            return
        }
        XCTAssertEqual(paintMasks.first?["\(crsNS)What"], .simple("Mask/Paint"))
        XCTAssertEqual(dabs, ["f 0.5000", "d 0.5 0.5"])
    }

    func testRegionUnitWithSpecialCharactersProducesValidXML() throws {
        // Area/dimension unit strings come straight from the source file; a quote in
        // them must not break the rewritten packet.
        var xmp = XMPData()
        xmp.regions = XMPRegionList(
            regions: [XMPRegion(
                name: "Face",
                type: .face,
                area: XMPRegionArea(x: 0.5, y: 0.5, w: 0.1, h: 0.1, unit: "norm\"alized"),
                description: nil
            )],
            appliedToDimensionsW: 100,
            appliedToDimensionsH: 100,
            appliedToDimensionsUnit: "pix\"el"
        )

        let xml = XMPWriter.generateXML(xmp)
        let decoded = try XMPReader.readFromXML(Data(xml.utf8))
        XCTAssertEqual(decoded.regions?.regions.first?.area.unit, "norm\"alized")
        XCTAssertEqual(decoded.regions?.appliedToDimensionsUnit, "pix\"el")
    }
}
