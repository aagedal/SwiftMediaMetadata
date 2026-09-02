import XCTest
import SwiftMediaMetadata

final class XMPGPSTests: XCTestCase {
    func testParsesSupportedLatitudeSpellings() throws {
        let values = ["59.9", "59.9N", "59.9 N", "59,54N", "59 54 0 N", "59°54′0″N"]
        for value in values {
            let coordinate = try XMPGPSCoordinate(parsing: value, axis: .latitude)
            XCTAssertEqual(coordinate.decimalDegrees, 59.9, accuracy: 0.000_000_001, value)
            XCTAssertEqual(coordinate.originalLexicalValue, value)
        }
    }

    func testParsesAllHemispheresPolesAntimeridianAndZero() throws {
        XCTAssertEqual(try XMPGPSCoordinate(parsing: "12,30S", axis: .latitude).decimalDegrees, -12.5)
        XCTAssertEqual(try XMPGPSCoordinate(parsing: "12,30W", axis: .longitude).decimalDegrees, -12.5)
        XCTAssertEqual(try XMPGPSCoordinate(parsing: "90N", axis: .latitude).decimalDegrees, 90)
        XCTAssertEqual(try XMPGPSCoordinate(parsing: "180W", axis: .longitude).decimalDegrees, -180)
        XCTAssertEqual(try XMPGPSCoordinate(parsing: "0S", axis: .latitude).hemisphere, "S")
        XCTAssertEqual(try XMPGPSCoordinate(parsing: "0", axis: .longitude).xmpString(), "0,0.000000E")
    }

    func testSeparateReferencesAndContradictions() throws {
        XCTAssertEqual(
            try XMPGPSCoordinate(parsing: "12.5", axis: .latitude, reference: "S").decimalDegrees,
            -12.5
        )
        XCTAssertThrowsError(try XMPGPSCoordinate(parsing: "-12.5", axis: .latitude, reference: "N"))
        XCTAssertThrowsError(try XMPGPSCoordinate(parsing: "+12.5", axis: .longitude, reference: "W"))
        XCTAssertThrowsError(try XMPGPSCoordinate(parsing: "12N", axis: .latitude, reference: "S"))
        XCTAssertThrowsError(try XMPGPSCoordinate(parsing: "12E", axis: .latitude))
    }

    func testRejectsMalformedAndOutOfRangeCoordinates() {
        for (value, axis) in [("", XMPGPSAxis.latitude), ("91N", .latitude),
                              ("181E", .longitude), ("12,60N", .latitude),
                              ("abc", .longitude)] {
            XCTAssertThrowsError(try XMPGPSCoordinate(parsing: value, axis: axis), value)
        }
    }

    func testCanonicalWriterHasStableRoundTrip() throws {
        for (value, axis) in [(-59.913_868, XMPGPSAxis.latitude),
                              (179.999_999, .longitude), (90.0, .latitude),
                              (-180.0, .longitude)] {
            let original = try XMPGPSCoordinate(decimalDegrees: value, axis: axis)
            let lexical = original.xmpString(fractionalMinuteDigits: 8)
            let parsed = try XMPGPSCoordinate(parsing: lexical, axis: axis)
            XCTAssertEqual(parsed.decimalDegrees, value, accuracy: 0.000_000_001)
            XCTAssertEqual(parsed.xmpString(fractionalMinuteDigits: 8), lexical)
        }
    }

    func testTypedXMPAccessorsRetainLexicalValuesAndEmitRationals() throws {
        var xmp = XMPData()
        try xmp.setGPSLatitude(59.913_868)
        try xmp.setGPSLongitude(-10.752_245)
        try xmp.setGPSAltitude(-12.345)
        try xmp.setGPSImageDirection(271.25, reference: .magneticNorth)

        let gps = try xmp.parsedGPS()
        XCTAssertEqual(gps.latitude?.decimalDegrees ?? 0, 59.913_868, accuracy: 0.000_000_01)
        XCTAssertEqual(gps.longitude?.decimalDegrees ?? 0, -10.752_245, accuracy: 0.000_000_01)
        XCTAssertEqual(gps.altitude?.value ?? 0, -12.345, accuracy: 0.000_001)
        XCTAssertEqual(gps.altitude?.originalLexicalValue, "2469/200")
        XCTAssertEqual(gps.imageDirection?.value ?? 0, 271.25, accuracy: 0.000_001)
        XCTAssertEqual(gps.imageDirectionReference, .magneticNorth)
        XCTAssertEqual(xmp.simpleValue(namespace: XMPNamespace.exif, property: "GPSAltitudeRef"), "1")
    }

