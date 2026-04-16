import XCTest
@testable import SwiftExif

final class MakerNoteReaderTests: XCTestCase {

    // MARK: - Canon MakerNote

    func testCanonSerialNumber() {
        let makerNoteData = buildCanonMakerNote(serialNumber: "123456789", byteOrder: .bigEndian)
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "Canon", byteOrder: .bigEndian)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.manufacturer, .canon)
        if case .string(let serial) = result?.tags["SerialNumber"] {
            XCTAssertEqual(serial, "123456789")
        } else {
            XCTFail("SerialNumber not found")
        }
    }

    func testCanonFirmwareVersion() {
        let makerNoteData = buildCanonMakerNote(serialNumber: "SN1", firmwareVersion: "Firmware 1.2.3", byteOrder: .bigEndian)
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "Canon", byteOrder: .bigEndian)

        if case .string(let fw) = result?.tags["FirmwareVersion"] {
            XCTAssertEqual(fw, "Firmware 1.2.3")
        } else {
            XCTFail("FirmwareVersion not found")
        }
    }

    // MARK: - Nikon MakerNote

    func testNikonSerialNumber() {
        let makerNoteData = buildNikonMakerNote(serialNumber: "D850-98765")
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "NIKON CORPORATION", byteOrder: .bigEndian)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.manufacturer, .nikon)
        if case .string(let serial) = result?.tags["SerialNumber"] {
            XCTAssertEqual(serial, "D850-98765")
        } else {
            XCTFail("SerialNumber not found")
        }
    }

    func testNikonShutterCount() {
        let makerNoteData = buildNikonMakerNote(serialNumber: "SN", shutterCount: 42000)
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "Nikon", byteOrder: .bigEndian)

        if case .int(let count) = result?.tags["ShutterCount"] {
            XCTAssertEqual(count, 42000)
        } else {
            XCTFail("ShutterCount not found")
        }
    }

    // MARK: - Sony MakerNote

    func testSonySerialNumber() {
        let makerNoteData = buildSonyMakerNote(serialNumber: "A7R-12345")
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "SONY", byteOrder: .bigEndian)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.manufacturer, .sony)
        if case .string(let serial) = result?.tags["SerialNumber"] {
            XCTAssertEqual(serial, "A7R-12345")
        } else {
            XCTFail("SerialNumber not found")
        }
    }

    func testSonyWithPrefix() {
        let makerNoteData = buildSonyMakerNote(serialNumber: "SN999", withPrefix: true)
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "Sony", byteOrder: .bigEndian)

        XCTAssertNotNil(result)
        if case .string(let serial) = result?.tags["SerialNumber"] {
            XCTAssertEqual(serial, "SN999")
        } else {
            XCTFail("SerialNumber not found with prefix")
        }
    }

    // MARK: - Unknown / Invalid

    func testUnknownManufacturerReturnsNil() {
        let data = Data(repeating: 0xAA, count: 100)
        let ifd = buildExifIFDWithMakerNote(data, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "Pentax", byteOrder: .bigEndian)
        XCTAssertNil(result)
    }

    func testNilMakeReturnsNil() {
        let data = Data(repeating: 0xAA, count: 100)
        let ifd = buildExifIFDWithMakerNote(data, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: nil, byteOrder: .bigEndian)
        XCTAssertNil(result)
    }

    func testMissingMakerNoteTagReturnsNil() {
        let ifd = IFD(entries: [], nextIFDOffset: 0)
        let result = MakerNoteReader.parse(from: ifd, make: "Canon", byteOrder: .bigEndian)
        XCTAssertNil(result)
    }

    func testCorruptedDataReturnsNil() {
        let data = Data(repeating: 0xFF, count: 20)
        let ifd = buildExifIFDWithMakerNote(data, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "Canon", byteOrder: .bigEndian)
        XCTAssertNil(result)
    }

    func testTooShortDataReturnsNil() {
        let data = Data([0x00, 0x01])
        let ifd = buildExifIFDWithMakerNote(data, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "Canon", byteOrder: .bigEndian)
        XCTAssertNil(result)
    }

    // MARK: - Fujifilm MakerNote

    func testFujifilmSerialNumber() {
        let makerNoteData = buildFujifilmMakerNote(serialNumber: "FX-99887766")
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "FUJIFILM", byteOrder: .bigEndian)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.manufacturer, .fujifilm)
        if case .string(let serial) = result?.tags["SerialNumber"] {
            XCTAssertEqual(serial, "FX-99887766")
        } else {
            XCTFail("SerialNumber not found")
        }
    }

    func testFujifilmAlwaysLittleEndian() {
        // Even with big-endian parent, Fujifilm uses little-endian
        let makerNoteData = buildFujifilmMakerNote(serialNumber: "LE-TEST")
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "Fujifilm", byteOrder: .bigEndian)

        XCTAssertNotNil(result)
        if case .string(let serial) = result?.tags["SerialNumber"] {
            XCTAssertEqual(serial, "LE-TEST")
        } else {
            XCTFail("SerialNumber not found")
        }
    }

    // MARK: - Olympus MakerNote

    func testOlympusOldFormat() {
        let makerNoteData = buildOlympusMakerNote(cameraID: "E-M1 Mark III", useNewFormat: false)
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "OLYMPUS CORPORATION", byteOrder: .bigEndian)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.manufacturer, .olympus)
        if case .string(let id) = result?.tags["CameraID"] {
            XCTAssertEqual(id, "E-M1 Mark III")
        } else {
            XCTFail("CameraID not found")
        }
    }

    func testOlympusNewFormat() {
        let makerNoteData = buildOlympusMakerNote(cameraID: "OM-1", useNewFormat: true)
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "OM Digital Solutions", byteOrder: .bigEndian)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.manufacturer, .olympus)
    }

    // MARK: - Panasonic MakerNote

    func testPanasonicSerialNumber() {
        let makerNoteData = buildPanasonicMakerNote(serialNumber: "GH6-ABC123")
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "Panasonic", byteOrder: .bigEndian)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.manufacturer, .panasonic)
        if case .string(let serial) = result?.tags["InternalSerialNumber"] {
            XCTAssertEqual(serial, "GH6-ABC123")
        } else {
            XCTFail("InternalSerialNumber not found")
        }
    }

    func testPanasonicLensType() {
        let makerNoteData = buildPanasonicMakerNote(serialNumber: "SN1", lensType: "LUMIX G 25/F1.7")
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "Panasonic", byteOrder: .bigEndian)

        if case .string(let lt) = result?.tags["LensType"] {
            XCTAssertEqual(lt, "LUMIX G 25/F1.7")
        } else {
            XCTFail("LensType not found")
        }
    }

    // MARK: - DJI MakerNote

    func testDJIMake() {
        let makerNoteData = buildDJIMakerNote(make: "DJI", byteOrder: .littleEndian)
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .littleEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "DJI", byteOrder: .littleEndian)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.manufacturer, .dji)
        if case .string(let m) = result?.tags["Make"] {
            XCTAssertEqual(m, "DJI")
        } else {
            XCTFail("Make not found")
        }
    }

    func testDJISpeedAndOrientation() {
        let makerNoteData = buildDJIMakerNote(
            make: "DJI", speedX: 1.5, yaw: -45.3, cameraRoll: 0.12,
            byteOrder: .littleEndian
        )
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .littleEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "DJI", byteOrder: .littleEndian)

        XCTAssertNotNil(result)
        if case .double(let sx) = result?.tags["SpeedX"] {
            XCTAssertEqual(sx, Double(Float(1.5)), accuracy: 0.001)
        } else {
            XCTFail("SpeedX not found")
        }
        if case .double(let y) = result?.tags["Yaw"] {
            XCTAssertEqual(y, Double(Float(-45.3)), accuracy: 0.01)
        } else {
            XCTFail("Yaw not found")
        }
        if case .double(let cr) = result?.tags["CameraRoll"] {
            XCTAssertEqual(cr, Double(Float(0.12)), accuracy: 0.001)
        } else {
            XCTFail("CameraRoll not found")
        }
    }

    // MARK: - Samsung MakerNote

    func testSamsungDeviceType() {
        let makerNoteData = buildSamsungMakerNote(deviceType: 0x3000, byteOrder: .bigEndian)
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "SAMSUNG", byteOrder: .bigEndian)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.manufacturer, .samsung)
        if case .uint(let dt) = result?.tags["DeviceType"] {
            XCTAssertEqual(dt, 0x3000) // phone
        } else {
            XCTFail("DeviceType not found")
        }
    }

    func testSamsungFirmwareName() {
        let makerNoteData = buildSamsungMakerNote(
            deviceType: 0x3000, firmwareName: "S24Ultra_v3.1", byteOrder: .bigEndian
        )
        let ifd = buildExifIFDWithMakerNote(makerNoteData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "Samsung", byteOrder: .bigEndian)

        if case .string(let fw) = result?.tags["FirmwareName"] {
            XCTAssertEqual(fw, "S24Ultra_v3.1")
        } else {
            XCTFail("FirmwareName not found")
        }
    }

    // MARK: - Round-trip Preservation

    func testMakerNoteRawDataPreserved() {
        let originalData = buildCanonMakerNote(serialNumber: "RoundTrip123", byteOrder: .bigEndian)
        let ifd = buildExifIFDWithMakerNote(originalData, byteOrder: .bigEndian)
        let result = MakerNoteReader.parse(from: ifd, make: "Canon", byteOrder: .bigEndian)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.rawData, originalData)
    }

    // MARK: - Helpers

    private func buildExifIFDWithMakerNote(_ data: Data, byteOrder: ByteOrder) -> IFD {
        let entry = IFDEntry(tag: ExifTag.makerNote, type: .undefined, count: UInt32(data.count), valueData: data)
        return IFD(entries: [entry], nextIFDOffset: 0)
    }

    /// Build a Canon-style MakerNote: IFD starting immediately, big-endian.
    private func buildCanonMakerNote(serialNumber: String, firmwareVersion: String? = nil, byteOrder: ByteOrder = .bigEndian) -> Data {
        var entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)] = []

        // Serial number (tag 0x0006)
        let snBytes = Data(serialNumber.utf8) + Data([0x00])
        entries.append((0x0006, .ascii, UInt32(snBytes.count), snBytes))

        // Firmware version (tag 0x0007)
        if let fw = firmwareVersion {
            let fwBytes = Data(fw.utf8) + Data([0x00])
            entries.append((0x0007, .ascii, UInt32(fwBytes.count), fwBytes))
        }

        entries.sort { $0.tag < $1.tag }
        return buildMiniIFD(entries: entries, byteOrder: byteOrder)
    }

    /// Build a Nikon Type 3 MakerNote: "Nikon\0" + version + embedded TIFF + IFD.
    private func buildNikonMakerNote(serialNumber: String, shutterCount: UInt32? = nil) -> Data {
        var entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)] = []

        // Serial number (tag 0x001D)
        let snBytes = Data(serialNumber.utf8) + Data([0x00])
        entries.append((0x001D, .ascii, UInt32(snBytes.count), snBytes))

        // Shutter count (tag 0x00A7) — UInt32 (stored as .long)
        if let sc = shutterCount {
            var scWriter = BinaryWriter(capacity: 4)
            scWriter.writeUInt32(sc, endian: .bigEndian)
            entries.append((0x00A7, .long, 1, scWriter.data))
        }

        entries.sort { $0.tag < $1.tag }

        // Build: "Nikon\0" (6) + version (2) + padding (2) = offset 10 for TIFF header
        var writer = BinaryWriter(capacity: 256)
        writer.writeBytes([0x4E, 0x69, 0x6B, 0x6F, 0x6E, 0x00]) // "Nikon\0"
        writer.writeBytes([0x02, 0x10]) // Version
        writer.writeBytes([0x00, 0x00]) // Padding

        // Embedded TIFF header at offset 10
        writer.writeBytes([0x4D, 0x4D]) // Big-endian
        writer.writeUInt16BigEndian(42)
        writer.writeUInt32BigEndian(8) // IFD at offset 8 relative to this TIFF header

        // IFD data (IFD at offset 8 relative to embedded tiffStart)
        let ifdData = buildMiniIFD(entries: entries, byteOrder: .bigEndian, offsetBase: 8)
        writer.writeBytes(ifdData)

        return writer.data
    }

    /// Build a Sony MakerNote: optional "SONY DSC \0\0\0" prefix + IFD.
    private func buildSonyMakerNote(serialNumber: String, withPrefix: Bool = false) -> Data {
        var entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)] = []

        // Serial number (tag 0xB020)
        let snBytes = Data(serialNumber.utf8) + Data([0x00])
        entries.append((0xB020, .ascii, UInt32(snBytes.count), snBytes))

        entries.sort { $0.tag < $1.tag }

        var writer = BinaryWriter(capacity: 256)
        if withPrefix {
            writer.writeBytes(Data("SONY DSC \0\0\0".utf8))
        }
        let ifdData = buildMiniIFD(entries: entries, byteOrder: .bigEndian, offsetBase: withPrefix ? 12 : 0)
        writer.writeBytes(ifdData)
        return writer.data
    }

    /// Build a minimal IFD from entries. All values stored inline or after IFD.
    /// - Parameter offsetBase: offset of IFD relative to tiffStart (0 for Canon, 8 for Nikon).
    private func buildMiniIFD(entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)], byteOrder: ByteOrder, offsetBase: Int = 0) -> Data {
        var writer = BinaryWriter(capacity: 256)

        writer.writeUInt16(UInt16(entries.count), endian: byteOrder)

        let ifdDirectorySize = 2 + entries.count * 12 + 4
        var externalOffset = offsetBase + ifdDirectorySize
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

        writer.writeUInt32(0, endian: byteOrder) // Next IFD offset
        writer.writeBytes(externalData)

        return writer.data
    }

    /// Build a Fujifilm MakerNote: "FUJIFILM" (8B) + LE offset (4B) + IFD (little-endian).
    private func buildFujifilmMakerNote(serialNumber: String) -> Data {
        var entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)] = []
        let snBytes = Data(serialNumber.utf8) + Data([0x00])
        entries.append((0x0010, .ascii, UInt32(snBytes.count), snBytes))
        entries.sort { $0.tag < $1.tag }

        let ifdData = buildMiniIFD(entries: entries, byteOrder: .littleEndian, offsetBase: 12)

        var writer = BinaryWriter(capacity: 256)
        // "FUJIFILM" header
        writer.writeBytes(Data([0x46, 0x55, 0x4A, 0x49, 0x46, 0x49, 0x4C, 0x4D]))
        // IFD offset (4 bytes, little-endian) — IFD starts right after this = offset 12
        writer.writeUInt32(12, endian: .littleEndian)
        // IFD data
        writer.writeBytes(ifdData)
        return writer.data
    }

    /// Build an Olympus MakerNote.
    private func buildOlympusMakerNote(cameraID: String, useNewFormat: Bool) -> Data {
        var entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)] = []
        let idBytes = Data(cameraID.utf8) + Data([0x00])
        entries.append((0x0207, .ascii, UInt32(idBytes.count), idBytes))
        entries.sort { $0.tag < $1.tag }

        var writer = BinaryWriter(capacity: 256)
        if useNewFormat {
            // "OLYMPUS\0" + "II" (little-endian) + version (2B)
            writer.writeBytes(Data([0x4F, 0x4C, 0x59, 0x4D, 0x50, 0x55, 0x53, 0x00])) // "OLYMPUS\0"
            writer.writeBytes([0x49, 0x49]) // Little-endian
            writer.writeBytes([0x03, 0x00]) // Version
            let ifdData = buildMiniIFD(entries: entries, byteOrder: .littleEndian, offsetBase: 12)
            writer.writeBytes(ifdData)
        } else {
            // "OLYMP\0" + version (2B)
            writer.writeBytes(Data([0x4F, 0x4C, 0x59, 0x4D, 0x50, 0x00])) // "OLYMP\0"
            writer.writeBytes([0x01, 0x00]) // Version
            let ifdData = buildMiniIFD(entries: entries, byteOrder: .bigEndian, offsetBase: 8)
            writer.writeBytes(ifdData)
        }
        return writer.data
    }

    /// Build a Panasonic MakerNote: "Panasonic\0\0\0" (12B) + IFD.
    private func buildPanasonicMakerNote(serialNumber: String, lensType: String? = nil) -> Data {
        var entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)] = []
        let snBytes = Data(serialNumber.utf8) + Data([0x00])
        entries.append((0x0025, .ascii, UInt32(snBytes.count), snBytes))

        if let lt = lensType {
            let ltBytes = Data(lt.utf8) + Data([0x00])
            entries.append((0x0051, .ascii, UInt32(ltBytes.count), ltBytes))
        }

        entries.sort { $0.tag < $1.tag }

        var writer = BinaryWriter(capacity: 256)
        writer.writeBytes(Data("Panasonic\0\0\0".utf8))
        let ifdData = buildMiniIFD(entries: entries, byteOrder: .bigEndian, offsetBase: 12)
        writer.writeBytes(ifdData)
        return writer.data
    }

    /// Build a DJI MakerNote: IFD starting immediately, like Canon.
    private func buildDJIMakerNote(
        make: String = "DJI",
        speedX: Float? = nil,
        yaw: Float? = nil,
        cameraRoll: Float? = nil,
        byteOrder: ByteOrder = .littleEndian
    ) -> Data {
        var entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)] = []

        // Make (tag 0x0001)
        let makeBytes = Data(make.utf8) + Data([0x00])
        entries.append((0x0001, .ascii, UInt32(makeBytes.count), makeBytes))

        // SpeedX (tag 0x0003) — Float32
        if let sx = speedX {
            var w = BinaryWriter(capacity: 4)
            w.writeFloat32(sx, endian: byteOrder)
            entries.append((0x0003, .float, 1, w.data))
        }

        // Yaw (tag 0x0007) — Float32
        if let y = yaw {
            var w = BinaryWriter(capacity: 4)
            w.writeFloat32(y, endian: byteOrder)
            entries.append((0x0007, .float, 1, w.data))
        }

        // CameraRoll (tag 0x000b) — Float32
        if let cr = cameraRoll {
            var w = BinaryWriter(capacity: 4)
            w.writeFloat32(cr, endian: byteOrder)
            entries.append((0x000b, .float, 1, w.data))
        }

        entries.sort { $0.tag < $1.tag }
        return buildMiniIFD(entries: entries, byteOrder: byteOrder)
    }

    /// Build a Samsung MakerNote: IFD starting immediately, like Canon.
    private func buildSamsungMakerNote(
        deviceType: UInt32 = 0x3000,
        firmwareName: String? = nil,
        byteOrder: ByteOrder = .bigEndian
    ) -> Data {
        var entries: [(tag: UInt16, type: TIFFDataType, count: UInt32, data: Data)] = []

        // DeviceType (tag 0x0002) — UInt32
        var dtWriter = BinaryWriter(capacity: 4)
        dtWriter.writeUInt32(deviceType, endian: byteOrder)
        entries.append((0x0002, .long, 1, dtWriter.data))

        // FirmwareName (tag 0x0043) — ASCII
        if let fw = firmwareName {
            let fwBytes = Data(fw.utf8) + Data([0x00])
            entries.append((0x0043, .ascii, UInt32(fwBytes.count), fwBytes))
        }

        entries.sort { $0.tag < $1.tag }
        return buildMiniIFD(entries: entries, byteOrder: byteOrder)
    }
}
