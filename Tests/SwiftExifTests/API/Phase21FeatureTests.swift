import XCTest
@testable import SwiftExif

// MARK: - ICC Profile Depth (Phase 21.1)

final class ICCProfileDepthTests: XCTestCase {

    func testParsesHeaderFields() {
        guard let p = makeICCProfile() else { XCTFail("profile build failed"); return }
        XCTAssertEqual(p.profileVersion, "2.1.0")
        XCTAssertEqual(p.deviceClass, "mntr")
        XCTAssertEqual(p.colorSpace, "RGB ")
        XCTAssertEqual(p.profileConnectionSpace, "XYZ ")
        XCTAssertEqual(p.creationDate, "2024:03:15 12:30:45")
        XCTAssertEqual(p.primaryPlatform, "APPL")
        XCTAssertEqual(p.manufacturer, "appl")
        XCTAssertEqual(p.renderingIntent, 1)  // relative colorimetric
        XCTAssertEqual(p.creator, "Test")
    }

    func testParsesPCSIlluminant() {
        guard let p = makeICCProfile() else { XCTFail(); return }
        // D50 illuminant ICC values: X=0.9642, Y=1.0000, Z=0.8249
        guard let pcs = p.pcsIlluminant else { XCTFail("missing pcs"); return }
        XCTAssertEqual(pcs.x, 0.9642, accuracy: 0.0005)
        XCTAssertEqual(pcs.y, 1.0000, accuracy: 0.0005)
        XCTAssertEqual(pcs.z, 0.8249, accuracy: 0.0005)
    }

    func testParsesXYZTags() {
        guard let p = makeICCProfile() else { XCTFail(); return }
        XCTAssertNotNil(p.mediaWhitePoint)
        XCTAssertEqual(p.mediaWhitePoint?.y ?? 0, 1.0, accuracy: 0.001)
        XCTAssertNotNil(p.redColorant)
        XCTAssertNotNil(p.greenColorant)
        XCTAssertNotNil(p.blueColorant)
    }

    func testParsesTRCs() {
        guard let p = makeICCProfile() else { XCTFail(); return }
        // We seeded an "rTRC" with a single-entry curve (gamma 2.2 → 0x0233 = 563/256 ≈ 2.199).
        guard case .gamma(let g) = p.redTRC else {
            XCTFail("expected gamma TRC, got \(String(describing: p.redTRC))"); return
        }
        XCTAssertEqual(g, 2.199, accuracy: 0.005)
        XCTAssertNotNil(p.greenTRC)
        XCTAssertNotNil(p.blueTRC)
    }

    func testParsesCopyright() {
        guard let p = makeICCProfile() else { XCTFail(); return }
        XCTAssertEqual(p.copyright, "Copyright 2024")
    }

    func testTagTableIsPopulated() {
        guard let p = makeICCProfile() else { XCTFail(); return }
        XCTAssertGreaterThan(p.tags.count, 0)
        XCTAssertNotNil(p.tags["desc"])
        XCTAssertNotNil(p.tags["cprt"])
        XCTAssertNotNil(p.tags["wtpt"])
    }

