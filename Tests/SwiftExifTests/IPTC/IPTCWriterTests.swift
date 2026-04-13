import XCTest
@testable import SwiftExif

final class IPTCWriterTests: XCTestCase {

    func testWriteSingleKeyword() {
        var iptc = IPTCData()
        iptc.keywords = ["TestKeyword"]

        let data = try! IPTCWriter.write(iptc)

        // Should contain at least one 0x1C marker
        XCTAssertTrue(data.contains(0x1C))

        // Parse back and verify
        let parsed = try? IPTCReader.read(from: data)
        XCTAssertEqual(parsed?.values(for: .keywords), ["TestKeyword"])
    }

    func testWriteMultipleKeywords() {
        var iptc = IPTCData()
        iptc.keywords = ["Photo", "News", "Breaking"]

        let data = try! IPTCWriter.write(iptc)
        let parsed = try! IPTCReader.read(from: data)
        XCTAssertEqual(parsed.keywords, ["Photo", "News", "Breaking"])
    }

    func testWriteHeadline() {
        var iptc = IPTCData()
        iptc.headline = "Test Headline"

        let data = try! IPTCWriter.write(iptc)
        let parsed = try! IPTCReader.read(from: data)
        XCTAssertEqual(parsed.headline, "Test Headline")
    }

    func testBinaryFormat() {
        var iptc = IPTCData()
        iptc.setValue("Hi", for: .headline)

        let data = try! IPTCWriter.write(iptc)
        let bytes = Array(data)

        // Find the headline dataset
        // Look for 0x1C, record 2, dataset 105
        var found = false
        for i in 0..<bytes.count - 4 {
            if bytes[i] == 0x1C && bytes[i+1] == 2 && bytes[i+2] == 105 {
                let length = UInt16(bytes[i+3]) << 8 | UInt16(bytes[i+4])
                XCTAssertEqual(length, 2) // "Hi" = 2 bytes
                XCTAssertEqual(bytes[i+5], 0x48) // 'H'
                XCTAssertEqual(bytes[i+6], 0x69) // 'i'
                found = true
                break
            }
        }
        XCTAssertTrue(found, "Headline dataset not found in binary output")
    }

    func testUTF8CharacterSetAutoEmitted() {
        var iptc = IPTCData()
        iptc.city = "Tromsø" // Contains non-ASCII

        let data = try! IPTCWriter.write(iptc)
        let bytes = Array(data)

        // Should contain 1:90 with UTF-8 escape sequence
        var foundCharset = false
        for i in 0..<bytes.count - 7 {
            if bytes[i] == 0x1C && bytes[i+1] == 1 && bytes[i+2] == 90 {
                // Length should be 3
                let length = UInt16(bytes[i+3]) << 8 | UInt16(bytes[i+4])
                XCTAssertEqual(length, 3)
                XCTAssertEqual(bytes[i+5], 0x1B) // ESC
                XCTAssertEqual(bytes[i+6], 0x25) // %
                XCTAssertEqual(bytes[i+7], 0x47) // G
                foundCharset = true
                break
            }
        }
        XCTAssertTrue(foundCharset, "CodedCharacterSet 1:90 not found for non-ASCII content")
    }

    func testASCIIOnlyNoCharacterSet() {
        var iptc = IPTCData()
        iptc.headline = "Plain ASCII"

        let data = try! IPTCWriter.write(iptc)
        let bytes = Array(data)

        // Should NOT contain 1:90 (no non-ASCII)
        for i in 0..<bytes.count - 2 {
            if bytes[i] == 0x1C && bytes[i+1] == 1 && bytes[i+2] == 90 {
                XCTFail("Found unexpected CodedCharacterSet for ASCII-only content")
                return
            }
        }
    }

    func testWriteToAPP13() throws {
        var iptc = IPTCData()
        iptc.headline = "Test"

        let app13Data = try IPTCWriter.writeToAPP13(iptc)

        // Should start with "Photoshop 3.0\0"
        let header = String(data: app13Data.prefix(13), encoding: .ascii)
        XCTAssertEqual(header, "Photoshop 3.0")

        // Should be parseable by PhotoshopIRB
        let blocks = try PhotoshopIRB.parse(app13Data)
        XCTAssertTrue(blocks.contains { $0.resourceID == 0x0404 })
    }

    // MARK: - Max Length Validation

    func testWriteThrowsWhenBylineExceedsMaxLength() {
        var iptc = IPTCData()
        // byline maxLength = 32
        iptc.byline = String(repeating: "A", count: 33)

        XCTAssertThrowsError(try IPTCWriter.write(iptc)) { error in
            guard case MetadataError.dataExceedsMaxLength(let tag, let max, let actual) = error else {
                XCTFail("Expected dataExceedsMaxLength, got \(error)")
                return
            }
            XCTAssertEqual(tag, "By-line")
            XCTAssertEqual(max, 32)
            XCTAssertEqual(actual, 33)
        }
    }

    func testWriteThrowsWhenKeywordExceedsMaxLength() {
        var iptc = IPTCData()
        // keywords maxLength = 64
        iptc.keywords = ["OK", String(repeating: "B", count: 65)]

        XCTAssertThrowsError(try IPTCWriter.write(iptc)) { error in
            guard case MetadataError.dataExceedsMaxLength(_, let max, let actual) = error else {
                XCTFail("Expected dataExceedsMaxLength, got \(error)")
                return
            }
            XCTAssertEqual(max, 64)
            XCTAssertEqual(actual, 65)
        }
    }

    func testWriteAllowsValueAtExactMaxLength() throws {
        var iptc = IPTCData()
        // byline maxLength = 32, exactly 32 should be fine
        iptc.byline = String(repeating: "X", count: 32)

        let data = try IPTCWriter.write(iptc)
        let parsed = try IPTCReader.read(from: data)
        XCTAssertEqual(parsed.byline, String(repeating: "X", count: 32))
    }

    func testValidateReturnsAllFields() {
        var iptc = IPTCData()
        // city maxLength = 32
        iptc.city = String(repeating: "C", count: 40)

        XCTAssertThrowsError(try iptc.validate()) { error in
            guard case MetadataError.dataExceedsMaxLength(let tag, _, _) = error else {
                XCTFail("Expected dataExceedsMaxLength, got \(error)")
                return
            }
            XCTAssertEqual(tag, "City")
        }
    }

    func testWriteThrowsForMultibyteUTF8ExceedingMaxLength() {
        var iptc = IPTCData()
        // city maxLength = 32 bytes. Nordic chars are multi-byte in UTF-8.
        // "Ø" is 2 bytes in UTF-8, so 17 of them = 34 bytes > 32
        iptc.city = String(repeating: "Ø", count: 17)

        XCTAssertThrowsError(try IPTCWriter.write(iptc)) { error in
            guard case MetadataError.dataExceedsMaxLength(_, let max, let actual) = error else {
                XCTFail("Expected dataExceedsMaxLength, got \(error)")
                return
            }
            XCTAssertEqual(max, 32)
            XCTAssertEqual(actual, 34) // 17 × 2 bytes
        }
    }
}
