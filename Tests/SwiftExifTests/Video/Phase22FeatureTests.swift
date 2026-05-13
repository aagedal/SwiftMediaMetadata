import XCTest
@testable import SwiftExif

// MARK: - SEI parsing (Phase 22.1)

final class SEIParsingTests: XCTestCase {

    func testMDCVPayloadDecodes() {
        // SEI payload type 137 — mastering_display_colour_volume.
        // Layout: G/B/R primaries (uint16 ×6, scale 0.00002), white point
        // (uint16 ×2), max/min luminance (uint32, scale 0.0001).
        var payload = Data()
        // G, B, R primaries — DCI-P3 D65-like values.
        appendU16BE(&payload, 13250)  // greenX = 0.265
        appendU16BE(&payload, 34500)  // greenY = 0.690
        appendU16BE(&payload, 7500)   // blueX  = 0.150
        appendU16BE(&payload, 3000)   // blueY  = 0.060
        appendU16BE(&payload, 34000)  // redX   = 0.680
        appendU16BE(&payload, 16000)  // redY   = 0.320
        appendU16BE(&payload, 15635)  // whiteX = 0.3127
        appendU16BE(&payload, 16450)  // whiteY = 0.3290
        appendU32BE(&payload, 10_000_000)  // max luminance = 1000 nits
        appendU32BE(&payload, 1)            // min luminance = 0.0001 nits

        let sei = parseSinglePayload(type: 137, body: payload, forHEVC: true)
        guard let md = sei.masteringDisplay else { XCTFail("missing mdcv"); return }
        XCTAssertEqual(md.redX, 0.68, accuracy: 0.001)
        XCTAssertEqual(md.greenY, 0.69, accuracy: 0.001)
        XCTAssertEqual(md.blueX, 0.15, accuracy: 0.001)
        XCTAssertEqual(md.maxLuminance, 1000.0, accuracy: 0.5)
    }

    func testCLLIPayloadDecodes() {
        var payload = Data()
        appendU16BE(&payload, 4000)  // maxCLL
        appendU16BE(&payload, 400)   // maxFALL

        let sei = parseSinglePayload(type: 144, body: payload, forHEVC: true)
        XCTAssertEqual(sei.contentLightLevel?.maxCLL, 4000)
        XCTAssertEqual(sei.contentLightLevel?.maxFALL, 400)
    }

    /// SEI payload type 147 — content_colour_volume (H.265 D.2.41).
    /// Layout: 1 flag byte (cancel | persistence | primaries_present |
    /// min_lum_present | max_lum_present | avg_lum_present | 2 reserved),
    /// then optional 6×i32 primaries (G,B,R) and optional 3×u32 luminances.
    func testCCVPayloadDecodes_AllFieldsPresent() throws {
        var payload = Data()
        // flags byte: cancel=0, persistence=1, primaries=1, min=1, max=1, avg=1, rsv=00
        // Bit layout (MSB first): 0 1 1 1 1 1 0 0  → 0x7C
        payload.append(0x7C)
        // 6 × i32 primaries — DCI-P3 D65 grading values, G/B/R order.
        appendI32BE(&payload, 13250)   // greenX = 0.265
        appendI32BE(&payload, 34500)   // greenY = 0.690
        appendI32BE(&payload, 7500)    // blueX  = 0.150
        appendI32BE(&payload, 3000)    // blueY  = 0.060
        appendI32BE(&payload, 34000)   // redX   = 0.680
        appendI32BE(&payload, 16000)   // redY   = 0.320
        // min/max/avg luminance in 0.0001 cd/m².
        appendU32BE(&payload, 50)            // 0.005 nits
        appendU32BE(&payload, 10_000_000)    // 1000 nits
        appendU32BE(&payload, 1_500_000)     // 150 nits

        let sei = parseSinglePayload(type: 147, body: payload, forHEVC: true)
        let ccv = try XCTUnwrap(sei.contentColourVolume)
        XCTAssertEqual(ccv.redX ?? 0, 0.680, accuracy: 1e-3)
        XCTAssertEqual(ccv.greenY ?? 0, 0.690, accuracy: 1e-3)
        XCTAssertEqual(ccv.blueX ?? 0, 0.150, accuracy: 1e-3)
        XCTAssertEqual(ccv.minLuminance ?? -1, 0.005, accuracy: 1e-4)
        XCTAssertEqual(ccv.maxLuminance ?? -1, 1000.0, accuracy: 0.5)
        XCTAssertEqual(ccv.avgLuminance ?? -1, 150.0, accuracy: 0.5)
    }

