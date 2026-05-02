import XCTest
@testable import SwiftExif

/// R3D (RED RAW) clip-header reader tests. Fixtures are built by hand —
/// the format is small (1202-byte RED2 atom) and we want to verify the
/// per-tag decoders without committing a multi-GB binary to the repo.
final class R3DReaderTests: XCTestCase {

    // MARK: - Detection

    func testR3DDetectionAcceptsRED2() {
        var d = Data([0, 0, 0x04, 0xB2]) // outer atom size
        d.append(Data("RED2".utf8))
        XCTAssertTrue(R3DReader.isR3D(d))
    }

    func testR3DDetectionAcceptsRED1() {
        var d = Data([0, 0, 0x04, 0xB2])
        d.append(Data("RED1".utf8))
        XCTAssertTrue(R3DReader.isR3D(d))
    }

    func testR3DDetectionRejectsRED3() {
        // Future-proof: only RED1 / RED2 are accepted; an unknown variant
        // shouldn't get routed to this reader.
        var d = Data([0, 0, 0x04, 0xB2])
        d.append(Data("RED3".utf8))
        XCTAssertFalse(R3DReader.isR3D(d))
    }

    func testR3DDetectionRejectsTooShort() {
        XCTAssertFalse(R3DReader.isR3D(Data([0, 0, 0x04, 0xB2, 0x52])))
    }

    func testFormatDetectorRoutesR3D() {
        let d = makeMinimalR3D(records: [])
        XCTAssertEqual(FormatDetector.detectVideo(d), .r3d)
    }

