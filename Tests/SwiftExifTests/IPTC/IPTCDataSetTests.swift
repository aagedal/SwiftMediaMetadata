import XCTest
@testable import SwiftExif

final class IPTCDataSetTests: XCTestCase {

    func testStringDataSet() throws {
        let ds = try IPTCDataSet(tag: .headline, stringValue: "Test Headline")
        XCTAssertEqual(ds.tag, IPTCTag.headline)
        XCTAssertEqual(ds.stringValue(), "Test Headline")
    }

    func testUTF8NordicDataSet() throws {
        let ds = try IPTCDataSet(tag: .city, stringValue: "Tromsø")
        XCTAssertEqual(ds.stringValue(encoding: .utf8), "Tromsø")

        // Verify the raw bytes: "Tromsø" = T r o m s ø
        // ø in UTF-8 = 0xC3 0xB8
        let bytes = Array(ds.rawValue)
        XCTAssertEqual(bytes.count, 7) // 5 ASCII + 2 for ø
        XCTAssertEqual(bytes[5], 0xC3)
        XCTAssertEqual(bytes[6], 0xB8)
    }

    func testUInt16DataSet() {
        let ds = IPTCDataSet(tag: .applicationRecordVersion, uint16Value: 4)
        XCTAssertEqual(ds.uint16Value(), 4)
        XCTAssertEqual(ds.rawValue, Data([0x00, 0x04]))
    }

    func testRawDataSet() {
        let data = Data([0x1B, 0x25, 0x47]) // UTF-8 escape sequence
        let ds = IPTCDataSet(tag: .codedCharacterSet, rawValue: data)
        XCTAssertEqual(ds.tag, IPTCTag.codedCharacterSet)
        XCTAssertEqual(ds.rawValue, data)
    }

    func testEquality() throws {
        let ds1 = try IPTCDataSet(tag: .headline, stringValue: "Test")
        let ds2 = try IPTCDataSet(tag: .headline, stringValue: "Test")
        let ds3 = try IPTCDataSet(tag: .headline, stringValue: "Other")
        XCTAssertEqual(ds1, ds2)
        XCTAssertNotEqual(ds1, ds3)
    }

    func testNordicCharacterBytes() throws {
        // ø = 0xC3 0xB8
        let dsOSlash = try IPTCDataSet(tag: .city, stringValue: "ø")
        XCTAssertEqual(Array(dsOSlash.rawValue), [0xC3, 0xB8])

        // æ = 0xC3 0xA6
        let dsAE = try IPTCDataSet(tag: .city, stringValue: "æ")
        XCTAssertEqual(Array(dsAE.rawValue), [0xC3, 0xA6])

        // å = 0xC3 0xA5
        let dsAA = try IPTCDataSet(tag: .city, stringValue: "å")
        XCTAssertEqual(Array(dsAA.rawValue), [0xC3, 0xA5])

        // Ø = 0xC3 0x98
        let dsOSlashUpper = try IPTCDataSet(tag: .city, stringValue: "Ø")
        XCTAssertEqual(Array(dsOSlashUpper.rawValue), [0xC3, 0x98])

        // Æ = 0xC3 0x86
        let dsAEUpper = try IPTCDataSet(tag: .city, stringValue: "Æ")
        XCTAssertEqual(Array(dsAEUpper.rawValue), [0xC3, 0x86])

        // Å = 0xC3 0x85
        let dsAAUpper = try IPTCDataSet(tag: .city, stringValue: "Å")
        XCTAssertEqual(Array(dsAAUpper.rawValue), [0xC3, 0x85])
    }

    func testEncodingFailureThrows() {
        // Emoji cannot be encoded as ASCII
        XCTAssertThrowsError(try IPTCDataSet(tag: .headline, stringValue: "Hello 🌍", encoding: .ascii)) { error in
            guard case MetadataError.encodingError = error else {
                XCTFail("Expected MetadataError.encodingError, got \(error)")
                return
            }
        }
    }

    func testSetValueEncodingFailureThrows() {
        var iptc = IPTCData(encoding: .ascii)
        XCTAssertThrowsError(try iptc.setValue("Tromsø", for: .city)) { error in
            guard case MetadataError.encodingError = error else {
                XCTFail("Expected MetadataError.encodingError, got \(error)")
                return
            }
        }
    }

    func testSetValueEncodingFailurePreservesExistingData() throws {
        var iptc = IPTCData(encoding: .ascii)
        try iptc.setValue("Oslo", for: .city)
        XCTAssertEqual(iptc.city, "Oslo")

        // Trying to set an unencodable value should fail and preserve the old value
        XCTAssertThrowsError(try iptc.setValue("Tromsø", for: .city))
        XCTAssertEqual(iptc.city, "Oslo")
    }
}
