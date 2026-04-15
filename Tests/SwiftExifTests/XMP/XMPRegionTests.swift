import XCTest
@testable import SwiftExif

final class XMPRegionTests: XCTestCase {

    // MARK: - Parsing

    func testParseRegionsFromXML() throws {
        let xml = sampleRegionXML(names: ["Alice", "Bob"], types: ["Face", "Face"])
        let xmpData = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertNotNil(xmpData.regions)
        XCTAssertEqual(xmpData.regions?.regions.count, 2)

        let alice = xmpData.regions!.regions[0]
        XCTAssertEqual(alice.name, "Alice")
        XCTAssertEqual(alice.type, .face)
        XCTAssertEqual(alice.area.x, 0.3, accuracy: 0.001)
        XCTAssertEqual(alice.area.y, 0.4, accuracy: 0.001)
        XCTAssertEqual(alice.area.w, 0.1, accuracy: 0.001)
        XCTAssertEqual(alice.area.h, 0.15, accuracy: 0.001)
        XCTAssertEqual(alice.area.unit, "normalized")

        let bob = xmpData.regions!.regions[1]
        XCTAssertEqual(bob.name, "Bob")
        XCTAssertEqual(bob.type, .face)
    }

    func testParseAppliedDimensions() throws {
        let xml = sampleRegionXML(names: ["Test"], types: ["Face"], dimW: 4000, dimH: 3000)
        let xmpData = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertEqual(xmpData.regions?.appliedToDimensionsW, 4000)
        XCTAssertEqual(xmpData.regions?.appliedToDimensionsH, 3000)
        XCTAssertEqual(xmpData.regions?.appliedToDimensionsUnit, "pixel")
    }

    func testParseRegionWithoutName() throws {
        let xml = sampleRegionXML(names: [nil], types: ["Focus"])
        let xmpData = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertEqual(xmpData.regions?.regions.count, 1)
        XCTAssertNil(xmpData.regions?.regions.first?.name)
        XCTAssertEqual(xmpData.regions?.regions.first?.type, .focus)
    }

    func testParseRegionWithoutType() throws {
        let xml = sampleRegionXML(names: ["NoType"], types: [nil])
        let xmpData = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertEqual(xmpData.regions?.regions.count, 1)
        XCTAssertEqual(xmpData.regions?.regions.first?.name, "NoType")
        XCTAssertNil(xmpData.regions?.regions.first?.type)
    }

    func testParseAllRegionTypes() throws {
        let xml = sampleRegionXML(
            names: ["face", "pet", "focus", "barcode"],
            types: ["Face", "Pet", "Focus", "BarCode"]
        )
        let xmpData = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertEqual(xmpData.regions?.regions.count, 4)
        XCTAssertEqual(xmpData.regions?.regions[0].type, .face)
        XCTAssertEqual(xmpData.regions?.regions[1].type, .pet)
        XCTAssertEqual(xmpData.regions?.regions[2].type, .focus)
        XCTAssertEqual(xmpData.regions?.regions[3].type, .barCode)
    }

