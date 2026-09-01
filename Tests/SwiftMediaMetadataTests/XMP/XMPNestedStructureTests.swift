import XCTest
@testable import SwiftMediaMetadata

/// Round-trip tests for nested XMP structures — the canonical regression case is
/// Adobe Camera Raw's MaskGroupBasedCorrections schema, where each correction in an
/// rdf:Bag carries its own rdf:Bag of mask sub-structs. The flat `[String: String]`
/// form couldn't represent this; the recursive `[String: XMPValue]` form can.
final class XMPNestedStructureTests: XCTestCase {

    private let crsNS = "http://ns.adobe.com/camera-raw-settings/1.0/"

    /// Camera Raw mask-group: rdf:Bag of correction structs, each with a nested
    /// rdf:Bag of mask structs. Verifies the writer emits child-element form for
    /// non-simple fields and the reader recovers the deep tree.
    func testMaskGroupBasedCorrectionsRoundTrip() throws {
        let mask: [String: XMPValue] = [
            "\(crsNS)What": .simple("Mask/Image"),
            "\(crsNS)MaskActive": .simple("true"),
            "\(crsNS)MaskName": .simple("Background"),
            "\(crsNS)MaskBlendMode": .simple("0"),
            "\(crsNS)MaskInverted": .simple("false"),
        ]

        let correction: [String: XMPValue] = [
            "\(crsNS)What": .simple("Correction"),
            "\(crsNS)CorrectionAmount": .simple("1.000000"),
            "\(crsNS)CorrectionActive": .simple("true"),
            "\(crsNS)LocalExposure2012": .simple("0.250000"),
            "\(crsNS)CorrectionMasks": .structuredArray([mask]),
        ]

        var xmp = XMPData()
        xmp.setValue(.structuredArray([correction]),
                     namespace: crsNS,
                     property: "MaskGroupBasedCorrections")

        let xml = XMPWriter.generateXML(xmp)
        let decoded = try XMPReader.readFromXML(Data(xml.utf8))

        guard let outer = decoded.structuredArrayValue(namespace: crsNS, property: "MaskGroupBasedCorrections") else {
            XCTFail("Expected outer structuredArray")
            return
        }
        XCTAssertEqual(outer.count, 1, "Outer Bag should have one correction")

        let outerItem = outer[0]
        XCTAssertEqual(outerItem["\(crsNS)What"], .simple("Correction"))
        XCTAssertEqual(outerItem["\(crsNS)CorrectionAmount"], .simple("1.000000"))
        XCTAssertEqual(outerItem["\(crsNS)LocalExposure2012"], .simple("0.250000"))

        guard case .structuredArray(let masks) = outerItem["\(crsNS)CorrectionMasks"] else {
            XCTFail("Expected nested CorrectionMasks structuredArray, got \(String(describing: outerItem["\(crsNS)CorrectionMasks"]))")
            return
        }
        XCTAssertEqual(masks.count, 1)
        XCTAssertEqual(masks[0]["\(crsNS)What"], .simple("Mask/Image"))
        XCTAssertEqual(masks[0]["\(crsNS)MaskName"], .simple("Background"))
        XCTAssertEqual(masks[0]["\(crsNS)MaskActive"], .simple("true"))
    }

