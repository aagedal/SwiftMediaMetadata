import Foundation

/// A lightweight wrapper around an ICC color profile.
/// Stores the raw profile data and parses key header fields for identification.
public struct ICCProfile: Equatable, Sendable {
    /// The raw ICC profile data (complete, including header).
    public let data: Data

    /// Profile size in bytes (from header bytes 0-3).
    public let profileSize: UInt32

    /// Color space of the profile data (e.g. "RGB ", "CMYK", "GRAY").
    /// 4-character ASCII string from header bytes 16-19.
    public let colorSpace: String

    /// Profile connection space (e.g. "XYZ ", "Lab ").
    /// 4-character ASCII string from header bytes 20-23.
    public let profileConnectionSpace: String

    /// Human-readable profile description from the 'desc' tag, if present.
    public let profileDescription: String?

    /// Parse an ICC profile from raw data.
    /// Returns nil if the data is too small to contain a valid ICC header.
    public init?(data: Data) {
        guard data.count >= 128 else { return nil }

        self.data = data

        var reader = BinaryReader(data: data)

        // Bytes 0-3: Profile size (big-endian)
        self.profileSize = (try? reader.readUInt32BigEndian()) ?? 0

        // Skip bytes 4-15 (preferred CMM, version, class, etc.)
        try? reader.skip(12)

        // Bytes 16-19: Data color space
        if let csData = try? reader.readBytes(4),
           let cs = String(data: csData, encoding: .ascii) {
            self.colorSpace = cs
        } else {
            self.colorSpace = "????"
        }

        // Bytes 20-23: Profile connection space
        if let pcsData = try? reader.readBytes(4),
           let pcs = String(data: pcsData, encoding: .ascii) {
            self.profileConnectionSpace = pcs
        } else {
            self.profileConnectionSpace = "????"
        }

        // Parse the 'desc' tag for a human-readable description
        self.profileDescription = Self.parseDescription(from: data)
    }

    /// Create an ICC profile with pre-parsed fields (for testing).
    public init(data: Data, profileSize: UInt32, colorSpace: String, profileConnectionSpace: String, profileDescription: String?) {
        self.data = data
        self.profileSize = profileSize
        self.colorSpace = colorSpace
        self.profileConnectionSpace = profileConnectionSpace
        self.profileDescription = profileDescription
    }

    // MARK: - Description Parsing

    /// Parse the profile description from the tag table.
    /// The tag table starts at byte 128: 4-byte tag count, then 12-byte entries (signature + offset + size).
    private static func parseDescription(from data: Data) -> String? {
        guard data.count >= 132 else { return nil }

        var reader = BinaryReader(data: data)
        try? reader.seek(to: 128)

        guard let tagCount = try? reader.readUInt32BigEndian() else { return nil }
        let count = min(Int(tagCount), 100) // safety cap

        for _ in 0..<count {
            guard let sig = try? reader.readBytes(4),
                  let offset = try? reader.readUInt32BigEndian(),
                  let size = try? reader.readUInt32BigEndian() else { break }

            let tagSig = String(data: sig, encoding: .ascii) ?? ""

            // Look for 'desc' (profile description) tag
            if tagSig == "desc" {
                return parseDescTag(data: data, offset: Int(offset), size: Int(size))
            }
        }

        return nil
    }

    /// Parse a 'desc' (textDescriptionType) tag.
    /// Format: 4-byte type signature ("desc") + 4 reserved + 4-byte ASCII length + ASCII string.
    private static func parseDescTag(data: Data, offset: Int, size: Int) -> String? {
        guard offset + 12 < data.count, size > 12 else { return nil }

        var reader = BinaryReader(data: data)
        try? reader.seek(to: offset)

        // Type signature (4 bytes) — "desc" or "mluc"
        guard let typeSig = try? reader.readBytes(4) else { return nil }
        let typeStr = String(data: typeSig, encoding: .ascii) ?? ""

        if typeStr == "desc" {
            // textDescriptionType: 4 reserved + 4-byte count + ASCII string
            try? reader.skip(4) // reserved
            guard let strLen = try? reader.readUInt32BigEndian(), strLen > 0 else { return nil }
            let readLen = min(Int(strLen), size - 12)
            guard readLen > 0, let strData = try? reader.readBytes(readLen) else { return nil }
            // Remove null terminator if present
            var trimmed = strData
            if let lastByte = trimmed.last, lastByte == 0 {
                trimmed = trimmed.dropLast()
            }
            return String(data: trimmed, encoding: .ascii) ?? String(data: trimmed, encoding: .utf8)
        } else if typeStr == "mluc" {
            // multiLocalizedUnicodeType (ICC v4)
            try? reader.skip(4) // reserved
            guard let recordCount = try? reader.readUInt32BigEndian(),
                  let recordSize = try? reader.readUInt32BigEndian(),
                  recordCount > 0, recordSize >= 12 else { return nil }
            // First record: language (2) + country (2) + string length (4) + string offset (4)
            try? reader.skip(4) // language + country
            guard let strLen = try? reader.readUInt32BigEndian(),
                  let strOffset = try? reader.readUInt32BigEndian() else { return nil }
            let absOffset = offset + Int(strOffset)
            let readLen = min(Int(strLen), data.count - absOffset)
            guard readLen > 0, absOffset >= 0, absOffset + readLen <= data.count else { return nil }
            let strData = Data(data[data.startIndex + absOffset ..< data.startIndex + absOffset + readLen])
            // mluc strings are big-endian UTF-16
            return String(data: strData, encoding: .utf16BigEndian)
        }

        return nil
    }
}
