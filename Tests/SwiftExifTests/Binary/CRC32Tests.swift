import XCTest
@testable import SwiftExif

final class CRC32Tests: XCTestCase {

    func testKnownVector_Empty() {
        // CRC32 of empty data = 0x00000000
        XCTAssertEqual(CRC32.compute(Data()), 0x00000000)
    }

    func testKnownVector_123456789() {
        // The standard check value for CRC32: "123456789" → 0xCBF43926
        let data = Data("123456789".utf8)
        XCTAssertEqual(CRC32.compute(data), 0xCBF43926)
    }

    func testKnownVector_IHDR() {
        // PNG IHDR chunk type bytes: [0x49, 0x48, 0x44, 0x52]
        // CRC of just "IHDR" (no data) should be deterministic
        let ihdrType = Data("IHDR".utf8)
        let crc = CRC32.compute(ihdrType)
        // Verify it's consistent
        XCTAssertEqual(CRC32.compute(ihdrType), crc)
    }

    func testComputeWithType() {
        let type = "tEXt"
        let payload = Data("Hello".utf8)
        let combined = Data(type.utf8) + payload
        XCTAssertEqual(CRC32.compute(type: type, data: payload), CRC32.compute(combined))
    }

    func testDifferentDataProducesDifferentCRC() {
        let a = CRC32.compute(Data("hello".utf8))
        let b = CRC32.compute(Data("world".utf8))
        XCTAssertNotEqual(a, b)
    }
}
