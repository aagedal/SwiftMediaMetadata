import Foundation

/// Parser for Canon MakerNote data.
/// Canon MakerNotes use standard IFD format starting immediately (no header prefix).
/// Offsets are relative to the start of the MakerNote data.
///
/// Tag IDs and array indices match ExifTool's `Canon.pm` (Phil Harvey). Indices into the
/// CameraSettings/ShotInfo/AFInfo2/FileInfo/SensorInfo arrays use the same numbering as
/// ExifTool, where index 0 holds the byte-count marker and the named fields start at 1.
struct CanonMakerNote: Sendable {

    // Top-level Canon MakerNote tag IDs
    private static let cameraSettings: UInt16   = 0x0001
    private static let focalLength: UInt16      = 0x0002
    private static let shotInfo: UInt16         = 0x0004
    private static let serialNumber: UInt16     = 0x0006
    private static let firmwareVersion: UInt16  = 0x0007
    private static let fileNumber: UInt16       = 0x0008
    private static let ownerName: UInt16        = 0x0009
    private static let serialNumberAlt: UInt16  = 0x000C
    private static let modelID: UInt16          = 0x0010
    private static let afInfo2: UInt16          = 0x0026
    private static let fileInfo: UInt16         = 0x0093
    private static let lensModel: UInt16        = 0x0095
    private static let internalSerial: UInt16   = 0x0096
    private static let sensorInfo: UInt16       = 0x00E0

    static func parse(data: Data, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: 0, offset: 0, endian: byteOrder
        ) else { return tags }

        // ---- Scalar / string tags ------------------------------------------------------
        if let entry = ifd.entry(for: serialNumber),
           let value = entry.stringValue(endian: byteOrder) {
            tags["SerialNumber"] = .string(value)
        }
        if let entry = ifd.entry(for: firmwareVersion),
           let value = entry.stringValue(endian: byteOrder) {
            tags["FirmwareVersion"] = .string(value)
        }
        if let entry = ifd.entry(for: ownerName),
           let value = entry.stringValue(endian: byteOrder) {
            tags["OwnerName"] = .string(value)
        }
        if let entry = ifd.entry(for: lensModel),
           let value = entry.stringValue(endian: byteOrder) {
            tags["LensModel"] = .string(value)
        }
        if let entry = ifd.entry(for: internalSerial),
           let value = entry.stringValue(endian: byteOrder) {
            tags["InternalSerialNumber"] = .string(value)
        }
        if let entry = ifd.entry(for: modelID),
           let value = entry.uint32Value(endian: byteOrder) {
            tags["ModelID"] = .uint(UInt(value))
        }
        if let entry = ifd.entry(for: fileNumber),
           let value = entry.uint32Value(endian: byteOrder) {
            // Canon FileNumber encodes Folder*10000 + Image (e.g. 100_5678 -> 1005678).
            tags["FileNumber"] = .uint(UInt(value))
            let folder = Int(value) / 10000
            let image  = Int(value) % 10000
            if folder > 0 {
                tags["FileIndex"] = .string(String(format: "%03d-%04d", folder, image))
            }
        }
        if let entry = ifd.entry(for: serialNumberAlt),
           tags["SerialNumber"] == nil,
           let value = entry.stringValue(endian: byteOrder) {
            tags["SerialNumber"] = .string(value)
        }

        // ---- Array tags ----------------------------------------------------------------
        if let entry = ifd.entry(for: cameraSettings), entry.type == .short {
            parseCameraSettings(entry.uint16Values(endian: byteOrder), into: &tags)
        }
        if let entry = ifd.entry(for: focalLength), entry.type == .short {
            parseFocalLength(entry.uint16Values(endian: byteOrder), into: &tags)
        }
        if let entry = ifd.entry(for: shotInfo), entry.type == .short {
            parseShotInfo(entry.uint16Values(endian: byteOrder), into: &tags)
        }
        if let entry = ifd.entry(for: afInfo2), entry.type == .short {
            parseAFInfo2(entry.uint16Values(endian: byteOrder), into: &tags)
        }
        if let entry = ifd.entry(for: fileInfo), entry.type == .short {
            parseFileInfo(entry.uint16Values(endian: byteOrder), into: &tags)
        }
        if let entry = ifd.entry(for: sensorInfo), entry.type == .short {
            parseSensorInfo(entry.uint16Values(endian: byteOrder), into: &tags)
        }

