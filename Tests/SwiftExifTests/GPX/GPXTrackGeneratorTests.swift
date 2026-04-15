import XCTest
@testable import SwiftExif

final class GPXTrackGeneratorTests: XCTestCase {

    func testGenerateFromMetadataWithGPS() {
        var m1 = ImageMetadata.empty()
        m1.setGPS(latitude: 59.9139, longitude: 10.7522, altitude: 10.0)

        var m2 = ImageMetadata.empty()
        m2.setGPS(latitude: 59.9300, longitude: 10.7600, altitude: 15.0)

        let gpx = GPXTrackGenerator.generate(from: [m1, m2], name: "Test Track")

        XCTAssertTrue(gpx.contains("<gpx"))
        XCTAssertTrue(gpx.contains("SwiftExif"))
        XCTAssertTrue(gpx.contains("<name>Test Track</name>"))
        XCTAssertTrue(gpx.contains("<trkseg>"))
        XCTAssertTrue(gpx.contains("59.913"))
        XCTAssertTrue(gpx.contains("10.752"))
        XCTAssertTrue(gpx.contains("<ele>"))
    }

    func testGenerateSkipsImagesWithoutGPS() {
        var m1 = ImageMetadata.empty()
        m1.setGPS(latitude: 59.9139, longitude: 10.7522)

        let m2 = ImageMetadata.empty() // No GPS

        let gpx = GPXTrackGenerator.generate(from: [m1, m2])

        // Should have exactly one trackpoint
        let trkptCount = gpx.components(separatedBy: "<trkpt").count - 1
        XCTAssertEqual(trkptCount, 1)
    }

    func testGenerateEmptyInput() {
        let gpx = GPXTrackGenerator.generate(from: [ImageMetadata]())

        XCTAssertTrue(gpx.contains("<gpx"))
        XCTAssertTrue(gpx.contains("<trkseg>"))
        // No trackpoints
        XCTAssertFalse(gpx.contains("<trkpt"))
    }

    func testGenerateNoName() {
        var m = ImageMetadata.empty()
        m.setGPS(latitude: 0.0, longitude: 0.0)

        let gpx = GPXTrackGenerator.generate(from: [m])

        XCTAssertTrue(gpx.contains("<gpx"))
        XCTAssertFalse(gpx.contains("<metadata>"))
    }

    func testGenerateValidXML() {
        var m = ImageMetadata.empty()
        m.setGPS(latitude: -33.8688, longitude: 151.2093, altitude: 5.0)

        let gpx = GPXTrackGenerator.generate(from: [m], name: "Sydney")

        // Should be valid XML (basic check — starts with XML declaration, ends with </gpx>)
        XCTAssertTrue(gpx.hasPrefix("<?xml"))
        XCTAssertTrue(gpx.hasSuffix("</gpx>\n"))
    }

    func testGenerateNegativeCoordinates() {
        var m = ImageMetadata.empty()
        m.setGPS(latitude: -33.8688, longitude: -70.6693) // Santiago, Chile

        let gpx = GPXTrackGenerator.generate(from: [m])

        XCTAssertTrue(gpx.contains("-33.868"))
        XCTAssertTrue(gpx.contains("-70.669"))
    }
}