    func testExporterIncludesNewICCFields() throws {
        guard let p = makeICCProfile() else { XCTFail(); return }
        let m = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg, iccProfile: p)
        let dict = MetadataExporter.toJSON(m)
        let json = String(data: dict, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("ICCProfile:Version"))
        XCTAssertTrue(json.contains("ICCProfile:Class"))
        XCTAssertTrue(json.contains("ICCProfile:Copyright"))
        XCTAssertTrue(json.contains("ICCProfile:RedTRC"))
        XCTAssertTrue(json.contains("ICCProfile:MediaWhitePoint"))
    }

    // MARK: - Helpers

    /// Build an ICC profile with header + a tag table containing
    /// desc, cprt, wtpt, rXYZ, gXYZ, bXYZ, rTRC, gTRC, bTRC.
    private func makeICCProfile() -> ICCProfile? {
        // Layout:
        //   0–127      : header
        //   128–131    : tag count = 9
        //   132–239    : 9 × 12-byte tag entries
        //   240+       : tag data area
        var tagEntries: [(sig: String, data: Data)] = []

        // desc (textDescriptionType): "sRGB" + null
        tagEntries.append((sig: "desc", data: makeDescTag("sRGB Test")))
        // cprt (textType): "Copyright 2024" — for ICC v2/v4, simplest path is descType
        tagEntries.append((sig: "cprt", data: makeDescTag("Copyright 2024")))
        // wtpt: D50 white point
        tagEntries.append((sig: "wtpt", data: makeXYZTag(x: 0.9642, y: 1.0000, z: 0.8249)))
        // rXYZ, gXYZ, bXYZ — sRGB primaries
        tagEntries.append((sig: "rXYZ", data: makeXYZTag(x: 0.4361, y: 0.2225, z: 0.0139)))
        tagEntries.append((sig: "gXYZ", data: makeXYZTag(x: 0.3851, y: 0.7169, z: 0.0971)))
        tagEntries.append((sig: "bXYZ", data: makeXYZTag(x: 0.1431, y: 0.0606, z: 0.7139)))
        // rTRC, gTRC, bTRC: single-gamma curves (count==1, value u8.8 fixed)
        // 2.2 gamma in u8.8 = 0x0233 = 563
        tagEntries.append((sig: "rTRC", data: makeCurvSingleGamma(563)))
        tagEntries.append((sig: "gTRC", data: makeCurvSingleGamma(563)))
        tagEntries.append((sig: "bTRC", data: makeCurvSingleGamma(563)))

        // Header
        var data = Data(repeating: 0, count: 128)
        // CMM
        data[4] = 0x61; data[5] = 0x70; data[6] = 0x70; data[7] = 0x6C
        // Version 2.1.0
        data[8] = 0x02; data[9] = 0x10
        // Device class "mntr"
        data[12] = 0x6D; data[13] = 0x6E; data[14] = 0x74; data[15] = 0x72
        // Color space "RGB "
        data[16] = 0x52; data[17] = 0x47; data[18] = 0x42; data[19] = 0x20
        // PCS "XYZ "
        data[20] = 0x58; data[21] = 0x59; data[22] = 0x5A; data[23] = 0x20
        // dateTime: 2024-03-15 12:30:45
        writeBE16(into: &data, at: 24, value: 2024)
        writeBE16(into: &data, at: 26, value: 3)
        writeBE16(into: &data, at: 28, value: 15)
        writeBE16(into: &data, at: 30, value: 12)
        writeBE16(into: &data, at: 32, value: 30)
        writeBE16(into: &data, at: 34, value: 45)
        // Signature "acsp"
        data[36] = 0x61; data[37] = 0x63; data[38] = 0x73; data[39] = 0x70
        // Primary platform "APPL"
        data[40] = 0x41; data[41] = 0x50; data[42] = 0x50; data[43] = 0x4C
        // Manufacturer "appl"
        data[48] = 0x61; data[49] = 0x70; data[50] = 0x70; data[51] = 0x6C
        // Rendering intent: 1 (relative colorimetric)
        writeBE32(into: &data, at: 64, value: 1)
        // PCS illuminant: D50
        writeS15Fixed16(into: &data, at: 68, value: 0.9642)
        writeS15Fixed16(into: &data, at: 72, value: 1.0000)
        writeS15Fixed16(into: &data, at: 76, value: 0.8249)
        // Creator "Test"
        data[80] = 0x54; data[81] = 0x65; data[82] = 0x73; data[83] = 0x74

        // Tag table
        writeBE32(into: &data, at: 0, value: 0) // size — patched at end
        let tagCount = UInt32(tagEntries.count)
        var tagTable = Data()
        var w = BinaryWriter(capacity: 128)
        w.writeUInt32BigEndian(tagCount)
        // Tag table starts at byte 128. Entries are 12 bytes each. Tag data
        // begins after the table at offset 132 + 12 × tagCount.
        var dataAreaOffset = 132 + Int(tagCount) * 12
        var tagDataArea = Data()
        for entry in tagEntries {
            let sigBytes = Array(entry.sig.utf8)
            for b in sigBytes { w.writeUInt8(b) }
            w.writeUInt32BigEndian(UInt32(dataAreaOffset))
            w.writeUInt32BigEndian(UInt32(entry.data.count))
            tagDataArea.append(entry.data)
            dataAreaOffset += entry.data.count
        }
        tagTable = w.data
        data.append(tagTable)
        data.append(tagDataArea)

        // Patch profile size
        writeBE32(into: &data, at: 0, value: UInt32(data.count))

        return ICCProfile(data: data)
    }

    private func makeDescTag(_ text: String) -> Data {
        // textDescriptionType: 4 sig + 4 reserved + 4 ASCII length + ASCII string + null
        var w = BinaryWriter(capacity: 64)
        w.writeBytes(Array("desc".utf8))
        w.writeUInt32BigEndian(0)  // reserved
        let strBytes = Array(text.utf8)
        w.writeUInt32BigEndian(UInt32(strBytes.count + 1))
        for b in strBytes { w.writeUInt8(b) }
        w.writeUInt8(0)
        return w.data
    }

    private func makeXYZTag(x: Double, y: Double, z: Double) -> Data {
        // 4 sig "XYZ " + 4 reserved + 3 × s15Fixed16
        var d = Data()
        d.append(contentsOf: Array("XYZ ".utf8))
        d.append(contentsOf: [0, 0, 0, 0])
        appendS15Fixed16(into: &d, value: x)
        appendS15Fixed16(into: &d, value: y)
        appendS15Fixed16(into: &d, value: z)
        return d
    }

    /// `curv` with a single gamma entry (count == 1, value is u8.8 fixed-point).
    private func makeCurvSingleGamma(_ u8_8: UInt16) -> Data {
        var w = BinaryWriter(capacity: 16)
        w.writeBytes(Array("curv".utf8))
        w.writeUInt32BigEndian(0)  // reserved
        w.writeUInt32BigEndian(1)  // count
        w.writeUInt16BigEndian(u8_8)
        return w.data
    }

    private func appendS15Fixed16(into data: inout Data, value: Double) {
        let raw = Int32(value * 65536.0)
        let u = UInt32(bitPattern: raw)
        data.append(UInt8((u >> 24) & 0xFF))
        data.append(UInt8((u >> 16) & 0xFF))
        data.append(UInt8((u >> 8) & 0xFF))
        data.append(UInt8(u & 0xFF))
    }

    private func writeS15Fixed16(into data: inout Data, at offset: Int, value: Double) {
        let raw = Int32(value * 65536.0)
        let u = UInt32(bitPattern: raw)
        writeBE32(into: &data, at: offset, value: u)
    }

    private func writeBE32(into data: inout Data, at offset: Int, value: UInt32) {
        data[offset]     = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private func writeBE16(into data: inout Data, at offset: Int, value: UInt16) {
        data[offset]     = UInt8((value >> 8) & 0xFF)
        data[offset + 1] = UInt8(value & 0xFF)
    }
}

