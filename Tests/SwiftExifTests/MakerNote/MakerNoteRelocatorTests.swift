import XCTest
@testable import SwiftExif

/// Unit tests for `MakerNoteRelocator` — the per-manufacturer internal-offset
/// fix-up applied when a MakerNote block is relocated during a write.
final class MakerNoteRelocatorTests: XCTestCase {

    // MARK: - Little-endian builders

    private func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
    private func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        let s = data.startIndex + offset
        return UInt32(data[s]) | (UInt32(data[s + 1]) << 8) | (UInt32(data[s + 2]) << 16) | (UInt32(data[s + 3]) << 24)
    }

    /// A Canon-style bare IFD at offset 0 (little-endian) with one out-of-line
    /// ASCII value whose 4-byte offset field holds `valuePtr`. Optionally append
    /// a TIFF footer ("II*\0" + `footerOffset` LONG). The value-offset field
    /// sits at byte 10 (count(2) + tag(2)+type(2)+count(4) = entryPos 2, +8).
    private func canonNote(valuePtr: UInt32, footerOffset: UInt32? = nil) -> Data {
        var d = Data()
        d += le16(1)                                   // 1 entry
        d += le16(0x0006) + le16(2) + le32(8) + le32(valuePtr) // tag, ASCII, count=8, offset
        d += le32(0)                                   // next-IFD = 0
        d += Data("CANONSER".utf8)                     // 8-byte value
        if let f = footerOffset {
            d += Data([0x49, 0x49, 0x2A, 0x00]) + le32(f) // TIFF footer
        }
        return d
    }

    // MARK: - Absolute (Canon) fix-up

    func testAbsoluteCanonNotePatchesOffsetByDelta() {
        let note = canonNote(valuePtr: 140)
        let r = MakerNoteRelocator.relocate(data: note, make: "Canon", endian: .littleEndian, delta: 64)
        XCTAssertTrue(r.didFixUp)
        XCTAssertTrue(r.isSafe)
        XCTAssertEqual(r.bytes.count, note.count, "fix-up must preserve length")
        XCTAssertEqual(readLE32(r.bytes, at: 10), 140 + 64, "absolute value offset must shift by delta")
        // Everything except the patched field is untouched.
        XCTAssertEqual(r.bytes.suffix(8), Data("CANONSER".utf8))
    }

    func testAbsoluteNegativeDelta() {
        let note = canonNote(valuePtr: 200)
        let r = MakerNoteRelocator.relocate(data: note, make: "Canon", endian: .littleEndian, delta: -50)
        XCTAssertTrue(r.didFixUp)
        XCTAssertEqual(readLE32(r.bytes, at: 10), 150)
    }

    func testCanonTiffFooterOffsetAlsoPatched() {
        // Footer holds the MakerNote's original start offset; it must shift too
        // so footer-aware readers compute a zero correction.
        let note = canonNote(valuePtr: 140, footerOffset: 122)
        let r = MakerNoteRelocator.relocate(data: note, make: "Canon", endian: .littleEndian, delta: 64)
        XCTAssertTrue(r.isSafe)
        XCTAssertEqual(readLE32(r.bytes, at: 10), 140 + 64, "IFD value offset patched")
        let footerOffPos = r.bytes.count - 4
        XCTAssertEqual(readLE32(r.bytes, at: footerOffPos), 122 + 64, "footer offset patched")
    }

    func testChainedNextIFDBailsToVerbatim() {
        // A non-zero next-IFD pointer implies a chained MakerNote IFD we don't
        // walk; bail rather than emit a half-fixed note.
        var d = Data()
        d += le16(1)
        d += le16(0x0006) + le16(2) + le32(8) + le32(140)
        d += le32(40)                       // next-IFD != 0
        d += Data("CANONSER".utf8)
        let r = MakerNoteRelocator.relocate(data: d, make: "Canon", endian: .littleEndian, delta: 64)
        XCTAssertFalse(r.didFixUp)
        XCTAssertFalse(r.isSafe)
        XCTAssertEqual(r.bytes, d)
    }

    func testTruncatedAbsoluteNoteBailsToVerbatim() {
        let r = MakerNoteRelocator.relocate(data: Data([0x05, 0x00, 0x01]), make: "Canon", endian: .littleEndian, delta: 64)
        XCTAssertFalse(r.isSafe)
        XCTAssertEqual(r.bytes, Data([0x05, 0x00, 0x01]))
    }

    // MARK: - Relative (safe verbatim) manufacturers

    func testNikonNoteIsSafeVerbatim() {
        // Nikon offsets are relative to its embedded TIFF header → moving the
        // block keeps them valid; copy verbatim, no warning, no fix-up.
        let note = Data("Nikon\u{0}".utf8) + Data([0x02, 0x10]) + Data(repeating: 0xAB, count: 32)
        let r = MakerNoteRelocator.relocate(data: note, make: "NIKON CORPORATION", endian: .littleEndian, delta: 1000)
        XCTAssertFalse(r.didFixUp)
        XCTAssertTrue(r.isSafe)
        XCTAssertEqual(r.bytes, note)
    }

    func testFujifilmNoteIsSafeVerbatim() {
        let note = Data("FUJIFILM".utf8) + le32(12) + Data(repeating: 0x11, count: 16)
        let r = MakerNoteRelocator.relocate(data: note, make: "FUJIFILM", endian: .littleEndian, delta: 500)
        XCTAssertFalse(r.didFixUp)
        XCTAssertTrue(r.isSafe)
        XCTAssertEqual(r.bytes, note)
    }

    // MARK: - Unknown / no-op

    func testUnknownManufacturerWarnsVerbatim() {
        let note = canonNote(valuePtr: 140)
        let r = MakerNoteRelocator.relocate(data: note, make: "Frobozz Magic Camera Co", endian: .littleEndian, delta: 64)
        XCTAssertFalse(r.didFixUp)
        XCTAssertFalse(r.isSafe)
        XCTAssertEqual(r.bytes, note)
    }

    func testNilMakeWarnsVerbatim() {
        let note = canonNote(valuePtr: 140)
        let r = MakerNoteRelocator.relocate(data: note, make: nil, endian: .littleEndian, delta: 64)
        XCTAssertFalse(r.isSafe)
        XCTAssertEqual(r.bytes, note)
    }

    func testZeroDeltaIsSafeNoOp() {
        let note = canonNote(valuePtr: 140)
        let r = MakerNoteRelocator.relocate(data: note, make: "Canon", endian: .littleEndian, delta: 0)
        XCTAssertFalse(r.didFixUp)
        XCTAssertTrue(r.isSafe, "no move means nothing can break")
        XCTAssertEqual(r.bytes, note)
    }
}
