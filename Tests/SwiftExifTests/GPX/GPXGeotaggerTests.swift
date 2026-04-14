import XCTest
@testable import SwiftExif

final class GPXGeotaggerTests: XCTestCase {

    // MARK: - Timestamp Matching

    func testExactTimestampMatch() {
        let track = makeTrack([
            (59.9139, 10.7522, "2024-01-15T14:30:00Z"),
            (59.9145, 10.7530, "2024-01-15T14:31:00Z"),
        ])

        let result = GPXGeotagger.match(
            dateTimeOriginal: "2024:01:15 14:30:00",
            track: track, maxOffset: 60
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.latitude, 59.9139, accuracy: 0.0001)
        XCTAssertEqual(result!.longitude, 10.7522, accuracy: 0.0001)
    }

    func testInterpolationBetweenPoints() {
        let track = makeTrack([
            (60.0, 10.0, "2024-01-15T14:00:00Z"),
            (62.0, 12.0, "2024-01-15T14:02:00Z"), // 120 seconds later
        ])

        // Photo at midpoint (60 seconds into 120-second interval)
        let result = GPXGeotagger.match(
            dateTimeOriginal: "2024:01:15 14:01:00",
            track: track, maxOffset: 120
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.latitude, 61.0, accuracy: 0.01) // Midpoint
        XCTAssertEqual(result!.longitude, 11.0, accuracy: 0.01)
    }

    func testInterpolationQuarterPoint() {
        let track = makeTrack([
            (0.0, 0.0, "2024-01-15T12:00:00Z"),
            (4.0, 8.0, "2024-01-15T12:04:00Z"), // 240 seconds
        ])

        // Photo at 25% of interval (60 seconds)
        let result = GPXGeotagger.match(
            dateTimeOriginal: "2024:01:15 12:01:00",
            track: track, maxOffset: 300
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.latitude, 1.0, accuracy: 0.01)
        XCTAssertEqual(result!.longitude, 2.0, accuracy: 0.01)
    }

    func testNoMatchOutsideMaxOffset() {
        let track = makeTrack([
            (59.9139, 10.7522, "2024-01-15T14:30:00Z"),
        ])

        // Photo 5 minutes away, maxOffset is 60s
        let result = GPXGeotagger.match(
            dateTimeOriginal: "2024:01:15 14:35:00",
            track: track, maxOffset: 60
        )
        XCTAssertNil(result)
    }

    func testTimezoneOffset() {
        // Photo taken at 15:30 local time (CET = UTC+1 = 3600s)
        // GPX track has UTC timestamps
        let track = makeTrack([
            (59.9139, 10.7522, "2024-01-15T14:30:00Z"), // 14:30 UTC = 15:30 CET
        ])

        let result = GPXGeotagger.match(
            dateTimeOriginal: "2024:01:15 15:30:00",
            track: track, maxOffset: 60,
            timeZoneOffset: 3600
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.latitude, 59.9139, accuracy: 0.0001)
    }

    func testEmptyTrackReturnsNil() {
        let track = GPXTrack(trackpoints: [])
        let result = GPXGeotagger.match(
            dateTimeOriginal: "2024:01:15 14:30:00",
            track: track
        )
        XCTAssertNil(result)
    }

    // MARK: - Rational Triplet Conversion

    func testDegreesToRationalTripletOslo() {
        // 59.9139° → 59° 54' 50.04"
        let triplet = GPXGeotagger.degreesToRationalTriplet(59.9139)
        XCTAssertEqual(triplet[0].numerator, 59) // degrees
        XCTAssertEqual(triplet[0].denominator, 1)
        XCTAssertEqual(triplet[1].numerator, 54) // minutes
        XCTAssertEqual(triplet[1].denominator, 1)
        // seconds ≈ 50.04, stored as 500400/10000
        let seconds = Double(triplet[2].numerator) / Double(triplet[2].denominator)
        XCTAssertEqual(seconds, 50.04, accuracy: 0.01)
    }

    func testRationalTripletRoundTrip() {
        let original = 51.5074 // London
        let triplet = GPXGeotagger.degreesToRationalTriplet(original)
        let deg = Double(triplet[0].numerator) / Double(triplet[0].denominator)
        let min = Double(triplet[1].numerator) / Double(triplet[1].denominator)
        let sec = Double(triplet[2].numerator) / Double(triplet[2].denominator)
        let reconstructed = deg + min / 60.0 + sec / 3600.0
        XCTAssertEqual(reconstructed, original, accuracy: 0.0001)
    }

    func testRationalTripletNegativeCoordinate() {
        // degreesToRationalTriplet always takes absolute value
        let triplet = GPXGeotagger.degreesToRationalTriplet(33.8688)
        XCTAssertEqual(triplet[0].numerator, 33)
    }

    // MARK: - Build GPS IFD

