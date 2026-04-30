import XCTest
@testable import SwiftExif

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