// MARK: - IPTC Records 3, 6–9 + PLUS (Phase 21.2)

final class IPTCNewsPhotoTagsTests: XCTestCase {

    func testRecord3TagsHaveMetadata() {
        let record3Tags: [IPTCTag] = [
            .newsPhotoVersion, .iptcImageWidth, .iptcImageHeight,
            .iptcPixelWidth, .iptcPixelHeight, .supplementalType,
            .colorRepresentation, .interchangeColorSpace, .colorSequence,
            .iccProfile, .iptcBitsPerSample, .iptcImageRotation,
            .dataCompressionMethod,
        ]
        for tag in record3Tags {
            XCTAssertEqual(tag.record, 3, "\(tag) should be on Record 3")
            XCTAssertNotEqual(tag.name, "Unknown(\(tag.record):\(tag.dataSet))",
                              "\(tag) missing metadata")
        }
    }

    func testObjectDataRecordsHaveMetadata() {
        XCTAssertEqual(IPTCTag.subfile.record, 6)
        XCTAssertEqual(IPTCTag.objectDataPreviewFileFormat.record, 7)
        XCTAssertEqual(IPTCTag.objectDataPreviewFileFormatVersion.record, 7)
        XCTAssertEqual(IPTCTag.objectDataPreviewData.record, 7)
        XCTAssertEqual(IPTCTag.confirmedDataSize.record, 8)
    }

    func testIntegerDataTypes() {
        XCTAssertEqual(IPTCTag.iptcImageWidth.dataType, .int16u)
        XCTAssertEqual(IPTCTag.supplementalType.dataType, .int8u)
        XCTAssertEqual(IPTCTag.dataCompressionMethod.dataType, .int32u)
        XCTAssertEqual(IPTCTag.confirmedDataSize.dataType, .int32u)
    }

