import Foundation

public enum ByteOrder: Sendable {
    case bigEndian
    case littleEndian
}

public struct BinaryReader: Sendable {
    private let data: Data
    public private(set) var offset: Int

    public init(data: Data) {
        self.data = data
        self.offset = 0
    }

    public var remainingCount: Int {
        max(0, data.count - offset)
    }

    public var isAtEnd: Bool {
        offset >= data.count
    }

    public var count: Int {
        data.count
    }

    // MARK: - Peeking

    public func peek() throws -> UInt8 {
        guard offset < data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        return data[data.startIndex + offset]
    }

    public func peekUInt16BigEndian() throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        let start = data.startIndex + offset
        return UInt16(data[start]) << 8 | UInt16(data[start + 1])
    }

    // MARK: - Reading Primitives

    public mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        let value = data[data.startIndex + offset]
        offset += 1
        return value
    }

    public mutating func readUInt16BigEndian() throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        let start = data.startIndex + offset
        let value = UInt16(data[start]) << 8 | UInt16(data[start + 1])
        offset += 2
        return value
    }

    public mutating func readUInt16LittleEndian() throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        let start = data.startIndex + offset
        let value = UInt16(data[start]) | UInt16(data[start + 1]) << 8
        offset += 2
        return value
    }

    public mutating func readUInt16(endian: ByteOrder) throws -> UInt16 {
        switch endian {
        case .bigEndian: return try readUInt16BigEndian()
        case .littleEndian: return try readUInt16LittleEndian()
        }
    }

    public mutating func readInt16(endian: ByteOrder) throws -> Int16 {
        let unsigned = try readUInt16(endian: endian)
        return Int16(bitPattern: unsigned)
    }

    public mutating func readUInt32BigEndian() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        let start = data.startIndex + offset
        let value = UInt32(data[start]) << 24
            | UInt32(data[start + 1]) << 16
            | UInt32(data[start + 2]) << 8
            | UInt32(data[start + 3])
        offset += 4
        return value
    }

    public mutating func readUInt32LittleEndian() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        let start = data.startIndex + offset
        let value = UInt32(data[start])
            | UInt32(data[start + 1]) << 8
            | UInt32(data[start + 2]) << 16
            | UInt32(data[start + 3]) << 24
        offset += 4
        return value
    }

    public mutating func readUInt32(endian: ByteOrder) throws -> UInt32 {
        switch endian {
        case .bigEndian: return try readUInt32BigEndian()
        case .littleEndian: return try readUInt32LittleEndian()
        }
    }

    public mutating func readInt32(endian: ByteOrder) throws -> Int32 {
        let unsigned = try readUInt32(endian: endian)
        return Int32(bitPattern: unsigned)
    }

    public mutating func readUInt64BigEndian() throws -> UInt64 {
        guard offset + 8 <= data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        let start = data.startIndex + offset
        let value = UInt64(data[start]) << 56
            | UInt64(data[start + 1]) << 48
            | UInt64(data[start + 2]) << 40
            | UInt64(data[start + 3]) << 32
            | UInt64(data[start + 4]) << 24
            | UInt64(data[start + 5]) << 16
            | UInt64(data[start + 6]) << 8
            | UInt64(data[start + 7])
        offset += 8
        return value
    }

    public mutating func readUInt64LittleEndian() throws -> UInt64 {
        guard offset + 8 <= data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        let start = data.startIndex + offset
        let value = UInt64(data[start])
            | UInt64(data[start + 1]) << 8
            | UInt64(data[start + 2]) << 16
            | UInt64(data[start + 3]) << 24
            | UInt64(data[start + 4]) << 32
            | UInt64(data[start + 5]) << 40
            | UInt64(data[start + 6]) << 48
            | UInt64(data[start + 7]) << 56
        offset += 8
        return value
    }

    public mutating func readUInt64(endian: ByteOrder) throws -> UInt64 {
        switch endian {
        case .bigEndian: return try readUInt64BigEndian()
        case .littleEndian: return try readUInt64LittleEndian()
        }
    }

    public mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0 else {
            throw MetadataError.invalidSegmentLength
        }
        guard offset + count <= data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        let start = data.startIndex + offset
        let result = data[start..<(start + count)]
        offset += count
        return Data(result)
    }

    public mutating func readString(_ count: Int, encoding: String.Encoding = .utf8) throws -> String {
        let bytes = try readBytes(count)
        guard let string = String(data: bytes, encoding: encoding) else {
            throw MetadataError.encodingError("Failed to decode \(count) bytes as \(encoding)")
        }
        return string
    }

    /// Read all remaining bytes from the current offset to end.
    public mutating func readRemainingBytes() -> Data {
        let start = data.startIndex + offset
        let result = data[start...]
        offset = data.count
        return Data(result)
    }

    // MARK: - Navigation

    public mutating func skip(_ count: Int) throws {
        guard count >= 0 else {
            throw MetadataError.invalidSegmentLength
        }
        guard offset + count <= data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        offset += count
    }

    public mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        offset = newOffset
    }

    // MARK: - Pattern Matching

    public func hasPrefix(_ bytes: [UInt8]) -> Bool {
        guard offset + bytes.count <= data.count else { return false }
        let start = data.startIndex + offset
        for (i, byte) in bytes.enumerated() {
            if data[start + i] != byte { return false }
        }
        return true
    }

    public mutating func expect(_ bytes: [UInt8]) throws {
        for (i, expected) in bytes.enumerated() {
            let actual = try readUInt8()
            if actual != expected {
                offset -= (i + 1)
                throw MetadataError.invalidIPTCData(
                    "Expected 0x\(String(expected, radix: 16)) at offset \(offset + i), got 0x\(String(actual, radix: 16))"
                )
            }
        }
    }

    /// Get a slice of the underlying data without advancing the offset.
    public func slice(from start: Int, count: Int) throws -> Data {
        guard start >= 0, start + count <= data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        let dataStart = data.startIndex + start
        return Data(data[dataStart..<(dataStart + count)])
    }
}
