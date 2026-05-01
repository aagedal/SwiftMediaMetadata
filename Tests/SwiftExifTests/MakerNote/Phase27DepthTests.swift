import XCTest
@testable import SwiftExif

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
        values[22] = UInt16(bitPattern: Int16(-1))   // LensType (sentinel: unknown lens)
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
        XCTAssertEqual(result["LensType"], .int(-1))
        XCTAssertEqual(result["MaxFocalLength"], .double(200.0))
        XCTAssertEqual(result["MinFocalLength"], .double(24.0))
        XCTAssertEqual(result["FocalUnits"], .int(1))
        XCTAssertEqual(result["ImageStabilization"], .int(1))
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
        var values = [UInt16](repeating: 0, count: 8)
        values[2] = 1     // AFAreaMode
        values[3] = 9     // NumAFPoints
        values[4] = 1     // ValidAFPoints
        values[5] = 6720  // AFImageWidth
        values[6] = 4480  // AFImageHeight

        let mn = makeCanonMakerNote(afInfo2: values, byteOrder: .bigEndian)
        let result = parseCanon(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["AFAreaMode"], .int(1))
        XCTAssertEqual(result["NumAFPoints"], .int(9))
        XCTAssertEqual(result["AFImageWidth"], .int(6720))
        XCTAssertEqual(result["AFImageHeight"], .int(4480))
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
        XCTAssertEqual(result["DynamicRangeOptimizer"], .uint(1))
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

    // MARK: - Sony WB_RGBLevels (tag 0x2014)

    func testSonyWBRGBLevels() {
        let values: [UInt16] = [3500, 1024, 2200]
        let mn = makeSonyMakerNote(uint16Arrays: [0x2014: values], byteOrder: .bigEndian)
        let result = parseSony(mn, byteOrder: .bigEndian)

        XCTAssertEqual(result["WB_RGBLevels"], .intArray([3500, 1024, 2200]))
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
