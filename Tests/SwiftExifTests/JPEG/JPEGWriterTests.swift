import XCTest
@testable import SwiftExif

final class JPEGWriterTests: XCTestCase {

    func testRoundTripMinimalJPEG() throws {
        let original = TestFixtures.minimalJPEG()
        let file = try JPEGParser.parse(original)
        let reconstructed = try JPEGWriter.write(file)

        // Round-trip should produce identical output
        XCTAssertEqual(original, reconstructed)
    }

    func testRoundTripWithIPTC() throws {
        let datasets = [
            try IPTCDataSet(tag: .headline, stringValue: "Test Headline"),
            try IPTCDataSet(tag: .captionAbstract, stringValue: "A caption"),
        ]
        let original = TestFixtures.jpegWithIPTC(datasets: datasets)
        let file = try JPEGParser.parse(original)
        let reconstructed = try JPEGWriter.write(file)

        XCTAssertEqual(original, reconstructed)
    }

    func testSegmentReplacement() throws {
        let original = TestFixtures.minimalJPEG()
        var file = try JPEGParser.parse(original)

        // Add an APP13 segment
        let iptcData = try IPTCWriter.write(IPTCData(datasets: [
            try IPTCDataSet(tag: .headline, stringValue: "New Headline"),
        ]))
        let app13Payload = TestFixtures.buildAPP13(iptcData: iptcData)
        let segment = JPEGSegment(marker: .app13, data: app13Payload)
        file.segments.append(segment)

        let modified = try JPEGWriter.write(file)
        let reparsed = try JPEGParser.parse(modified)

        XCTAssertNotNil(reparsed.iptcSegment())
    }

    func testImageDataPreservedAfterMetadataChange() throws {
        let original = TestFixtures.minimalJPEG()
        let originalFile = try JPEGParser.parse(original)

        // Add IPTC metadata
        var modifiedFile = originalFile
        let iptcData = try IPTCWriter.write(IPTCData(datasets: [
            try IPTCDataSet(tag: .headline, stringValue: "Breaking News"),
            try IPTCDataSet(tag: .byline, stringValue: "Photographer"),
        ]))
        let app13Payload = TestFixtures.buildAPP13(iptcData: iptcData)
        modifiedFile.segments.append(JPEGSegment(marker: .app13, data: app13Payload))

        let modifiedData = try JPEGWriter.write(modifiedFile)
        let reparsed = try JPEGParser.parse(modifiedData)

        // Scan data must be identical
        XCTAssertEqual(originalFile.scanData, reparsed.scanData)
    }

    func testSegmentRemoval() throws {
        let datasets = [try IPTCDataSet(tag: .headline, stringValue: "Test")]
        let original = TestFixtures.jpegWithIPTC(datasets: datasets)
        var file = try JPEGParser.parse(original)

        XCTAssertNotNil(file.iptcSegment())
        file.removeSegments(.app13)
        XCTAssertNil(file.iptcSegment())

        let modified = try JPEGWriter.write(file)
        let reparsed = try JPEGParser.parse(modified)
        XCTAssertNil(reparsed.iptcSegment())
    }

    func testOutputStartsWithSOI() throws {
        let file = JPEGFile(
            segments: [JPEGSegment(marker: .app0, data: Data(repeating: 0, count: 14))],
            scanData: Data([0xFF, 0xDA, 0x00, 0x02, 0xFF, 0xD9])
        )
        let output = try JPEGWriter.write(file)
        XCTAssertEqual(output[0], 0xFF)
        XCTAssertEqual(output[1], 0xD8)
    }

    func testOversizedSegmentThrows() {
        let oversizedData = Data(repeating: 0x41, count: JPEGWriter.maxSegmentPayload + 1)
        let file = JPEGFile(
            segments: [JPEGSegment(marker: .app1, data: oversizedData)],
            scanData: Data([0xFF, 0xDA, 0x00, 0x02, 0xFF, 0xD9])
        )
        XCTAssertThrowsError(try JPEGWriter.write(file)) { error in
            guard case MetadataError.invalidSegmentLength = error else {
                XCTFail("Expected invalidSegmentLength, got \(error)")
                return
            }
        }
    }

    func testMaxSizeSegmentSucceeds() throws {
        let maxData = Data(repeating: 0x41, count: JPEGWriter.maxSegmentPayload)
        let file = JPEGFile(
            segments: [JPEGSegment(marker: .app1, data: maxData)],
            scanData: Data([0xFF, 0xDA, 0x00, 0x02, 0xFF, 0xD9])
        )
        let output = try JPEGWriter.write(file)
        XCTAssertEqual(output[0], 0xFF)
        XCTAssertEqual(output[1], 0xD8)
    }
}
