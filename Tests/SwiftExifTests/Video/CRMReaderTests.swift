import XCTest
@testable import SwiftExif

/// Tests for Canon Cinema RAW Light (.CRM master / .CRL proxy) reading.
final class CRMReaderTests: XCTestCase {

    // MARK: - Format detection

    func testFTYPCRXBrandDetectedAsCRM() {
        let data = buildMinimalCRM()
        XCTAssertEqual(FormatDetector.detectVideo(data), .crm)
    }

    func testCRMExtensionRouting() {
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("crm"), .crm)
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("crl"), .crl)
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("CRM"), .crm)
    }

    func testIsCanonCinemaRAWAcceptsCRMNotCR3() {
        XCTAssertTrue(CRMReader.isCanonCinemaRAW(buildMinimalCRM(cncv: "CanonCRM0001/02.10.00/00.00.00")))
        XCTAssertFalse(CRMReader.isCanonCinemaRAW(buildMinimalCRM(cncv: "CanonCR3_001/00.09.00/00.00.00")))
    }

    func testIsCanonCinemaRAWFalseForPlainMP4() {
        let mp4 = buildMinimalCRM(brand: "isom", canonUUID: nil)
        XCTAssertFalse(CRMReader.isCanonCinemaRAW(mp4))
    }

    // MARK: - CMT1 → CameraMetadata

    func testCMT1MakeModelExtracted() throws {
        let cmt1 = buildTIFF(entries: [
            (tag: 0x010F, type: .ascii, value: stringValue("Canon")),
            (tag: 0x0110, type: .ascii, value: stringValue("Canon EOS C70")),
        ])
        let data = buildMinimalCRM(cmt1: cmt1)
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.format, .crm)
        XCTAssertEqual(metadata.formatLongName, "Canon Cinema RAW Light")
        XCTAssertEqual(metadata.camera?.deviceManufacturer, "Canon")
        XCTAssertEqual(metadata.camera?.deviceModelName, "Canon EOS C70")
    }

    // MARK: - CTMD per-frame timeline

    func testCTMDTimestampDecoded() throws {
        let record = makeCTMDRecord(type: 0x0001, payload: makeTimestampPayload(year: 2026, month: 5, day: 2, hour: 14, minute: 30, second: 15, hundredths: 25))
        let data = buildMinimalCRM(ctmdSamples: [record])
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.cameraTimeline.count, 1)
        let ts = try XCTUnwrap(metadata.cameraTimeline.first?.timestamp)
        var components = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")!
        let parts = components.dateComponents(in: TimeZone(identifier: "UTC")!, from: ts)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 5)
        XCTAssertEqual(parts.day, 2)
        XCTAssertEqual(parts.hour, 14)
        XCTAssertEqual(parts.minute, 30)
        XCTAssertEqual(parts.second, 15)
    }

    func testCTMDFocalLengthDecoded() throws {
        let record = makeCTMDRecord(type: 0x0004, payload: makeFocalPayload(num: 24, den: 1))
        let data = buildMinimalCRM(ctmdSamples: [record])
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.cameraTimeline.first?.focalLengthMm, 24.0)
        XCTAssertEqual(metadata.camera?.lensZoomActualFocalLengthMm, 24.0)
    }

    func testCTMDExposureDecoded() throws {
        let record = makeCTMDRecord(type: 0x0005, payload: makeExposurePayload(fNum: 4, fDen: 1, expNum: 1, expDen: 50, iso: 800))
        let data = buildMinimalCRM(ctmdSamples: [record])
        let metadata = try VideoMetadata.read(from: data)
        let frame = try XCTUnwrap(metadata.cameraTimeline.first)
        XCTAssertEqual(frame.fNumber, 4.0)
        XCTAssertEqual(try XCTUnwrap(frame.exposureTimeS), 1.0 / 50.0, accuracy: 1e-6)
        XCTAssertEqual(frame.iso, 800)
        XCTAssertEqual(metadata.camera?.irisFNumber, 4.0)
        XCTAssertEqual(try XCTUnwrap(metadata.camera?.shutterTimeMs), 20.0, accuracy: 1e-3)
        XCTAssertEqual(metadata.camera?.isoSensitivity, 800)
    }

    func testCTMDFullTimelineMultipleSamples() throws {
        let s1 = makeCTMDRecord(type: 0x0005, payload: makeExposurePayload(fNum: 4, fDen: 1, expNum: 1, expDen: 50, iso: 800))
        let s2 = makeCTMDRecord(type: 0x0005, payload: makeExposurePayload(fNum: 56, fDen: 10, expNum: 1, expDen: 100, iso: 1600))
        let s3 = makeCTMDRecord(type: 0x0005, payload: makeExposurePayload(fNum: 8, fDen: 1, expNum: 1, expDen: 200, iso: 3200))
        let data = buildMinimalCRM(ctmdSamples: [s1, s2, s3])
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.cameraTimeline.count, 3)
        XCTAssertEqual(metadata.cameraTimeline[0].iso, 800)
        XCTAssertEqual(metadata.cameraTimeline[1].iso, 1600)
        XCTAssertEqual(metadata.cameraTimeline[2].iso, 3200)
        XCTAssertEqual(try XCTUnwrap(metadata.cameraTimeline[1].fNumber), 5.6, accuracy: 1e-6)
        // First-frame snapshot wins on the camera scalar fields.
        XCTAssertEqual(metadata.camera?.isoSensitivity, 800)
    }

    // MARK: - Thumb / preview

    func testTHMBExtractedAsEmbeddedThumbnail() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xDB, 0xCA, 0xFE, 0xFF, 0xD9])
        let thmbBoxBody = buildJPEGBoxBody(jpeg: jpeg, width: 160, height: 120)
        let thmbBox = writeBoxRaw("THMB", payload: thmbBoxBody)
        let canonMetadataPayload = Data(CanonUUID.canonMetadata)
            + writeBoxRaw("CNCV", payload: Data("CanonCRM0001/02.10.00/00.00.00".utf8))
            + thmbBox
        let moovBoxes = writeBoxRaw("uuid", payload: canonMetadataPayload)
        let data = buildCRMWithMoovChildren(moovChildren: moovBoxes)
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.embeddedThumbnailJPEG, jpeg)
    }

    func testPRVWExtractedAsEmbeddedPreview() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xDB, 0xBE, 0xEF, 0xFF, 0xD9])
        let prvwBody = buildJPEGBoxBody(jpeg: jpeg, width: 1620, height: 1080)
        let prvwBox = writeBoxRaw("PRVW", payload: prvwBody)
        let canonPreviewPayload = Data(CanonUUID.canonPreview) + prvwBox
        let canonMetaPayload = Data(CanonUUID.canonMetadata)
            + writeBoxRaw("CNCV", payload: Data("CanonCRM0001/02.10.00/00.00.00".utf8))
        let moovChildren = writeBoxRaw("uuid", payload: canonMetaPayload)
            + writeBoxRaw("uuid", payload: canonPreviewPayload)
        let data = buildCRMWithMoovChildren(moovChildren: moovChildren)
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.embeddedPreviewJPEG, jpeg)
    }

    // MARK: - Read-only

    func testCRMIsReadOnly() throws {
        let data = buildMinimalCRM()
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.format, .crm)
        XCTAssertThrowsError(try metadata.writeToData())
    }

    // MARK: - Real-file smoke (skipped when fixture absent)

    func testRealC70CRMSampleIfPresent() throws {
        let path = "/Users/traag222/Movies/TestVideo/Canon Cinema RAW Light/A001C004_22032472_CANON.CRM"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("CRM sample not present on this machine")
        }
        let url = URL(fileURLWithPath: path)
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.format, .crm)
        XCTAssertEqual(m.formatLongName, "Canon Cinema RAW Light")
        XCTAssertEqual(m.camera?.deviceManufacturer, "Canon")
        XCTAssertEqual(m.camera?.deviceModelName, "Canon EOS C70")
        XCTAssertNotNil(m.embeddedThumbnailJPEG)
    }

    // MARK: - Builders

    /// Build a minimal CRM file: ftyp("crx ") + moov(canon-metadata uuid optionally
    /// with CMT1, optionally a CTMD trak + matching mdat).
    private func buildMinimalCRM(
        brand: String = "crx ",
        cncv: String = "CanonCRM0001/02.10.00/00.00.00",
        cmt1: Data? = nil,
        canonUUID: Data? = CanonUUID.canonMetadata,
        ctmdSamples: [Data] = []
    ) -> Data {
        // 1) Build the canon-metadata uuid payload (if requested)
        var uuidPayload = Data()
        if let canonUUID {
            uuidPayload.append(canonUUID)
            uuidPayload.append(writeBoxRaw("CNCV", payload: Data(cncv.utf8)))
            if let cmt1 {
                uuidPayload.append(writeBoxRaw("CMT1", payload: cmt1))
            }
        }

        // 2) Build moov children: mvhd + (uuid?) + (CTMD trak?)
        var mvhd = Data([0, 0, 0, 0]) // version+flags
        mvhd.append(Data(repeating: 0, count: 96))
        var moovChildren = writeBoxRaw("mvhd", payload: mvhd)
        if !uuidPayload.isEmpty {
            moovChildren.append(writeBoxRaw("uuid", payload: uuidPayload))
        }

        // We need the CTMD trak's stco offset to point at the actual sample
        // location in `mdat`. That offset depends on the size of all the
        // bytes that come *before* mdat — including the moov box header and
        // its children. So build the trak with a placeholder offset, measure,
        // then re-build with the correct offset.
        var sampleData = Data()
        var sampleSizes: [UInt32] = []
        for s in ctmdSamples {
            sampleSizes.append(UInt32(s.count))
            sampleData.append(s)
        }

        if !ctmdSamples.isEmpty {
            // Provisional trak with offset = 0
            let trakProvisional = buildCTMDTrak(sampleSizes: sampleSizes, chunkOffset: 0)
            moovChildren.append(trakProvisional)

            // Compute absolute mdat-payload offset:
            // ftypBox + moovBox-header(8) + moovChildren + mdatBox-header(8)
            let ftypBox = writeBoxRaw("ftyp", payload: Data(brand.utf8) + Data([0, 0, 0, 0]))
            let mdatHeaderSize = 8
            let provisionalMoovBox = writeBoxRaw("moov", payload: moovChildren)
            let mdatPayloadOffset = ftypBox.count + provisionalMoovBox.count + mdatHeaderSize

            // Rebuild the trak with the correct chunk offset
            let trakFinal = buildCTMDTrak(sampleSizes: sampleSizes, chunkOffset: UInt32(mdatPayloadOffset))
            // Replace the provisional trak — same byte length as long as the only
            // changing bytes are the stco offset (4 bytes), which they are.
            assert(trakFinal.count == trakProvisional.count, "CTMD trak rebuild must preserve length")
            // The provisional trak is the LAST appended box, so trim & append.
            moovChildren.removeLast(trakProvisional.count)
            moovChildren.append(trakFinal)
        }

        // 3) Assemble final file
        var data = Data()
        data.append(writeBoxRaw("ftyp", payload: Data(brand.utf8) + Data([0, 0, 0, 0])))
        data.append(writeBoxRaw("moov", payload: moovChildren))
        if !sampleData.isEmpty {
            data.append(writeBoxRaw("mdat", payload: sampleData))
        }
        return data
    }

    /// Build a CRM whose moov already has its full byte sequence wired up.
    private func buildCRMWithMoovChildren(moovChildren: Data, brand: String = "crx ") -> Data {
        var mvhd = Data([0, 0, 0, 0])
        mvhd.append(Data(repeating: 0, count: 96))
        var children = writeBoxRaw("mvhd", payload: mvhd)
        children.append(moovChildren)
        var data = Data()
        data.append(writeBoxRaw("ftyp", payload: Data(brand.utf8) + Data([0, 0, 0, 0])))
        data.append(writeBoxRaw("moov", payload: children))
        return data
    }

    /// Construct a `trak` whose sample-table boxes point to a single chunk
    /// at `chunkOffset` containing `sampleSizes.count` consecutive samples.
    private func buildCTMDTrak(sampleSizes: [UInt32], chunkOffset: UInt32) -> Data {
        // hdlr: 4 (FullBox) + 4 (pre_defined) + 4 (handler="meta") + 12 (reserved) + 1 (null terminator)
        var hdlr = Data(repeating: 0, count: 4 + 4)
        hdlr.append(Data("meta".utf8))
        hdlr.append(Data(repeating: 0, count: 12))
        hdlr.append(0x00) // empty name string, null terminated

        // stsd: FullBox + entry_count(1) + sample entry [size=16, type=CTMD, reserved(6), data_ref_idx(2)]
        var stsd = Data(repeating: 0, count: 4)
        stsd.append(uint32BE(1)) // entry_count
        var sampleEntry = uint32BE(16)
        sampleEntry.append(Data("CTMD".utf8))
        sampleEntry.append(Data(repeating: 0, count: 6)) // reserved
        sampleEntry.append(uint16BE(1)) // data_reference_index
        stsd.append(sampleEntry)

        // stsz: FullBox + sample_size(0) + sample_count + per-sample sizes
        var stsz = Data(repeating: 0, count: 4) // version+flags
        stsz.append(uint32BE(0)) // sample_size = 0 → use per-sample table
        stsz.append(uint32BE(UInt32(sampleSizes.count)))
        for size in sampleSizes {
            stsz.append(uint32BE(size))
        }

        // stsc: FullBox + entry_count(1) + entry [first_chunk=1, samples_per_chunk=N, sample_description_index=1]
        var stsc = Data(repeating: 0, count: 4)
        stsc.append(uint32BE(1))
        stsc.append(uint32BE(1)) // first_chunk
        stsc.append(uint32BE(UInt32(sampleSizes.count))) // samples_per_chunk
        stsc.append(uint32BE(1)) // sample_description_index

        // stco: FullBox + entry_count(1) + offset
        var stco = Data(repeating: 0, count: 4)
        stco.append(uint32BE(1))
        stco.append(uint32BE(chunkOffset))

        var stbl = writeBoxRaw("stsd", payload: stsd)
        stbl.append(writeBoxRaw("stsz", payload: stsz))
        stbl.append(writeBoxRaw("stsc", payload: stsc))
        stbl.append(writeBoxRaw("stco", payload: stco))

        var minf = writeBoxRaw("stbl", payload: stbl)

        var mdia = writeBoxRaw("hdlr", payload: hdlr)
        mdia.append(writeBoxRaw("minf", payload: minf))

        return writeBoxRaw("trak", payload: writeBoxRaw("mdia", payload: mdia))
    }

    /// Wrap a JPEG payload into the THMB/PRVW header layout
    /// (version(4) + width(2) + height(2) + jpegSize(4) + padding(2) + jpeg).
    private func buildJPEGBoxBody(jpeg: Data, width: UInt16, height: UInt16) -> Data {
        var body = uint32BE(0) // version
        body.append(uint16BE(width))
        body.append(uint16BE(height))
        body.append(uint32BE(UInt32(jpeg.count)))
        body.append(uint16BE(0)) // padding
        body.append(jpeg)
        return body
    }

    // MARK: - CTMD record builders

    private func makeCTMDRecord(type: UInt16, payload: Data) -> Data {
        var record = Data()
        let recordSize = UInt32(12 + payload.count)
        record.append(uint32LE(recordSize))
        record.append(uint16LE(type))
        record.append(uint16LE(0)) // tiff_flag
        record.append(uint16LE(1)) // reserved
        record.append(uint16LE(0)) // unknown
        record.append(payload)
        return record
    }

    private func makeTimestampPayload(year: UInt16, month: UInt8, day: UInt8, hour: UInt8, minute: UInt8, second: UInt8, hundredths: UInt8) -> Data {
        var payload = Data()
        payload.append(uint16LE(0)) // unknown
        payload.append(uint16LE(year))
        payload.append(month)
        payload.append(day)
        payload.append(hour)
        payload.append(minute)
        payload.append(second)
        payload.append(hundredths)
        payload.append(uint16LE(0)) // unknown
        return payload
    }

    private func makeFocalPayload(num: UInt16, den: UInt16) -> Data {
        var payload = uint16LE(num)
        payload.append(uint16LE(den))
        payload.append(Data(repeating: 0, count: 8)) // unknown trailing
        return payload
    }

    private func makeExposurePayload(fNum: UInt16, fDen: UInt16, expNum: UInt16, expDen: UInt16, iso: UInt32) -> Data {
        var payload = uint16LE(fNum)
        payload.append(uint16LE(fDen))
        payload.append(uint16LE(expNum))
        payload.append(uint16LE(expDen))
        payload.append(uint32LE(iso))
        payload.append(Data(repeating: 0, count: 16)) // padding to match real-world record size
        return payload
    }

    // MARK: - TIFF builders

    /// Build a minimal little-endian TIFF with the given IFD entries. Strings
    /// (`type == .ascii`) are stored with their length in `count` and either
    /// inline (≤4 bytes) or via offset.
    private func buildTIFF(entries: [(tag: UInt16, type: TIFFDataType, value: Data)]) -> Data {
        var data = Data()
        data.append(Data("II".utf8)) // little-endian
        data.append(uint16LE(42))    // magic
        data.append(uint32LE(8))     // first IFD offset

        // IFD: 2-byte count + 12-byte entries + 4-byte next-IFD offset.
        let ifdHeaderSize = 2 + entries.count * 12 + 4
        var entryRecords = Data()
        var offsetData = Data()
        var nextOffset = UInt32(8 + ifdHeaderSize)

        for entry in entries {
            entryRecords.append(uint16LE(entry.tag))
            entryRecords.append(uint16LE(entry.type.rawValue))
            // For ascii strings, count is byte length (incl null terminator).
            let count: UInt32 = (entry.type == .ascii) ? UInt32(entry.value.count) : UInt32(entry.value.count / max(entry.type.unitSize, 1))
            entryRecords.append(uint32LE(count))

            let totalSize = entry.value.count
            if totalSize <= 4 {
                var inline = entry.value
                while inline.count < 4 { inline.append(0) }
                entryRecords.append(inline)
            } else {
                entryRecords.append(uint32LE(nextOffset))
                offsetData.append(entry.value)
                nextOffset += UInt32(totalSize)
            }
        }

        data.append(uint16LE(UInt16(entries.count)))
        data.append(entryRecords)
        data.append(uint32LE(0)) // nextIFDOffset
        data.append(offsetData)
        return data
    }

    private func stringValue(_ s: String) -> Data {
        var d = Data(s.utf8)
        d.append(0) // null terminator
        return d
    }

    // MARK: - Byte helpers

    private func writeBoxRaw(_ type: String, payload: Data) -> Data {
        var out = Data()
        let size = UInt32(8 + payload.count)
        out.append(uint32BE(size))
        out.append(Data(type.utf8))
        out.append(payload)
        return out
    }

    private func uint16BE(_ v: UInt16) -> Data {
        Data([UInt8(v >> 8), UInt8(v & 0xFF)])
    }

    private func uint32BE(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private func uint16LE(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    private func uint32LE(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
}
