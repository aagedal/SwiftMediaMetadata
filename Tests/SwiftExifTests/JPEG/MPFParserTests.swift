import XCTest
@testable import SwiftExif

/// Synthetic-fixture coverage for the JPEG Multi-Picture Format (CIPA DC-007)
/// parser. MPF travels inside an APP2 segment and indexes the secondary
/// images stored later in the same JPEG byte stream — Apple Live Photo aux
/// frames, Sony A-series multi-shot bursts, and stereo / 3D pairs.
final class MPFParserTests: XCTestCase {

    // MARK: - Direct parser

    func testParseTwoImageMPF() throws {
        // Image 1: Representative Baseline MP Primary (10_000 bytes at offset 0)
        // Image 2: Dependent-child Multi-frame Disparity / depth map
        //          (5_000 bytes at offset 10_000)
        let entries: [(attribute: UInt32, size: UInt32, offset: UInt32, dep1: UInt16, dep2: UInt16)] = [
            (0x20030000, 10_000, 0, 0, 0),
            (0x40020002,  5_000, 10_000, 1, 0),
        ]
        let segment = makeMPFSegment(version: "0100", entries: entries)

        let parsed = try XCTUnwrap(MPFParser.parse(segment))
        XCTAssertEqual(parsed.version, "0100")
        XCTAssertEqual(parsed.numberOfImages, 2)
        XCTAssertEqual(parsed.entries.count, 2)

        XCTAssertEqual(parsed.entries[0].imageType, "Baseline MP Primary Image")
        XCTAssertTrue(parsed.entries[0].isRepresentative)
        XCTAssertFalse(parsed.entries[0].isDependentChild)
        XCTAssertEqual(parsed.entries[0].imageSize, 10_000)
        XCTAssertEqual(parsed.entries[0].imageOffset, 0)

        XCTAssertEqual(parsed.entries[1].imageType, "Multi-Frame Disparity")
        XCTAssertTrue(parsed.entries[1].isDependentChild)
        XCTAssertFalse(parsed.entries[1].isRepresentative)
        XCTAssertEqual(parsed.entries[1].imageSize, 5_000)
        XCTAssertEqual(parsed.entries[1].imageOffset, 10_000)
        XCTAssertEqual(parsed.entries[1].dependentEntry1, 1)
    }

    func testRejectsNonMPFSegment() {
        // ICC profile APP2 prefix is "ICC_PROFILE\0" — must not be treated as MPF.
        let icc = Data([0x49, 0x43, 0x43, 0x5F, 0x50, 0x52, 0x4F, 0x46, 0x49, 0x4C, 0x45, 0x00])
            + Data(repeating: 0, count: 32)
        XCTAssertNil(MPFParser.parse(icc))
    }

    func testTruncatedMPFReturnsNil() {
        // Identifier present but no IFD body.
        let truncated = MPFParser.mpfIdentifier
        XCTAssertNil(MPFParser.parse(truncated))
    }

    // MARK: - End-to-end through ImageMetadata.read

    func testJPEGWithMPFSegmentExposesMPFData() throws {
        let entries: [(attribute: UInt32, size: UInt32, offset: UInt32, dep1: UInt16, dep2: UInt16)] = [
            (0x20030000, 12_345, 0, 0, 0),
            (0x40010001,  4_321, 12_345, 1, 0),
        ]
        let mpfSegment = makeMPFSegment(version: "0100", entries: entries)
        let jpeg = TestFixtures.jpegWithSegment(marker: .app2, data: mpfSegment)

        let metadata = try ImageMetadata.read(from: jpeg, format: .jpeg)
        let mpf = try XCTUnwrap(metadata.mpf)
        XCTAssertEqual(mpf.numberOfImages, 2)
        XCTAssertEqual(mpf.entries.count, 2)
        XCTAssertEqual(mpf.entries[0].imageSize, 12_345)
        XCTAssertEqual(mpf.entries[1].imageType, "Large Thumbnail (VGA equivalent)")
        XCTAssertTrue(mpf.entries[1].isDependentChild)
    }

    func testMPFRoundTripPreservesAPP2Bytes() throws {
        let entries: [(attribute: UInt32, size: UInt32, offset: UInt32, dep1: UInt16, dep2: UInt16)] = [
            (0x20030000, 10_000, 0, 0, 0),
        ]
        let mpfSegment = makeMPFSegment(version: "0100", entries: entries)
        let jpeg = TestFixtures.jpegWithSegment(marker: .app2, data: mpfSegment)

        let parsed = try JPEGParser.parse(jpeg)
        let written = try JPEGWriter.write(parsed)
        let reparsed = try JPEGParser.parse(written)

        let original = try XCTUnwrap(parsed.mpfSegment())
        let roundTripped = try XCTUnwrap(reparsed.mpfSegment())
        XCTAssertEqual(original.data, roundTripped.data,
                       "MPF APP2 bytes must survive a parse/write cycle untouched")
    }