    /// The namespace-aware field accessors must agree with the raw concatenated
    /// keys the reader produces — they exist so consumers never hand-build
    /// `"<namespaceURI><name>"` strings (a bare-name lookup compiles fine but
    /// silently never matches; that exact mistake shipped in a consumer app).
    func testFieldAccessorsMatchReaderKeys() throws {
        let mask: [String: XMPValue] = [
            "\(crsNS)What": .simple("Mask/CircularGradient"),
            "\(crsNS)Top": .simple("0.367451"),
        ]
        let correction: [String: XMPValue] = [
            "\(crsNS)CorrectionActive": .simple("true"),
            "\(crsNS)CorrectionMasks": .structuredArray([mask]),
        ]
        var xmp = XMPData()
        xmp.setValue(.structuredArray([correction]),
                     namespace: crsNS,
                     property: "MaskGroupBasedCorrections")

        let decoded = try XMPReader.readFromXML(Data(XMPWriter.generateXML(xmp).utf8))
        let outer = try XCTUnwrap(
            decoded.structuredArrayValue(namespace: crsNS, property: "MaskGroupBasedCorrections")
        ).first ?? [:]

        XCTAssertEqual(outer[namespace: crsNS, property: "CorrectionActive"], .simple("true"))
        XCTAssertEqual(outer.simpleField(namespace: crsNS, property: "CorrectionActive"), "true")
        XCTAssertNil(outer["CorrectionActive"], "fields are never keyed by bare local name")

        guard case .structuredArray(let masks)? = outer[namespace: crsNS, property: "CorrectionMasks"] else {
            XCTFail("Expected nested CorrectionMasks structuredArray")
            return
        }
        XCTAssertEqual(masks.first?.simpleField(namespace: crsNS, property: "What"), "Mask/CircularGradient")
        XCTAssertEqual(masks.first?.simpleField(namespace: crsNS, property: "Top"), "0.367451")

        // The subscript setter writes the same key shape the reader produces.
        var fields: [String: XMPValue] = [:]
        fields[namespace: crsNS, property: "Feather"] = .simple("50")
        XCTAssertEqual(fields["\(crsNS)Feather"], .simple("50"))
    }

    /// A struct field that holds another struct (single rdf:Description, not a Bag).
    func testNestedStructureRoundTrip() throws {
        let inner: [String: XMPValue] = [
            "\(crsNS)X": .simple("0.5"),
            "\(crsNS)Y": .simple("0.25"),
        ]
        let outer: [String: XMPValue] = [
            "\(crsNS)Name": .simple("Origin"),
            "\(crsNS)Point": .structure(inner),
        ]

        var xmp = XMPData()
        xmp.setValue(.structure(outer), namespace: crsNS, property: "Anchor")

        let xml = XMPWriter.generateXML(xmp)
        let decoded = try XMPReader.readFromXML(Data(xml.utf8))

        guard let fields = decoded.structureValue(namespace: crsNS, property: "Anchor") else {
            XCTFail("Expected outer structure")
            return
        }
        XCTAssertEqual(fields["\(crsNS)Name"], .simple("Origin"))

        guard case .structure(let nested) = fields["\(crsNS)Point"] else {
            XCTFail("Expected nested struct field, got \(String(describing: fields["\(crsNS)Point"]))")
            return
        }
        XCTAssertEqual(nested["\(crsNS)X"], .simple("0.5"))
        XCTAssertEqual(nested["\(crsNS)Y"], .simple("0.25"))
    }

    /// A struct field that holds a simple string array (rdf:Bag of strings).
    func testStructureWithArrayFieldRoundTrip() throws {
        let outer: [String: XMPValue] = [
            "\(crsNS)Name": .simple("Tagged"),
            "\(crsNS)Tags": .array(["a", "b", "c"]),
        ]

        var xmp = XMPData()
        xmp.setValue(.structure(outer), namespace: crsNS, property: "Tagged")

        let xml = XMPWriter.generateXML(xmp)
        let decoded = try XMPReader.readFromXML(Data(xml.utf8))

        guard let fields = decoded.structureValue(namespace: crsNS, property: "Tagged") else {
            XCTFail("Expected struct")
            return
        }
        XCTAssertEqual(fields["\(crsNS)Name"], .simple("Tagged"))
        XCTAssertEqual(fields["\(crsNS)Tags"], .array(["a", "b", "c"]))
    }

    /// Sanity check: flat-string structures still emit the compact attribute form, so existing
    /// IPTC round-trip tests aren't affected by the recursive change.
    func testFlatStructureUsesCompactAttributeForm() {
        let fields: [String: XMPValue] = [
            "\(crsNS)A": .simple("alpha"),
            "\(crsNS)B": .simple("beta"),
        ]
        var xmp = XMPData()
        xmp.setValue(.structure(fields), namespace: crsNS, property: "Pair")

        let xml = XMPWriter.generateXML(xmp)
        // All-simple fields stay as attributes; no child elements emitted.
        XCTAssertTrue(xml.contains("crs:A=\"alpha\""))
        XCTAssertTrue(xml.contains("crs:B=\"beta\""))
        XCTAssertFalse(xml.contains("<crs:A>"), "Simple fields should not be emitted as child elements")
    }