    func testReadIntegerValues() {
        // Build a synthetic IIM stream containing iptcImageWidth (uint16be = 1920),
        // supplementalType (uint8 = 1), and dataCompressionMethod (uint32be = 5).
        var iim = Data()
        appendDataSet(&iim, record: 3, dataSet: 20, value: Data([0x07, 0x80]))           // 1920
        appendDataSet(&iim, record: 3, dataSet: 55, value: Data([0x01]))                 // 1
        appendDataSet(&iim, record: 3, dataSet: 110, value: Data([0x00, 0x00, 0x00, 0x05])) // 5

        guard let parsed = try? IPTCReader.read(from: iim) else {
            XCTFail("IIM parse failed"); return
        }
        XCTAssertEqual(parsed.iptcImageWidth, 1920)
        XCTAssertEqual(parsed.supplementalType, 1)
        XCTAssertEqual(parsed.dataCompressionMethod, 5)
    }

    func testPLUSLicensingFieldsRoundTrip() {
        var xmp = XMPData()
        xmp.licenseTransactionID = "TX-12345"
        xmp.licenseStartDate = "2026-01-01"
        xmp.licenseEndDate = "2026-12-31"
        xmp.copyrightStatus = "http://ns.useplus.org/ldf/vocab/CS-PRO"
        xmp.dataMining = "http://ns.useplus.org/ldf/vocab/DM-NMP"

        XCTAssertEqual(xmp.licenseTransactionID, "TX-12345")
        XCTAssertEqual(xmp.licenseStartDate, "2026-01-01")
        XCTAssertEqual(xmp.licenseEndDate, "2026-12-31")
        XCTAssertEqual(xmp.copyrightStatus, "http://ns.useplus.org/ldf/vocab/CS-PRO")
        XCTAssertEqual(xmp.dataMining, "http://ns.useplus.org/ldf/vocab/DM-NMP")
    }

    func testImageSupplierStructRoundTrip() {
        var xmp = XMPData()
        xmp.imageSupplier = [
            IPTCImageSupplier(imageSupplierID: "AGN001", imageSupplierName: "Test Agency")
        ]
        let read = xmp.imageSupplier
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.imageSupplierID, "AGN001")
        XCTAssertEqual(read.first?.imageSupplierName, "Test Agency")
    }

    private func appendDataSet(_ data: inout Data, record: UInt8, dataSet: UInt8, value: Data) {
        data.append(0x1C)
        data.append(record)
        data.append(dataSet)
        let len = UInt16(value.count)
        data.append(UInt8((len >> 8) & 0xFF))
        data.append(UInt8(len & 0xFF))
        data.append(value)
    }
}

// MARK: - DNG Private Tags (Phase 21.3)

final class DNGMetadataTests: XCTestCase {

    func testPlainTIFFHasNoDNGMetadata() throws {
        // A regular TIFF without DNGVersion (0xC612) should not produce DNG metadata.
        let tiff = TestFixtures.minimalTIFF(byteOrder: .littleEndian, entries: [
            (tag: ExifTag.make, type: .ascii, count: 5, valueData: Data("Test\0".utf8)),
        ])
        let m = try ImageMetadata.read(from: tiff)
        XCTAssertNil(m.dng)
    }

    func testDNGVersionTagIsParsed() throws {
        // Minimum DNG: just IFD0 with DNGVersion = 1.4.0.0
        let dngVersionData = Data([0x01, 0x04, 0x00, 0x00])
        let tiff = TestFixtures.minimalTIFF(byteOrder: .littleEndian, entries: [
            (tag: DNGTag.dngVersion, type: .byte, count: 4, valueData: dngVersionData),
        ])
        let m = try ImageMetadata.read(from: tiff)
        guard let dng = m.dng else {
            XCTFail("Expected DNG metadata"); return
        }
        XCTAssertEqual(dng.dngVersion, "1.4.0.0")
    }