        return tags
    }

    // MARK: - CameraSettings (tag 0x0001)

    /// Index map matches ExifTool's CanonCameraSettings table. Most fields are signed Int16.
    private static func parseCameraSettings(_ values: [UInt16], into tags: inout [String: MakerNoteValue]) {
        func signed(_ idx: Int) -> Int16? {
            guard idx < values.count else { return nil }
            return Int16(bitPattern: values[idx])
        }
        if let v = signed(1)  { tags["MacroMode"]          = .int(Int(v)) }
        if let v = signed(2), v != 0 { tags["SelfTimer"]   = .int(Int(v)) }
        if let v = signed(3)  { tags["Quality"]            = .int(Int(v)) }
        if let v = signed(4)  { tags["CanonFlashMode"]     = .int(Int(v)) }
        if let v = signed(5)  { tags["ContinuousDrive"]    = .int(Int(v)) }
        if let v = signed(7)  { tags["FocusMode"]          = .int(Int(v)) }
        if let v = signed(9)  { tags["RecordMode"]         = .int(Int(v)) }
        if let v = signed(10) { tags["CanonImageSize"]     = .int(Int(v)) }
        if let v = signed(11) { tags["EasyMode"]           = .int(Int(v)) }
        if let v = signed(12) { tags["DigitalZoom"]        = .int(Int(v)) }
        if let v = signed(13) { tags["Contrast"]           = .int(Int(v)) }
        if let v = signed(14) { tags["Saturation"]         = .int(Int(v)) }
        if let v = signed(15) { tags["Sharpness"]          = .int(Int(v)) }
        if let v = signed(16) { tags["CameraISO"]          = .int(Int(v)) }
        if let v = signed(17) { tags["MeteringMode"]       = .int(Int(v)) }
        if let v = signed(18) { tags["FocusRange"]         = .int(Int(v)) }
        if let v = signed(19) { tags["AFPoint"]            = .int(Int(v)) }
        if let v = signed(20) { tags["CanonExposureMode"]  = .int(Int(v)) }
        if let v = signed(22) { tags["LensType"]           = .int(Int(v)) }
        if values.count > 25 {
            // Focal-length triplet: stored in "focal units per mm" — divide by units to get mm.
            let units = max(Int(values[25]), 1)
            tags["MaxFocalLength"] = .double(Double(values[23]) / Double(units))
            tags["MinFocalLength"] = .double(Double(values[24]) / Double(units))
            tags["FocalUnits"]     = .int(units)
        }
        if let v = signed(34) { tags["ImageStabilization"] = .int(Int(v)) }
    }

    // MARK: - FocalLength (tag 0x0002)

    /// values[1] = focal length in focal units (use FocalUnits from CameraSettings to convert).
    /// values[2] = FocalPlaneXSize, values[3] = FocalPlaneYSize (sensor dimensions in pixels).
    private static func parseFocalLength(_ values: [UInt16], into tags: inout [String: MakerNoteValue]) {
        if values.count > 1 {
            let units = (tags["FocalUnits"].flatMap { if case .int(let u) = $0 { return u } else { return nil } }) ?? 1
            tags["FocalLength"] = .double(Double(values[1]) / Double(max(units, 1)))
        }
        if values.count > 2, values[2] > 0 { tags["FocalPlaneXSize"] = .int(Int(values[2])) }
        if values.count > 3, values[3] > 0 { tags["FocalPlaneYSize"] = .int(Int(values[3])) }
    }

    // MARK: - ShotInfo (tag 0x0004)

    /// Indices match ExifTool's CanonShotInfo. Values are Int16 except where noted.
    /// Note: ShutterCount is NOT in ShotInfo for most modern EOS bodies — use FileInfo (0x0093) instead.
    private static func parseShotInfo(_ values: [UInt16], into tags: inout [String: MakerNoteValue]) {
        func signed(_ idx: Int) -> Int16? {
            guard idx < values.count else { return nil }
            return Int16(bitPattern: values[idx])
        }
        if let v = signed(1)  { tags["AutoISO"]              = .int(Int(v)) }
        if let v = signed(2)  { tags["BaseISO"]              = .int(Int(v)) }
        if let v = signed(3)  { tags["MeasuredEV"]           = .int(Int(v)) }
        if let v = signed(7)  { tags["WhiteBalance"]         = .int(Int(v)) }
        if let v = signed(8)  { tags["SlowShutter"]          = .int(Int(v)) }
        if let v = signed(9), v >= 0 { tags["SequenceNumber"] = .int(Int(v)) }
        if let v = signed(12), v != 0 {
            // Encoded as Celsius + 128. Sentinel 0 means "unset".
            tags["CameraTemperature"] = .int(Int(v) - 128)
        }
        if let v = signed(13) { tags["FlashGuideNumber"]     = .int(Int(v)) }
        if let v = signed(14) { tags["AFPointsInFocus"]      = .int(Int(v)) }
        if let v = signed(15) { tags["FlashExposureComp"]    = .double(Double(v) / 32.0) }
        if let v = signed(16) { tags["AutoExposureBracketing"] = .int(Int(v)) }
        if let v = signed(17) { tags["AEBBracketValue"]      = .double(Double(v) / 32.0) }
        if let v = signed(18) { tags["ControlMode"]          = .int(Int(v)) }
        if let v = signed(19) { tags["FocusDistanceUpper"]   = .int(Int(v)) }
        if let v = signed(20) { tags["FocusDistanceLower"]   = .int(Int(v)) }
        if let v = signed(33) { tags["FlashOutput"]          = .int(Int(v)) }
    }

    // MARK: - AFInfo2 (tag 0x0026)

    /// Header (1..4) + variable-length AF point arrays. Layout:
    /// 1: AFInfoSize (bytes), 2: AFAreaMode, 3: NumAFPoints, 4: ValidAFPoints,
    /// 5: AFImageWidth, 6: AFImageHeight, then per-point Width/Height/X/Y arrays.
    /// We surface the scalar header — per-point arrays are model-specific and rarely consumed.
    private static func parseAFInfo2(_ values: [UInt16], into tags: inout [String: MakerNoteValue]) {
        func signed(_ idx: Int) -> Int16? {
            guard idx < values.count else { return nil }
            return Int16(bitPattern: values[idx])
        }
        if let v = signed(2) { tags["AFAreaMode"]      = .int(Int(v)) }
        if let v = signed(3) { tags["NumAFPoints"]     = .int(Int(v)) }
        if let v = signed(4) { tags["ValidAFPoints"]   = .int(Int(v)) }
        if let v = signed(5), v > 0 { tags["AFImageWidth"]  = .int(Int(v)) }
        if let v = signed(6), v > 0 { tags["AFImageHeight"] = .int(Int(v)) }
    }

    // MARK: - FileInfo (tag 0x0093)

    /// Modern EOS bodies store the actual shutter count in FileInfo[1] as a 32-bit value
    /// (two consecutive UInt16 words, low-word first). Other interesting fields:
    /// 3: BracketMode, 4: BracketValue, 5: BracketShotNumber, 6: RawJpgQuality,
    /// 7: RawJpgSize, 8: NoiseReduction, 19: LiveViewShooting.
    private static func parseFileInfo(_ values: [UInt16], into tags: inout [String: MakerNoteValue]) {
        func signed(_ idx: Int) -> Int16? {
            guard idx < values.count else { return nil }
            return Int16(bitPattern: values[idx])
        }
        // FileNumber is a 32-bit value spanning indices 1 and 2 (low/high).
        if values.count > 2 {
            let combined = UInt32(values[1]) | (UInt32(values[2]) << 16)
            if combined > 0 { tags["ShutterCount"] = .int(Int(combined)) }
        }
        if let v = signed(3) { tags["BracketMode"]        = .int(Int(v)) }
        if let v = signed(4) { tags["BracketValue"]       = .double(Double(v) / 32.0) }
        if let v = signed(5) { tags["BracketShotNumber"]  = .int(Int(v)) }
        if let v = signed(6) { tags["RawJpgQuality"]      = .int(Int(v)) }
        if let v = signed(7) { tags["RawJpgSize"]         = .int(Int(v)) }
        if let v = signed(8) { tags["NoiseReduction"]     = .int(Int(v)) }
        if let v = signed(19) { tags["LiveViewShooting"]  = .int(Int(v)) }
    }

    // MARK: - SensorInfo (tag 0x00E0)

    /// 1: SensorWidth, 2: SensorHeight, 5..8: SensorLeft/Top/Right/Bottom (active area).
    private static func parseSensorInfo(_ values: [UInt16], into tags: inout [String: MakerNoteValue]) {
        if values.count > 1, values[1] > 0 { tags["SensorWidth"]        = .int(Int(values[1])) }
        if values.count > 2, values[2] > 0 { tags["SensorHeight"]       = .int(Int(values[2])) }
        if values.count > 8 {
            tags["SensorLeftBorder"]   = .int(Int(values[5]))
            tags["SensorTopBorder"]    = .int(Int(values[6]))
            tags["SensorRightBorder"]  = .int(Int(values[7]))
            tags["SensorBottomBorder"] = .int(Int(values[8]))
        }
    }
}