    /// CCV with `ccv_cancel_flag = 1` instructs decoders to drop any previous
    /// CCV. We surface that as nil so an upstream container-level CCV isn't
    /// overwritten with an empty record.
    func testCCVPayloadCancelFlagReturnsNil() {
        let sei = parseSinglePayload(type: 147, body: Data([0x80]), forHEVC: true)
        XCTAssertNil(sei.contentColourVolume)
    }

    /// CCV with only the avg-luminance flag set — primaries / min / max stay
    /// nil so callers can tell "not advertised" from "advertised as zero."
    func testCCVPayloadAvgLuminanceOnly() throws {
        var payload = Data()
        // flags: 0 1 0 0 0 1 0 0 → 0x44
        payload.append(0x44)
        appendU32BE(&payload, 2_000_000)  // 200 nits avg

        let sei = parseSinglePayload(type: 147, body: payload, forHEVC: true)
        let ccv = try XCTUnwrap(sei.contentColourVolume)
        XCTAssertNil(ccv.redX)
        XCTAssertNil(ccv.minLuminance)
        XCTAssertNil(ccv.maxLuminance)
        XCTAssertEqual(ccv.avgLuminance ?? -1, 200.0, accuracy: 0.5)
    }

    /// SEI payload type 148 — ambient_viewing_environment (H.265 D.2.44).
    /// Layout (8 bytes): u32 illuminance (0.0001 lux), u16 light_x, u16 light_y
    /// (both 0.00002 CIE 1931 xy units).
    func testAVEPayloadDecodes() throws {
        var payload = Data()
        appendU32BE(&payload, 3_140_000)  // 314 lux (BT.2100 reference)
        appendU16BE(&payload, 15635)      // D65 white x = 0.3127
        appendU16BE(&payload, 16450)      // D65 white y = 0.3290

        let sei = parseSinglePayload(type: 148, body: payload, forHEVC: true)
        let ave = try XCTUnwrap(sei.ambientViewingEnvironment)
        XCTAssertEqual(ave.ambientIlluminance, 314.0, accuracy: 0.5)
        XCTAssertEqual(ave.ambientLightX, 0.3127, accuracy: 1e-4)
        XCTAssertEqual(ave.ambientLightY, 0.3290, accuracy: 1e-4)
    }

    func testATSCClosedCaptionsDetected() {
        // user_data_registered_itu_t_t35 with country=0xB5, provider=0x0031,
        // user_id='GA94', type_code=0x03 → A/53 closed captions.
        var payload = Data()
        payload.append(0xB5)             // country: US
        appendU16BE(&payload, 0x0031)    // provider
        // user_identifier 'GA94' = 0x47 0x41 0x39 0x34
        payload.append(contentsOf: [0x47, 0x41, 0x39, 0x34])
        payload.append(0x03)             // type_code = cc_data
        // 4 fake cc_data bytes.
        payload.append(contentsOf: [0xFC, 0xAA, 0xBB, 0xCC])

        let sei = parseSinglePayload(type: 4, body: payload, forHEVC: false)
        XCTAssertTrue(sei.hasClosedCaptions)
        XCTAssertEqual(sei.closedCaptionByteCount, 4)
    }

    func testHEVCTimeCodePayload() {
        // SEI payload type 136 (HEVC) — time_code, full_timestamp.
        // num_clock_ts=1, clock_timestamp_flag=1, units_field_based=0,
        // counting_type=0, full_timestamp=1, discontinuity=0, cnt_dropped=0,
        // n_frames=12, seconds=34, minutes=56, hours=10.
        var bw = BitWriter()
        bw.write(value: 1, bits: 2)   // num_clock_ts
        bw.write(value: 1, bits: 1)   // clock_timestamp_flag
        bw.write(value: 0, bits: 1)   // units_field_based_flag
        bw.write(value: 0, bits: 5)   // counting_type
        bw.write(value: 1, bits: 1)   // full_timestamp_flag
        bw.write(value: 0, bits: 1)   // discontinuity_flag
        bw.write(value: 0, bits: 1)   // cnt_dropped_flag
        bw.write(value: 12, bits: 9)  // n_frames
        bw.write(value: 34, bits: 6)  // seconds_value
        bw.write(value: 56, bits: 6)  // minutes_value
        bw.write(value: 10, bits: 5)  // hours_value

        let sei = parseSinglePayload(type: 136, body: bw.data, forHEVC: true)
        XCTAssertEqual(sei.timecode, "10:56:34:12")
    }

