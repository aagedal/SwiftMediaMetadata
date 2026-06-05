import XCTest
@testable import SwiftExif

/// Regression coverage for copying EXIF that carries an oversized proprietary
/// blob (a Sony A1's ~1.5 MB C2PA / Content Credentials manifest in IFD0 tag
/// 0xCD41) onto a JPEG. JPEG's Exif APP1 has a hard ~64 KB per-segment ceiling,
/// so the blob can't survive — but it must be dropped gracefully with a warning
/// rather than aborting the whole write and silently losing ALL the good
/// metadata (the original `MetadataError.invalidSegmentLength` failure).
final class OversizedExifTests: XCTestCase {

    // Roughly the size of the real Sony A1 C2PA manifest blob.
    private static let blobByteCount = 1_572_864
    private static let c2paTag: UInt16 = 0xCD41

    // MARK: - Synthetic EXIF builders

    private func ascii(_ tag: UInt16, _ string: String) -> IFDEntry {
        var data = Data(string.utf8)
        data.append(0) // NUL terminator
        return IFDEntry(tag: tag, type: .ascii, count: UInt32(data.count), valueData: data)
    }

    private func short(_ tag: UInt16, _ value: UInt16, _ endian: ByteOrder) -> IFDEntry {
        var writer = BinaryWriter(capacity: 2)
        writer.writeUInt16(value, endian: endian)
        return IFDEntry(tag: tag, type: .short, count: 1, valueData: writer.data)
    }

    private func rational(_ tag: UInt16, _ num: UInt32, _ den: UInt32, _ endian: ByteOrder) -> IFDEntry {
        var writer = BinaryWriter(capacity: 8)
        writer.writeUInt32(num, endian: endian)
        writer.writeUInt32(den, endian: endian)
        return IFDEntry(tag: tag, type: .rational, count: 1, valueData: writer.data)
    }

    private func undefinedBlob(_ tag: UInt16, byteCount: Int) -> IFDEntry {
        IFDEntry(tag: tag, type: .undefined, count: UInt32(byteCount), valueData: Data(count: byteCount))
    }

    /// EXIF mimicking a Sony A1 .ARW: standard tags plus a ~1.5 MB C2PA blob in IFD0.
    private func sonyExifWithC2PABlob() -> ExifData {
        var exif = ExifData(byteOrder: .littleEndian)
        exif.ifd0 = IFD(entries: [
            ascii(ExifTag.make, "SONY"),
            ascii(ExifTag.model, "ILCE-1"),
            short(ExifTag.orientation, 1, .littleEndian),
            undefinedBlob(Self.c2paTag, byteCount: Self.blobByteCount),
        ])
        exif.exifIFD = IFD(entries: [
            rational(ExifTag.exposureTime, 1, 100, .littleEndian),
            rational(ExifTag.fNumber, 28, 10, .littleEndian),
            ascii(ExifTag.lensModel, "FE 24-70mm F2.8 GM"),
        ])
        return exif
    }

    // MARK: - End-to-end: copy onto a JPEG

    func testWritingOversizedExifOntoJPEGSucceedsAndKeepsStandardTags() throws {
        var metadata = try ImageMetadata.read(from: TestFixtures.bareJPEG())
        metadata.exif = sonyExifWithC2PABlob()

        // Previously threw MetadataError.invalidSegmentLength, losing everything.
        let (data, warnings) = try metadata.writeToDataWithWarnings()

        // The serialized Exif APP1 must fit JPEG's hard per-segment ceiling.
        let written = try JPEGParser.parse(data)
        let exifSegment = try XCTUnwrap(written.exifSegment(), "Exif APP1 segment should still be present")
        XCTAssertLessThanOrEqual(exifSegment.data.count, JPEGWriter.maxSegmentPayload,
                                 "Exif APP1 payload must not exceed the 65,533-byte JPEG limit")

        // A non-fatal warning must record the drop (naming the C2PA blob).
        XCTAssertTrue(warnings.contains { $0.contains("C2PA") },
                      "expected a warning naming the dropped C2PA blob, got: \(warnings)")

        // The standard tags must survive the trim.
        let reread = try ImageMetadata.read(from: data)
        XCTAssertEqual(reread.exif?.make, "SONY")
        XCTAssertEqual(reread.exif?.model, "ILCE-1")
        XCTAssertEqual(reread.exif?.lensModel, "FE 24-70mm F2.8 GM")
        XCTAssertEqual(reread.exif?.orientation, 1)
        XCTAssertEqual(reread.exif?.exposureTime?.numerator, 1)
        XCTAssertEqual(reread.exif?.exposureTime?.denominator, 100)
        XCTAssertEqual(reread.exif?.fNumber?.numerator, 28)

        // The oversized blob itself must be gone.
        XCTAssertNil(reread.exif?.ifd0?.entry(for: Self.c2paTag),
                     "the oversized C2PA blob should have been dropped")
    }

    // MARK: - ExifWriter cap, in isolation

    func testCappedWriterDropsOversizedBlobAndFits() {
        var warnings: [String] = []
        let data = ExifWriter.write(sonyExifWithC2PABlob(),
                                    maxPayload: JPEGWriter.maxSegmentPayload,
                                    warnings: &warnings)

        XCTAssertLessThanOrEqual(data.count, JPEGWriter.maxSegmentPayload)
        XCTAssertFalse(warnings.isEmpty, "dropping a tag should record a warning")
        XCTAssertTrue(data.starts(with: JPEGSegment.exifIdentifier),
                      "capped output must still be a valid Exif APP1 payload")
    }

    func testCappedWriterPassesSmallExifThroughUnchanged() {
        var exif = ExifData(byteOrder: .littleEndian)
        exif.ifd0 = IFD(entries: [
            ascii(ExifTag.make, "SONY"),
            ascii(ExifTag.model, "ILCE-1"),
        ])

        var cappedWarnings: [String] = []
        let capped = ExifWriter.write(exif, maxPayload: JPEGWriter.maxSegmentPayload, warnings: &cappedWarnings)

        var plainWarnings: [String] = []
        let plain = ExifWriter.write(exif, warnings: &plainWarnings)

        // EXIF that already fits must round-trip byte-identical with no warnings.
        XCTAssertEqual(capped, plain)
        XCTAssertTrue(cappedWarnings.isEmpty, "in-budget EXIF should not warn: \(cappedWarnings)")
        XCTAssertLessThanOrEqual(capped.count, JPEGWriter.maxSegmentPayload)
    }
}
