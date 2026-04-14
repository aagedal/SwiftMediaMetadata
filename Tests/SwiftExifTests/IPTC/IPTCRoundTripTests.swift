import XCTest
@testable import SwiftExif

final class IPTCRoundTripTests: XCTestCase {

    func testRoundTripSingleField() throws {
        var original = IPTCData()
        original.headline = "Breaking News"

        let binary = try! IPTCWriter.write(original)
        let parsed = try IPTCReader.read(from: binary)

        XCTAssertEqual(parsed.headline, "Breaking News")
    }

    func testRoundTripAllJournalismFields() throws {
        var original = IPTCData()
        original.objectName = "OBJ-2026-001"
        original.headline = "Major Event in Oslo"
        original.caption = "A significant event took place in downtown Oslo today, affecting thousands of residents."
        original.bylines = ["Erik Nordmann", "Kari Olsen"]
        original.keywords = ["news", "oslo", "event", "breaking"]
        original.city = "Oslo"
        original.sublocation = "Karl Johans gate"
        original.provinceState = "Oslo"
        original.countryCode = "NOR"
        original.countryName = "Norway"
        original.credit = "NTB Scanpix"
        original.source = "NTB"
        original.copyright = "© 2026 NTB Scanpix"
        original.dateCreated = "20260412"
        original.timeCreated = "143000+0200"
        original.specialInstructions = "Mandatory credit"
        original.writerEditor = "Desk Editor"
        original.originatingProgram = "SwiftExif"
        original.programVersion = "1.0"

        let binary = try! IPTCWriter.write(original)
        let parsed = try IPTCReader.read(from: binary)

        XCTAssertEqual(parsed.objectName, original.objectName)
        XCTAssertEqual(parsed.headline, original.headline)
        XCTAssertEqual(parsed.caption, original.caption)
        XCTAssertEqual(parsed.bylines, original.bylines)
        XCTAssertEqual(parsed.keywords, original.keywords)
        XCTAssertEqual(parsed.city, original.city)
        XCTAssertEqual(parsed.sublocation, original.sublocation)
        XCTAssertEqual(parsed.provinceState, original.provinceState)
        XCTAssertEqual(parsed.countryCode, original.countryCode)
        XCTAssertEqual(parsed.countryName, original.countryName)
        XCTAssertEqual(parsed.credit, original.credit)
        XCTAssertEqual(parsed.source, original.source)
        XCTAssertEqual(parsed.copyright, original.copyright)
        XCTAssertEqual(parsed.dateCreated, original.dateCreated)
        XCTAssertEqual(parsed.timeCreated, original.timeCreated)
        XCTAssertEqual(parsed.specialInstructions, original.specialInstructions)
        XCTAssertEqual(parsed.writerEditor, original.writerEditor)
        XCTAssertEqual(parsed.originatingProgram, original.originatingProgram)
        XCTAssertEqual(parsed.programVersion, original.programVersion)
    }

    func testRoundTripRepeatableFields() throws {
        var original = IPTCData()
        original.keywords = ["photo", "news", "breaking", "exclusive", "world"]
        original.bylines = ["Photographer One", "Photographer Two", "Photographer Three"]

        let binary = try! IPTCWriter.write(original)
        let parsed = try IPTCReader.read(from: binary)

        XCTAssertEqual(parsed.keywords, original.keywords)
        XCTAssertEqual(parsed.bylines, original.bylines)
    }

    func testRoundTripEmptyValues() throws {
        let original = IPTCData()
        let binary = try! IPTCWriter.write(original)
        let parsed = try IPTCReader.read(from: binary)

        XCTAssertNil(parsed.headline)
        XCTAssertNil(parsed.caption)
        XCTAssertEqual(parsed.keywords, [])
    }

    func testRoundTripMaxLengthCaption() throws {
        var original = IPTCData()
        original.caption = String(repeating: "A", count: 2000)

        let binary = try! IPTCWriter.write(original)
        let parsed = try IPTCReader.read(from: binary)

        XCTAssertEqual(parsed.caption?.count, 2000)
        XCTAssertEqual(parsed.caption, original.caption)
    }

    func testRoundTripThroughJPEG() throws {
        var original = IPTCData()
        original.headline = "JPEG Round Trip"
        original.keywords = ["test", "jpeg", "roundtrip"]
        original.city = "Bergen"
        original.countryName = "Norway"

        // Build JPEG with IPTC
        let datasets = original.datasets
        let jpeg = TestFixtures.jpegWithIPTC(datasets: datasets)

        // Parse JPEG and read IPTC
        let file = try JPEGParser.parse(jpeg)
        guard let iptcSegment = file.iptcSegment() else {
            XCTFail("No IPTC segment found")
            return
        }

        let parsed = try IPTCReader.readFromAPP13(iptcSegment.data)

        XCTAssertEqual(parsed.headline, "JPEG Round Trip")
        XCTAssertEqual(parsed.keywords, ["test", "jpeg", "roundtrip"])
        XCTAssertEqual(parsed.city, "Bergen")
        XCTAssertEqual(parsed.countryName, "Norway")
    }

    func testRoundTripModifyAndRewrite() throws {
        // Create initial JPEG with IPTC
        var iptc = IPTCData()
        iptc.headline = "Original Headline"
        let jpeg = TestFixtures.jpegWithIPTC(datasets: iptc.datasets)

        // Parse, modify, write, parse again
        var file = try JPEGParser.parse(jpeg)

        // Read existing IPTC
        var parsed = try IPTCReader.readFromAPP13(file.iptcSegment()!.data)
        XCTAssertEqual(parsed.headline, "Original Headline")

        // Modify
        parsed.headline = "Modified Headline"
        parsed.keywords = ["new", "keywords"]

        // Write back
        let newApp13 = try IPTCWriter.writeToAPP13(parsed, existingAPP13: file.iptcSegment()?.data)
        file.replaceOrAddIPTCSegment(JPEGSegment(marker: .app13, data: newApp13))

        let modifiedJPEG = try JPEGWriter.write(file)

        // Parse final result
        let finalFile = try JPEGParser.parse(modifiedJPEG)
        let finalIPTC = try IPTCReader.readFromAPP13(finalFile.iptcSegment()!.data)

        XCTAssertEqual(finalIPTC.headline, "Modified Headline")
        XCTAssertEqual(finalIPTC.keywords, ["new", "keywords"])
    }
}
