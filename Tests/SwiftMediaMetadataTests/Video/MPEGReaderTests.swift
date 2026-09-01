import XCTest
@testable import SwiftMediaMetadata

/// MPEG-TS container parse tests driven by synthetic PAT/PMT byte fixtures —
/// no ffmpeg dependency so CI stays green on bare runners.
final class MPEGReaderTests: XCTestCase {

    // MARK: - H.264 SPS

    /// Real-world H.264 SPS pulled from
    /// `~/Downloads/n-drapholmen-290426-two-card1-proxy.ts` via
    /// `ffmpeg -bsf:v filter_units=pass_types=7`. Profile Main, level
    /// 4.0, 1440×1080 (90×68 macroblocks with crop_bottom=4 chroma
    /// units), SAR 4:3 → DAR 16:9, 25 fps from VUI timing.
    private static let drapholmenH264SPS: [UInt8] = [
        0x4D, 0x40, 0x28, 0xDA, 0x01, 0x68, 0x08, 0x9F, 0x97, 0x0E,
        0x6A, 0x02, 0x02, 0x02, 0x80, 0x00, 0x00, 0x03, 0x00, 0x80,
        0x00, 0x00, 0x19, 0x07, 0x8C, 0x19, 0x50,
    ]

    func testParseH264SPSExtractsResolutionProfileFrameRateAspect() {
        let raw = Data(MPEGReaderTests.drapholmenH264SPS)
        let rbsp = MPEGBitstream.stripEmulationPrevention(raw)
        let f = MPEGBitstream.parseH264SPS(rbsp)
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.profile, "Main")
        XCTAssertEqual(f?.level, "4.0")
        XCTAssertEqual(f?.width, 1440)
        XCTAssertEqual(f?.height, 1080)
        XCTAssertEqual(f?.chromaSubsampling, "4:2:0")
        XCTAssertEqual(f?.bitDepth, 8)
        XCTAssertEqual(f?.fieldOrder, .progressive)
        if let sar = f?.sampleAspect {
            XCTAssertEqual(sar.0, 4)
            XCTAssertEqual(sar.1, 3)
        } else {
            XCTFail("expected sample aspect ratio from SPS VUI")
        }
        if let dar = f?.displayAspect {
            XCTAssertEqual(dar.0, 16)
            XCTAssertEqual(dar.1, 9)
        } else {
            XCTFail("expected display aspect ratio derived from SAR×size")
        }
        XCTAssertNotNil(f?.frameRate)
        if let fps = f?.frameRate {
            XCTAssertEqual(fps, 25.0, accuracy: 0.001)
        }
    }

    // MARK: - HEVC SPS

    /// Real-world H.265 SPS pulled from `~/Downloads/HGT_test_fra_DVR_CR.mov`
    /// via `ffmpeg -c:v copy -bsf:v hevc_mp4toannexb -f hevc`. Profile
    /// Main 10, level 4.0, 1920×1080, 4:2:0 10-bit, SAR 1:1 → DAR 16:9.
    /// Includes the 2-byte NAL header (`0x42 0x01`, nal_unit_type 33).
    /// Frame rate is *not* signalled in this SPS — most MOV-encoded HEVC
    /// elementary streams carry timing in the container's edit list, not
    /// in the SPS VUI, so `vui_timing_info_present_flag` is 0 here.
    private static let hgtHEVCSPS: [UInt8] = [
        0x42, 0x01, 0x01, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0xB0,
        0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x78, 0xA0, 0x03,
        0xC0, 0x80, 0x11, 0x07, 0xCA, 0xD8, 0x81, 0x5E, 0xE4, 0x59,
        0x56, 0x02, 0xD4, 0x04, 0x04, 0x04, 0x02,
    ]

    /// Real-world HDR10 HEVC SPS pulled from a Blu-ray remux's `hvcC`
    /// `CodecPrivate` (Harry Potter and the Order of the Phoenix 4K UHD,
    /// MakeMKV-muxed). Profile Main 10, level 5.1, 3840×2160, 4:2:0 10-bit,
    /// BT.2020 primaries (9), SMPTE ST 2084 transfer (16), BT.2020-NCL matrix
    /// (9), full scaling_list_data with 32×32 Inter-Y coefficients. The
    /// scaling-list block lives between bits 207–4981 — a previous
    /// off-by-one in `skipHEVCScalingListData` (matrixCount=2 instead of 6 for
    /// sizeId=3) dropped the [3][3] Inter-Y matrix, desyncing the bit cursor
    /// by ~454 bits and silently shifting the VUI block out of reach. This
    /// fixture regression-tests the corrected iteration. Includes the
    /// 2-byte NAL header (`0x42 0x01`).
    private static let hpHDRHEVCSPS: [UInt8] = [
        0x42, 0x01, 0x01, 0x22, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x99, 0xA0, 0x01, 0xE0, 0x20, 0x02, 0x1C, 0x4D, 0x8D, 0x35,
        0x92, 0x4F, 0x84, 0x14, 0x70, 0xF1, 0xC0, 0x90, 0x3B, 0x0E, 0x18, 0x36,
        0x1A, 0x08, 0x42, 0xF0, 0x81, 0x21, 0x00, 0x88, 0x40, 0x10, 0x06, 0xE1,
        0xA3, 0x06, 0xC3, 0x41, 0x08, 0x5C, 0xA0, 0xA0, 0x21, 0x04, 0x41, 0x70,
        0xB0, 0x2A, 0x0A, 0xC2, 0x80, 0x35, 0x40, 0x70, 0x80, 0xE0, 0x07, 0xD0,
        0x2B, 0x41, 0x80, 0xA8, 0x20, 0x0B, 0x85, 0x81, 0x50, 0x56, 0x14, 0x01,
        0xAA, 0x03, 0x84, 0x07, 0x00, 0x3E, 0x81, 0x58, 0xA1, 0x0D, 0x35, 0xE9,
        0xE8, 0x60, 0xD7, 0x43, 0x03, 0x41, 0xB1, 0xB8, 0xC0, 0xD0, 0x70, 0x3A,
        0x1B, 0x1B, 0x18, 0x1A, 0x0E, 0x43, 0x21, 0x30, 0xC8, 0x60, 0x24, 0x18,
        0x10, 0x1F, 0x1F, 0x1C, 0x1E, 0x30, 0x74, 0x26, 0x12, 0x0E, 0x0C, 0x04,
        0x30, 0x40, 0x38, 0x10, 0x82, 0x00, 0x94, 0x0F, 0xF0, 0x86, 0x9A, 0xF2,
        0x17, 0x20, 0x48, 0x26, 0x59, 0x02, 0x41, 0x20, 0x98, 0x4F, 0x09, 0x04,
        0x83, 0x81, 0xD0, 0x98, 0x4E, 0x12, 0x09, 0x07, 0x21, 0x90, 0x98, 0x5C,
        0x2C, 0x12, 0x0C, 0x08, 0x0F, 0x8F, 0x8E, 0x0F, 0x18, 0x3A, 0x13, 0x09,
        0x07, 0x06, 0x02, 0x18, 0x20, 0x1C, 0x08, 0x41, 0x00, 0x4A, 0x07, 0xF2,
        0x86, 0x89, 0x4D, 0x08, 0x2C, 0x83, 0x8E, 0x52, 0x18, 0x17, 0x02, 0xF2,
        0xC8, 0x0B, 0x80, 0xDC, 0x06, 0xB0, 0x5F, 0x82, 0xE0, 0x35, 0x03, 0xA0,
        0x66, 0x06, 0xB0, 0x63, 0x06, 0x00, 0x6A, 0x06, 0x40, 0xE0, 0x0B, 0x20,
        0x73, 0x06, 0x60, 0xC8, 0x0E, 0x40, 0x58, 0x03, 0x90, 0x0A, 0xB0, 0x77,
        0x07, 0x40, 0x2A, 0x81, 0xC7, 0xFF, 0xC1, 0x24, 0x34, 0x49, 0x8E, 0x61,
        0x82, 0x62, 0x0C, 0x72, 0x90, 0xC0, 0xB8, 0x17, 0x96, 0x40, 0x5C, 0x06,
        0xE0, 0x35, 0x82, 0xFC, 0x17, 0x01, 0xA8, 0x1D, 0x03, 0x30, 0x35, 0x83,
        0x18, 0x30, 0x03, 0x50, 0x32, 0x07, 0x00, 0x59, 0x03, 0x98, 0x33, 0x06,
        0x40, 0x72, 0x02, 0xC0, 0x1C, 0x80, 0x55, 0x83, 0xB8, 0x3A, 0x01, 0x54,
        0x0E, 0x3F, 0xFE, 0x09, 0x0A, 0x10, 0xE9, 0xAF, 0x4F, 0x43, 0x06, 0xBA,
        0x18, 0x1A, 0x0D, 0x8D, 0xC6, 0x06, 0x83, 0x81, 0xD0, 0xD8, 0xD8, 0xC0,
        0xD0, 0x72, 0x19, 0x09, 0x86, 0x43, 0x01, 0x20, 0xC0, 0x80, 0xF8, 0xF8,
        0xE0, 0xF1, 0x83, 0xA1, 0x30, 0x90, 0x70, 0x60, 0x21, 0x82, 0x01, 0xC0,
        0x84, 0x10, 0x04, 0xA0, 0x7F, 0x84, 0x3A, 0x6B, 0xC8, 0x5C, 0x81, 0x20,
        0x99, 0x64, 0x09, 0x04, 0x82, 0x61, 0x3C, 0x24, 0x12, 0x0E, 0x07, 0x42,
        0x61, 0x38, 0x48, 0x24, 0x1C, 0x86, 0x42, 0x61, 0x70, 0xB0, 0x48, 0x30,
        0x20, 0x3E, 0x3E, 0x38, 0x3C, 0x60, 0xE8, 0x4C, 0x24, 0x1C, 0x18, 0x08,
        0x60, 0x80, 0x70, 0x21, 0x04, 0x01, 0x28, 0x1F, 0xCA, 0x1A, 0x92, 0x9A,
        0x10, 0x59, 0x07, 0x1C, 0xA4, 0x30, 0x2E, 0x05, 0xE5, 0x90, 0x17, 0x01,
        0xB8, 0x0D, 0x60, 0xBF, 0x05, 0xC0, 0x6A, 0x07, 0x40, 0xCC, 0x0D, 0x60,
        0xC6, 0x0C, 0x00, 0xD4, 0x0C, 0x81, 0xC0, 0x16, 0x40, 0xE6, 0x0C, 0xC1,
        0x90, 0x1C, 0x80, 0xB0, 0x07, 0x20, 0x15, 0x60, 0xEE, 0x0E, 0x80, 0x55,
        0x03, 0x8F, 0xFF, 0x82, 0x48, 0x6A, 0x49, 0x8E, 0x61, 0x82, 0x62, 0x0C,
        0x72, 0x90, 0xC0, 0xB8, 0x17, 0x96, 0x40, 0x5C, 0x06, 0xE0, 0x35, 0x82,
        0xFC, 0x17, 0x01, 0xA8, 0x1D, 0x03, 0x30, 0x35, 0x83, 0x18, 0x30, 0x03,
        0x50, 0x32, 0x07, 0x00, 0x59, 0x03, 0x98, 0x33, 0x06, 0x40, 0x72, 0x02,
        0xC0, 0x1C, 0x80, 0x55, 0x83, 0xB8, 0x3A, 0x01, 0x54, 0x0E, 0x3F, 0xFE,
        0x09, 0x0A, 0x10, 0xE9, 0xAF, 0x4F, 0x43, 0x06, 0xBA, 0x18, 0x1A, 0x0D,
        0x8D, 0xC6, 0x06, 0x83, 0x81, 0xD0, 0xD8, 0xD8, 0xC0, 0xD0, 0x72, 0x19,
        0x09, 0x86, 0x43, 0x01, 0x20, 0xC0, 0x80, 0xF8, 0xF8, 0xE0, 0xF1, 0x83,
        0xA1, 0x30, 0x90, 0x70, 0x60, 0x21, 0x82, 0x01, 0xC0, 0x84, 0x10, 0x04,
        0xA0, 0x7F, 0x86, 0xA4, 0x98, 0xE6, 0x18, 0x26, 0x20, 0xC7, 0x29, 0x0C,
        0x0B, 0x81, 0x79, 0x64, 0x05, 0xC0, 0x6E, 0x03, 0x58, 0x2F, 0xC1, 0x70,
        0x1A, 0x81, 0xD0, 0x33, 0x03, 0x58, 0x31, 0x83, 0x00, 0x35, 0x03, 0x20,
        0x70, 0x05, 0x90, 0x39, 0x83, 0x30, 0x64, 0x07, 0x20, 0x2C, 0x01, 0xC8,
        0x05, 0x58, 0x3B, 0x83, 0xA0, 0x15, 0x40, 0xE3, 0xFF, 0xE0, 0x91, 0x11,
        0x5C, 0x96, 0xA5, 0xDE, 0x02, 0xD4, 0x24, 0x40, 0x26, 0xD9, 0x40, 0x00,
        0x13, 0x8D, 0x00, 0x01, 0xD4, 0xC0, 0x3E, 0x13, 0x81, 0x09, 0xC0, 0x00,
        0x04, 0xE3, 0x38, 0x80, 0x00, 0x09, 0xC6, 0x71, 0x00, 0x00, 0x09, 0xC6,
        0x71, 0x00, 0x00, 0x13, 0x8C, 0xE2, 0x8B, 0x84, 0x02, 0x08,
    ]

    /// Locks in two HEVC SPS parser fixes that landed for 1.8.0:
    ///   1. `skipHEVCScalingListData` now iterates `matrixId < 6` for every
    ///      sizeId (the inner step of 3 for sizeId=3 handles the 32×32 case).
    ///   2. `short_term_ref_pic_set` with `inter_ref_pic_set_prediction_flag=1`
    ///      no longer bails out; `NumDeltaPocs[stRpsIdx]` is tracked so chained
    ///      inter-RPS sets can be walked through.
    /// The Harry Potter fixture exercises #1 directly (it has a 32×32 Inter-Y
    /// scaling-list matrix). With the bug present, the bit cursor lands ~450
    /// bits short and `vui_parameters_present_flag` reads as garbage — VUI
    /// color extraction silently produces nil.
    func testParseHEVCSPSExtractsHDR10VUIColorSignalling() {
        let nal = Data(MPEGReaderTests.hpHDRHEVCSPS)
        let raw = nal.subdata(in: 2..<nal.count)
        let rbsp = MPEGBitstream.stripEmulationPrevention(raw)
        guard let f = MPEGBitstream.parseHEVCSPS(rbsp) else {
            XCTFail("parseHEVCSPS returned nil on real-world HDR10 SPS")
            return
        }
        // High Tier — Blu-ray HEVC encodes at tier=1 above level 5.0.
        XCTAssertEqual(f.profile, "Main 10 High Tier")
        XCTAssertEqual(f.width, 3840)
        XCTAssertEqual(f.height, 2160)
        XCTAssertEqual(f.chromaSubsampling, "4:2:0")
        XCTAssertEqual(f.bitDepth, 10)
        // Real VUI fields — these are precisely what ffprobe `-show_streams`
        // reports for this file: `color_primaries: bt2020`,
        // `color_transfer: smpte2084`, `color_space: bt2020nc`,
        // `chroma_location: topleft`.
        XCTAssertEqual(f.color?.primaries, 9,  "BT.2020 primaries")
        XCTAssertEqual(f.color?.transfer,  16, "SMPTE ST 2084 (PQ) transfer")
        XCTAssertEqual(f.color?.matrix,    9,  "BT.2020 non-constant luminance")
        XCTAssertEqual(f.chromaLocation, "topleft")
    }

    func testParseHEVCSPSExtractsResolutionProfileBitDepthAspect() {
        // HEVC NAL header is 2 bytes; parseHEVCSPS expects RBSP starting
        // after the header, mirroring MPEGReader.extractHEVCFields.
        let nal = Data(MPEGReaderTests.hgtHEVCSPS)
        let raw = nal.subdata(in: 2..<nal.count)
        let rbsp = MPEGBitstream.stripEmulationPrevention(raw)
        let f = MPEGBitstream.parseHEVCSPS(rbsp)
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.profile, "Main 10")
        XCTAssertEqual(f?.level, "4")
        XCTAssertEqual(f?.width, 1920)
        XCTAssertEqual(f?.height, 1080)
        XCTAssertEqual(f?.chromaSubsampling, "4:2:0")
        XCTAssertEqual(f?.bitDepth, 10)
        if let sar = f?.sampleAspect {
            XCTAssertEqual(sar.0, 1)
            XCTAssertEqual(sar.1, 1)
        } else {
            XCTFail("expected sample aspect ratio from SPS VUI")
        }
        if let dar = f?.displayAspect {
            XCTAssertEqual(dar.0, 16)
            XCTAssertEqual(dar.1, 9)
        } else {
            XCTFail("expected display aspect ratio derived from SAR×size")
        }
    }

    // MARK: - AAC ADTS

    func testParseAACADTSExtractsProfileSampleRateChannels() {
        // Synthetic ADTS fixed header: profile=LC (aotMinus1=1), sfi=3
        // (48 kHz), channel_configuration=1 (mono).
        // syncword(12) | mpegVer(1) | layer(2) | protection_absent(1)
        // | profile(2) | sfi(4) | private(1) | ch_config(3)
        // | original_copy(1) | home(1) | copyright_id_bit(1)
        // | copyright_id_start(1) | frame_length(13) | buf_fullness(11)
        // | num_raw_data_blocks_in_frame(2)
        // = 7 bytes header (no CRC since protection_absent=1).
        var bytes: [UInt8] = [
            0xFF, 0xF1,                  // sync + version 0 (MPEG-4) + layer 0 + protection_absent 1
            0x4C,                        // profile=01 (LC), sfi=0011 (48k), private=0, ch_config[2]=0
            0x40,                        // ch_config[1:0]=01 → 1 mono, …rest=0
            0x00, 0x00, 0x00,
        ]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 32))
        let f = MPEGBitstream.parseAACADTS(Data(bytes))
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.profile, "LC")
        XCTAssertEqual(f?.sampleRate, 48000)
        XCTAssertEqual(f?.channels, 1)
        XCTAssertEqual(f?.channelLayout, "mono")
    }

    // MARK: - End-to-end pipeline

    /// Build a synthetic TS that exercises the whole path: PAT → PMT
    /// (H.264 + AAC streams + PCR PID), an H.264 PES carrying the real
    /// drapholmen SPS NAL, an AAC PES carrying an ADTS frame, and two
    /// adaptation-field PCR packets (start ≈ 0 s, end ≈ 10 s) so the
    /// parser can derive duration. Verifies the full ffprobe-parity
    /// surface lights up without depending on a real video file.
    func testEndToEndExtractsSPSADTSAndPCRDuration() throws {
        var data = Data()
        data.append(makePATPacket(pmtPID: 0x100))
        data.append(makePMTWithThreeStreams(
            pmtPID: 0x100,
            pcrPID: 0x101,
            videoPID: 0x101,
            audioPID: 0x102
        ))
        // PCR at t=0
        data.append(makePCRPacket(pid: 0x101, pcrSeconds: 0.0))
        // Video PES carrying the SPS NAL
        data.append(makeVideoPES(pid: 0x101, sps: MPEGReaderTests.drapholmenH264SPS))
        // Audio PES carrying an ADTS frame (LC, 48k, mono)
        data.append(makeAudioADTSPES(pid: 0x102))
        // Closing PCR at t=10 to give a known duration
        data.append(makePCRPacket(pid: 0x101, pcrSeconds: 10.0))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftexif-mpegts-e2e-\(UUID().uuidString).ts")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.formatLongName, "MPEG-TS (MPEG-2 Transport Stream)")

        // Video stream: H.264 SPS extraction ran end-to-end.
        XCTAssertEqual(m.videoStreams.count, 1)
        let v = m.videoStreams[0]
        XCTAssertEqual(v.codec, "avc1")
        XCTAssertEqual(v.width, 1440)
        XCTAssertEqual(v.height, 1080)
        XCTAssertEqual(v.profile, "Main")
        XCTAssertEqual(v.chromaSubsampling, "4:2:0")
        XCTAssertEqual(v.bitDepth, 8)
        XCTAssertEqual(v.fieldOrder, .progressive)

        // Audio stream: ADTS extraction ran end-to-end.
        XCTAssertEqual(m.audioStreams.count, 1)
        let a = m.audioStreams[0]
        XCTAssertEqual(a.codec, "aac")
        XCTAssertEqual(a.codecName, "AAC LC")
        XCTAssertEqual(a.profile, "LC")
        XCTAssertEqual(a.sampleRate, 48000)
        XCTAssertEqual(a.channels, 1)

        // PCR-derived duration.
        XCTAssertNotNil(m.duration)
        if let d = m.duration {
            XCTAssertEqual(d, 10.0, accuracy: 0.001)
        }
    }

    // MARK: - Format long name

    func testFormatLongNameForPlainTSDistinguishesFromPS() throws {
        let data = buildTSWithBitRateDescriptor(audioRate: 100, videoRate: 100)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftexif-mpegts-fmt-\(UUID().uuidString).ts")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.formatLongName, "MPEG-TS (MPEG-2 Transport Stream)")
    }

    // MARK: - Maximum-bitrate descriptor (existing)

    /// ISO/IEC 13818-1 maximum_bitrate_descriptor (tag 0x0E) carries the only
    /// bit-rate most DVB streams advertise for AAC and H.264/H.265 elementary
    /// streams. The parser should surface it as AudioStream.bitRate /
    /// VideoStream.bitRate in bits per second (the raw value is in 50 byte/s
    /// units, i.e. multiplied by 400).
    func testMaximumBitRateDescriptorPopulatesStreamBitRate() throws {
        // 1500 units × 400 = 600 000 bits/s = 600 kbps for the AAC stream.
        // 5000 units × 400 = 2 000 000 bits/s = 2 Mbps for the H.264 stream.
        let data = buildTSWithBitRateDescriptor(audioRate: 1500, videoRate: 5000)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftexif-mpegts-\(UUID().uuidString).ts")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.audioStreams.count, 1)
        XCTAssertEqual(m.audioStreams[0].codec, "aac")
        XCTAssertEqual(m.audioStreams[0].bitRate, 600_000)

        XCTAssertEqual(m.videoStreams.count, 1)
        XCTAssertEqual(m.videoStreams[0].codec, "avc1")
        XCTAssertEqual(m.videoStreams[0].bitRate, 2_000_000)
    }

    // MARK: - Synthetic TS builder

    /// Build a 4-packet TS: PAT, PMT with one H.264 video ES and one AAC audio
    /// ES (each carrying a maximum_bitrate_descriptor), plus two null packets
    /// so `isMPEG` sees sync bytes at 0/188/376/564.
    private func buildTSWithBitRateDescriptor(audioRate: UInt32, videoRate: UInt32) -> Data {
        var data = Data()
        data.append(makePATPacket(pmtPID: 0x100))
        data.append(makePMTWithTwoStreams(pmtPID: 0x100,
                                          videoPID: 0x101, videoRate: videoRate,
                                          audioPID: 0x102, audioRate: audioRate))
        data.append(makeNullPacket())
        data.append(makeNullPacket())
        return data
    }

    private func makePATPacket(pmtPID: UInt16) -> Data {
        var section = Data()
        section.append(0x00)                                  // pointer_field
        section.append(0x00)                                  // table_id (PAT)
        section.append(0xB0)                                  // section_syntax=1, length high=0
        section.append(0x0D)                                  // section_length = 13
        section.append(contentsOf: [0x00, 0x01])              // transport_stream_id
        section.append(0xC1)                                  // version + current_next
        section.append(0x00)                                  // section_number
        section.append(0x00)                                  // last_section_number
        section.append(contentsOf: [0x00, 0x01])              // program_number
        section.append(UInt8(0xE0 | ((pmtPID >> 8) & 0x1F)))
        section.append(UInt8(pmtPID & 0xFF))
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // CRC32 (ignored)
        return wrapInTSPacket(pid: 0x0000, payloadUnitStart: true, payload: section)
    }

    private func makePMTWithTwoStreams(pmtPID: UInt16,
                                       videoPID: UInt16, videoRate: UInt32,
                                       audioPID: UInt16, audioRate: UInt32) -> Data {
        let videoDescriptor = makeMaxBitRateDescriptor(units: videoRate)
        let audioDescriptor = makeMaxBitRateDescriptor(units: audioRate)

        var esLoop = Data()
        esLoop.append(esEntry(streamType: 0x1B, pid: videoPID, descriptors: videoDescriptor)) // H.264
        esLoop.append(esEntry(streamType: 0x0F, pid: audioPID, descriptors: audioDescriptor)) // AAC

        let sectionLength = UInt16(2 + 1 + 1 + 1 + 2 + 2 + esLoop.count + 4)

        var section = Data()
        section.append(0x00)                                  // pointer_field
        section.append(0x02)                                  // table_id (PMT)
        section.append(UInt8(0xB0 | ((sectionLength >> 8) & 0x0F)))
        section.append(UInt8(sectionLength & 0xFF))
        section.append(contentsOf: [0x00, 0x01])              // program_number
        section.append(0xC1)                                  // version / current_next
        section.append(0x00)                                  // section_number
        section.append(0x00)                                  // last_section_number
        section.append(contentsOf: [0xE1, 0x00])              // PCR_PID
        section.append(contentsOf: [0xF0, 0x00])              // program_info_length = 0
        section.append(esLoop)
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // CRC32 (ignored)

        return wrapInTSPacket(pid: pmtPID, payloadUnitStart: true, payload: section)
    }

    private func esEntry(streamType: UInt8, pid: UInt16, descriptors: Data) -> Data {
        var entry = Data()
        entry.append(streamType)
        entry.append(UInt8(0xE0 | ((pid >> 8) & 0x1F)))
        entry.append(UInt8(pid & 0xFF))
        let len = UInt16(descriptors.count)
        entry.append(UInt8(0xF0 | ((len >> 8) & 0x0F)))
        entry.append(UInt8(len & 0xFF))
        entry.append(descriptors)
        return entry
    }

    private func makeMaxBitRateDescriptor(units: UInt32) -> Data {
        // Tag 0x0E, length 3, payload = 2 reserved bits set to 11 + 22-bit value.
        var d = Data()
        d.append(0x0E)
        d.append(0x03)
        d.append(UInt8(0xC0 | UInt8((units >> 16) & 0x3F)))
        d.append(UInt8((units >> 8) & 0xFF))
        d.append(UInt8(units & 0xFF))
        return d
    }

    private func makeNullPacket() -> Data {
        wrapInTSPacket(pid: 0x1FFF, payloadUnitStart: false, payload: Data())
    }

    /// PMT with H.264 video + AAC audio + explicit PCR PID. Differs
    /// from `makePMTWithTwoStreams` by omitting the bit-rate descriptors
    /// (the end-to-end test exercises PES parsing, not descriptors).
    private func makePMTWithThreeStreams(
        pmtPID: UInt16,
        pcrPID: UInt16,
        videoPID: UInt16,
        audioPID: UInt16
    ) -> Data {
        var esLoop = Data()
        esLoop.append(esEntry(streamType: 0x1B, pid: videoPID, descriptors: Data()))
        esLoop.append(esEntry(streamType: 0x0F, pid: audioPID, descriptors: Data()))

        let sectionLength = UInt16(2 + 1 + 1 + 1 + 2 + 2 + esLoop.count + 4)

        var section = Data()
        section.append(0x00)                                  // pointer_field
        section.append(0x02)                                  // table_id (PMT)
        section.append(UInt8(0xB0 | ((sectionLength >> 8) & 0x0F)))
        section.append(UInt8(sectionLength & 0xFF))
        section.append(contentsOf: [0x00, 0x01])              // program_number
        section.append(0xC1)                                  // version / current_next
        section.append(0x00)                                  // section_number
        section.append(0x00)                                  // last_section_number
        section.append(UInt8(0xE0 | ((pcrPID >> 8) & 0x1F)))
        section.append(UInt8(pcrPID & 0xFF))
        section.append(contentsOf: [0xF0, 0x00])              // program_info_length = 0
        section.append(esLoop)
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // CRC32 (ignored)

        return wrapInTSPacket(pid: pmtPID, payloadUnitStart: true, payload: section)
    }

    /// TS packet whose adaptation field carries a PCR at the given time
    /// in seconds. PCR base ticks at 90 kHz; extension ticks at 27 MHz.
    private func makePCRPacket(pid: UInt16, pcrSeconds: Double) -> Data {
        // 33-bit pcrBase + 9-bit pcrExt encoding.
        let total27MHz = UInt64(pcrSeconds * 27_000_000.0)
        let pcrBase = total27MHz / 300
        let pcrExt = UInt64(total27MHz % 300)
        // Pack into 6 bytes.
        var pcr = Data()
        pcr.append(UInt8((pcrBase >> 25) & 0xFF))
        pcr.append(UInt8((pcrBase >> 17) & 0xFF))
        pcr.append(UInt8((pcrBase >> 9)  & 0xFF))
        pcr.append(UInt8((pcrBase >> 1)  & 0xFF))
        let baseLowBit = UInt64(pcrBase & 0x1) << 7
        let extHighBit = UInt64((pcrExt >> 8) & 0x1)
        let reserved6: UInt64 = 0x7E
        pcr.append(UInt8(baseLowBit | reserved6 | extHighBit))
        pcr.append(UInt8(pcrExt & 0xFF))

        // Build packet with adaptation field + 1 stuffing byte to reach 188.
        var packet = Data(capacity: 188)
        packet.append(0x47)
        packet.append(UInt8((pid >> 8) & 0x1F))               // no payload-unit-start
        packet.append(UInt8(pid & 0xFF))
        packet.append(0x20)                                   // adaptation only, no payload
        // adaptation_field_length: 1 flags byte + 6 PCR + stuffing.
        let adFlags: UInt8 = 0x10                             // PCR_flag
        let adBody = Data([adFlags]) + pcr
        let stuffing = 188 - 4 - 1 - adBody.count
        packet.append(UInt8(adBody.count + stuffing))
        packet.append(adBody)
        if stuffing > 0 {
            packet.append(Data(repeating: 0xFF, count: stuffing))
        }
        precondition(packet.count == 188)
        return packet
    }

    /// PES packet wrapping the H.264 SPS as an Annex-B NAL on the given
    /// PID. Caller passes the raw SPS RBSP excluding the NAL header.
    private func makeVideoPES(pid: UInt16, sps: [UInt8]) -> Data {
        // Build the PES payload: PES header + Annex-B start code + NAL
        // header byte (0x67 = nal_ref_idc=3, nal_unit_type=7) + SPS RBSP.
        var pes = Data()
        pes.append(contentsOf: [0x00, 0x00, 0x01, 0xE0])      // start code + stream_id E0 (video)
        pes.append(contentsOf: [0x00, 0x00])                  // PES_packet_length=0 (unbounded)
        pes.append(0x80)                                       // marker / scrambling
        pes.append(0x00)                                       // PTS_DTS_flags=00
        pes.append(0x00)                                       // PES_header_data_length=0
        pes.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x67]) // Annex-B SPS NAL
        pes.append(contentsOf: sps)
        return wrapInTSPacket(pid: pid, payloadUnitStart: true, payload: pes)
    }

    /// PES packet wrapping a single ADTS frame (LC, 48 kHz, mono) on the
    /// given PID. Mirrors the test fixture used by `testParseAACADTS…`.
    private func makeAudioADTSPES(pid: UInt16) -> Data {
        var pes = Data()
        pes.append(contentsOf: [0x00, 0x00, 0x01, 0xC0])      // start code + stream_id C0 (audio)
        pes.append(contentsOf: [0x00, 0x00])
        pes.append(0x80)
        pes.append(0x00)
        pes.append(0x00)
        // ADTS fixed header: profile=LC, sfi=3 (48k), ch_config=1 (mono).
        pes.append(contentsOf: [0xFF, 0xF1, 0x4C, 0x40, 0x00, 0x00, 0x00] as [UInt8])
        // A bit of padding so the per-PES-cap heuristic triggers.
        pes.append(Data(repeating: 0, count: 32))
        return wrapInTSPacket(pid: pid, payloadUnitStart: true, payload: pes)
    }

    private func wrapInTSPacket(pid: UInt16, payloadUnitStart: Bool, payload: Data) -> Data {
        precondition(payload.count <= 184, "TS payload exceeds 184 bytes")
        var packet = Data(capacity: 188)
        packet.append(0x47)
        let pus: UInt8 = payloadUnitStart ? 0x40 : 0x00
        packet.append(pus | UInt8((pid >> 8) & 0x1F))
        packet.append(UInt8(pid & 0xFF))
        packet.append(0x10)                                   // adaptation=01 (payload only)
        packet.append(payload)
        if packet.count < 188 {
            packet.append(Data(repeating: 0xFF, count: 188 - packet.count))
        }
        return packet
    }
}
