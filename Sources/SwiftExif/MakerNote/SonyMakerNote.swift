import Foundation

/// Parser for Sony MakerNote data.
/// Sony MakerNotes may have a "SONY DSC \0\0\0" or "SONY CAM \0\0\0" prefix (12 bytes)
/// followed by a standard IFD, or start directly with an IFD.
///
/// Tag IDs match ExifTool's `Sony.pm`. The 0xB0xx range is the modern Alpha / RX / FX
/// block; the 0x10xx range is the older Cyber-shot / multi-burst block; 0x2xxx is shared
/// shooting-settings block used across most modern bodies.
struct SonyMakerNote: Sendable {

    // 0x01xx — older Cyber-shot / Minolta-derived
    private static let quality:                UInt16 = 0x0102
    private static let flashExposureComp:      UInt16 = 0x0104
    private static let teleconverter:          UInt16 = 0x0105
    private static let whiteBalanceFineTune:   UInt16 = 0x0112
    private static let multiBurstMode:         UInt16 = 0x1000
    private static let multiBurstImageWidth:   UInt16 = 0x1001
    private static let multiBurstImageHeight:  UInt16 = 0x1002
    private static let panorama:               UInt16 = 0x1003

    // 0x2xxx — modern shooting-settings block
    private static let sonyImageSize:               UInt16 = 0x2002
    private static let imageStabilization:          UInt16 = 0x2003
    private static let highISONoiseReduction:       UInt16 = 0x2009
    private static let multiFrameNoiseReduction:    UInt16 = 0x200B
    private static let pictureEffect:               UInt16 = 0x200C
    private static let softSkinEffect:              UInt16 = 0x200D
    private static let wbRGBLevels:                 UInt16 = 0x2014

    // 0xB0xx — Alpha / RX / FX top-level block
    // 0xB020 is an ASCII string holding the creative-style / color-reproduction
    // preset ("Standard", "Vivid", "AdobeRGB", …) per ExifTool's Sony.pm. It is
    // NOT a serial number — the body serial lives in ExifIFD tag 0xA431.
    private static let creativeStyle:          UInt16 = 0xB020
    private static let sceneMode:              UInt16 = 0xB023
    private static let zoneMatching:           UInt16 = 0xB024
    private static let dynamicRangeOptimizer:  UInt16 = 0xB025
    private static let imageStabilizationOld:  UInt16 = 0xB026
    private static let lensType:               UInt16 = 0xB027
    private static let colorMode:              UInt16 = 0xB029
    private static let fullImageSize:          UInt16 = 0xB02B
    private static let previewImageSize:       UInt16 = 0xB02C
    private static let macro:                  UInt16 = 0xB040
    private static let exposureMode:           UInt16 = 0xB041
    private static let focusMode:              UInt16 = 0xB042
    private static let afAreaMode:             UInt16 = 0xB043
    private static let afIlluminator:          UInt16 = 0xB044
    private static let quality16:              UInt16 = 0xB047
    private static let flashLevel:             UInt16 = 0xB048
    private static let releaseMode:            UInt16 = 0xB049
    private static let antiBlur:               UInt16 = 0xB04B
    private static let longExposureNR:         UInt16 = 0xB04E
    private static let dynamicRangeOptimizer2: UInt16 = 0xB04F
    private static let intelligentAuto:        UInt16 = 0xB052
    private static let whiteBalance:           UInt16 = 0xB054

    private static let sonyDSCPrefix = Data("SONY DSC \0\0\0".utf8)
    private static let sonyCAMPrefix = Data("SONY CAM \0\0\0".utf8)

