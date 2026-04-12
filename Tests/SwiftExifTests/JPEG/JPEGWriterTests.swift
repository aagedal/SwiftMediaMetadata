import XCTest
@testable import SwiftExif

final class JPEGWriterTests: XCTestCase {

    func testRoundTripMinimalJPEG() throws {
        let original = TestFixtures.minimalJPEG()
        let file = try JPEGParser.parse(original)
        let reconstructed = JPEGWriter.write(file)

        // Round-trip should produce identical output
        XCTAssertEqual(original, reconstructed)
    }

    func testRoundTripWithIPTC() throws {
        let datasets = [
            IPTCDataSet(tag: .headline, stringValue: "Test Headline"),
            IPTCDataSet(tag: .captionAbstract, stringValue: "A caption"),
        ]
        let original = TestFixtures.jpegWithIPTC(datasets: datasets)
        let file = try JPEGParser.parse(original)
        let reconstructed = JPEGWriter.write(file)

        XCTAssertEqual(original, reconstructed)
    }

    func testSegmentReplacement() throws {
        let original = TestFixtures.minimalJPEG()
        var file = try JPEGParser.parse(original)

        // Add an APP13 segment
        let iptcData = IPTCWriter.write(IPTCData(datasets: [
            IPTCDataSet(tag: .headline, stringValue: "New Headline"),
        ]))
        let app13Payload = TestFixtures.buildAPP13(iptcData: iptcData)
        let segment = JPEGSegment(marker: .app13, data: app13Payload)
        file.segments.append(segment)

        let modified = JPEGWriter.write(file)
        let reparsed = try JPEGParser.parse(modified)

        XCTAssertNotNil(reparsed.iptcSegment())
    }

    func testImageDataPreservedAfterMetadataChange() throws {
        let original = TestFixtures.minimalJPEG()
        let originalFile = try JPEGParser.parse(original)

        // Add IPTC metadata
        var modifiedFile = originalFile
        let iptcData = IPTCWriter.write(IPTCData(datasets: [
            IPTCDataSet(tag: .headline, stringValue: "Breaking News"),
            IPTCDataSet(tag: .byline, stringValue: "Photographer"),
        ]))
        let app13Payload = TestFixtures.buildAPP13(iptcData: iptcData)
        modifiedFile.segments.append(JPEGSegment(marker: .app13, data: app13Payload))

        let modifiedData = JPEGWriter.write(modifiedFile)
        let reparsed = try JPEGParser.parse(modifiedData)

        // Scan data must be identical
        XCTAssertEqual(originalFile.scanData, reparsed.scanData)
    }

    func testSegmentRemoval() throws {
        let datasets = [IPTCDataSet(tag: .headline, stringValue: "Test")]
        let original = TestFixtures.jpegWithIPTC(datasets: datasets)
        var file = try JPEGParser.parse(original)

        XCTAssertNotNil(file.iptcSegment())
        file.removeSegments(.app13)
        XCTAssertNil(file.iptcSegment())

        let modified = JPEGWriter.write(file)
        let reparsed = try JPEGParser.parse(modified)
        XCTAssertNil(reparsed.iptcSegment())
    }

    func testOutputStartsWithSOI() throws {
        let file = JPEGFile(
            segments: [JPEGSegment(marker: .app0, data: Data(repeating: 0, count: 14))],
            scanData: Data([0xFF, 0xDA, 0x00, 0x02, 0xFF, 0xD9])
        )
        let output = JPEGWriter.write(file)
        XCTAssertEqual(output[0], 0xFF)
        XCTAssertEqual(output[1], 0xD8)
    }
}
