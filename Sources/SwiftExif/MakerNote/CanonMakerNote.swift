import Foundation

/// Parser for Canon MakerNote data.
/// Canon MakerNotes use standard IFD format starting immediately (no header prefix).
/// Offsets are relative to the start of the MakerNote data.
struct CanonMakerNote: Sendable {

    // Canon MakerNote tag IDs
    private static let cameraSettings: UInt16 = 0x0001
    private static let shotInfo: UInt16       = 0x0004
    private static let serialNumber: UInt16   = 0x0006
    private static let firmwareVersion: UInt16 = 0x0007
    private static let modelID: UInt16        = 0x0010
    private static let lensModel: UInt16      = 0x0095

    static func parse(data: Data, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: 0, offset: 0, endian: byteOrder
        ) else { return tags }

        // Serial number (tag 0x0006) — ASCII string
        if let entry = ifd.entry(for: serialNumber),
           let value = entry.stringValue(endian: byteOrder) {
            tags["SerialNumber"] = .string(value)
        }

        // Firmware version (tag 0x0007) — ASCII string
        if let entry = ifd.entry(for: firmwareVersion),
           let value = entry.stringValue(endian: byteOrder) {
            tags["FirmwareVersion"] = .string(value)
        }

        // Lens model (tag 0x0095) — ASCII string
        if let entry = ifd.entry(for: lensModel),
           let value = entry.stringValue(endian: byteOrder) {
            tags["LensModel"] = .string(value)
        }

        // Model ID (tag 0x0010) — UInt32
        if let entry = ifd.entry(for: modelID),
           let value = entry.uint32Value(endian: byteOrder) {
            tags["ModelID"] = .uint(UInt(value))
        }

        // Camera settings (tag 0x0001) — array of Int16 values
        if let entry = ifd.entry(for: cameraSettings), entry.type == .short {
            let values = entry.uint16Values(endian: byteOrder)
            if values.count > 22 {
                // Index 22 = LensType
                tags["LensType"] = .int(Int(values[22]))
            }
        }

        // Shot info (tag 0x0004) — array of Int16 values
        if let entry = ifd.entry(for: shotInfo), entry.type == .short {
            let values = entry.uint16Values(endian: byteOrder)
            if values.count > 16 {
                // Index 16 = ShutterCount (approximate position, varies by model)
                let count = Int(values[16])
                if count > 0 {
                    tags["ShutterCount"] = .int(count)
                }
            }
        }

        return tags
    }
}
