import XCTest
@testable import SwiftExif

final class ISOBMFFBoxTests: XCTestCase {

    func testParseSimpleBox() throws {
        var writer = BinaryWriter(capacity: 32)
        writer.writeUInt32BigEndian(12) // size = 12 (8 header + 4 payload)
        writer.writeString("test", encoding: .ascii)
        writer.writeBytes([0x01, 0x02, 0x03, 0x04])

        let boxes = try ISOBMFFBoxReader.parseBoxes(from: writer.data)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].type, "test")
        XCTAssertEqual(boxes[0].data, Data([0x01, 0x02, 0x03, 0x04]))
    }

    func testParseMultipleBoxes() throws {
        var writer = BinaryWriter(capacity: 64)
        // Box 1
        writer.writeUInt32BigEndian(12)
        writer.writeString("aaaa", encoding: .ascii)
        writer.writeBytes([0x01, 0x02, 0x03, 0x04])
        // Box 2
        writer.writeUInt32BigEndian(10)
        writer.writeString("bbbb", encoding: .ascii)
        writer.writeBytes([0x05, 0x06])

        let boxes = try ISOBMFFBoxReader.parseBoxes(from: writer.data)
        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes[0].type, "aaaa")
        XCTAssertEqual(boxes[1].type, "bbbb")
    }

    func testParseEmptyPayloadBox() throws {
        var writer = BinaryWriter(capacity: 16)
        writer.writeUInt32BigEndian(8) // size = 8 (header only, no payload)
        writer.writeString("emty", encoding: .ascii)

        let boxes = try ISOBMFFBoxReader.parseBoxes(from: writer.data)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].type, "emty")
        XCTAssertTrue(boxes[0].data.isEmpty)
    }

    func testParseBoxToEnd() throws {
        // size=0 means "to end of data"
        var writer = BinaryWriter(capacity: 32)
        writer.writeUInt32BigEndian(0) // size = 0 (extends to end)
        writer.writeString("last", encoding: .ascii)
        writer.writeBytes([0xAA, 0xBB, 0xCC])

        let boxes = try ISOBMFFBoxReader.parseBoxes(from: writer.data)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].type, "last")
        XCTAssertEqual(boxes[0].data, Data([0xAA, 0xBB, 0xCC]))
    }

    func testParseExtendedSizeBox() throws {
        // size=1 means extended size (UInt64 follows type)
        var writer = BinaryWriter(capacity: 32)
        writer.writeUInt32BigEndian(1) // size field = 1 (use extended)
        writer.writeString("ext ", encoding: .ascii)
        writer.writeUInt64BigEndian(20) // extended size = 20 (16 header + 4 payload)
        writer.writeBytes([0xDE, 0xAD, 0xBE, 0xEF])

        let boxes = try ISOBMFFBoxReader.parseBoxes(from: writer.data)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].type, "ext ")
        XCTAssertEqual(boxes[0].data, Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testEmptyInput() throws {
        let boxes = try ISOBMFFBoxReader.parseBoxes(from: Data())
        XCTAssertTrue(boxes.isEmpty)
    }
}