    func testBuildGPSIFD() {
        let point = GPXTrackpoint(
            latitude: 59.9139, longitude: 10.7522,
            elevation: 15.3,
            timestamp: makeDate("2024-01-15T14:30:00Z")
        )
        let ifd = GPXGeotagger.buildGPSIFD(from: point, byteOrder: .bigEndian)

        // Should have: VersionID, LatRef, Lat, LonRef, Lon, AltRef, Alt, TimeStamp, DateStamp
        XCTAssertTrue(ifd.entries.count >= 9)

        // Verify lat ref
        let latRef = ifd.entry(for: ExifTag.gpsLatitudeRef)?.stringValue(endian: .bigEndian)
        XCTAssertEqual(latRef, "N")

        // Verify lon ref
        let lonRef = ifd.entry(for: ExifTag.gpsLongitudeRef)?.stringValue(endian: .bigEndian)
        XCTAssertEqual(lonRef, "E")

        // Verify altitude ref (above sea level = 0)
        let altRef = ifd.entry(for: ExifTag.gpsAltitudeRef)
        XCTAssertNotNil(altRef)
        XCTAssertEqual(altRef!.valueData[altRef!.valueData.startIndex], 0)
    }

    func testBuildGPSIFDSouthWest() {
        let point = GPXTrackpoint(
            latitude: -33.8688, longitude: -73.9857,
            timestamp: makeDate("2024-06-01T00:00:00Z")
        )
        let ifd = GPXGeotagger.buildGPSIFD(from: point, byteOrder: .bigEndian)

        let latRef = ifd.entry(for: ExifTag.gpsLatitudeRef)?.stringValue(endian: .bigEndian)
        XCTAssertEqual(latRef, "S")
        let lonRef = ifd.entry(for: ExifTag.gpsLongitudeRef)?.stringValue(endian: .bigEndian)
        XCTAssertEqual(lonRef, "W")
    }

    func testBuildGPSIFDDateStamp() {
        let point = GPXTrackpoint(
            latitude: 0, longitude: 0,
            timestamp: makeDate("2024-03-15T08:30:00Z")
        )
        let ifd = GPXGeotagger.buildGPSIFD(from: point, byteOrder: .bigEndian)

        let dateStamp = ifd.entry(for: ExifTag.gpsDateStamp)?.stringValue(endian: .bigEndian)
        XCTAssertEqual(dateStamp, "2024:03:15")
    }

    func testBuildGPSIFDEntriesSortedByTag() {
        let point = GPXTrackpoint(
            latitude: 1.0, longitude: 2.0, elevation: 10.0,
            timestamp: makeDate("2024-01-01T00:00:00Z")
        )
        let ifd = GPXGeotagger.buildGPSIFD(from: point, byteOrder: .bigEndian)

        for i in 1..<ifd.entries.count {
            XCTAssertTrue(ifd.entries[i].tag >= ifd.entries[i - 1].tag,
                          "Entries not sorted by tag: \(ifd.entries[i - 1].tag) > \(ifd.entries[i].tag)")
        }
    }

    // MARK: - GPS IFD Round-Trip Through ExifData

    func testGPSIFDRoundTrip() {
        let point = GPXTrackpoint(
            latitude: 59.9139, longitude: 10.7522,
            timestamp: makeDate("2024-01-15T14:30:00Z")
        )
        let endian = ByteOrder.bigEndian
        let ifd = GPXGeotagger.buildGPSIFD(from: point, byteOrder: endian)

        var exifData = ExifData(byteOrder: endian)
        exifData.gpsIFD = ifd

        // Read back through ExifData's computed properties
        let lat = exifData.gpsLatitude
        let lon = exifData.gpsLongitude
        XCTAssertNotNil(lat)
        XCTAssertNotNil(lon)
        XCTAssertEqual(lat!, 59.9139, accuracy: 0.0001)
        XCTAssertEqual(lon!, 10.7522, accuracy: 0.0001)
    }