    /// Parse a Sony MakerNote.
    /// - Parameters:
    ///   - data: the verbatim MakerNote value bytes (the 0x927C entry value).
    ///   - byteOrder: the parent TIFF byte order.
    ///   - makerNoteTIFFOffset: the TIFF-relative offset at which `data` begins in
    ///     the originating file (i.e. the MakerNote entry's value offset). Modern
    ///     Sony ("Sony5") MakerNotes store out-of-line value pointers as offsets
    ///     from the TIFF header, not from the start of the MakerNote block. Passing
    ///     the block's own TIFF-relative offset lets us rebase those pointers back
    ///     into `data`. Defaults to 0 for callers that hand us a self-contained,
    ///     block-relative MakerNote.
    static func parse(data: Data, byteOrder: ByteOrder, makerNoteTIFFOffset: Int = 0) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]

        // Detect prefix and determine IFD start
        let ifdStart: Int
        if data.count > 12 && (data.prefix(9) == Data("SONY DSC ".utf8) || data.prefix(9) == Data("SONY CAM ".utf8)) {
            ifdStart = 12
        } else {
            ifdStart = 0
        }

        guard ifdStart < data.count else { return tags }

        // Resolve the offset base. Out-of-line value pointers are either
        // block-relative (some older notes, and our synthetic test fixtures) or
        // TIFF-absolute (modern Sony5 bodies). For the absolute case, the correct
        // index into `data` is `pointer - makerNoteTIFFOffset`, which we model by
        // parsing with a negative `tiffStart`. We pick whichever base keeps every
        // out-of-line value in bounds, preferring block-relative.
        let tiffStart = resolveOffsetBase(
            data: data, ifdStart: ifdStart, endian: byteOrder,
            makerNoteTIFFOffset: makerNoteTIFFOffset
        )

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: tiffStart, offset: ifdStart, endian: byteOrder
        ) else { return tags }

        // ---- Creative style ------------------------------------------------------------
        if let entry = ifd.entry(for: creativeStyle),
           let value = entry.stringValue(endian: byteOrder) {
            let trimmed = value.trimmingCharacters(
                in: CharacterSet(charactersIn: "\0").union(.whitespaces)
            )
            if !trimmed.isEmpty { tags["CreativeStyle"] = .string(trimmed) }
        }

        // ---- Lens info -----------------------------------------------------------------
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

        // ---- 0x01xx range --------------------------------------------------------------
        readUInt16(ifd, quality, byteOrder: byteOrder, into: &tags, as: "Quality")
        if let entry = ifd.entry(for: flashExposureComp), entry.type == .srational,
           let (num, den) = entry.srationalValue(endian: byteOrder), den != 0 {
            tags["FlashExposureComp"] = .double(Double(num) / Double(den))
        }
        readUInt16(ifd, teleconverter, byteOrder: byteOrder, into: &tags, as: "Teleconverter")
        if let entry = ifd.entry(for: whiteBalanceFineTune), entry.type == .srational,
           let (num, den) = entry.srationalValue(endian: byteOrder), den != 0 {
            tags["WhiteBalanceFineTune"] = .double(Double(num) / Double(den))
        }
        readUInt16(ifd, multiBurstMode, byteOrder: byteOrder, into: &tags, as: "MultiBurstMode")
        readUInt16(ifd, multiBurstImageWidth, byteOrder: byteOrder, into: &tags, as: "MultiBurstImageWidth")
        readUInt16(ifd, multiBurstImageHeight, byteOrder: byteOrder, into: &tags, as: "MultiBurstImageHeight")
        readUInt16(ifd, panorama, byteOrder: byteOrder, into: &tags, as: "Panorama")

        // ---- 0x2xxx range --------------------------------------------------------------
        readUInt32(ifd, sonyImageSize, byteOrder: byteOrder, into: &tags, as: "SonyImageSize")
        readUInt32(ifd, imageStabilization, byteOrder: byteOrder, into: &tags, as: "ImageStabilization")
        readUInt32(ifd, highISONoiseReduction, byteOrder: byteOrder, into: &tags, as: "HighISONoiseReduction")
        readUInt32(ifd, multiFrameNoiseReduction, byteOrder: byteOrder, into: &tags, as: "MultiFrameNoiseReduction")
        readUInt32(ifd, pictureEffect, byteOrder: byteOrder, into: &tags, as: "PictureEffect")
        readUInt32(ifd, softSkinEffect, byteOrder: byteOrder, into: &tags, as: "SoftSkinEffect")
        if let entry = ifd.entry(for: wbRGBLevels), entry.type == .short {
            let v = entry.uint16Values(endian: byteOrder)
            if v.count >= 3 {
                tags["WB_RGBLevels"] = .intArray([Int(v[0]), Int(v[1]), Int(v[2])])
            }
        }

        // ---- 0xB0xx range --------------------------------------------------------------
        // SceneMode is documented as UInt32 on modern bodies; older Cyber-shots returned UInt16
        // as a different field, so accept either width.
        if let entry = ifd.entry(for: sceneMode) {
            if let v = entry.uint32Value(endian: byteOrder) {
                tags["SceneMode"] = .int(Int(v))
            } else if let v = entry.uint16Value(endian: byteOrder) {
                tags["SceneMode"] = .int(Int(v))
            }
        }
        readUInt32(ifd, zoneMatching, byteOrder: byteOrder, into: &tags, as: "ZoneMatching")
        readUInt32(ifd, dynamicRangeOptimizer, byteOrder: byteOrder, into: &tags, as: "DynamicRangeOptimizer")
        readUInt16(ifd, imageStabilizationOld, byteOrder: byteOrder, into: &tags, as: "ImageStabilizationOld")
        readUInt32(ifd, colorMode, byteOrder: byteOrder, into: &tags, as: "ColorMode")
        if let entry = ifd.entry(for: fullImageSize), entry.type == .short {
            let v = entry.uint16Values(endian: byteOrder)
            if v.count >= 2 { tags["FullImageSize"] = .string("\(v[1])x\(v[0])") }
        }
        if let entry = ifd.entry(for: previewImageSize), entry.type == .short {
            let v = entry.uint16Values(endian: byteOrder)
            if v.count >= 2 { tags["PreviewImageSize"] = .string("\(v[1])x\(v[0])") }
        }
        readUInt16(ifd, macro, byteOrder: byteOrder, into: &tags, as: "Macro")
        readUInt16(ifd, exposureMode, byteOrder: byteOrder, into: &tags, as: "ExposureMode")
        readUInt16(ifd, focusMode, byteOrder: byteOrder, into: &tags, as: "FocusMode")
        readUInt16(ifd, afAreaMode, byteOrder: byteOrder, into: &tags, as: "AFAreaMode")
        readUInt16(ifd, afIlluminator, byteOrder: byteOrder, into: &tags, as: "AFIlluminator")
        readUInt16(ifd, quality16, byteOrder: byteOrder, into: &tags, as: "Quality")
        if let entry = ifd.entry(for: flashLevel),
           let value = entry.uint16Value(endian: byteOrder) {
            // Stored as Int16 (negative = subtract); store the signed view.
            tags["FlashLevel"] = .int(Int(Int16(bitPattern: value)))
        }
        readUInt16(ifd, releaseMode, byteOrder: byteOrder, into: &tags, as: "ReleaseMode")
        readUInt16(ifd, antiBlur, byteOrder: byteOrder, into: &tags, as: "AntiBlur")
        readUInt16(ifd, longExposureNR, byteOrder: byteOrder, into: &tags, as: "LongExposureNoiseReduction")
        readUInt16(ifd, dynamicRangeOptimizer2, byteOrder: byteOrder, into: &tags, as: "DynamicRangeOptimizerSetting")
        readUInt16(ifd, intelligentAuto, byteOrder: byteOrder, into: &tags, as: "IntelligentAuto")
        readUInt16(ifd, whiteBalance, byteOrder: byteOrder, into: &tags, as: "WhiteBalance")

        return tags
    }

    // MARK: - Helpers

    /// Determine the `tiffStart` to feed `IFDParser` so that out-of-line value
    /// pointers land inside `data`. Returns 0 for block-relative pointers, or
    /// `-makerNoteTIFFOffset` for TIFF-absolute pointers (Sony5). Walks the IFD
    /// header (always readable inline) and checks which base keeps every
    /// out-of-line value within bounds, preferring block-relative on a tie.
    private static func resolveOffsetBase(
        data: Data, ifdStart: Int, endian: ByteOrder, makerNoteTIFFOffset: Int
    ) -> Int {
        // Without a base offset, the two interpretations coincide.
        guard makerNoteTIFFOffset > 0 else { return 0 }

        var reader = BinaryReader(data: data)
        guard (try? reader.seek(to: ifdStart)) != nil,
              let count = try? reader.readUInt16(endian: endian) else { return 0 }

        let blobLen = data.count
        var blockRelativeOK = true
        var absoluteOK = true
        var sawOutOfLine = false

        for _ in 0..<count {
            guard let _ = try? reader.readUInt16(endian: endian),          // tag
                  let typeRaw = try? reader.readUInt16(endian: endian),
                  let valueCount = try? reader.readUInt32(endian: endian),
                  let valueOrOffset = try? reader.readBytes(4) else { return 0 }

            guard let type = TIFFDataType(rawValue: typeRaw) else { continue }
            let totalSize = Int(valueCount) * type.unitSize
            guard totalSize > 4 else { continue }   // inline — base-independent

            sawOutOfLine = true
            var offsetReader = BinaryReader(data: valueOrOffset)
            guard let pointer = try? offsetReader.readUInt32(endian: endian) else { return 0 }
            let ptr = Int(pointer)

            if ptr < 0 || ptr + totalSize > blobLen { blockRelativeOK = false }
            let absIdx = ptr - makerNoteTIFFOffset
            if absIdx < 0 || absIdx + totalSize > blobLen { absoluteOK = false }
        }

        if !sawOutOfLine { return 0 }
        if blockRelativeOK { return 0 }
        if absoluteOK { return -makerNoteTIFFOffset }
        return 0
    }

    private static func readUInt16(_ ifd: IFD, _ tag: UInt16, byteOrder: ByteOrder,
                                   into tags: inout [String: MakerNoteValue], as name: String) {
        guard let entry = ifd.entry(for: tag),
              let value = entry.uint16Value(endian: byteOrder) else { return }
        tags[name] = .int(Int(value))
    }

    private static func readUInt32(_ ifd: IFD, _ tag: UInt16, byteOrder: ByteOrder,
                                   into tags: inout [String: MakerNoteValue], as name: String) {
        guard let entry = ifd.entry(for: tag),
              let value = entry.uint32Value(endian: byteOrder) else { return }
        tags[name] = .uint(UInt(value))
    }

    /// Human-readable names for common Sony LensType IDs. Curated from ExifTool's table —
    /// not exhaustive, focused on FE-mount lenses commonly used by Scandinavian press
    /// photographers plus a handful of A-mount staples. Add IDs as they show up in real files.
    static let sonyLensTypeNames: [UInt16: String] = [
        0:    "Minolta AF 28-85mm F3.5-4.5",
        1:    "Minolta AF 80-200mm F2.8 HS-APO G",
        2:    "Minolta AF 28-70mm F2.8 G",
        16:   "Sony 70-200mm F2.8 G SSM",
        18:   "Sony DT 18-250mm F3.5-6.3",
        25:   "Sony DT 18-200mm F3.5-6.3",
        27:   "Sony 70-400mm F4-5.6 G SSM",
        32:   "Sony 500mm F4 G SSM",
        33:   "Sony FE 24-70mm F4 ZA OSS",
        49:   "Sony FE 55mm F1.8 ZA",
        50:   "Sony FE 28-70mm F3.5-5.6 OSS",
        51:   "Sony FE 35mm F2.8 ZA",
        53:   "Sony FE 24-240mm F3.5-6.3 OSS",
        54:   "Sony FE 70-200mm F4 G OSS",
        56:   "Sony FE 16-35mm F4 ZA OSS",
        57:   "Sony FE 90mm F2.8 Macro G OSS",
        58:   "Sony FE 28mm F2",
        59:   "Sony FE 28-135mm F4 G OSS",
        61:   "Sony LA-EA1/3 Adapter",
        62:   "Sony LA-EA2/4 Adapter",
        63:   "Sony FE 35mm F1.4 ZA",
        64:   "Sony FE 24-70mm F2.8 GM",
        65:   "Sony FE 70-200mm F2.8 GM OSS",
        66:   "Sony FE 85mm F1.4 GM",
        67:   "Sony FE 50mm F1.8",
        68:   "Sony FE 50mm F2.8 Macro",
        69:   "Sony FE 100mm F2.8 STF GM OSS",
        70:   "Sony FE 100-400mm F4.5-5.6 GM OSS",
        71:   "Sony FE 16-35mm F2.8 GM",
        72:   "Sony FE 12-24mm F4 G",
        73:   "Sony FE 400mm F2.8 GM OSS",
        74:   "Sony FE 24mm F1.4 GM",
        75:   "Sony FE 135mm F1.8 GM",
        76:   "Sony FE 200-600mm F5.6-6.3 G OSS",
        77:   "Sony FE 600mm F4 GM OSS",
        78:   "Sony FE 35mm F1.8",
        79:   "Sony FE 20mm F1.8 G",
        80:   "Sony FE 12-24mm F2.8 GM",
        81:   "Sony FE 50mm F1.2 GM",
        82:   "Sony FE 14mm F1.8 GM",
        83:   "Sony FE 24-70mm F2.8 GM II",
        84:   "Sony FE 70-200mm F2.8 GM OSS II",
    ]
}