    func testMetadataExporterIncludesMPF() throws {
        let entries: [(attribute: UInt32, size: UInt32, offset: UInt32, dep1: UInt16, dep2: UInt16)] = [
            (0x20030000, 11_111, 0, 0, 0),
            (0x40020002,  2_222, 11_111, 1, 0),
        ]
        let mpfSegment = makeMPFSegment(version: "0100", entries: entries)
        let jpeg = TestFixtures.jpegWithSegment(marker: .app2, data: mpfSegment)
        let metadata = try ImageMetadata.read(from: jpeg, format: .jpeg)

        let dict = MetadataExporter.buildDictionary(metadata)
        XCTAssertEqual(dict["MPF:Version"] as? String, "0100")
        XCTAssertEqual(dict["MPF:NumberOfImages"] as? Int, 2)
        XCTAssertEqual(dict["MPF:Image1:Type"] as? String, "Baseline MP Primary Image")
        XCTAssertEqual(dict["MPF:Image2:Type"] as? String, "Multi-Frame Disparity")
        XCTAssertEqual(dict["MPF:Image1:Size"] as? Int, 11_111)
        XCTAssertEqual(dict["MPF:Image2:Offset"] as? Int, 11_111)
    }

    // MARK: - Helpers

    /// Build a complete APP2 MPF segment payload: "MPF\0" identifier followed
    /// by a little-endian TIFF-shaped IFD carrying MPFVersion, NumberOfImages,
    /// and the per-image MPEntry table.
    private func makeMPFSegment(
        version: String,
        entries: [(attribute: UInt32, size: UInt32, offset: UInt32, dep1: UInt16, dep2: UInt16)]
    ) -> Data {
        let endian = ByteOrder.littleEndian
        var w = BinaryWriter(capacity: 256)

        // APP2 MPF identifier — the parser's anchor.
        w.writeBytes(MPFParser.mpfIdentifier)

        // TIFF header at MPF base: byte order ("II" = little), version 42, IFD offset = 8.
        w.writeBytes(Data([0x49, 0x49]))  // "II"
        w.writeUInt16(42, endian: endian)
        w.writeUInt32(8, endian: endian)

        // IFD with 3 entries (MPFVersion, NumberOfImages, MPEntry).
        let entryCount: UInt16 = 3
        w.writeUInt16(entryCount, endian: endian)

        // MPEntry data goes after the IFD (12 bytes per entry × 3 + 4 bytes nextIFD = 40 bytes
        // beyond the entry-count field). MPF base = byte after "MPF\0".
        // IFD itself starts 8 bytes into the MPF base; entries start at base+10; nextIFD at
        // base + 10 + 36 = base + 46. MPEntry payload starts at base + 50.
        let mpEntryOffset: UInt32 = 50
        let mpEntryByteCount = UInt32(entries.count * 16)

        // Tag 0xB000 MPFVersion: type=7 (UNDEFINED), count=4, value = "0100" inline.
        w.writeUInt16(0xB000, endian: endian)
        w.writeUInt16(7, endian: endian)
        w.writeUInt32(4, endian: endian)
        var versionBytes = Data(version.utf8)
        while versionBytes.count < 4 { versionBytes.append(0x00) }
        w.writeBytes(versionBytes.prefix(4))

        // Tag 0xB001 NumberOfImages: type=4 (LONG), count=1, value=count inline.
        w.writeUInt16(0xB001, endian: endian)
        w.writeUInt16(4, endian: endian)
        w.writeUInt32(1, endian: endian)
        w.writeUInt32(UInt32(entries.count), endian: endian)

        // Tag 0xB002 MPEntry: type=7 (UNDEFINED), count = 16 × N, offset.
        w.writeUInt16(0xB002, endian: endian)
        w.writeUInt16(7, endian: endian)
        w.writeUInt32(mpEntryByteCount, endian: endian)
        w.writeUInt32(mpEntryOffset, endian: endian)

        // Next IFD offset (none).
        w.writeUInt32(0, endian: endian)

        // MPEntry payload (16 bytes per image).
        for e in entries {
            w.writeUInt32(e.attribute, endian: endian)
            w.writeUInt32(e.size, endian: endian)
            w.writeUInt32(e.offset, endian: endian)
            w.writeUInt16(e.dep1, endian: endian)
            w.writeUInt16(e.dep2, endian: endian)
        }

        return w.data
    }
}
