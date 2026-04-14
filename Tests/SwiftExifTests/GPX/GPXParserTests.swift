import XCTest
@testable import SwiftExif

final class GPXParserTests: XCTestCase {

    // MARK: - Valid GPX

    func testParseBasicGPX() throws {
        let gpx = """
        <?xml version="1.0"?>
        <gpx>
          <trk>
            <name>Morning Walk</name>
            <trkseg>
              <trkpt lat="59.9139" lon="10.7522">
                <time>2024-01-15T14:30:00Z</time>
              </trkpt>
              <trkpt lat="59.9145" lon="10.7530">
                <time>2024-01-15T14:31:00Z</time>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>
        """
        let track = try GPXParser.parse(from: gpx)
        XCTAssertEqual(track.name, "Morning Walk")
        XCTAssertEqual(track.trackpoints.count, 2)
        XCTAssertEqual(track.trackpoints[0].latitude, 59.9139, accuracy: 0.0001)
        XCTAssertEqual(track.trackpoints[0].longitude, 10.7522, accuracy: 0.0001)
        XCTAssertEqual(track.trackpoints[1].latitude, 59.9145, accuracy: 0.0001)
    }

    func testParseGPXWithElevation() throws {
        let gpx = """
        <?xml version="1.0"?>
        <gpx>
          <trk><trkseg>
            <trkpt lat="51.5074" lon="-0.1278">
              <ele>15.3</ele>
              <time>2024-06-01T10:00:00Z</time>
            </trkpt>
          </trkseg></trk>
        </gpx>
        """
        let track = try GPXParser.parse(from: gpx)
        XCTAssertEqual(track.trackpoints.count, 1)
        XCTAssertEqual(track.trackpoints[0].elevation!, 15.3, accuracy: 0.01)
    }

    func testParseGPXMultipleSegments() throws {
        let gpx = """
        <?xml version="1.0"?>
        <gpx>
          <trk>
            <trkseg>
              <trkpt lat="1.0" lon="2.0"><time>2024-01-01T01:00:00Z</time></trkpt>
            </trkseg>
            <trkseg>
              <trkpt lat="3.0" lon="4.0"><time>2024-01-01T02:00:00Z</time></trkpt>
            </trkseg>
          </trk>
        </gpx>
        """
        let track = try GPXParser.parse(from: gpx)
        XCTAssertEqual(track.trackpoints.count, 2)
    }

    func testParseGPXSortsByTimestamp() throws {
        let gpx = """
        <?xml version="1.0"?>
        <gpx>
          <trk><trkseg>
            <trkpt lat="2.0" lon="2.0"><time>2024-01-01T12:00:00Z</time></trkpt>
            <trkpt lat="1.0" lon="1.0"><time>2024-01-01T10:00:00Z</time></trkpt>
            <trkpt lat="3.0" lon="3.0"><time>2024-01-01T11:00:00Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let track = try GPXParser.parse(from: gpx)
        XCTAssertEqual(track.trackpoints[0].latitude, 1.0) // Earliest
        XCTAssertEqual(track.trackpoints[1].latitude, 3.0) // Middle
        XCTAssertEqual(track.trackpoints[2].latitude, 2.0) // Latest
    }

    func testParseGPXWithFractionalSeconds() throws {
        let gpx = """
        <?xml version="1.0"?>
        <gpx>
          <trk><trkseg>
            <trkpt lat="40.0" lon="-74.0">
              <time>2024-03-15T08:30:45.123Z</time>
            </trkpt>
          </trkseg></trk>
        </gpx>
        """
        let track = try GPXParser.parse(from: gpx)
        XCTAssertEqual(track.trackpoints.count, 1)
    }

    // MARK: - Edge Cases

    func testParseGPXSkipsMissingTimestamp() throws {
        let gpx = """
        <?xml version="1.0"?>
        <gpx>
          <trk><trkseg>
            <trkpt lat="1.0" lon="1.0"></trkpt>
            <trkpt lat="2.0" lon="2.0"><time>2024-01-01T12:00:00Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let track = try GPXParser.parse(from: gpx)
        XCTAssertEqual(track.trackpoints.count, 1) // Only the one with a timestamp
    }

    func testParseEmptyGPX() throws {
        let gpx = """
        <?xml version="1.0"?>
        <gpx></gpx>
        """
        let track = try GPXParser.parse(from: gpx)
        XCTAssertEqual(track.trackpoints.count, 0)
        XCTAssertNil(track.timeRange)
    }

    func testParseInvalidXMLThrows() {
        let gpx = "this is not xml <<<"
        XCTAssertThrowsError(try GPXParser.parse(from: gpx))
    }

    // MARK: - Time Range

    func testTimeRange() throws {
        let gpx = """
        <?xml version="1.0"?>
        <gpx>
          <trk><trkseg>
            <trkpt lat="1.0" lon="1.0"><time>2024-01-15T10:00:00Z</time></trkpt>
            <trkpt lat="2.0" lon="2.0"><time>2024-01-15T12:00:00Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let track = try GPXParser.parse(from: gpx)
        let range = track.timeRange
        XCTAssertNotNil(range)
        XCTAssertEqual(range!.upperBound.timeIntervalSince(range!.lowerBound), 7200, accuracy: 1)
    }

    // MARK: - Negative Coordinates

    func testParseNegativeCoordinates() throws {
        let gpx = """
        <?xml version="1.0"?>
        <gpx>
          <trk><trkseg>
            <trkpt lat="-33.8688" lon="-73.9857">
              <time>2024-06-01T00:00:00Z</time>
            </trkpt>
          </trkseg></trk>
        </gpx>
        """
        let track = try GPXParser.parse(from: gpx)
        XCTAssertEqual(track.trackpoints[0].latitude, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(track.trackpoints[0].longitude, -73.9857, accuracy: 0.0001)
    }
}
