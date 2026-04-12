import XCTest
@testable import SwiftExif

final class IPTCWriterTests: XCTestCase {

    func testWriteSingleKeyword() {
        var iptc = IPTCData()
        iptc.keywords = ["TestKeyword"]

        let data = IPTCWriter.write(iptc)

        // Should contain at least one 0x1C marker
        XCTAssertTrue(data.contains(0x1C))

        // Parse back and verify
        let parsed = try? IPTCReader.read(from: data)
        XCTAssertEqual(parsed?.values(for: .keywords), ["TestKeyword"])
    }

    func testWriteMultipleKeywords() {
        var iptc = IPTCData()
        iptc.keywords = ["Photo", "News", "Breaking"]

        let data = IPTCWriter.write(iptc)
        let parsed = try! IPTCReader.read(from: data)
        XCTAssertEqual(parsed.keywords, ["Photo", "News", "Breaking"])
    }

    func testWriteHeadline() {
        var iptc = IPTCData()
        iptc.headline = "Test Headline"

        let data = IPTCWriter.write(iptc)
        let parsed = try! IPTCReader.read(from: data)
        XCTAssertEqual(parsed.headline, "Test Headline")
    }

    func testBinaryFormat() {
        var iptc = IPTCData()
        iptc.setValue("Hi", for: .headline)

        let data = IPTCWriter.write(iptc)
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

        let data = IPTCWriter.write(iptc)
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

        let data = IPTCWriter.write(iptc)
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
}