    func testNoRegionsReturnsNil() throws {
        let xml = """
        <?xpacket begin="\u{feff}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="\(XMPNamespace.rdf)"
           xmlns:dc="\(XMPNamespace.dc)">
         <rdf:Description rdf:about="" dc:format="image/jpeg"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let xmpData = try XMPReader.readFromXML(Data(xml.utf8))
        XCTAssertNil(xmpData.regions)
    }

    // MARK: - Writing

    func testWriteRegions() {
        var xmpData = XMPData()
        xmpData.regions = XMPRegionList(
            regions: [
                XMPRegion(name: "Alice", type: .face, area: XMPRegionArea(x: 0.5, y: 0.3, w: 0.1, h: 0.15)),
            ],
            appliedToDimensionsW: 4000,
            appliedToDimensionsH: 3000,
            appliedToDimensionsUnit: "pixel"
        )

        let xml = XMPWriter.generateXML(xmpData)

        XCTAssertTrue(xml.contains("mwg-rs:Regions"))
        XCTAssertTrue(xml.contains("mwg-rs:Name=\"Alice\""))
        XCTAssertTrue(xml.contains("mwg-rs:Type=\"Face\""))
        XCTAssertTrue(xml.contains("stArea:x=\"0.5\""))
        XCTAssertTrue(xml.contains("stArea:y=\"0.3\""))
        XCTAssertTrue(xml.contains("stArea:w=\"0.1\""))
        XCTAssertTrue(xml.contains("stArea:h=\"0.15\""))
        XCTAssertTrue(xml.contains("stDim:w=\"4000\""))
        XCTAssertTrue(xml.contains("stDim:h=\"3000\""))
    }

    func testWriteRegionWithoutName() {
        var xmpData = XMPData()
        xmpData.regions = XMPRegionList(regions: [
            XMPRegion(type: .focus, area: XMPRegionArea(x: 0.5, y: 0.5, w: 0.2, h: 0.2)),
        ])

        let xml = XMPWriter.generateXML(xmpData)
        XCTAssertTrue(xml.contains("mwg-rs:Type=\"Focus\""))
        XCTAssertFalse(xml.contains("mwg-rs:Name"))
    }

    // MARK: - Round-Trip

    func testRegionRoundTrip() throws {
        let original = XMPRegionList(
            regions: [
                XMPRegion(name: "Alice", type: .face, area: XMPRegionArea(x: 0.3, y: 0.4, w: 0.1, h: 0.15)),
                XMPRegion(name: "Bob", type: .face, area: XMPRegionArea(x: 0.7, y: 0.5, w: 0.12, h: 0.18)),
            ],
            appliedToDimensionsW: 6000,
            appliedToDimensionsH: 4000,
            appliedToDimensionsUnit: "pixel"
        )

        var xmpData = XMPData()
        xmpData.regions = original

        let xml = XMPWriter.generateXML(xmpData)
        let parsed = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertNotNil(parsed.regions)
        XCTAssertEqual(parsed.regions?.regions.count, 2)
        XCTAssertEqual(parsed.regions?.regions[0].name, "Alice")
        XCTAssertEqual(parsed.regions?.regions[1].name, "Bob")
        XCTAssertEqual(parsed.regions?.regions[0].type, .face)
        XCTAssertEqual(parsed.regions!.regions[0].area.x, 0.3, accuracy: 0.001)
        XCTAssertEqual(parsed.regions!.regions[0].area.w, 0.1, accuracy: 0.001)
        XCTAssertEqual(parsed.regions?.appliedToDimensionsW, 6000)
        XCTAssertEqual(parsed.regions?.appliedToDimensionsH, 4000)
    }

    func testRegionRoundTripInJPEG() throws {
        let jpeg = TestFixtures.minimalJPEG()
        var metadata = try ImageMetadata.read(from: jpeg)

        if metadata.xmp == nil { metadata.xmp = XMPData() }
        metadata.xmp?.regions = XMPRegionList(regions: [
            XMPRegion(name: "Test Face", type: .face, area: XMPRegionArea(x: 0.5, y: 0.5, w: 0.2, h: 0.25)),
        ])

        let written = try metadata.writeToData()
        let reread = try ImageMetadata.read(from: written)

        XCTAssertNotNil(reread.xmp?.regions)
        XCTAssertEqual(reread.xmp?.regions?.regions.count, 1)
        XCTAssertEqual(reread.xmp?.regions?.regions.first?.name, "Test Face")
        XCTAssertEqual(reread.xmp?.regions?.regions.first?.type, .face)
    }

    func testRegionsPreservedAlongsideOtherXMP() throws {
        var xmpData = XMPData()
        xmpData.title = "Photo with faces"
        xmpData.regions = XMPRegionList(regions: [
            XMPRegion(name: "Person", type: .face, area: XMPRegionArea(x: 0.5, y: 0.5, w: 0.1, h: 0.1)),
        ])

        let xml = XMPWriter.generateXML(xmpData)
        let parsed = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertEqual(parsed.title, "Photo with faces")
        XCTAssertEqual(parsed.regions?.regions.count, 1)
        XCTAssertEqual(parsed.regions?.regions.first?.name, "Person")
    }

    func testSpecialCharactersInRegionName() throws {
        var xmpData = XMPData()
        xmpData.regions = XMPRegionList(regions: [
            XMPRegion(name: "O'Brien & \"Friends\" <3", type: .face,
                      area: XMPRegionArea(x: 0.5, y: 0.5, w: 0.1, h: 0.1)),
        ])

        let xml = XMPWriter.generateXML(xmpData)
        // Apostrophes don't need escaping inside double-quoted attributes
        XCTAssertTrue(xml.contains("O'Brien &amp; &quot;Friends&quot; &lt;3"))

        let parsed = try XMPReader.readFromXML(Data(xml.utf8))
        XCTAssertEqual(parsed.regions?.regions.first?.name, "O'Brien & \"Friends\" <3")
    }

    // MARK: - Helpers

    private func sampleRegionXML(
        names: [String?],
        types: [String?],
        dimW: Int? = nil,
        dimH: Int? = nil
    ) -> String {
        var xml = """
        <?xpacket begin="\u{feff}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="\(XMPNamespace.rdf)"
           xmlns:mwg-rs="\(XMPNamespace.mwgRegions)"
           xmlns:stArea="\(XMPNamespace.stArea)"
           xmlns:stDim="\(XMPNamespace.stDim)">
         <rdf:Description rdf:about="">
          <mwg-rs:Regions>
        """
        if let w = dimW, let h = dimH {
            xml += "\n   <mwg-rs:AppliedToDimensions stDim:w=\"\(w)\" stDim:h=\"\(h)\" stDim:unit=\"pixel\"/>"
        }
        xml += "\n   <mwg-rs:RegionList>\n    <rdf:Bag>"

        for (i, name) in names.enumerated() {
            let type = i < types.count ? types[i] : nil
            let x = 0.3 + Double(i) * 0.2
            xml += "\n     <rdf:li>\n      <rdf:Description"
            if let n = name { xml += " mwg-rs:Name=\"\(n)\"" }
            if let t = type { xml += " mwg-rs:Type=\"\(t)\"" }
            xml += ">"
            xml += "\n       <mwg-rs:Area stArea:x=\"\(x)\" stArea:y=\"0.4\" stArea:w=\"0.1\" stArea:h=\"0.15\" stArea:unit=\"normalized\"/>"
            xml += "\n      </rdf:Description>\n     </rdf:li>"
        }

        xml += """

            </rdf:Bag>
           </mwg-rs:RegionList>
          </mwg-rs:Regions>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        return xml
    }
}