    /// Three levels deep — verifies the frame stack handles arbitrary nesting depth.
    func testThreeLevelNesting() throws {
        let level3: [String: XMPValue] = ["\(crsNS)Leaf": .simple("deep")]
        let level2: [String: XMPValue] = ["\(crsNS)Mid": .structure(level3)]
        let level1: [String: XMPValue] = ["\(crsNS)Outer": .structure(level2)]

        var xmp = XMPData()
        xmp.setValue(.structure(level1), namespace: crsNS, property: "Top")

        let xml = XMPWriter.generateXML(xmp)
        let decoded = try XMPReader.readFromXML(Data(xml.utf8))

        guard let top = decoded.structureValue(namespace: crsNS, property: "Top"),
              case .structure(let mid) = top["\(crsNS)Outer"],
              case .structure(let leaf) = mid["\(crsNS)Mid"] else {
            XCTFail("Failed to walk 3-level deep structure")
            return
        }
        XCTAssertEqual(leaf["\(crsNS)Leaf"], .simple("deep"))
    }

    /// A structure that contains a structuredArray field — verifies the outer .structure path
    /// (not just structuredArray-of-structuredArray which is already covered).
    func testStructureContainingStructuredArray() throws {
        let items: [[String: XMPValue]] = [
            ["\(crsNS)Tag": .simple("foo")],
            ["\(crsNS)Tag": .simple("bar")],
        ]
        let outer: [String: XMPValue] = [
            "\(crsNS)Name": .simple("Group"),
            "\(crsNS)Items": .structuredArray(items),
        ]

        var xmp = XMPData()
        xmp.setValue(.structure(outer), namespace: crsNS, property: "Group")

        let xml = XMPWriter.generateXML(xmp)
        let decoded = try XMPReader.readFromXML(Data(xml.utf8))

        guard let fields = decoded.structureValue(namespace: crsNS, property: "Group"),
              case .structuredArray(let decodedItems) = fields["\(crsNS)Items"] else {
            XCTFail("Expected structure with nested structuredArray")
            return
        }
        XCTAssertEqual(decodedItems.count, 2)
        XCTAssertEqual(decodedItems[0]["\(crsNS)Tag"], .simple("foo"))
        XCTAssertEqual(decodedItems[1]["\(crsNS)Tag"], .simple("bar"))
    }

    /// A structure containing a langAlternative field — verifies the Alt descend trigger.
    func testStructureContainingLangAlternative() throws {
        let outer: [String: XMPValue] = [
            "\(crsNS)Code": .simple("EN"),
            "\(crsNS)Description": .langAlternative("Hello world"),
        ]

        var xmp = XMPData()
        xmp.setValue(.structure(outer), namespace: crsNS, property: "Localized")

        let xml = XMPWriter.generateXML(xmp)
        let decoded = try XMPReader.readFromXML(Data(xml.utf8))

        guard let fields = decoded.structureValue(namespace: crsNS, property: "Localized") else {
            XCTFail("Expected outer struct")
            return
        }
        XCTAssertEqual(fields["\(crsNS)Code"], .simple("EN"))
        XCTAssertEqual(fields["\(crsNS)Description"], .langAlternative("Hello world"))
    }

