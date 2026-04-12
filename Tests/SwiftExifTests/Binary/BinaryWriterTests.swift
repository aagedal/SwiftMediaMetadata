import XCTest
@testable import SwiftExif

final class BinaryWriterTests: XCTestCase {

    // MARK: - Writing Primitives

    func testWriteUInt8() {
        var writer = BinaryWriter()
        writer.writeUInt8(0x42)
        writer.writeUInt8(0xFF)
        XCTAssertEqual(writer.data, Data([0x42, 0xFF]))
    }

    func testWriteUInt16BigEndian() {
        var writer = BinaryWriter()
        writer.writeUInt16BigEndian(0xFFD8)
        XCTAssertEqual(writer.data, Data([0xFF, 0xD8]))
    }

    func testWriteUInt16LittleEndian() {
        var writer = BinaryWriter()
        writer.writeUInt16LittleEndian(0xFFD8)
        XCTAssertEqual(writer.data, Data([0xD8, 0xFF]))
    }

    func testWriteUInt32BigEndian() {
        var writer = BinaryWriter()
        writer.writeUInt32BigEndian(0x00010203)
        XCTAssertEqual(writer.data, Data([0x00, 0x01, 0x02, 0x03]))
    }

    func testWriteUInt32LittleEndian() {
        var writer = BinaryWriter()
        writer.writeUInt32LittleEndian(0x00010203)
        XCTAssertEqual(writer.data, Data([0x03, 0x02, 0x01, 0x00]))
    }

    // MARK: - Writing Bytes and Strings

    func testWriteBytes() {
        var writer = BinaryWriter()
        writer.writeBytes(Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(writer.data, Data([0x01, 0x02, 0x03]))
    }

    func testWriteBytesArray() {
        var writer = BinaryWriter()
        writer.writeBytes([0x01, 0x02, 0x03])
        XCTAssertEqual(writer.data, Data([0x01, 0x02, 0x03]))
    }

    func testWriteString() {
        var writer = BinaryWriter()
        writer.writeString("Hi")
        XCTAssertEqual(writer.data, Data([0x48, 0x69]))
    }

    func testWriteNordicString() {
        var writer = BinaryWriter()
        writer.writeString("øæå")
        // ø = 0xC3 0xB8, æ = 0xC3 0xA6, å = 0xC3 0xA5
        XCTAssertEqual(writer.data, Data([0xC3, 0xB8, 0xC3, 0xA6, 0xC3, 0xA5]))
    }

    func testWriteNullTerminatedString() {
        var writer = BinaryWriter()
        writer.writeNullTerminatedString("AB")
        XCTAssertEqual(writer.data, Data([0x41, 0x42, 0x00]))
    }

    // MARK: - Padding

    func testPadToEvenOddLength() {
        var writer = BinaryWriter()
        writer.writeUInt8(0x01)
        XCTAssertEqual(writer.count, 1)
        writer.padToEven()
        XCTAssertEqual(writer.count, 2)
        XCTAssertEqual(writer.data[1], 0x00)
    }

    func testPadToEvenEvenLength() {
        var writer = BinaryWriter()
        writer.writeUInt16BigEndian(0x0102)
        XCTAssertEqual(writer.count, 2)
        writer.padToEven()
        XCTAssertEqual(writer.count, 2) // No change
    }

    func testAlign() {
        var writer = BinaryWriter()
        writer.writeBytes([0x01, 0x02, 0x03])
        writer.align(to: 4)
        XCTAssertEqual(writer.count, 4)
        XCTAssertEqual(writer.data[3], 0x00)
    }

    func testAlignAlreadyAligned() {
        var writer = BinaryWriter()
        writer.writeBytes([0x01, 0x02, 0x03, 0x04])
        writer.align(to: 4)
        XCTAssertEqual(writer.count, 4) // No change
    }

    // MARK: - Round-trip Tests

    func testRoundTripUInt16BigEndian() throws {
        var writer = BinaryWriter()
        writer.writeUInt16BigEndian(0xABCD)
        var reader = BinaryReader(data: writer.data)
        XCTAssertEqual(try reader.readUInt16BigEndian(), 0xABCD)
    }

    func testRoundTripUInt16LittleEndian() throws {
        var writer = BinaryWriter()
        writer.writeUInt16LittleEndian(0xABCD)
        var reader = BinaryReader(data: writer.data)
        XCTAssertEqual(try reader.readUInt16LittleEndian(), 0xABCD)
    }

    func testRoundTripUInt32BigEndian() throws {
        var writer = BinaryWriter()
        writer.writeUInt32BigEndian(0xDEADBEEF)
        var reader = BinaryReader(data: writer.data)
        XCTAssertEqual(try reader.readUInt32BigEndian(), 0xDEADBEEF)
    }

    func testRoundTripUInt32LittleEndian() throws {
        var writer = BinaryWriter()
        writer.writeUInt32LittleEndian(0xDEADBEEF)
        var reader = BinaryReader(data: writer.data)
        XCTAssertEqual(try reader.readUInt32LittleEndian(), 0xDEADBEEF)
    }

    func testRoundTripMixedValues() throws {
        var writer = BinaryWriter()
        writer.writeUInt8(0x42)
        writer.writeUInt16BigEndian(0x1234)
        writer.writeUInt32BigEndian(0xDEADBEEF)
        writer.writeString("Tromsø")

        var reader = BinaryReader(data: writer.data)
        XCTAssertEqual(try reader.readUInt8(), 0x42)
        XCTAssertEqual(try reader.readUInt16BigEndian(), 0x1234)
        XCTAssertEqual(try reader.readUInt32BigEndian(), 0xDEADBEEF)
        XCTAssertEqual(try reader.readString(7), "Tromsø")
    }

    // MARK: - Patching

    func testPatchUInt16BigEndian() {
        var writer = BinaryWriter()
        writer.writeUInt16BigEndian(0x0000) // placeholder
        writer.writeUInt16BigEndian(0x1234)
        writer.patchUInt16BigEndian(0xABCD, at: 0)
        XCTAssertEqual(writer.data[0], 0xAB)
        XCTAssertEqual(writer.data[1], 0xCD)
    }

    func testPatchUInt32BigEndian() {
        var writer = BinaryWriter()
        writer.writeUInt32BigEndian(0x00000000) // placeholder
        writer.patchUInt32BigEndian(0xDEADBEEF, at: 0)
        XCTAssertEqual(writer.data, Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testPatchUInt32LittleEndian() {
        var writer = BinaryWriter()
        writer.writeUInt32LittleEndian(0x00000000)
        writer.patchUInt32LittleEndian(0xDEADBEEF, at: 0)
        XCTAssertEqual(writer.data, Data([0xEF, 0xBE, 0xAD, 0xDE]))
    }

    // MARK: - Count

    func testCount() {
        var writer = BinaryWriter()
        XCTAssertEqual(writer.count, 0)
        writer.writeUInt8(0x01)
        XCTAssertEqual(writer.count, 1)
        writer.writeUInt32BigEndian(0x02030405)
        XCTAssertEqual(writer.count, 5)
    }
}
