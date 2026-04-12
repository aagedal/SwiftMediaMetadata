import XCTest
@testable import SwiftExif

final class BinaryReaderTests: XCTestCase {

    // MARK: - Reading UInt8

    func testReadUInt8() throws {
        var reader = BinaryReader(data: Data([0x42, 0xFF, 0x00]))
        XCTAssertEqual(try reader.readUInt8(), 0x42)
        XCTAssertEqual(try reader.readUInt8(), 0xFF)
        XCTAssertEqual(try reader.readUInt8(), 0x00)
    }

    func testReadUInt8PastEnd() {
        var reader = BinaryReader(data: Data([0x42]))
        _ = try? reader.readUInt8()
        XCTAssertThrowsError(try reader.readUInt8())
    }

    // MARK: - Reading UInt16

    func testReadUInt16BigEndian() throws {
        var reader = BinaryReader(data: Data([0xFF, 0xD8]))
        XCTAssertEqual(try reader.readUInt16BigEndian(), 0xFFD8)
    }

    func testReadUInt16LittleEndian() throws {
        var reader = BinaryReader(data: Data([0xD8, 0xFF]))
        XCTAssertEqual(try reader.readUInt16LittleEndian(), 0xFFD8)
    }

    func testReadUInt16WithEndianParameter() throws {
        let data = Data([0xFF, 0xD8])
        var readerBE = BinaryReader(data: data)
        XCTAssertEqual(try readerBE.readUInt16(endian: .bigEndian), 0xFFD8)

        var readerLE = BinaryReader(data: data)
        XCTAssertEqual(try readerLE.readUInt16(endian: .littleEndian), 0xD8FF)
    }

    func testReadUInt16PastEnd() {
        var reader = BinaryReader(data: Data([0xFF]))
        XCTAssertThrowsError(try reader.readUInt16BigEndian())
    }

    // MARK: - Reading UInt32

    func testReadUInt32BigEndian() throws {
        var reader = BinaryReader(data: Data([0x00, 0x01, 0x02, 0x03]))
        XCTAssertEqual(try reader.readUInt32BigEndian(), 0x00010203)
    }

    func testReadUInt32LittleEndian() throws {
        var reader = BinaryReader(data: Data([0x03, 0x02, 0x01, 0x00]))
        XCTAssertEqual(try reader.readUInt32LittleEndian(), 0x00010203)
    }

    func testReadUInt32PastEnd() {
        var reader = BinaryReader(data: Data([0x00, 0x01, 0x02]))
        XCTAssertThrowsError(try reader.readUInt32BigEndian())
    }

    // MARK: - Reading Bytes

    func testReadBytes() throws {
        var reader = BinaryReader(data: Data([0x01, 0x02, 0x03, 0x04]))
        let bytes = try reader.readBytes(2)
        XCTAssertEqual(bytes, Data([0x01, 0x02]))
        XCTAssertEqual(reader.offset, 2)
    }

    func testReadBytesPastEnd() {
        var reader = BinaryReader(data: Data([0x01, 0x02]))
        XCTAssertThrowsError(try reader.readBytes(3))
    }

    func testReadString() throws {
        var reader = BinaryReader(data: Data("Hello".utf8))
        XCTAssertEqual(try reader.readString(5), "Hello")
    }

    func testReadStringUTF8Nordic() throws {
        let nordicString = "Tromsø"
        var reader = BinaryReader(data: Data(nordicString.utf8))
        // "Tromsø" is 7 bytes in UTF-8 (ø = 0xC3 0xB8)
        XCTAssertEqual(try reader.readString(7, encoding: .utf8), nordicString)
    }

    func testReadRemainingBytes() {
        var reader = BinaryReader(data: Data([0x01, 0x02, 0x03, 0x04]))
        _ = try? reader.skip(2)
        let remaining = reader.readRemainingBytes()
        XCTAssertEqual(remaining, Data([0x03, 0x04]))
        XCTAssertTrue(reader.isAtEnd)
    }

    // MARK: - Navigation

    func testSkip() throws {
        var reader = BinaryReader(data: Data([0x01, 0x02, 0x03, 0x04]))
        try reader.skip(2)
        XCTAssertEqual(reader.offset, 2)
        XCTAssertEqual(try reader.readUInt8(), 0x03)
    }

    func testSkipPastEnd() {
        var reader = BinaryReader(data: Data([0x01, 0x02]))
        XCTAssertThrowsError(try reader.skip(3))
    }

    func testSeek() throws {
        var reader = BinaryReader(data: Data([0x01, 0x02, 0x03, 0x04]))
        try reader.seek(to: 3)
        XCTAssertEqual(try reader.readUInt8(), 0x04)
    }

    func testSeekToEnd() throws {
        var reader = BinaryReader(data: Data([0x01, 0x02]))
        try reader.seek(to: 2)
        XCTAssertTrue(reader.isAtEnd)
    }

    func testSeekPastEnd() {
        var reader = BinaryReader(data: Data([0x01, 0x02]))
        XCTAssertThrowsError(try reader.seek(to: 3))
    }

    // MARK: - Peeking

    func testPeek() throws {
        var reader = BinaryReader(data: Data([0x42, 0x43]))
        XCTAssertEqual(try reader.peek(), 0x42)
        // Peek should not advance offset
        XCTAssertEqual(reader.offset, 0)
        _ = try reader.readUInt8()
        XCTAssertEqual(try reader.peek(), 0x43)
    }

    func testPeekUInt16BigEndian() throws {
        let reader = BinaryReader(data: Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(try reader.peekUInt16BigEndian(), 0xFFD8)
        XCTAssertEqual(reader.offset, 0) // Should not advance
    }

    // MARK: - Pattern Matching

    func testHasPrefix() {
        let reader = BinaryReader(data: Data([0xFF, 0xD8, 0xFF, 0xE1]))
        XCTAssertTrue(reader.hasPrefix([0xFF, 0xD8]))
        XCTAssertFalse(reader.hasPrefix([0xFF, 0xE1]))
    }

    func testHasPrefixTooLong() {
        let reader = BinaryReader(data: Data([0xFF]))
        XCTAssertFalse(reader.hasPrefix([0xFF, 0xD8]))
    }

    func testExpect() throws {
        var reader = BinaryReader(data: Data([0xFF, 0xD8, 0xFF]))
        try reader.expect([0xFF, 0xD8])
        XCTAssertEqual(reader.offset, 2)
    }

    func testExpectFails() {
        var reader = BinaryReader(data: Data([0xFF, 0xD8, 0xFF]))
        XCTAssertThrowsError(try reader.expect([0xFF, 0xE1]))
    }

    // MARK: - State

    func testRemainingCount() {
        var reader = BinaryReader(data: Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(reader.remainingCount, 3)
        _ = try? reader.readUInt8()
        XCTAssertEqual(reader.remainingCount, 2)
    }

    func testIsAtEnd() {
        var reader = BinaryReader(data: Data([0x01]))
        XCTAssertFalse(reader.isAtEnd)
        _ = try? reader.readUInt8()
        XCTAssertTrue(reader.isAtEnd)
    }

    func testEmptyReader() {
        let reader = BinaryReader(data: Data())
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertEqual(reader.remainingCount, 0)
    }

    // MARK: - Slice

    func testSlice() throws {
        let reader = BinaryReader(data: Data([0x01, 0x02, 0x03, 0x04]))
        let slice = try reader.slice(from: 1, count: 2)
        XCTAssertEqual(slice, Data([0x02, 0x03]))
        XCTAssertEqual(reader.offset, 0) // Should not advance
    }
}
