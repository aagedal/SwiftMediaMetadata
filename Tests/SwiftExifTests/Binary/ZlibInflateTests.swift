import XCTest
@testable import SwiftExif

final class ZlibInflateTests: XCTestCase {

    // MARK: - Roundtrip

    func testDeflateInflateRoundtrip() {
        let original = Data(repeating: 0x42, count: 8192)
        guard let compressed = ZlibInflate.deflate(original) else {
            XCTFail("deflate returned nil")
            return
        }
        XCTAssertEqual(ZlibInflate.inflate(compressed), original)
    }

    // MARK: - Decompression-bomb cap
    //
    // A runaway deflate stream could expand 1000:1 or more; without an output
    // cap, crafted PNG iCCP/iTXt chunks or PDF FlateDecode streams would let
    // an attacker exhaust host memory during metadata parsing.

    func testInflateHonoursExplicitMaxOutput() {
        let original = Data(repeating: 0x00, count: 16 * 1024) // highly compressible
        guard let compressed = ZlibInflate.deflate(original) else {
            XCTFail("deflate returned nil")
            return
        }
        // Cap below the real output size — inflate must abort and return nil.
        XCTAssertNil(ZlibInflate.inflate(compressed, maxOutput: 1024))
        // Cap at (or above) the real output size — inflate must succeed.
        XCTAssertEqual(
            ZlibInflate.inflate(compressed, maxOutput: original.count),
            original
        )
    }

    func testInflateRawDeflateHonoursMaxOutput() {
        // Raw-deflate bytes for 32 KB of zeros. Build them by taking the zlib
        // output and stripping the 2-byte header + 4-byte Adler32 trailer.
        let zeros = Data(repeating: 0x00, count: 32 * 1024)
        guard let zlib = ZlibInflate.deflate(zeros), zlib.count >= 6 else {
            XCTFail("deflate returned nil")
            return
        }
        let rawDeflate = zlib.subdata(in: 2..<(zlib.count - 4))
        XCTAssertNil(ZlibInflate.inflate(rawDeflate, rawDeflate: true, maxOutput: 1024))
        XCTAssertEqual(
            ZlibInflate.inflate(rawDeflate, rawDeflate: true, maxOutput: zeros.count),
            zeros
        )
    }
}
