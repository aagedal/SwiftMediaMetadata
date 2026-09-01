import Foundation

/// Lazily decoded GeoNames data bundled with the Swift package.
///
/// Keeping the generated records in a binary resource avoids asking the Swift
/// compiler to type-check tens of thousands of array literals. The resource is
/// still loaded entirely in memory because the k-d tree needs every coordinate
/// and the existing API expects constant-time access to the parallel arrays.
enum GeoLocationDatabase {
    static let shared: Storage = {
        do {
            return try Storage.loadBundledResource()
        } catch {
            preconditionFailure("Invalid bundled geolocation database: \(error)")
        }
    }()

    struct Storage: Sendable {
        let cityNames: [String]
        let latitudes: [Float]
        let longitudes: [Float]
        let populations: [Int32]
        let regionIndices: [UInt16]
        let countryIndices: [UInt8]
        let timezoneIndices: [UInt16]
        let countryCodeIndices: [UInt8]
        let regionNames: [String]
        let countryNames: [String]
        let timezoneNames: [String]
        let countryCode2s: [String]
        let alpha2ToAlpha3: [String: String]

        var cityCount: Int { cityNames.count }

        fileprivate static func loadBundledResource() throws -> Self {
            guard let url = Bundle.module.url(
                forResource: "GeoLocationDatabase",
                withExtension: "bin"
            ) else {
                throw DatabaseError.missingResource
            }

            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            var reader = DatabaseReader(data: data)
            try reader.readHeader()

            let cityNames = try reader.readStrings()
            let latitudes = try reader.readArray { try $0.readFloat() }
            let longitudes = try reader.readArray { try $0.readFloat() }
            let populations = try reader.readArray { try $0.readInt32() }
            let regionIndices = try reader.readArray { try $0.readUInt16() }
            let countryIndices = try reader.readArray { try $0.readUInt8() }
            let timezoneIndices = try reader.readArray { try $0.readUInt16() }
            let countryCodeIndices = try reader.readArray { try $0.readUInt8() }
            let regionNames = try reader.readStrings()
            let countryNames = try reader.readStrings()
            let timezoneNames = try reader.readStrings()
            let countryCode2s = try reader.readStrings()

            let mappingCount = try reader.readCount()
            var alpha2ToAlpha3: [String: String] = [:]
            alpha2ToAlpha3.reserveCapacity(mappingCount)
            for _ in 0..<mappingCount {
                alpha2ToAlpha3[try reader.readString()] = try reader.readString()
            }
            try reader.requireEnd()

            let cityCount = cityNames.count
            let parallelCounts = [
                latitudes.count,
                longitudes.count,
                populations.count,
                regionIndices.count,
                countryIndices.count,
                timezoneIndices.count,
                countryCodeIndices.count,
            ]
            guard parallelCounts.allSatisfy({ $0 == cityCount }) else {
                throw DatabaseError.inconsistentCityArrays
            }
            guard regionIndices.allSatisfy({ Int($0) < regionNames.count }),
                  countryIndices.allSatisfy({ Int($0) < countryNames.count }),
                  timezoneIndices.allSatisfy({ Int($0) < timezoneNames.count }),
                  countryCodeIndices.allSatisfy({ Int($0) < countryCode2s.count })
            else {
                throw DatabaseError.invalidStringIndex
            }

            return Self(
                cityNames: cityNames,
                latitudes: latitudes,
                longitudes: longitudes,
                populations: populations,
                regionIndices: regionIndices,
                countryIndices: countryIndices,
                timezoneIndices: timezoneIndices,
                countryCodeIndices: countryCodeIndices,
                regionNames: regionNames,
                countryNames: countryNames,
                timezoneNames: timezoneNames,
                countryCode2s: countryCode2s,
                alpha2ToAlpha3: alpha2ToAlpha3
            )
        }
    }
}

private enum DatabaseError: Error, CustomStringConvertible {
    case missingResource
    case invalidHeader
    case unsupportedVersion(UInt32)
    case truncated
    case invalidUTF8
    case unreasonableCount(UInt32)
    case trailingBytes
    case inconsistentCityArrays
    case invalidStringIndex

    var description: String {
        switch self {
        case .missingResource: "resource not found"
        case .invalidHeader: "invalid file header"
        case .unsupportedVersion(let version): "unsupported version \(version)"
        case .truncated: "truncated data"
        case .invalidUTF8: "invalid UTF-8 string"
        case .unreasonableCount(let count): "unreasonable element count \(count)"
        case .trailingBytes: "unexpected trailing bytes"
        case .inconsistentCityArrays: "parallel city arrays have different lengths"
        case .invalidStringIndex: "city record refers outside a string table"
        }
    }
}

private struct DatabaseReader {
    private static let magic = Data([0x53, 0x4D, 0x4D, 0x47, 0x45, 0x4F, 0x31, 0x00])
    private static let currentVersion: UInt32 = 1
    private static let maximumElementCount: UInt32 = 1_000_000

    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readHeader() throws {
        guard try readBytes(count: Self.magic.count) == Self.magic else {
            throw DatabaseError.invalidHeader
        }
        let version = try readUInt32()
        guard version == Self.currentVersion else {
            throw DatabaseError.unsupportedVersion(version)
        }
    }

    mutating func readArray<Element>(
        _ readElement: (inout Self) throws -> Element
    ) throws -> [Element] {
        let count = try readCount()
        var result: [Element] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try readElement(&self))
        }
        return result
    }

    mutating func readStrings() throws -> [String] {
        try readArray { try $0.readString() }
    }

    mutating func readString() throws -> String {
        let count = try readCount()
        let bytes = try readBytes(count: count)
        guard let result = String(data: bytes, encoding: .utf8) else {
            throw DatabaseError.invalidUTF8
        }
        return result
    }

    mutating func readCount() throws -> Int {
        let value = try readUInt32()
        guard value <= Self.maximumElementCount else {
            throw DatabaseError.unreasonableCount(value)
        }
        return Int(value)
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readUInt8() throws -> UInt8 {
        let bytes = try readBytes(count: 1)
        return bytes[bytes.startIndex]
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readBytes(count: 2)
        let start = bytes.startIndex
        return UInt16(bytes[start]) | UInt16(bytes[start + 1]) << 8
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        let start = bytes.startIndex
        return UInt32(bytes[start])
            | UInt32(bytes[start + 1]) << 8
            | UInt32(bytes[start + 2]) << 16
            | UInt32(bytes[start + 3]) << 24
    }

    mutating func requireEnd() throws {
        guard offset == data.count else { throw DatabaseError.trailingBytes }
    }

    private mutating func readBytes(count: Int) throws -> Data.SubSequence {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw DatabaseError.truncated
        }
        let range = offset..<(offset + count)
        offset += count
        return data[range]
    }
}
