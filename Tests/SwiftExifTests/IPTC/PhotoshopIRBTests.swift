import XCTest
@testable import SwiftExif

final class PhotoshopIRBTests: XCTestCase {

    func testParseMinimalAPP13() throws {
        let iptcData = IPTCWriter.write(IPTCData(datasets: [
            IPTCDataSet(tag: .headline, stringValue: "Test"),
        ]))
        let app13Data = TestFixtures.buildAPP13(iptcData: iptcData)

        let blocks = try PhotoshopIRB.parse(app13Data)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].resourceID, 0x0404)
    }

    func testExtractIPTCData() throws {
        let iptcData = IPTCWriter.write(IPTCData(datasets: [
            IPTCDataSet(tag: .headline, stringValue: "Extract Test"),
        ]))
        let app13Data = TestFixtures.buildAPP13(iptcData: iptcData)

        let extracted = try PhotoshopIRB.extractIPTCData(app13Data)
        XCTAssertNotNil(extracted)

        let parsed = try IPTCReader.read(from: extracted!)
        XCTAssertEqual(parsed.headline, "Extract Test")
    }

    func testMultipleIRBBlocks() throws {
        // Create APP13 with IPTC + a dummy block
        var blocks = [
            IRBBlock(resourceID: 0x0404, data: IPTCWriter.write(IPTCData(datasets: [
                IPTCDataSet(tag: .headline, stringValue: "Multi Block"),
            ]))),
            IRBBlock(resourceID: 0x040C, name: "", data: Data([0x01, 0x02, 0x03])), // Dummy thumbnail
        ]

        let written = PhotoshopIRB.write(blocks: blocks)
        let parsed = try PhotoshopIRB.parse(written)

        XCTAssertEqual(parsed.count, 2)
        XCTAssertTrue(parsed.contains { $0.resourceID == 0x0404 })
        XCTAssertTrue(parsed.contains { $0.resourceID == 0x040C })
    }

    func testReplaceIPTCPreservesOtherBlocks() throws {
        // Create APP13 with IPTC + dummy block
        let blocks = [
            IRBBlock(resourceID: 0x0404, data: IPTCWriter.write(IPTCData(datasets: [
                IPTCDataSet(tag: .headline, stringValue: "Original"),
            ]))),
            IRBBlock(resourceID: 0x040C, data: Data([0xAA, 0xBB, 0xCC])),
        ]

        let original = PhotoshopIRB.write(blocks: blocks)

        // Replace IPTC
        let newIPTC = IPTCWriter.write(IPTCData(datasets: [
            IPTCDataSet(tag: .headline, stringValue: "Replaced"),
        ]))
        let modified = try PhotoshopIRB.replaceIPTCData(in: original, with: newIPTC)
        let parsed = try PhotoshopIRB.parse(modified)

        XCTAssertEqual(parsed.count, 2)

        // IPTC should be updated
        let iptcBlock = parsed.first { $0.resourceID == 0x0404 }!
        let iptcParsed = try IPTCReader.read(from: iptcBlock.data)
        XCTAssertEqual(iptcParsed.headline, "Replaced")

        // Dummy block should be preserved
        let dummyBlock = parsed.first { $0.resourceID == 0x040C }!
        XCTAssertEqual(dummyBlock.data, Data([0xAA, 0xBB, 0xCC]))
    }

    func testRoundTripIRBBlocks() throws {
        let blocks = [
            IRBBlock(resourceID: 0x0404, data: Data([0x01, 0x02, 0x03, 0x04])),
            IRBBlock(resourceID: 0x0422, data: Data([0x05, 0x06, 0x07])),
        ]

        let written = PhotoshopIRB.write(blocks: blocks)
        let parsed = try PhotoshopIRB.parse(written)

        XCTAssertEqual(parsed.count, blocks.count)
        for (orig, reparsed) in zip(blocks, parsed) {
            XCTAssertEqual(orig.resourceID, reparsed.resourceID)
            XCTAssertEqual(orig.data, reparsed.data)
        }
    }

    func testInvalidPhotoshopHeader() {
        let badData = Data("Not Photoshop\0".utf8)
        XCTAssertThrowsError(try PhotoshopIRB.parse(badData))
    }

    func testPaddingHandling() throws {
        // Odd-length data should be padded
        let blocks = [
            IRBBlock(resourceID: 0x0404, data: Data([0x01, 0x02, 0x03])), // 3 bytes (odd)
        ]

        let written = PhotoshopIRB.write(blocks: blocks)
        let parsed = try PhotoshopIRB.parse(written)

        XCTAssertEqual(parsed[0].data, Data([0x01, 0x02, 0x03]))
    }
}