    /// Realistic Camera Raw mask group: multiple corrections, each with multiple masks. Verifies
    /// the parser handles the high-cardinality case the consumer's app actually produces.
    func testRealisticMaskGroupShape() throws {
        let mask1: [String: XMPValue] = [
            "\(crsNS)What": .simple("Mask/Image"),
            "\(crsNS)MaskName": .simple("Sky"),
            "\(crsNS)MaskActive": .simple("true"),
        ]
        let mask2: [String: XMPValue] = [
            "\(crsNS)What": .simple("Mask/Linear"),
            "\(crsNS)MaskName": .simple("Foreground"),
            "\(crsNS)MaskActive": .simple("true"),
            "\(crsNS)Top": .simple("0.0"),
            "\(crsNS)Left": .simple("0.0"),
            "\(crsNS)Bottom": .simple("0.5"),
            "\(crsNS)Right": .simple("1.0"),
        ]
        let correction1: [String: XMPValue] = [
            "\(crsNS)What": .simple("Correction"),
            "\(crsNS)CorrectionAmount": .simple("0.750000"),
            "\(crsNS)LocalExposure2012": .simple("-0.5"),
            "\(crsNS)CorrectionMasks": .structuredArray([mask1, mask2]),
        ]
        let correction2: [String: XMPValue] = [
            "\(crsNS)What": .simple("Correction"),
            "\(crsNS)CorrectionAmount": .simple("1.000000"),
            "\(crsNS)LocalContrast2012": .simple("0.25"),
            "\(crsNS)CorrectionMasks": .structuredArray([mask1]),
        ]

        var xmp = XMPData()
        xmp.setValue(.structuredArray([correction1, correction2]),
                     namespace: crsNS,
                     property: "MaskGroupBasedCorrections")

        let xml = XMPWriter.generateXML(xmp)
        let decoded = try XMPReader.readFromXML(Data(xml.utf8))

        guard let outer = decoded.structuredArrayValue(namespace: crsNS, property: "MaskGroupBasedCorrections") else {
            XCTFail("Expected outer structuredArray")
            return
        }
        XCTAssertEqual(outer.count, 2)
        XCTAssertEqual(outer[0]["\(crsNS)CorrectionAmount"], .simple("0.750000"))
        XCTAssertEqual(outer[1]["\(crsNS)CorrectionAmount"], .simple("1.000000"))

        guard case .structuredArray(let masks0) = outer[0]["\(crsNS)CorrectionMasks"],
              case .structuredArray(let masks1) = outer[1]["\(crsNS)CorrectionMasks"] else {
            XCTFail("Both corrections should have nested masks")
            return
        }
        XCTAssertEqual(masks0.count, 2)
        XCTAssertEqual(masks0[0]["\(crsNS)MaskName"], .simple("Sky"))
        XCTAssertEqual(masks0[1]["\(crsNS)MaskName"], .simple("Foreground"))
        XCTAssertEqual(masks0[1]["\(crsNS)Bottom"], .simple("0.5"))
        XCTAssertEqual(masks1.count, 1)
        XCTAssertEqual(masks1[0]["\(crsNS)MaskName"], .simple("Sky"))
    }

    /// Idempotency: parsing what we wrote, then writing again, then parsing — should give the
    /// same XMPData. Catches subtle reader/writer asymmetries.
    func testWriteReadWriteReadStability() throws {
        let mask: [String: XMPValue] = [
            "\(crsNS)What": .simple("Mask"),
            "\(crsNS)Top": .simple("0.5"),
        ]
        let correction: [String: XMPValue] = [
            "\(crsNS)What": .simple("Correction"),
            "\(crsNS)CorrectionMasks": .structuredArray([mask]),
        ]

        var xmp = XMPData()
        xmp.setValue(.structuredArray([correction]),
                     namespace: crsNS,
                     property: "MaskGroupBasedCorrections")

        let xml1 = XMPWriter.generateXML(xmp)
        let decoded1 = try XMPReader.readFromXML(Data(xml1.utf8))
        let xml2 = XMPWriter.generateXML(decoded1)
        let decoded2 = try XMPReader.readFromXML(Data(xml2.utf8))

        // Second-generation XML and parsed value should match the first.
        XCTAssertEqual(decoded1.value(namespace: crsNS, property: "MaskGroupBasedCorrections"),
                       decoded2.value(namespace: crsNS, property: "MaskGroupBasedCorrections"))
    }

    // MARK: - Flat-helper accessor tests

    func testFlatStructureValueDropsNonSimple() throws {
        // Build a struct that has both simple AND complex fields. flatStructureValue should
        // expose only the simple ones, dropping nested structures and arrays.
        let fields: [String: XMPValue] = [
            "\(crsNS)Name": .simple("Mixed"),
            "\(crsNS)Tags": .array(["a", "b"]),
            "\(crsNS)Inner": .structure(["\(crsNS)X": .simple("1")]),
        ]
        var xmp = XMPData()
        xmp.setValue(.structure(fields), namespace: crsNS, property: "Mixed")

        let flat = xmp.flatStructureValue(namespace: crsNS, property: "Mixed")
        XCTAssertNotNil(flat)
        XCTAssertEqual(flat?["\(crsNS)Name"], "Mixed")
        XCTAssertNil(flat?["\(crsNS)Tags"], "Array fields must be dropped from flat view")
        XCTAssertNil(flat?["\(crsNS)Inner"], "Nested struct fields must be dropped from flat view")
    }