    func testRejectsInvalidAltitudeAndDirectionReferences() throws {
        var xmp = XMPData()
        xmp.setValue(.simple("12/1"), namespace: XMPNamespace.exif, property: "GPSAltitude")
        xmp.setValue(.simple("2"), namespace: XMPNamespace.exif, property: "GPSAltitudeRef")
        XCTAssertThrowsError(try xmp.parsedGPS())

        xmp.removeValue(namespace: XMPNamespace.exif, property: "GPSAltitude")
        xmp.removeValue(namespace: XMPNamespace.exif, property: "GPSAltitudeRef")
        xmp.setValue(.simple("360/1"), namespace: XMPNamespace.exif, property: "GPSImgDirection")
        xmp.setValue(.simple("X"), namespace: XMPNamespace.exif, property: "GPSImgDirectionRef")
        XCTAssertThrowsError(try xmp.parsedGPS())
        XCTAssertThrowsError(try xmp.setGPSImageDirection(360))
    }

    func testPhotoProjectionRetainsExifAndXMPGPSDisagreement() throws {
        var xmp = XMPData()
        try xmp.setGPSLatitude(60)
        try xmp.setGPSLongitude(10)
        try xmp.setGPSAltitude(25)
        try xmp.setGPSImageDirection(90, reference: .trueNorth)

        let metadata = ImageMetadata(format: .jpeg, exif: makeExifGPS(), xmp: xmp)
        let photo = metadata.photoMetadata

        XCTAssertEqual(photo.number(.gpsLatitude), 60)
        XCTAssertEqual(photo[.gpsLatitude]?.candidates.count, 2)
        XCTAssertTrue(photo[.gpsLatitude]?.hasConflict == true)
        XCTAssertTrue(photo[.gpsLongitude]?.hasConflict == false)
        XCTAssertTrue(photo[.gpsAltitude]?.hasConflict == true)
        XCTAssertTrue(photo[.gpsImageDirection]?.hasConflict == true)
        XCTAssertEqual(photo[.gpsImageDirectionReference]?.candidates.count, 2)
    }

    private func makeExifGPS() -> ExifData {
        var exif = ExifData(byteOrder: .bigEndian)
        var latitude = BinaryWriter()
        for value in [59, 0, 0] {
            latitude.writeUInt32BigEndian(UInt32(value))
            latitude.writeUInt32BigEndian(1)
        }
        var longitude = BinaryWriter()
        for value in [10, 0, 0] {
            longitude.writeUInt32BigEndian(UInt32(value))
            longitude.writeUInt32BigEndian(1)
        }
        var altitude = BinaryWriter()
        altitude.writeUInt32BigEndian(30)
        altitude.writeUInt32BigEndian(1)
        var direction = BinaryWriter()
        direction.writeUInt32BigEndian(180)
        direction.writeUInt32BigEndian(1)
        exif.gpsIFD = IFD(entries: [
            IFDEntry(tag: ExifTag.gpsLatitudeRef, type: .ascii, count: 2, valueData: Data("N\0".utf8)),
            IFDEntry(tag: ExifTag.gpsLatitude, type: .rational, count: 3, valueData: latitude.data),
            IFDEntry(tag: ExifTag.gpsLongitudeRef, type: .ascii, count: 2, valueData: Data("E\0".utf8)),
            IFDEntry(tag: ExifTag.gpsLongitude, type: .rational, count: 3, valueData: longitude.data),
            IFDEntry(tag: ExifTag.gpsAltitudeRef, type: .byte, count: 1, valueData: Data([0])),
            IFDEntry(tag: ExifTag.gpsAltitude, type: .rational, count: 1, valueData: altitude.data),
            IFDEntry(tag: ExifTag.gpsImgDirectionRef, type: .ascii, count: 2, valueData: Data("T\0".utf8)),
            IFDEntry(tag: ExifTag.gpsImgDirection, type: .rational, count: 1, valueData: direction.data),
        ])
        return exif
    }
}
