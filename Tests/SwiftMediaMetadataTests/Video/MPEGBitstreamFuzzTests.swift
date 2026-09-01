import XCTest
@testable import SwiftMediaMetadata

/// Regression tests for integer-overflow crashes in the H.264/H.265 bitstream
/// decoder. A crafted SPS NAL can make the Exp-Golomb `readUE()` decode a
/// near-`UInt32.max` value; the SPS parsers then performed trapping `UInt32`
/// arithmetic (`ue + 1`, `+ 8`, `cropL + cropR`) on it, crashing the whole
/// process. These tests feed adversarial bytes through the same paths a
/// malformed video file would reach and assert the decoders return without
/// trapping. (Reaching the end of each test body == no crash == pass.)
final class MPEGBitstreamFuzzTests: XCTestCase {

    // MARK: - Exp-Golomb leaf decoders

    /// 32+ leading zero bits make `readUE()` return 0xFFFFFFFF; the old
    /// `readSE()` then evaluated `ue + 1` in UInt32 and trapped.
    func testReadSEDoesNotTrapOnMaxCodeNum() {
        var br = MPEGBitstream.BitReader(Data(repeating: 0x00, count: 9))
        _ = br.readSE()
    }

    func testReadUEAndReadSEDoNotTrapOnAdversarialBits() {
        for pattern: UInt8 in [0x00, 0xFF, 0xAA, 0x55, 0x80, 0x01] {
            for length in 1...12 {
                var a = MPEGBitstream.BitReader(Data(repeating: pattern, count: length))
                _ = a.readUE()
                var b = MPEGBitstream.BitReader(Data(repeating: pattern, count: length))
                _ = b.readSE()
            }
        }
    }

    // MARK: - SPS parsers

    /// `parseH264SPS` must tolerate any byte soup without trapping on the
    /// `picWidthInMBs + 1`, `bitDepthLuma + 8`, or crop-window arithmetic.
    func testParseH264SPSDoesNotTrapOnAdversarialInput() {
        for pattern: UInt8 in [0x00, 0xFF, 0xAA, 0x55] {
            for length in 4...40 {
                _ = MPEGBitstream.parseH264SPS(Data(repeating: pattern, count: length))
            }
        }
        // High-profile path (profile_idc 100) forces the bit-depth reads.
        _ = MPEGBitstream.parseH264SPS(Data([0x64] + Array(repeating: 0x00, count: 40)))
        _ = MPEGBitstream.parseH264SPS(Data([0x64] + Array(repeating: 0xFF, count: 40)))
    }

    func testParseHEVCSPSDoesNotTrapOnAdversarialInput() {
        for pattern: UInt8 in [0x00, 0xFF, 0xAA, 0x55] {
            for length in 4...48 {
                _ = MPEGBitstream.parseHEVCSPS(Data(repeating: pattern, count: length))
            }
        }
    }
}