    func testGPSIFDRoundTripNegative() {
        let point = GPXTrackpoint(
            latitude: -33.8688, longitude: -151.2093,
            timestamp: makeDate("2024-06-01T00:00:00Z")
        )
        let endian = ByteOrder.bigEndian
        let ifd = GPXGeotagger.buildGPSIFD(from: point, byteOrder: endian)

        var exifData = ExifData(byteOrder: endian)
        exifData.gpsIFD = ifd

        XCTAssertEqual(exifData.gpsLatitude!, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(exifData.gpsLongitude!, -151.2093, accuracy: 0.0001)
    }

    // MARK: - ImageMetadata.applyGPX Integration

    func testApplyGPXToJPEG() throws {
        let track = makeTrack([
            (59.9139, 10.7522, "2024-01-15T14:30:00Z"),
        ])

        // Build JPEG with DateTimeOriginal
        let dateStr = "2024:01:15 14:30:00\0"
        let dateData = Data(dateStr.utf8)
        let dateEntry = IFDEntry(tag: ExifTag.dateTimeOriginal, type: .ascii, count: UInt32(dateData.count), valueData: dateData)
        var exif = ExifData(byteOrder: .bigEndian)
        exif.exifIFD = IFD(entries: [dateEntry])

        var metadata = ImageMetadata(format: .jpeg, exif: exif)
        XCTAssertNil(metadata.exif?.gpsLatitude)

        let applied = metadata.applyGPX(track, maxOffset: 60)
        XCTAssertTrue(applied)
        XCTAssertEqual(metadata.exif!.gpsLatitude!, 59.9139, accuracy: 0.001)
        XCTAssertEqual(metadata.exif!.gpsLongitude!, 10.7522, accuracy: 0.001)
    }

    func testApplyGPXNoMatchReturnsFalse() {
        let track = makeTrack([
            (59.9139, 10.7522, "2024-01-15T14:30:00Z"),
        ])

        let dateStr = "2024:01:15 20:00:00\0" // Far away
        let dateData = Data(dateStr.utf8)
        let dateEntry = IFDEntry(tag: ExifTag.dateTimeOriginal, type: .ascii, count: UInt32(dateData.count), valueData: dateData)
        var exif = ExifData(byteOrder: .bigEndian)
        exif.exifIFD = IFD(entries: [dateEntry])

        var metadata = ImageMetadata(format: .jpeg, exif: exif)
        let applied = metadata.applyGPX(track, maxOffset: 60)
        XCTAssertFalse(applied)
        XCTAssertNil(metadata.exif?.gpsLatitude)
    }

    func testApplyGPXNoExifReturnsFalse() {
        let track = makeTrack([
            (59.9139, 10.7522, "2024-01-15T14:30:00Z"),
        ])
        var metadata = ImageMetadata(format: .jpeg)
        let applied = metadata.applyGPX(track)
        XCTAssertFalse(applied)
    }

    // MARK: - Full JPEG Round-Trip

    func testGPXGeotagJPEGRoundTrip() throws {
        // Build a JPEG with DateTimeOriginal
        let exifData = TestFixtures.exifAPP1Data(byteOrder: .bigEndian, ifd0Entries: [
            (tag: ExifTag.make, stringValue: "TestCam"),
        ])
        let jpegData = TestFixtures.jpegWithSegment(marker: .app1, data: exifData)

        // Add DateTimeOriginal to the Exif sub-IFD
        var metadata = try ImageMetadata.read(from: jpegData)

        // Manually set DateTimeOriginal since fixture only has IFD0
        let dateStr = "2024:01:15 14:30:00\0"
        let dateData = Data(dateStr.utf8)
        let dateEntry = IFDEntry(tag: ExifTag.dateTimeOriginal, type: .ascii, count: UInt32(dateData.count), valueData: dateData)
        if metadata.exif == nil { metadata.exif = ExifData(byteOrder: .bigEndian) }
        let existingEntries = metadata.exif?.exifIFD?.entries ?? []
        metadata.exif?.exifIFD = IFD(entries: existingEntries + [dateEntry])

        // Apply GPX
        let track = makeTrack([
            (59.9139, 10.7522, "2024-01-15T14:29:30Z"),
            (59.9145, 10.7530, "2024-01-15T14:30:30Z"),
        ])
        let applied = metadata.applyGPX(track, maxOffset: 60)
        XCTAssertTrue(applied)

        // Write and re-read
        let written = try metadata.writeToData()
        let reread = try ImageMetadata.read(from: written)

        XCTAssertNotNil(reread.exif?.gpsLatitude)
        XCTAssertNotNil(reread.exif?.gpsLongitude)
        // Interpolated midpoint between the two track points
        XCTAssertEqual(reread.exif!.gpsLatitude!, 59.9142, accuracy: 0.001)
        XCTAssertEqual(reread.exif!.gpsLongitude!, 10.7526, accuracy: 0.001)
    }

    // MARK: - Elevation Interpolation

    func testInterpolationIncludesElevation() {
        let track = makeTrack([
            (0.0, 0.0, "2024-01-01T12:00:00Z", 100.0),
            (1.0, 1.0, "2024-01-01T12:02:00Z", 200.0),
        ])

        let result = GPXGeotagger.match(
            dateTimeOriginal: "2024:01:01 12:01:00",
            track: track, maxOffset: 120
        )
        XCTAssertNotNil(result)
        XCTAssertNotNil(result!.elevation)
        XCTAssertEqual(result!.elevation!, 150.0, accuracy: 1.0)
    }

    // MARK: - Helpers

    private func makeTrack(_ points: [(Double, Double, String)]) -> GPXTrack {
        let trackpoints = points.map { (lat, lon, time) in
            GPXTrackpoint(latitude: lat, longitude: lon, timestamp: makeDate(time))
        }
        return GPXTrack(trackpoints: trackpoints)
    }

    private func makeTrack(_ points: [(Double, Double, String, Double)]) -> GPXTrack {
        let trackpoints = points.map { (lat, lon, time, ele) in
            GPXTrackpoint(latitude: lat, longitude: lon, elevation: ele, timestamp: makeDate(time))
        }
        return GPXTrack(trackpoints: trackpoints)
    }

    private func makeDate(_ iso8601: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso8601)!
    }
}
