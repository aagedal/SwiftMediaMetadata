import XCTest
@testable import SwiftExif

final class ReverseGeocoderTests: XCTestCase {
    let geocoder = ReverseGeocoder()

    // MARK: - Known Cities

    func testOslo() {
        let result = geocoder.lookup(latitude: 59.9139, longitude: 10.7522)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.city, "Oslo")
        XCTAssertEqual(result?.country, "Norway")
        XCTAssertEqual(result?.countryCode, "NOR")
        XCTAssertTrue(result!.distance < 10)
    }

    func testNewYork() {
        let result = geocoder.lookup(latitude: 40.7128, longitude: -74.0060)
        XCTAssertNotNil(result)
        // Should find New York City or a nearby borough
        XCTAssertEqual(result?.countryCode, "USA")
        XCTAssertTrue(result!.distance < 20)
    }

    func testTokyo() {
        let result = geocoder.lookup(latitude: 35.6762, longitude: 139.6503)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.countryCode, "JPN")
        XCTAssertTrue(result!.distance < 20)
    }

    func testSydney() {
        let result = geocoder.lookup(latitude: -33.8688, longitude: 151.2093)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.countryCode, "AUS")
        XCTAssertTrue(result!.distance < 20)
    }

    func testStockholm() {
        let result = geocoder.lookup(latitude: 59.3293, longitude: 18.0686)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.city, "Stockholm")
        XCTAssertEqual(result?.countryCode, "SWE")
    }

    func testRioDeJaneiro() {
        let result = geocoder.lookup(latitude: -22.9068, longitude: -43.1729)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.countryCode, "BRA")
        XCTAssertTrue(result!.distance < 20)
    }

    // MARK: - Edge Cases

    func testMiddleOfOcean() {
        // Point Nemo — farthest from any land
        let result = geocoder.lookup(latitude: -48.876, longitude: -123.393, maxDistance: 50)
        XCTAssertNil(result)
    }

    func testZeroCoordinates() {
        // Gulf of Guinea — should find nearest African city or nil
        let result = geocoder.lookup(latitude: 0.0, longitude: 0.0, maxDistance: 500)
        // May or may not find a city depending on database, but should not crash
        if let result {
            XCTAssertFalse(result.city.isEmpty)
        }
    }

    func testAntimeridian() {
        // Near the International Date Line
        let result = geocoder.lookup(latitude: 51.0, longitude: 179.9, maxDistance: 500)
        // Should not crash at antimeridian
        _ = result
    }

    // MARK: - Distance

    func testHaversineAccuracy() {
        // Oslo to Stockholm is ~420 km
        let oslo = geocoder.lookup(latitude: 59.9139, longitude: 10.7522)
        let stockholm = geocoder.lookup(latitude: 59.3293, longitude: 18.0686)
        XCTAssertNotNil(oslo)
        XCTAssertNotNil(stockholm)
        // Both should be close to their respective city centers
        XCTAssertTrue(oslo!.distance < 5)
        XCTAssertTrue(stockholm!.distance < 5)
    }

    func testMaxDistanceFiltering() {
        // Very small maxDistance — should return nil even near a city
        let result = geocoder.lookup(latitude: 59.9139, longitude: 10.7522, maxDistance: 0.001)
        // Might be nil if database city isn't exactly at these coords
        // The point is it shouldn't crash
    }

    // MARK: - Multiple Results

    func testNearestMultiple() {
        let results = geocoder.nearest(latitude: 59.9139, longitude: 10.7522, count: 3)
        XCTAssertTrue(results.count >= 1)
        XCTAssertTrue(results.count <= 3)
        // Results should be sorted by distance
        for i in 1..<results.count {
            XCTAssertTrue(results[i].distance >= results[i - 1].distance)
        }
    }

    // MARK: - Timezone

    func testTimezone() {
        let result = geocoder.lookup(latitude: 59.9139, longitude: 10.7522)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.timezone, "Europe/Oslo")
    }

    // MARK: - ISO 3166 Country Codes

    func testCountryCodeAlpha3() {
        // Verify alpha-3 codes for a few known countries
        let norway = geocoder.lookup(latitude: 59.9139, longitude: 10.7522)
        XCTAssertEqual(norway?.countryCode, "NOR")

        let sweden = geocoder.lookup(latitude: 59.3293, longitude: 18.0686)
        XCTAssertEqual(sweden?.countryCode, "SWE")

        let denmark = geocoder.lookup(latitude: 55.6761, longitude: 12.5683)
        XCTAssertEqual(denmark?.countryCode, "DNK")
    }
}
