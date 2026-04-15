import XCTest
@testable import SwiftExif

final class DirectGPSWriteTests: XCTestCase {

    // MARK: - setGPS

    func testSetGPSWritesLatLon() {
        var metadata = ImageMetadata.empty()
        metadata.setGPS(latitude: 59.9139, longitude: 10.7522)

        XCTAssertNotNil(metadata.exif?.gpsIFD)
        let lat = metadata.exif?.gpsLatitude
        let lon = metadata.exif?.gpsLongitude
        XCTAssertNotNil(lat)
        XCTAssertNotNil(lon)
        XCTAssertEqual(lat!, 59.9139, accuracy: 0.001)
        XCTAssertEqual(lon!, 10.7522, accuracy: 0.001)
    }

    func testSetGPSSouthernHemisphere() {
        var metadata = ImageMetadata.empty()
        metadata.setGPS(latitude: -33.8688, longitude: 151.2093) // Sydney

        let lat = metadata.exif?.gpsLatitude
        let lon = metadata.exif?.gpsLongitude
        XCTAssertNotNil(lat)
        XCTAssertNotNil(lon)
        XCTAssertEqual(lat!, -33.8688, accuracy: 0.001)
        XCTAssertEqual(lon!, 151.2093, accuracy: 0.001)
    }

    func testSetGPSWesternHemisphere() {
        var metadata = ImageMetadata.empty()
        metadata.setGPS(latitude: 40.7128, longitude: -74.0060) // New York

        let lat = metadata.exif?.gpsLatitude
        let lon = metadata.exif?.gpsLongitude
        XCTAssertNotNil(lat)
        XCTAssertNotNil(lon)
        XCTAssertEqual(lat!, 40.7128, accuracy: 0.001)
        XCTAssertEqual(lon!, -74.0060, accuracy: 0.001)
    }

    func testSetGPSWithAltitude() {
        var metadata = ImageMetadata.empty()
        metadata.setGPS(latitude: 27.9881, longitude: 86.9250, altitude: 8848.86) // Everest

        XCTAssertNotNil(metadata.exif?.gpsIFD)
        // Check altitude entry exists
        let altEntry = metadata.exif?.gpsIFD?.entry(for: ExifTag.gpsAltitude)
        XCTAssertNotNil(altEntry)
        let altRefEntry = metadata.exif?.gpsIFD?.entry(for: ExifTag.gpsAltitudeRef)
        XCTAssertNotNil(altRefEntry)
    }

    func testSetGPSNegativeAltitude() {
        var metadata = ImageMetadata.empty()
        metadata.setGPS(latitude: 31.5, longitude: 35.5, altitude: -430.0) // Dead Sea

        // AltitudeRef should be 1 (below sea level)
        let altRefEntry = metadata.exif?.gpsIFD?.entry(for: ExifTag.gpsAltitudeRef)
        XCTAssertNotNil(altRefEntry)
        if let data = altRefEntry?.valueData, !data.isEmpty {
            XCTAssertEqual(data[data.startIndex], 1) // below sea level
        }
    }

    func testSetGPSBoundaryValues() {
        var metadata = ImageMetadata.empty()

        // North pole
        metadata.setGPS(latitude: 90.0, longitude: 0.0)
        XCTAssertEqual(metadata.exif?.gpsLatitude ?? 0, 90.0, accuracy: 0.001)

        // South pole
        metadata.setGPS(latitude: -90.0, longitude: 0.0)
        XCTAssertEqual(metadata.exif?.gpsLatitude ?? 0, -90.0, accuracy: 0.001)

        // Antimeridian
        metadata.setGPS(latitude: 0.0, longitude: 180.0)
        XCTAssertEqual(metadata.exif?.gpsLongitude ?? 0, 180.0, accuracy: 0.001)

        metadata.setGPS(latitude: 0.0, longitude: -180.0)
        XCTAssertEqual(metadata.exif?.gpsLongitude ?? 0, -180.0, accuracy: 0.001)
    }

    func testSetGPSCreatesExifIfNil() {
        var metadata = ImageMetadata.empty()
        XCTAssertNil(metadata.exif)

        metadata.setGPS(latitude: 0.0, longitude: 0.0)
        XCTAssertNotNil(metadata.exif)
        XCTAssertNotNil(metadata.exif?.gpsIFD)
    }

    // MARK: - removeGPS

    func testRemoveGPS() {
        var metadata = ImageMetadata.empty()
        metadata.setGPS(latitude: 59.9139, longitude: 10.7522)
        XCTAssertNotNil(metadata.exif?.gpsIFD)

        metadata.removeGPS()
        XCTAssertNil(metadata.exif?.gpsIFD)
    }

    // MARK: - fillLocationFromGPS

    func testFillLocationFromGPS() {
        var metadata = ImageMetadata.empty()
        metadata.setGPS(latitude: 59.9139, longitude: 10.7522) // Oslo

        let location = metadata.fillLocationFromGPS()
        XCTAssertNotNil(location)
        XCTAssertEqual(location?.city, "Oslo")
        XCTAssertEqual(location?.countryCode, "NOR")

        // IPTC fields should be filled
        XCTAssertEqual(metadata.iptc.city, "Oslo")
        XCTAssertEqual(metadata.iptc.countryCode, "NOR")
        XCTAssertEqual(metadata.iptc.countryName, "Norway")
    }

    func testFillLocationPreservesExisting() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.city = "Tromsø"
        metadata.setGPS(latitude: 59.9139, longitude: 10.7522) // Oslo

        metadata.fillLocationFromGPS(overwrite: false)

        // Existing city preserved
        XCTAssertEqual(metadata.iptc.city, "Tromsø")
        // But missing fields filled
        XCTAssertNotNil(metadata.iptc.countryName)
    }

    func testFillLocationOverwrites() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.city = "Tromsø"
        metadata.setGPS(latitude: 59.9139, longitude: 10.7522) // Oslo

        metadata.fillLocationFromGPS(overwrite: true)

        XCTAssertEqual(metadata.iptc.city, "Oslo")
    }

    func testFillLocationReturnsNilWithoutGPS() {
        var metadata = ImageMetadata.empty()
        let result = metadata.fillLocationFromGPS()
        XCTAssertNil(result)
    }
}
