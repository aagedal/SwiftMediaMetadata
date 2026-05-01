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
