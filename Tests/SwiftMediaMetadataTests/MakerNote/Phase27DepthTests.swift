import XCTest
@testable import SwiftMediaMetadata

/// Phase 27: depth tests for Canon CameraSettings/ShotInfo/AFInfo2/FileInfo/SensorInfo
/// arrays and the expanded Sony 0xB0xx / 0x2xxx blocks.
final class Phase27DepthTests: XCTestCase {

    // MARK: - Canon CameraSettings (tag 0x0001)

    func testCanonCameraSettingsExtractsCommonIndices() {
        // Minimal CameraSettings array. Layout (1-indexed): 1=MacroMode, 3=Quality,
        // 5=ContinuousDrive, 17=MeteringMode, 22=LensType, 23/24/25=focal triplet, 34=IS.
        var values = [UInt16](repeating: 0, count: 36)
        values[1]  = UInt16(bitPattern: Int16(2))   // MacroMode = 2 (Normal)
        values[3]  = UInt16(bitPattern: Int16(4))   // Quality = 4 (Fine)
        values[5]  = UInt16(bitPattern: Int16(2))   // ContinuousDrive
        values[17] = UInt16(bitPattern: Int16(5))   // MeteringMode
        values[22] = 0xFFFF                          // LensType (0xFFFF = unsigned 65535 = "n/a")
        values[23] = 200                             // MaxFocalLength * units
        values[24] = 24                              // MinFocalLength * units
        values[25] = 1                               // FocalUnits
        values[34] = UInt16(bitPattern: Int16(1))   // IS = 1 (On)

        let mn = makeCanonMakerNote(cameraSettings: values, byteOrder: .bigEndian)
        let result = parseCanon(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["MacroMode"], .int(2))
        XCTAssertEqual(result["Quality"], .int(4))
        XCTAssertEqual(result["ContinuousDrive"], .int(2))
        XCTAssertEqual(result["MeteringMode"], .int(5))
        // LensType is the *unsigned* 16-bit Canon ID; 65535 is the "n/a" sentinel.
        XCTAssertEqual(result["LensType"], .int(65535))
        XCTAssertEqual(result["LensTypeName"], .string("n/a"))
        XCTAssertEqual(result["MaxFocalLength"], .double(200.0))
        XCTAssertEqual(result["MinFocalLength"], .double(24.0))
        XCTAssertEqual(result["FocalUnits"], .int(1))
        XCTAssertEqual(result["ImageStabilization"], .int(1))
    }

    func testCanonLensTypeUnsignedRFMarker() {
        // RF lenses report the shared marker 61182 (0xEEFE), which a naive signed read
        // would mangle to -4354. Verify we surface the unsigned ID and its name.
        var values = [UInt16](repeating: 0, count: 28)
        values[22] = 0xEEFE                           // 61182 — Canon RF lens marker
        values[26] = 96                               // MaxAperture EV code -> f/2.8
        values[27] = 288                              // MinAperture EV code -> f/22.6

        let mn = makeCanonMakerNote(cameraSettings: values, byteOrder: .bigEndian)
        let result = parseCanon(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["LensType"], .int(61182))
        XCTAssertEqual(result["LensTypeName"], .string("Canon RF 50mm F1.2L USM or other Canon RF Lens"))
        // Apertures are Canon hex-EV codes: f-number = 2^(CanonEv(code)/2).
        if case .double(let maxAp) = result["MaxAperture"] {
            XCTAssertEqual(maxAp, 2.8284271247, accuracy: 1e-4)
        } else { XCTFail("MaxAperture missing") }
        if case .double(let minAp) = result["MinAperture"] {
            XCTAssertEqual(minAp, 22.627416997, accuracy: 1e-3)
        } else { XCTFail("MinAperture missing") }
    }

