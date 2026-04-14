import Foundation

/// Manufacturer identifier for MakerNote data.
public enum MakerNoteManufacturer: String, Sendable, Equatable {
    case canon = "Canon"
    case nikon = "Nikon"
    case sony = "Sony"
    case unknown = "Unknown"
}

/// A single value extracted from a MakerNote tag.
public enum MakerNoteValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case uint(UInt)
    case double(Double)
    case data(Data)
    case intArray([Int])
}

/// Parsed MakerNote data from a camera manufacturer.
/// The raw data is preserved for lossless round-trip serialization.
public struct MakerNoteData: Equatable, Sendable {
    public let manufacturer: MakerNoteManufacturer
    public let tags: [String: MakerNoteValue]
    public let rawData: Data

    public init(manufacturer: MakerNoteManufacturer, tags: [String: MakerNoteValue], rawData: Data) {
        self.manufacturer = manufacturer
        self.tags = tags
        self.rawData = rawData
    }
}
