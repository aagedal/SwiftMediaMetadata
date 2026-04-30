import Foundation

/// Parser for Sony MakerNote data.
/// Sony MakerNotes may have a "SONY DSC \0\0\0" or "SONY CAM \0\0\0" prefix (12 bytes)
/// followed by a standard IFD, or start directly with an IFD.
struct SonyMakerNote: Sendable {

    // Sony MakerNote tag IDs
    private static let quality: UInt16         = 0xB047
    private static let macro: UInt16           = 0xB040
    private static let flashLevel: UInt16      = 0xB048
    private static let releaseMode: UInt16     = 0xB049
    private static let whiteBalance: UInt16    = 0xB054
    private static let serialNumber: UInt16    = 0xB020
    private static let lensType: UInt16        = 0xB027
    private static let temperature: UInt16     = 0xB023

    private static let sonyDSCPrefix = Data("SONY DSC \0\0\0".utf8)
    private static let sonyCAMPrefix = Data("SONY CAM \0\0\0".utf8)

    static func parse(data: Data, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]

        // Detect prefix and determine IFD start
        let ifdStart: Int
        if data.count > 12 && (data.prefix(9) == Data("SONY DSC ".utf8) || data.prefix(9) == Data("SONY CAM ".utf8)) {
            ifdStart = 12
        } else {
            ifdStart = 0
        }

        guard ifdStart < data.count else { return tags }

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: 0, offset: ifdStart, endian: byteOrder
        ) else { return tags }

        // Serial number (tag 0xB020) — ASCII string or undefined bytes
        if let entry = ifd.entry(for: serialNumber) {
            if let value = entry.stringValue(endian: byteOrder) {
                tags["SerialNumber"] = .string(value)
            } else if entry.type == .undefined, entry.valueData.count >= 4 {
                // Some Sony models store serial as raw bytes
                let hex = entry.valueData.prefix(8).map { String(format: "%02X", $0) }.joined()
                tags["SerialNumber"] = .string(hex)
            }
        }

        // Lens type (tag 0xB027) — UInt32 or UInt16 — surface numeric ID and human name when known.
        if let entry = ifd.entry(for: lensType) {
            var resolved: UInt32?
            if let value = entry.uint32Value(endian: byteOrder) {
                resolved = value
            } else if let value = entry.uint16Value(endian: byteOrder) {
                resolved = UInt32(value)
            }
            if let value = resolved {
                tags["LensType"] = .int(Int(value))
                if let name = sonyLensTypeNames[UInt16(clamping: value)] {
                    tags["LensTypeName"] = .string(name)
                }
            }
        }

        // Camera temperature (tag 0xB023) — Int16, value is in Celsius
        if let entry = ifd.entry(for: temperature), entry.type == .short || entry.type == .sshort {
            if let value = entry.uint16Value(endian: byteOrder) {
                let temp = Int16(bitPattern: value)
                tags["CameraTemperature"] = .int(Int(temp))
            }
        }

        if let entry = ifd.entry(for: quality),
           let value = entry.uint16Value(endian: byteOrder) {
            tags["Quality"] = .int(Int(value))
        }

        if let entry = ifd.entry(for: macro),
           let value = entry.uint16Value(endian: byteOrder) {
            tags["Macro"] = .int(Int(value))
        }

        if let entry = ifd.entry(for: flashLevel),
           let value = entry.uint16Value(endian: byteOrder) {
            tags["FlashLevel"] = .int(Int(Int16(bitPattern: value)))
        }

        if let entry = ifd.entry(for: releaseMode),
           let value = entry.uint16Value(endian: byteOrder) {
            tags["ReleaseMode"] = .int(Int(value))
        }

        if let entry = ifd.entry(for: whiteBalance),
           let value = entry.uint16Value(endian: byteOrder) {
            tags["WhiteBalance"] = .int(Int(value))
        }

        return tags
    }

    /// Human-readable names for common Sony LensType IDs (not exhaustive — covers the FE-mount
    /// lenses Scandinavian press photographers most commonly carry plus a handful of A-mount
    /// staples). Extend as needed; the table is data, not policy.
    static let sonyLensTypeNames: [UInt16: String] = [
        0:    "Minolta AF 28-85mm F3.5-4.5",
        1:    "Minolta AF 80-200mm F2.8 HS-APO G",
        2:    "Minolta AF 28-70mm F2.8 G",
        16:   "Sony 70-200mm F2.8 G SSM",
        18:   "Sony DT 18-250mm F3.5-6.3",
        25:   "Sony DT 18-200mm F3.5-6.3",
        27:   "Sony 70-400mm F4-5.6 G SSM",
        32:   "Sony 500mm F4 G SSM",
        51:   "Sony FE 28-70mm F3.5-5.6 OSS",
        61:   "Sony LA-EA1/3 Adapter",
    ]
}