    func testCanonCameraISOSentinelAndFlag() {
        // 0x7fff is "n/a" (suppressed); the 0x4000 flag means the low 14 bits are the ISO.
        var naValues = [UInt16](repeating: 0, count: 20)
        naValues[15] = 0x7fff                         // Sharpness n/a — suppressed
        naValues[16] = 0x7fff                         // CameraISO n/a — suppressed
        let naResult = parseCanon(makeCanonMakerNote(cameraSettings: naValues, byteOrder: .bigEndian),
                                  byteOrder: .bigEndian)
        XCTAssertNil(naResult["Sharpness"])
        XCTAssertNil(naResult["CameraISO"])

        var isoValues = [UInt16](repeating: 0, count: 20)
        isoValues[16] = 0x4000 | 1600                 // flagged ISO speed 1600
        let isoResult = parseCanon(makeCanonMakerNote(cameraSettings: isoValues, byteOrder: .bigEndian),
                                   byteOrder: .bigEndian)
        XCTAssertEqual(isoResult["CameraISO"], .int(1600))
    }

    // MARK: - Canon FileInfo (tag 0x0093) — modern shutter count

    func testCanonFileInfoShutterCount() {
        // FileInfo[1] (low) and FileInfo[2] (high) combine to a UInt32 ShutterCount.
        var values = [UInt16](repeating: 0, count: 22)
        let total: UInt32 = 123_456
        values[1] = UInt16(total & 0xFFFF)
        values[2] = UInt16((total >> 16) & 0xFFFF)
        values[3] = UInt16(bitPattern: Int16(2))   // BracketMode
        values[6] = UInt16(bitPattern: Int16(4))   // RawJpgQuality
        values[19] = UInt16(bitPattern: Int16(1))  // LiveViewShooting

        let mn = makeCanonMakerNote(fileInfo: values, byteOrder: .bigEndian)
        let result = parseCanon(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["ShutterCount"], .int(123_456))
        XCTAssertEqual(result["BracketMode"], .int(2))
        XCTAssertEqual(result["RawJpgQuality"], .int(4))
        XCTAssertEqual(result["LiveViewShooting"], .int(1))
    }

    // MARK: - Canon ShotInfo (tag 0x0004) — temperature offset, signed fields

    func testCanonShotInfoTemperatureAndWhiteBalance() {
        var values = [UInt16](repeating: 0, count: 25)
        values[7]  = UInt16(bitPattern: Int16(3))   // WhiteBalance = 3 (Tungsten)
        values[12] = UInt16(bitPattern: Int16(149)) // CameraTemperature stored as C+128 -> 21°C
        values[15] = UInt16(bitPattern: Int16(-32)) // FlashExposureComp -> -1.0 EV (32ths)

        let mn = makeCanonMakerNote(shotInfo: values, byteOrder: .bigEndian)
        let result = parseCanon(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["WhiteBalance"], .int(3))
        XCTAssertEqual(result["CameraTemperature"], .int(21))
        XCTAssertEqual(result["FlashExposureComp"], .double(-1.0))
    }

    // MARK: - Canon AFInfo2 (tag 0x0026)

    func testCanonAFInfo2() {
        // ProcessSerialData layout: index 0 is AFInfoSize, fields start at 1.
        var values = [UInt16](repeating: 0, count: 8)
        values[0] = 16    // AFInfoSize (not surfaced)
        values[1] = 7     // AFAreaMode (= Zone AF)
        values[2] = 9     // NumAFPoints
        values[3] = 1     // ValidAFPoints
        values[4] = 6000  // CanonImageWidth
        values[5] = 4000  // CanonImageHeight
        values[6] = 6720  // AFImageWidth
        values[7] = 4480  // AFImageHeight

        let mn = makeCanonMakerNote(afInfo2: values, byteOrder: .bigEndian)
        let result = parseCanon(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["AFAreaMode"], .int(7))
        XCTAssertEqual(result["NumAFPoints"], .int(9))
        XCTAssertEqual(result["ValidAFPoints"], .int(1))
        XCTAssertEqual(result["CanonImageWidth"], .int(6000))
        XCTAssertEqual(result["CanonImageHeight"], .int(4000))
        XCTAssertEqual(result["AFImageWidth"], .int(6720))
        XCTAssertEqual(result["AFImageHeight"], .int(4480))
    }

    // MARK: - Canon ShotInfo ISO log-encoding + focus distance