    func testColorMatrix1Parsing() throws {
        // 9 × s-rational matrix entries (numerator / denominator). Use simple values.
        var matrixData = Data()
        let nums: [Int32] = [10000, -2000, -500, -3000, 12000, 1000, -200, -1500, 9000]
        for n in nums {
            appendInt32LE(&matrixData, value: n)
            appendInt32LE(&matrixData, value: 10000) // denominator
        }
        let tiff = TestFixtures.minimalTIFF(byteOrder: .littleEndian, entries: [
            (tag: DNGTag.dngVersion, type: .byte, count: 4, valueData: Data([1,4,0,0])),
            (tag: DNGTag.colorMatrix1, type: .srational, count: 9, valueData: matrixData),
        ])
        let m = try ImageMetadata.read(from: tiff)
        guard let cm = m.dng?.colorMatrix1 else { XCTFail("missing colorMatrix1"); return }
        XCTAssertEqual(cm.count, 9)
        XCTAssertEqual(cm[0], 1.0, accuracy: 0.0001)
        XCTAssertEqual(cm[4], 1.2, accuracy: 0.0001)
        XCTAssertEqual(cm[8], 0.9, accuracy: 0.0001)
    }

    func testDefaultCropOriginAndSize() throws {
        // SHORT-typed 2-element pairs.
        let originData = Data([0, 8, 0, 16])  // 8, 16
        let sizeData = Data([0x07, 0x80, 0x04, 0x38])  // 1920, 1080
        let tiff = TestFixtures.minimalTIFF(byteOrder: .bigEndian, entries: [
            (tag: DNGTag.dngVersion, type: .byte, count: 4, valueData: Data([1,4,0,0])),
            (tag: DNGTag.defaultCropOrigin, type: .short, count: 2, valueData: originData),
            (tag: DNGTag.defaultCropSize, type: .short, count: 2, valueData: sizeData),
        ])
        let m = try ImageMetadata.read(from: tiff)
        XCTAssertEqual(m.dng?.defaultCropOrigin, [8.0, 16.0])
        XCTAssertEqual(m.dng?.defaultCropSize, [1920.0, 1080.0])
    }

    func testNoiseProfileDoubles() throws {
        // Two doubles: 1e-4 and 5e-3 (one channel pair).
        var nd = Data()
        appendDoubleLE(&nd, value: 1e-4)
        appendDoubleLE(&nd, value: 5e-3)
        let tiff = TestFixtures.minimalTIFF(byteOrder: .littleEndian, entries: [
            (tag: DNGTag.dngVersion, type: .byte, count: 4, valueData: Data([1,4,0,0])),
            (tag: DNGTag.noiseProfile, type: .double, count: 2, valueData: nd),
        ])
        let m = try ImageMetadata.read(from: tiff)
        guard let np = m.dng?.noiseProfile else { XCTFail("missing noiseProfile"); return }
        XCTAssertEqual(np.count, 2)
        XCTAssertEqual(np[0], 1e-4, accuracy: 1e-9)
        XCTAssertEqual(np[1], 5e-3, accuracy: 1e-9)
    }

    func testOpcodeListByteCount() throws {
        // OpcodeList3 with 32 bytes of opaque payload.
        let payload = Data(repeating: 0xAB, count: 32)
        let tiff = TestFixtures.minimalTIFF(byteOrder: .littleEndian, entries: [
            (tag: DNGTag.dngVersion, type: .byte, count: 4, valueData: Data([1,4,0,0])),
            (tag: DNGTag.opcodeList3, type: .undefined, count: 32, valueData: payload),
        ])
        let m = try ImageMetadata.read(from: tiff)
        XCTAssertEqual(m.dng?.opcodeList3Size, 32)
    }

    func testExporterIncludesDNGFields() throws {
        let tiff = TestFixtures.minimalTIFF(byteOrder: .littleEndian, entries: [
            (tag: DNGTag.dngVersion, type: .byte, count: 4, valueData: Data([1,4,0,0])),
        ])
        let m = try ImageMetadata.read(from: tiff)
        let json = String(data: MetadataExporter.toJSON(m), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("DNG:DNGVersion"))
        XCTAssertTrue(json.contains("1.4.0.0"))
    }

    private func appendInt32LE(_ data: inout Data, value: Int32) {
        let u = UInt32(bitPattern: value)
        data.append(UInt8(u & 0xFF))
        data.append(UInt8((u >> 8) & 0xFF))
        data.append(UInt8((u >> 16) & 0xFF))
        data.append(UInt8((u >> 24) & 0xFF))
    }

    private func appendDoubleLE(_ data: inout Data, value: Double) {
        let bits = value.bitPattern
        for i in 0..<8 {
            data.append(UInt8((bits >> (8 * i)) & 0xFF))
        }
    }
}
