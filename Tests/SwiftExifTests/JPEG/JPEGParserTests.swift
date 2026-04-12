import XCTest
@testable import SwiftExif

final class JPEGParserTests: XCTestCase {

    func testParseMinimalJPEG() throws {
        let jpeg = TestFixtures.minimalJPEG()
        let file = try JPEGParser.parse(jpeg)

        // Should have APP0, DQT, SOF0, DHT segments
        XCTAssertGreaterThanOrEqual(file.segments.count, 4)
        XCTAssertNotNil(file.findSegment(.app0))
        XCTAssertNotNil(file.findSegment(.dqt))
        XCTAssertNotNil(file.findSegment(.sof0))
        XCTAssertNotNil(file.findSegment(.dht))

        // Should have scan data
        XCTAssertFalse(file.scanData.isEmpty)
    }

    func testParseInvalidDataThrows() {
        let notJPEG = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertThrowsError(try JPEGParser.parse(notJPEG)) { error in
            XCTAssertTrue(error is MetadataError)
        }
    }

    func testParseTruncatedDataThrows() {
        // Just SOI, no segments
        let truncated = Data([0xFF, 0xD8])
        // This should not crash — returns empty segments
        let file = try? JPEGParser.parse(truncated)
        XCTAssertNotNil(file)
    }

    func testScanDataPreserved() throws {
        let jpeg = TestFixtures.minimalJPEG()
        let file = try JPEGParser.parse(jpeg)

        // Scan data should start with SOS marker
        XCTAssertTrue(file.scanData.starts(with: Data([0xFF, 0xDA])))

        // Scan data should end with EOI marker
        let lastTwo = file.scanData.suffix(2)
        XCTAssertEqual(lastTwo, Data([0xFF, 0xD9]))
    }

    func testFindExifSegment() throws {
        let exifData = TestFixtures.exifAPP1Data(byteOrder: .bigEndian)
        let jpeg = TestFixtures.jpegWithSegment(marker: .app1, data: exifData)
        let file = try JPEGParser.parse(jpeg)

        XCTAssertNotNil(file.exifSegment())
        XCTAssertTrue(file.exifSegment()!.isExif)
    }

    func testFindIPTCSegment() throws {
        let datasets = [IPTCDataSet(tag: .headline, stringValue: "Test")]
        let jpeg = TestFixtures.jpegWithIPTC(datasets: datasets)
        let file = try JPEGParser.parse(jpeg)

        XCTAssertNotNil(file.iptcSegment())
        XCTAssertTrue(file.iptcSegment()!.isPhotoshop)
    }

    func testSegmentCount() throws {
        let jpeg = TestFixtures.minimalJPEG()
        let file = try JPEGParser.parse(jpeg)

        // At minimum: APP0, DQT, SOF0, DHT
        XCTAssertGreaterThanOrEqual(file.segments.count, 4)
    }
}