    func testCanonShotInfoLogISOAndMeasuredEV() {
        // Raw values from a real EOS R1 frame: AutoISO 0 -> 100, BaseISO 268 -> 1037,
        // MeasuredEV 140 -> 9.375. These are log/offset-encoded in Canon.pm, not raw.
        var values = [UInt16](repeating: 0, count: 22)
        values[1] = 0                                 // AutoISO code -> ISO 100
        values[2] = 268                               // BaseISO code -> ISO 1037
        values[3] = 140                               // MeasuredEV code -> 9.375
        values[19] = 113                              // FocusDistanceUpper (cm) -> 1.13 m
        values[20] = 122                              // FocusDistanceLower (cm) -> 1.22 m

        let mn = makeCanonMakerNote(shotInfo: values, byteOrder: .bigEndian)
        let result = parseCanon(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["AutoISO"], .int(100))
        XCTAssertEqual(result["BaseISO"], .int(1037))
        if case .double(let ev) = result["MeasuredEV"] {
            XCTAssertEqual(ev, 9.375, accuracy: 1e-6)
        } else { XCTFail("MeasuredEV missing") }
        XCTAssertEqual(result["FocusDistanceUpper"], .double(1.13))
        XCTAssertEqual(result["FocusDistanceLower"], .double(1.22))
    }

    func testCanonFileInfoFocusDistanceOverridesShotInfo() {
        // FileInfo (parsed after ShotInfo) is the higher-priority focus-distance source,
        // and on this body it carries the values swapped relative to ShotInfo.
        var shot = [UInt16](repeating: 0, count: 22)
        shot[19] = 113   // ShotInfo Upper 1.13
        shot[20] = 122   // ShotInfo Lower 1.22
        var file = [UInt16](repeating: 0, count: 22)
        file[20] = 122   // FileInfo Upper 1.22  (wins)
        file[21] = 113   // FileInfo Lower 1.13  (wins)

        let mn = makeCanonMakerNote(shotInfo: shot, fileInfo: file, byteOrder: .bigEndian)
        let result = parseCanon(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["FocusDistanceUpper"], .double(1.22))
        XCTAssertEqual(result["FocusDistanceLower"], .double(1.13))
    }

    // MARK: - Canon SensorInfo (tag 0x00E0)

    func testCanonSensorInfo() {
        var values = [UInt16](repeating: 0, count: 12)
        values[1] = 6960  // SensorWidth
        values[2] = 4640  // SensorHeight
        values[5] = 84    // SensorLeftBorder
        values[6] = 52    // SensorTopBorder
        values[7] = 6803  // SensorRightBorder
        values[8] = 4555  // SensorBottomBorder

        let mn = makeCanonMakerNote(sensorInfo: values, byteOrder: .bigEndian)
        let result = parseCanon(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["SensorWidth"], .int(6960))
        XCTAssertEqual(result["SensorHeight"], .int(4640))
        XCTAssertEqual(result["SensorLeftBorder"], .int(84))
        XCTAssertEqual(result["SensorBottomBorder"], .int(4555))
    }

    // MARK: - Canon FileNumber + OwnerName

    func testCanonFileNumberAndOwner() {
        let mn = makeCanonMakerNote(fileNumber: 1_000_023, ownerName: "Press Photographer", byteOrder: .bigEndian)
        let result = parseCanon(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["FileNumber"], .uint(1_000_023))
        XCTAssertEqual(result["FileIndex"], .string("100-0023"))
        XCTAssertEqual(result["OwnerName"], .string("Press Photographer"))
    }

    // MARK: - Sony 0xB0xx scalar block

    func testSonyExposureModeFocusModeAFAreaMode() {
        let mn = makeSonyMakerNote(scalars: [
            0xB041: .uint16(1),   // ExposureMode = Aperture priority
            0xB042: .uint16(2),   // FocusMode
            0xB043: .uint16(0),   // AFAreaMode = Wide
            0xB04E: .uint16(2),   // LongExposureNoiseReduction
            0xB054: .uint16(4),   // WhiteBalance
            0xB025: .uint32(1),   // DynamicRangeOptimizer
        ], byteOrder: .bigEndian)
        let result = parseSony(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["ExposureMode"], .int(1))
        XCTAssertEqual(result["FocusMode"], .int(2))
        XCTAssertEqual(result["AFAreaMode"], .int(0))
        XCTAssertEqual(result["LongExposureNoiseReduction"], .int(2))
        XCTAssertEqual(result["WhiteBalance"], .int(4))
        XCTAssertEqual(result["DynamicRangeOptimizer"], .int(1))
    }