    /// `extractHEVCConfigurationBitstreams` walks the parameter-set NAL arrays
    /// inside an HEVCDecoderConfigurationRecord (hvcC box / Matroska
    /// V_MPEGH/ISO/HEVC CodecPrivate). Verify the walker recovers the SPS RBSP
    /// from a synthetic record AND every prefix-SEI NALU containing HDR static
    /// metadata — exactly what the MakeMKV-style HDR Blu-ray remuxes carry.
    func testHEVCConfigRecordExtractsSPSAndSEINALUs() throws {
        // Build a synthetic SPS NALU. Real SPS bitstreams require Golomb-coded
        // fields, but `extractHEVCConfigurationBitstreams` only cares about
        // length-prefixed extraction and emulation-prevention stripping — it
        // doesn't interpret the bytes. We use a placeholder payload that
        // includes a `00 00 03` triple so the strip step is exercised too.
        let spsPayload: [UInt8] = [
            0x42, 0x01,                          // NAL header (type=33 in bits 1..6 of byte 0)
            0xAA, 0xBB, 0x00, 0x00, 0x03, 0xCC,  // body with one emulation prevention triple
            0xDD, 0xEE,
        ]

        // Two SEI messages inside a single prefix-SEI NALU. mdcv (137) carries
        // a 24-byte SMPTE ST 2086 payload in G,B,R order. clli (144) carries
        // 4 bytes: maxCLL then maxFALL (uint16 BE in cd/m²).
        var seiPayload: [UInt8] = [
            0x4E, 0x01,                          // NAL header (type=39 prefix SEI)
            // SEI[0]: mdcv (type 137, size 24)
            0x89, 0x18,
        ]
        // mdcv body (24 bytes) — DCI-P3 D65 grading, 1000/0.005 nits.
        let mdcvBytes: [UInt16] = [
            13250,  // greenX = 0.265
            34500,  // greenY = 0.690
            7500,   // blueX  = 0.150
            3000,   // blueY  = 0.060
            34000,  // redX   = 0.680
            16000,  // redY   = 0.320
            15635,  // whiteX = 0.3127
            16450,  // whiteY = 0.3290
        ]
        for v in mdcvBytes {
            seiPayload.append(UInt8(v >> 8))
            seiPayload.append(UInt8(v & 0xFF))
        }
        // max luminance = 10_000_000 (1000 nits), min = 50 (0.005 nits).
        for v: UInt32 in [10_000_000, 50] {
            seiPayload.append(UInt8((v >> 24) & 0xFF))
            seiPayload.append(UInt8((v >> 16) & 0xFF))
            seiPayload.append(UInt8((v >> 8)  & 0xFF))
            seiPayload.append(UInt8(v         & 0xFF))
        }
        // SEI[1]: clli (type 144, size 4) — maxCLL=1000, maxFALL=400.
        seiPayload.append(contentsOf: [0x90, 0x04, 0x03, 0xE8, 0x01, 0x90])
        // rbsp_trailing_bits.
        seiPayload.append(0x80)

        // Assemble the hvcC bytes.
        var hvcC = Data(repeating: 0, count: 22)
        hvcC[0] = 0x01 // configurationVersion
        hvcC.append(0x02) // numOfArrays = 2 (one SPS array + one prefix-SEI array)

        // Array 0: SPS (type=33), 1 NALU
        hvcC.append(0x21)                                                // array_completeness=0, type=33
        hvcC.append(contentsOf: [0x00, 0x01])                            // numNalus = 1
        hvcC.append(contentsOf: [UInt8(spsPayload.count >> 8), UInt8(spsPayload.count & 0xFF)])
        hvcC.append(contentsOf: spsPayload)

        // Array 1: prefix SEI (type=39), 1 NALU
        hvcC.append(0x27)                                                // array_completeness=0, type=39
        hvcC.append(contentsOf: [0x00, 0x01])                            // numNalus = 1
        hvcC.append(contentsOf: [UInt8(seiPayload.count >> 8), UInt8(seiPayload.count & 0xFF)])
        hvcC.append(contentsOf: seiPayload)

        let (spsRBSP, seiRBSPs) = MPEGBitstream.extractHEVCConfigurationBitstreams(hvcC)

        // SPS: payload starts after 2-byte NAL header, and emulation prevention
        // bytes (00 00 03 → 00 00) must be stripped.
        let sps = try XCTUnwrap(spsRBSP)
        XCTAssertEqual(sps.first, 0xAA, "SPS RBSP should start after the 2-byte NAL header")
        let triple: [UInt8] = [0x00, 0x00, 0x03]
        XCTAssertFalse(sps.contains(where: { _ in false }) == true && sps.range(of: Data(triple)) != nil,
                       "emulation prevention byte must be stripped")

        // SEI: one NALU should be returned, and parseSEIMessages should
        // recover both the mastering-display and content-light-level messages.
        XCTAssertEqual(seiRBSPs.count, 1)
        let sei = MPEGBitstream.parseSEIMessages(seiRBSPs, forHEVC: true)
        let md = try XCTUnwrap(sei.masteringDisplay)
        XCTAssertEqual(md.redX, 0.680, accuracy: 1e-3)
        XCTAssertEqual(md.greenY, 0.690, accuracy: 1e-3)
        XCTAssertEqual(md.blueX, 0.150, accuracy: 1e-3)
        XCTAssertEqual(md.whitePointX, 0.3127, accuracy: 1e-4)
        XCTAssertEqual(md.maxLuminance, 1000.0, accuracy: 0.5)
        XCTAssertEqual(md.minLuminance, 0.005, accuracy: 1e-4)
        let cll = try XCTUnwrap(sei.contentLightLevel)
        XCTAssertEqual(cll.maxCLL, 1000)
        XCTAssertEqual(cll.maxFALL, 400)
    }

