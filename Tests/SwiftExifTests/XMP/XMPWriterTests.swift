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
}