    // MARK: - Sony LensType lookup

    func testSonyLensTypeNameLookup() {
        // 64 = Sony FE 24-70mm F2.8 GM (curated entry).
        let mn = makeSonyMakerNote(scalars: [0xB027: .uint32(64)], byteOrder: .bigEndian)
        let result = parseSony(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["LensType"], .int(64))
        XCTAssertEqual(result["LensTypeName"], .string("Sony FE 24-70mm F2.8 GM"))
    }

    func testSonyUnknownLensTypeOmitsName() {
        let mn = makeSonyMakerNote(scalars: [0xB027: .uint32(0xCAFE)], byteOrder: .bigEndian)
        let result = parseSony(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["LensType"], .int(0xCAFE))
        XCTAssertNil(result["LensTypeName"])
    }

    // MARK: - Sony Scene mode (renamed from CameraTemperature)

    func testSonySceneMode() {
        let mn = makeSonyMakerNote(scalars: [0xB023: .uint32(7)], byteOrder: .bigEndian)
        let result = parseSony(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["SceneMode"], .int(7))
        // Old wrong name must not appear.
        XCTAssertNil(result["CameraTemperature"])
    }

    // MARK: - Sony WBShiftAB_GM (tag 0x2014)

    func testSonyWBShiftABGM() {
        // ExifTool's Sony.pm Main table defines 0x2014 as WBShiftAB_GM (a 2-element
        // amber-blue / green-magenta shift), not WB_RGBLevels. Only the first two
        // elements are kept.
        let values: [UInt16] = [3500, 1024, 2200]
        let mn = makeSonyMakerNote(uint16Arrays: [0x2014: values], byteOrder: .bigEndian)
        let result = parseSony(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["WBShiftAB_GM"], .intArray([3500, 1024]))
        XCTAssertNil(result["WB_RGBLevels"], "old mislabel must not appear")
    }

    // MARK: - Sony FullImageSize (tag 0xB02B) — height/width pair

    func testSonyFullImageSize() {
        // ExifTool surfaces FullImageSize as "<width>x<height>" but the array stores [height, width].
        let mn = makeSonyMakerNote(uint16Arrays: [0xB02B: [4024, 6024]], byteOrder: .bigEndian)
        let result = parseSony(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["FullImageSize"], .string("6024x4024"))
    }

    // MARK: - Helpers

    private enum SonyScalar {
        case uint16(UInt16)
        case uint32(UInt32)
    }

    private func parseCanon(_ data: Data, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        let entry = IFDEntry(tag: ExifTag.makerNote, type: .undefined, count: UInt32(data.count), valueData: data)
        let ifd = IFD(entries: [entry], nextIFDOffset: 0)
        return MakerNoteReader.parse(from: ifd, make: "Canon", byteOrder: byteOrder)?.tags ?? [:]
    }

    private func parseSony(_ data: Data, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        let entry = IFDEntry(tag: ExifTag.makerNote, type: .undefined, count: UInt32(data.count), valueData: data)
        let ifd = IFD(entries: [entry], nextIFDOffset: 0)
        return MakerNoteReader.parse(from: ifd, make: "Sony", byteOrder: byteOrder)?.tags ?? [:]
    }