    /// Adobe Camera Raw (18.x) writes MaskGroupBasedCorrections as rdf:Seq (not Bag),
    /// with the correction struct as an attribute-bearing rdf:Description inside li and
    /// the inner mask items as attribute-form rdf:li with no Description child.
    /// Regression: this exact shape parsed as an empty array, silently dropping all masks.
    func testACRSeqAttributeFormMaskParsing() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:HasSettings="True">
           <crs:MaskGroupBasedCorrections>
            <rdf:Seq>
             <rdf:li>
              <rdf:Description crs:What="Correction" crs:CorrectionAmount="1" crs:CorrectionActive="true" crs:CorrectionName="Mask 1" crs:LocalExposure2012="-0.4875">
               <crs:CorrectionMasks>
                <rdf:Seq>
                 <rdf:li crs:What="Mask/CircularGradient" crs:MaskActive="true" crs:MaskName="Radial Gradient 1" crs:MaskValue="1" crs:Top="0.130294" crs:Left="0.249030" crs:Bottom="0.942355" crs:Right="0.790404" crs:Angle="15.5" crs:Midpoint="50" crs:Roundness="0" crs:Feather="0" crs:Flipped="true" crs:Version="2"/>
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
        let decoded = try XMPReader.readFromXML(Data(xml.utf8))

        guard let outer = decoded.structuredArrayValue(namespace: crsNS, property: "MaskGroupBasedCorrections") else {
            XCTFail("MaskGroupBasedCorrections did not parse as a structured array")
            return
        }
        XCTAssertEqual(outer.count, 1)
        let correction = outer[0]
        XCTAssertEqual(correction["\(crsNS)What"], .simple("Correction"))
        XCTAssertEqual(correction["\(crsNS)LocalExposure2012"], .simple("-0.4875"))
        XCTAssertEqual(correction["\(crsNS)CorrectionName"], .simple("Mask 1"))

        guard case .structuredArray(let masks)? = correction["\(crsNS)CorrectionMasks"] else {
            XCTFail("CorrectionMasks missing or wrong shape: \(String(describing: correction["\(crsNS)CorrectionMasks"]))")
            return
        }
        XCTAssertEqual(masks.count, 1)
        XCTAssertEqual(masks[0]["\(crsNS)What"], .simple("Mask/CircularGradient"))
        XCTAssertEqual(masks[0]["\(crsNS)Top"], .simple("0.130294"))
        XCTAssertEqual(masks[0]["\(crsNS)Left"], .simple("0.249030"))
        XCTAssertEqual(masks[0]["\(crsNS)Bottom"], .simple("0.942355"))
        XCTAssertEqual(masks[0]["\(crsNS)Right"], .simple("0.790404"))
        XCTAssertEqual(masks[0]["\(crsNS)Angle"], .simple("15.5"))
        XCTAssertEqual(masks[0]["\(crsNS)Flipped"], .simple("true"))

        // Sibling attribute-form simple property still lands top-level.
        XCTAssertEqual(decoded.simpleValue(namespace: crsNS, property: "HasSettings"), "True")
    }

    func testFlatStructuredArrayValueDropsNonSimple() throws {
        let items: [[String: XMPValue]] = [
            [
                "\(crsNS)Name": .simple("Item1"),
                "\(crsNS)Sub": .structure(["\(crsNS)X": .simple("1")]),
            ],
            [
                "\(crsNS)Name": .simple("Item2"),
            ],
        ]
        var xmp = XMPData()
        xmp.setValue(.structuredArray(items), namespace: crsNS, property: "Items")

        let flat = xmp.flatStructuredArrayValue(namespace: crsNS, property: "Items")
        XCTAssertEqual(flat?.count, 2)
        XCTAssertEqual(flat?[0]["\(crsNS)Name"], "Item1")
        XCTAssertNil(flat?[0]["\(crsNS)Sub"])
        XCTAssertEqual(flat?[1]["\(crsNS)Name"], "Item2")
    }
}
