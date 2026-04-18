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
}