    /// Build a Canon MakerNote with arbitrary array tags. Each array tag is encoded as
    /// .short with one UInt16 per element. Includes a serial number so the parser doesn't
    /// reject the empty-tag case.
    private func makeCanonMakerNote(
        cameraSettings: [UInt16]? = nil,
        shotInfo: [UInt16]? = nil,
        afInfo2: [UInt16]? = nil,
        fileInfo: [UInt16]? = nil,
        sensorInfo: [UInt16]? = nil,
        fileNumber: UInt32? = nil,
        ownerName: String? = nil,
        byteOrder: ByteOrder = .bigEndian
    ) -> Data {
        var entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)] = []
        // SerialNumber so the parser always emits at least one tag.
        let snBytes = Data("SN-1\0".utf8)
        entries.append((0x0006, .ascii, UInt32(snBytes.count), snBytes))

        func encodeUInt16Array(_ values: [UInt16]) -> Data {
            var w = BinaryWriter(capacity: values.count * 2)
            for v in values { w.writeUInt16(v, endian: byteOrder) }
            return w.data
        }

        if let v = cameraSettings { entries.append((0x0001, .short, UInt32(v.count), encodeUInt16Array(v))) }
        if let v = shotInfo       { entries.append((0x0004, .short, UInt32(v.count), encodeUInt16Array(v))) }
        if let v = afInfo2        { entries.append((0x0026, .short, UInt32(v.count), encodeUInt16Array(v))) }
        if let v = fileInfo       { entries.append((0x0093, .short, UInt32(v.count), encodeUInt16Array(v))) }
        if let v = sensorInfo     { entries.append((0x00E0, .short, UInt32(v.count), encodeUInt16Array(v))) }

        if let n = fileNumber {
            var w = BinaryWriter(capacity: 4)
            w.writeUInt32(n, endian: byteOrder)
            entries.append((0x0008, .long, 1, w.data))
        }
        if let owner = ownerName {
            let bytes = Data(owner.utf8) + Data([0x00])
            entries.append((0x0009, .ascii, UInt32(bytes.count), bytes))
        }

        entries.sort { $0.tag < $1.tag }
        return buildMiniIFD(entries: entries, byteOrder: byteOrder, offsetBase: 0)
    }

    private func makeSonyMakerNote(
        scalars: [UInt16: SonyScalar] = [:],
        uint16Arrays: [UInt16: [UInt16]] = [:],
        byteOrder: ByteOrder = .bigEndian
    ) -> Data {
        var entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)] = []
        // SerialNumber so the parser always returns a non-nil result.
        let snBytes = Data("SONY-SN\0".utf8)
        entries.append((0xB020, .ascii, UInt32(snBytes.count), snBytes))

        for (tag, scalar) in scalars {
            switch scalar {
            case .uint16(let value):
                var w = BinaryWriter(capacity: 2)
                w.writeUInt16(value, endian: byteOrder)
                entries.append((tag, .short, 1, w.data))
            case .uint32(let value):
                var w = BinaryWriter(capacity: 4)
                w.writeUInt32(value, endian: byteOrder)
                entries.append((tag, .long, 1, w.data))
            }
        }

        for (tag, values) in uint16Arrays {
            var w = BinaryWriter(capacity: values.count * 2)
            for v in values { w.writeUInt16(v, endian: byteOrder) }
            entries.append((tag, .short, UInt32(values.count), w.data))
        }

        entries.sort { $0.tag < $1.tag }
        return buildMiniIFD(entries: entries, byteOrder: byteOrder, offsetBase: 0)
    }

    /// Mirror of the helper in MakerNoteReaderTests — we want this file to be self-contained
    /// so re-orderings or refactors of that file don't ripple here.
    private func buildMiniIFD(
        entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)],
        byteOrder: ByteOrder,
        offsetBase: Int
    ) -> Data {
        var writer = BinaryWriter(capacity: 256)
        writer.writeUInt16(UInt16(entries.count), endian: byteOrder)

        let directorySize = 2 + entries.count * 12 + 4
        var externalOffset = offsetBase + directorySize
        var externalData = Data()

        for entry in entries {
            writer.writeUInt16(entry.tag, endian: byteOrder)
            writer.writeUInt16(entry.type.rawValue, endian: byteOrder)
            writer.writeUInt32(entry.count, endian: byteOrder)

            let totalSize = Int(entry.count) * entry.type.unitSize
            if totalSize <= 4 {
                var padded = entry.data
                while padded.count < 4 { padded.append(0x00) }
                writer.writeBytes(padded.prefix(4))
            } else {
                writer.writeUInt32(UInt32(externalOffset), endian: byteOrder)
                externalData.append(entry.data)
                if entry.data.count % 2 != 0 { externalData.append(0x00) }
                externalOffset += entry.data.count
                if entry.data.count % 2 != 0 { externalOffset += 1 }
            }
        }

        writer.writeUInt32(0, endian: byteOrder) // next IFD offset
        writer.writeBytes(externalData)
        return writer.data
    }
}
