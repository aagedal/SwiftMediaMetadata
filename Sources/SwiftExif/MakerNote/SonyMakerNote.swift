import Foundation

/// Parser for Sony MakerNote data.
/// Sony MakerNotes may have a "SONY DSC \0\0\0" or "SONY CAM \0\0\0" prefix (12 bytes)
/// followed by a standard IFD, or start directly with an IFD.
struct SonyMakerNote: Sendable {

    // Sony MakerNote tag IDs
    private static let quality: UInt16         = 0x0102
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

        // Lens type (tag 0xB027) — UInt32 or UInt16
        if let entry = ifd.entry(for: lensType) {
            if let value = entry.uint32Value(endian: byteOrder) {
                tags["LensType"] = .int(Int(value))
            } else if let value = entry.uint16Value(endian: byteOrder) {
                tags["LensType"] = .int(Int(value))
            }
        }

        // Camera temperature (tag 0xB023) — Int16, value is in Celsius
        if let entry = ifd.entry(for: temperature), entry.type == .short || entry.type == .sshort {
            if let value = entry.uint16Value(endian: byteOrder) {
                let temp = Int16(bitPattern: value)
                tags["CameraTemperature"] = .int(Int(temp))
            }
        }

        return tags
    }
}