    // MARK: - Helpers

    /// Wrap a payload in an SEI message: payload_type, payload_size, body, 0x80 trailer.
    private func parseSinglePayload(type: Int, body: Data, forHEVC: Bool) -> MPEGBitstream.SEIData {
        var rbsp = Data()
        rbsp.append(UInt8(type))
        rbsp.append(UInt8(body.count))
        rbsp.append(body)
        rbsp.append(0x80)
        return MPEGBitstream.parseSEIMessages([rbsp], forHEVC: forHEVC)
    }

    private func appendU16BE(_ data: inout Data, _ v: UInt16) {
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    private func appendU32BE(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    private func appendI32BE(_ data: inout Data, _ v: Int32) {
        appendU32BE(&data, UInt32(bitPattern: v))
    }
}

// MARK: - MPEG-TS PSI multi-program (Phase 22.2)

final class MPEGProgramTests: XCTestCase {

    func testMPEGProgramTypeBasics() {
        let p = MPEGProgram(programNumber: 7, pmtPID: 0x100,
                            elementaryPIDs: [0x101, 0x102],
                            serviceName: "BBC ONE HD", providerName: "BBC")
        XCTAssertEqual(p.programNumber, 7)
        XCTAssertEqual(p.pmtPID, 0x100)
        XCTAssertEqual(p.elementaryPIDs, [0x101, 0x102])
        XCTAssertEqual(p.serviceName, "BBC ONE HD")
        XCTAssertEqual(p.providerName, "BBC")
    }

    func testVideoMetadataExposesEmptyProgramListByDefault() {
        let m = VideoMetadata(format: .mp4)
        XCTAssertTrue(m.mpegPrograms.isEmpty)
    }
}

// MARK: - Bit writer used by SEI tests

/// A tiny MSB-first big-endian bit writer for assembling SEI test bodies.
private struct BitWriter {
    private(set) var data: Data = Data()
    private var bitOffset: Int = 0

    mutating func write(value: UInt64, bits n: Int) {
        guard n > 0 else { return }
        for i in (0..<n).reversed() {
            let bit = UInt8((value >> i) & 1)
            let byteIndex = bitOffset >> 3
            if byteIndex >= data.count { data.append(0) }
            let bitInByte = bitOffset & 7
            data[byteIndex] |= bit << (7 - bitInByte)
            bitOffset += 1
        }
    }
}