    func testExtensionDetectorRoutesR3D() {
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("r3d"), .r3d)
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("R3D"), .r3d)
    }

    /// Nikon Z8/Z9 ship files with a `.R3D` extension that are actually
    /// Nikon RAW Video (N-RAW) wrapped in MP4 — `ftyp niko` brand and
    /// codec FourCC `NR3D`. They share nothing with REDCODE except the
    /// file extension. R3DReader's magic-byte check rejects them
    /// (correctly), they fall through to MP4Parser, and the codec
    /// promotion in `VideoMetadata.read` upgrades the format from
    /// `.mp4` to `.nikonRaw` so callers can tell the two apart.
    func testNikonRAWPromotedFromMP4() throws {
        let data = buildNikonRAWMP4(width: 6060, height: 3410)
        // R3DReader must NOT claim this — only RED2/RED1 magic counts.
        XCTAssertFalse(R3DReader.isR3D(data))
        let m = try VideoMetadata.read(from: data)
        XCTAssertEqual(m.format, .nikonRaw)
        XCTAssertEqual(m.formatLongName, "Nikon RAW")
        XCTAssertEqual(m.videoStreams.first?.codec, "NR3D")
    }

    /// Build a minimal MP4 with `ftyp niko` and an `NR3D` codec FourCC in
    /// the visual sample entry — the smallest fixture that triggers the
    /// codec-based `.mp4 → .nikonRaw` promotion.
    private func buildNikonRAWMP4(width: Int, height: Int) -> Data {
        // ftyp: brand "niko" + minor version 0 + compatible "niko"
        var ftypPayload = Data("niko".utf8)
        ftypPayload.append(Data([0, 0, 0, 0]))
        ftypPayload.append(Data("niko".utf8))
        var data = Data()
        data.append(uint32BE(UInt32(8 + ftypPayload.count)))
        data.append(Data("ftyp".utf8))
        data.append(ftypPayload)

        // mvhd
        var mvhd = Data([0x00, 0x00, 0x00, 0x00])
        mvhd.append(Data(repeating: 0, count: 96))
        let mvhdBox = box("mvhd", payload: mvhd)

        // tkhd with width/height (16.16 fixed)
        var tkhd = Data([0x00, 0x00, 0x00, 0x03])
        tkhd.append(Data(repeating: 0, count: 76))
        tkhd.append(uint32BE(UInt32(width) << 16))
        tkhd.append(uint32BE(UInt32(height) << 16))
        let tkhdBox = box("tkhd", payload: tkhd)

        // hdlr type "vide"
        var hdlr = Data([0x00, 0x00, 0x00, 0x00])
        hdlr.append(Data(repeating: 0, count: 4))
        hdlr.append(Data("vide".utf8))
        hdlr.append(Data(repeating: 0, count: 12))
        let hdlrBox = box("hdlr", payload: hdlr)

        // stsd with one NR3D entry
        var stsd = Data([0x00, 0x00, 0x00, 0x00])
        stsd.append(uint32BE(1))         // entry_count
        stsd.append(uint32BE(16))        // entry size
        stsd.append(Data("NR3D".utf8))   // codec FourCC
        stsd.append(Data(repeating: 0, count: 8))
        let stsdBox = box("stsd", payload: stsd)

        let stbl = box("stbl", payload: stsdBox)
        let minf = box("minf", payload: stbl)
        let mdia = box("mdia", payload: hdlrBox + minf)
        let trak = box("trak", payload: tkhdBox + mdia)
        let moov = box("moov", payload: mvhdBox + trak)
        data.append(moov)
        return data
    }

    private func box(_ type: String, payload: Data) -> Data {
        var d = uint32BE(UInt32(8 + payload.count))
        d.append(Data(type.utf8))
        d.append(payload)
        return d
    }

    // MARK: - End-to-end parse

    func testParseAllKnownTags() throws {
        // One record per supported tag — verifies the dispatch table maps
        // each to the right place (camera.* field vs. slate entry).
        let data = makeMinimalR3D(
            width: 5760,
            height: 3240,
            audioSampleRate: 48000,
            records: [
                tlvString(0x1006, "KXZBK000532"),     // SerialNumber
                tlvString(0x1019, "B"),               // CameraType
                tlvString(0x101a, "004"),             // ReelNumber
                tlvString(0x101b, "036"),             // Take
                tlvString(0x1023, "20250808"),        // DateCreated
                tlvString(0x1024, "194623"),          // TimeCreated
                tlvString(0x1025, "2.0.3"),           // FirmwareVersion
                tlvString(0x1029, "12:34:56:00"),     // ReelTimecode
                tlvString(0x102a, "RED PRO CFexpress"),
                tlvString(0x1032, "H38AGCXABGA0065"),
                tlvString(0x1033, "RD4.15"),
                tlvString(0x1056, "B004_B036_0808P8_001.R3D"),
                tlvString(0x1070, "NIKKOR Z 50mm f/1.2 S"),
                tlvString(0x1086, "6K 16:9"),
                tlvString(0x10a0, "KOMODO-X 6K S35"),
                tlvString(0x10a1, "KOMODO-X S35"),
                tlvString(0x10ad, "01:06:15:10"),
                tlvString(0x10ae, "19:45:12:00"),
                tlvString(0x10be, "MQ"),
                tlvFloat32(0x200d, 5600.0),           // ColorTemperature
                tlvFloat32(0x2066, 23.976),           // OriginalFrameRate
                tlvCropArea(0x4037, x: 0, y: 0, width: 5760, height: 3240),
                tlvUInt16(0x403b, 800),               // ISO
                tlvUInt16(0x606c, 0),                 // FocusDistance
            ]
        )

        let m = try VideoMetadata.read(from: data)
        XCTAssertEqual(m.format, .r3d)
        XCTAssertEqual(m.formatLongName, "RED RAW")
        XCTAssertEqual(m.videoWidth, 5760)
        XCTAssertEqual(m.videoHeight, 3240)
        XCTAssertEqual(m.audioSampleRate, 48000)
        XCTAssertEqual(m.audioStreams.count, 1)

        let cam = try XCTUnwrap(m.camera)
        XCTAssertEqual(cam.deviceManufacturer, "RED")
        XCTAssertEqual(cam.deviceModelName, "KOMODO-X 6K S35")
        XCTAssertEqual(cam.deviceSerialNumber, "KXZBK000532")
        XCTAssertEqual(cam.lensModelName, "NIKKOR Z 50mm f/1.2 S")
        XCTAssertEqual(cam.captureFps ?? 0, 23.976, accuracy: 0.001)
        XCTAssertEqual(m.frameRate ?? 0, 23.976, accuracy: 0.001)

        // 0x1023 + 0x1024 combine into a UTC creation date.
        XCTAssertNotNil(cam.creationDate)
        if let cd = cam.creationDate {
            let f = ISO8601DateFormatter()
            XCTAssertEqual(f.string(from: cd), "2025-08-08T19:46:23Z")
        }

        // Three timecode TLVs (ReelTimecode, RecordTimecode, PlaybackTimecode)
        // each become a Timecode entry tagged with .redR3D.
        XCTAssertEqual(m.timecodes.count, 3)
        XCTAssertTrue(m.timecodes.allSatisfy { $0.source == .redR3D })
        XCTAssertEqual(m.timecode, "12:34:56:00") // first inserted (ReelTimecode)

        // Slate keys land on userMetaNames in declaration order. Spot-check
        // a handful — the strings carry the `red_` prefix to disambiguate
        // from BMD/Sony slate fields in mixed-format exports.
        let pairs = Dictionary(
            uniqueKeysWithValues: zip(cam.userMetaNames, cam.userMetaContents)
        )
        XCTAssertEqual(pairs["red_camera_type"], "B")
        XCTAssertEqual(pairs["red_reel_number"], "004")
        XCTAssertEqual(pairs["red_take"], "036")
        XCTAssertEqual(pairs["red_iso"], "800")
        XCTAssertEqual(pairs["red_quality"], "MQ")
        XCTAssertEqual(pairs["red_video_format"], "6K 16:9")
        XCTAssertEqual(pairs["red_crop_area"], "5760x3240+0+0")
        XCTAssertEqual(pairs["red_color_temperature_k"], "5600")
        XCTAssertEqual(pairs["red_focus_distance_mm"], "0")
        XCTAssertEqual(pairs["red_original_filename"], "B004_B036_0808P8_001.R3D")
        XCTAssertEqual(pairs["red_record_timecode"], "01:06:15:10")
        XCTAssertEqual(pairs["red_playback_timecode"], "19:45:12:00")
    }

    func testEmptyStringTagIsSuppressed() throws {
        // V-RAPTOR clips often carry CameraOperator (0x107c) as an empty
        // string; an empty value shouldn't add a slate entry.
        let data = makeMinimalR3D(records: [tlvString(0x107c, "")])
        let m = try VideoMetadata.read(from: data)
        let cam = try XCTUnwrap(m.camera)
        XCTAssertFalse(cam.userMetaNames.contains("red_camera_operator"))
    }

    func testUnknownTagIsSkippedWithoutBreakingAlignment() throws {
        // An unknown tag mid-stream must not desynchronise the TLV walk.
        // After a 6-byte unknown record, the SerialNumber that follows
        // should still land correctly on `camera.deviceSerialNumber`.
        let data = makeMinimalR3D(records: [
            tlvRaw(0x9999, valueBytes: Data([0x01, 0x02, 0x03])),
            tlvString(0x1006, "ABC123"),
        ])
        let m = try VideoMetadata.read(from: data)
        XCTAssertEqual(m.camera?.deviceSerialNumber, "ABC123")
    }

    func testTruncatedRecordStopsParsing() throws {
        // A record whose declared length runs past the RED2 payload must
        // be ignored — and the parse must not crash. We hand-build a TLV
        // with len=99 but only 4 bytes of value, then a valid record;
        // the parser should bail at the bogus record without consuming
        // the second one.
        var bogus = Data([0x63, 0x10, 0x06]) // len=99, tag=0x1006
        bogus.append(Data([0x41, 0x42, 0x43, 0x00])) // 4 byte payload
        // Append a valid SerialNumber record after it — which the parser
        // should never reach because the bogus record claims the rest.
        let valid = tlvString(0x1006, "REACHED")
        let data = makeMinimalR3D(records: [bogus, valid])
        let m = try VideoMetadata.read(from: data)
        // SerialNumber must be nil — parser bailed without misreading
        // the truncated record as a half-decoded string.
        XCTAssertNil(m.camera?.deviceSerialNumber)
    }

    // MARK: - Fixture helpers

    /// Build a single TLV record. Total length = 1 (len byte) + 2 (tag) +
    /// value count, and the length byte caps at 255 — fine for every R3D
    /// TLV we've seen (max is around 28 bytes for the original-filename
    /// string).
    private func tlvRaw(_ tag: UInt16, valueBytes: Data) -> Data {
        let total = 3 + valueBytes.count
        precondition(total <= 255, "TLV record too long for 1-byte length")
        var d = Data([UInt8(total), UInt8(tag >> 8), UInt8(tag & 0xFF)])
        d.append(valueBytes)
        return d
    }

    private func tlvString(_ tag: UInt16, _ value: String) -> Data {
        var bytes = Data(value.utf8)
        bytes.append(0) // null terminator
        return tlvRaw(tag, valueBytes: bytes)
    }

    private func tlvFloat32(_ tag: UInt16, _ value: Float) -> Data {
        let bits = value.bitPattern
        let bytes = Data([
            UInt8(truncatingIfNeeded: bits >> 24),
            UInt8(truncatingIfNeeded: bits >> 16),
            UInt8(truncatingIfNeeded: bits >> 8),
            UInt8(truncatingIfNeeded: bits),
            0x00, // trailing padding byte the camera always writes
        ])
        return tlvRaw(tag, valueBytes: bytes)
    }

    private func tlvUInt16(_ tag: UInt16, _ value: UInt16) -> Data {
        let bytes = Data([
            UInt8(value >> 8),
            UInt8(value & 0xFF),
            0x00, // trailing padding
        ])
        return tlvRaw(tag, valueBytes: bytes)
    }

    private func tlvCropArea(_ tag: UInt16, x: UInt16, y: UInt16, width: UInt16, height: UInt16) -> Data {
        var bytes = Data()
        for v in [x, y, width, height] {
            bytes.append(UInt8(v >> 8))
            bytes.append(UInt8(v & 0xFF))
        }
        bytes.append(0x00) // trailing pad
        return tlvRaw(tag, valueBytes: bytes)
    }

    /// Build a synthetic R3D RED2 atom: outer 8-byte size+type header,
    /// 4-byte sentinel, 16+16+16-byte UUID block, the rdi/rda/rdx
    /// sub-atoms with synthesized width/height/sample-rate, a 3-byte TLV
    /// preamble, then the records, then zero-padding to size 1202 bytes.
    private func makeMinimalR3D(
        width: UInt32 = 1920,
        height: UInt32 = 1080,
        audioSampleRate: UInt32 = 48000,
        records: [Data]
    ) -> Data {
        var d = Data(capacity: 1202)
        // outer atom header: size + "RED2"
        let size: UInt32 = 1202
        d.append(contentsOf: [
            UInt8(size >> 24), UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF),
        ])
        d.append(Data("RED2".utf8))

        // 0x08..0x3F : version sentinel + 3×16 byte UUID block (zeros)
        d.append(Data(repeating: 0, count: 0x40 - d.count))

        // 0x40..0x47 : 4-byte version (`01 01 02 01`) + "rdi" + 0x01
        d.append(Data([0x01, 0x01, 0x02, 0x01]))
        d.append(Data("rdi".utf8))
        d.append(0x01)

        // 0x48..0x5B : rdi payload — uint32 pad + width + height + 8 bytes of trailing junk
        d.append(uint32BE(0))
        d.append(uint32BE(width))
        d.append(uint32BE(height))
        d.append(uint32BE(0))
        d.append(uint32BE(24000))

        // 0x5C..0x6F : "rda" + 01 + audio header (uint64 sample_count + uint32 sample_rate + uint32 ?)
        d.append(Data("rda".utf8))
        d.append(0x01)
        d.append(Data(repeating: 0, count: 8))
        d.append(uint32BE(audioSampleRate))
        d.append(uint32BE(0))

        // 0x70..0x8F : two "rdx" sub-atoms with the "RED " marker
        for ver: UInt8 in [0x01, 0x02] {
            d.append(Data("rdx".utf8))
            d.append(ver)
            d.append(Data(repeating: 0, count: 7))
            d.append(0x06)
            d.append(Data("RED ".utf8))
        }

        // 0x90..0x92 : 3-byte preamble before TLVs (camera writes a
        // record-count-ish value here; the parser treats it as opaque).
        d.append(Data([0x04, 0x00, 0x00]))

        // 0x93+ : TLV records
        for r in records {
            d.append(r)
        }

        // Pad up to RED2's 1202-byte size with zeros.
        if d.count < Int(size) {
            d.append(Data(repeating: 0, count: Int(size) - d.count))
        }
        return d
    }

    private func uint32BE(_ v: UInt32) -> Data {
        Data([
            UInt8(v >> 24),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8(v & 0xFF),
        ])
    }
}
