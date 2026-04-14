import XCTest
@testable import SwiftExif

// MARK: - Copy Metadata Tests

final class MetadataCopyTests: XCTestCase {

    func testCopyAllMetadata() throws {
        let source = try makeSourceMetadata()
        var target = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)

        target.copyMetadata(from: source)

        XCTAssertEqual(target.iptc.headline, "Source Headline")
        XCTAssertEqual(target.iptc.city, "Oslo")
        XCTAssertNotNil(target.exif)
        XCTAssertNotNil(target.xmp)
        XCTAssertEqual(target.xmp?.title, "Source Title")
    }

    func testCopySelectiveGroups() throws {
        let source = try makeSourceMetadata()
        var target = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)

        // Copy only IPTC
        target.copyMetadata(from: source, groups: [.iptc])

        XCTAssertEqual(target.iptc.headline, "Source Headline")
        XCTAssertNil(target.exif)
        XCTAssertNil(target.xmp)
    }

    func testCopyExifOnly() throws {
        let source = try makeSourceMetadata()
        var target = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        target.iptc.headline = "Keep This"

        target.copyMetadata(from: source, groups: [.exif])

        XCTAssertNotNil(target.exif)
        XCTAssertEqual(target.iptc.headline, "Keep This") // Not overwritten
        XCTAssertNil(target.xmp) // Not copied
    }

    func testCopyXMPOnly() throws {
        let source = try makeSourceMetadata()
        var target = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)

        target.copyMetadata(from: source, groups: [.xmp])

        XCTAssertNil(target.exif)
        XCTAssertTrue(target.iptc.datasets.isEmpty)
        XCTAssertEqual(target.xmp?.title, "Source Title")
    }

    func testCopyMultipleGroups() throws {
        let source = try makeSourceMetadata()
        var target = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)

        target.copyMetadata(from: source, groups: [.iptc, .xmp])

        XCTAssertEqual(target.iptc.headline, "Source Headline")
        XCTAssertEqual(target.xmp?.title, "Source Title")
        XCTAssertNil(target.exif) // Not in the set
    }

    func testCopyReplacesExistingData() throws {
        let source = try makeSourceMetadata()
        var target = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        target.iptc.headline = "Old Headline"
        target.iptc.city = "Bergen"

        target.copyMetadata(from: source, groups: [.iptc])

        XCTAssertEqual(target.iptc.headline, "Source Headline")
        XCTAssertEqual(target.iptc.city, "Oslo")
    }

    func testCopyNilExifClearsTarget() throws {
        var source = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        source.exif = nil

        var target = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        target.exif = ExifData(byteOrder: .bigEndian)
        XCTAssertNotNil(target.exif)

        target.copyMetadata(from: source, groups: [.exif])
        XCTAssertNil(target.exif)
    }

    func testCopyC2PA() throws {
        var source = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        source.c2pa = C2PAData(manifests: [])
        var target = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)

        target.copyMetadata(from: source, groups: [.c2pa])

        XCTAssertNotNil(target.c2pa)
        XCTAssertNil(target.exif)
    }

    func testCopyAndWriteRoundTrip() throws {
        let source = try makeSourceMetadata()
        var iptc = IPTCData()
        iptc.headline = "Original"
        let jpegData = TestFixtures.jpegWithIPTC(datasets: iptc.datasets)

        var target = try ImageMetadata.read(from: jpegData)
        target.copyMetadata(from: source, groups: [.iptc])

        let written = try target.writeToData()
        let reparsed = try ImageMetadata.read(from: written)
        XCTAssertEqual(reparsed.iptc.headline, "Source Headline")
        XCTAssertEqual(reparsed.iptc.city, "Oslo")
    }

    func testCopyEmptyGroups() throws {
        let source = try makeSourceMetadata()
        var target = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        target.iptc.headline = "Keep"

        // Empty group set — nothing should be copied
        target.copyMetadata(from: source, groups: [])

        XCTAssertEqual(target.iptc.headline, "Keep")
        XCTAssertNil(target.exif)
    }

    private func makeSourceMetadata() throws -> ImageMetadata {
        var metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        metadata.iptc.headline = "Source Headline"
        metadata.iptc.city = "Oslo"
        metadata.iptc.keywords = ["photo", "journalism"]
        metadata.exif = ExifData(byteOrder: .bigEndian)
        metadata.exif?.ifd0 = IFD(entries: [
            IFDEntry(tag: ExifTag.make, type: .ascii, count: 6, valueData: Data("Nikon\0".utf8)),
        ])
        metadata.xmp = XMPData()
        metadata.xmp?.title = "Source Title"
        metadata.xmp?.headline = "Source XMP Headline"
        return metadata
    }
}

// MARK: - Metadata Diff Tests

final class MetadataDiffTests: XCTestCase {

    func testIdenticalMetadataProducesNoDiff() {
        var m1 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m1.iptc.headline = "Same"
        var m2 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m2.iptc.headline = "Same"

        let diff = m1.diff(against: m2)
        XCTAssertTrue(diff.isEmpty)
    }

    func testDiffDetectsAdditions() {
        let m1 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        var m2 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m2.iptc.headline = "New"

        let diff = m1.diff(against: m2)
        XCTAssertFalse(diff.isEmpty)

        let added = diff.additions
        XCTAssertTrue(added.contains { $0.key == "IPTC:Headline" && $0.newValue == "New" })
    }

    func testDiffDetectsRemovals() {
        var m1 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m1.iptc.headline = "Removed"
        let m2 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)

        let diff = m1.diff(against: m2)

        let removed = diff.removals
        XCTAssertTrue(removed.contains { $0.key == "IPTC:Headline" && $0.oldValue == "Removed" })
    }

    func testDiffDetectsModifications() {
        var m1 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m1.iptc.headline = "Old"
        var m2 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m2.iptc.headline = "New"

        let diff = m1.diff(against: m2)

        let modified = diff.modifications
        XCTAssertTrue(modified.contains { $0.key == "IPTC:Headline" && $0.oldValue == "Old" && $0.newValue == "New" })
    }

    func testDiffMultipleChanges() {
        var m1 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m1.iptc.headline = "Old Headline"
        m1.iptc.city = "Oslo"
        m1.iptc.credit = "To Be Removed"

        var m2 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m2.iptc.headline = "New Headline"
        m2.iptc.city = "Oslo" // Same
        m2.iptc.byline = "New Author" // Added

        let diff = m1.diff(against: m2)

        XCTAssertEqual(diff.modifications.count, 1)
        XCTAssertEqual(diff.modifications[0].key, "IPTC:Headline")

        XCTAssertTrue(diff.removals.contains { $0.key == "IPTC:Credit" })
        XCTAssertTrue(diff.additions.contains { $0.key == "IPTC:By-line" })
    }

    func testDiffExifFields() throws {
        let exif1Data = TestFixtures.exifAPP1Data(byteOrder: .bigEndian, ifd0Entries: [
            (tag: ExifTag.make, stringValue: "Nikon"),
        ])
        let jpeg1 = TestFixtures.jpegWithSegment(marker: .app1, data: exif1Data)
        let m1 = try ImageMetadata.read(from: jpeg1)

        let exif2Data = TestFixtures.exifAPP1Data(byteOrder: .bigEndian, ifd0Entries: [
            (tag: ExifTag.make, stringValue: "Canon"),
        ])
        let jpeg2 = TestFixtures.jpegWithSegment(marker: .app1, data: exif2Data)
        let m2 = try ImageMetadata.read(from: jpeg2)

        let diff = m1.diff(against: m2)
        XCTAssertTrue(diff.modifications.contains { $0.key == "Make" })
    }

    func testDiffXMPFields() {
        var m1 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m1.xmp = XMPData()
        m1.xmp?.headline = "XMP Old"

        var m2 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m2.xmp = XMPData()
        m2.xmp?.headline = "XMP New"

        let diff = m1.diff(against: m2)
        XCTAssertTrue(diff.modifications.contains { $0.key == "XMP-photoshop:Headline" })
    }

    func testDiffKeysSorted() {
        var m1 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m1.iptc.headline = "A"
        m1.iptc.city = "B"

        var m2 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m2.iptc.headline = "X"
        m2.iptc.city = "Y"

        let diff = m1.diff(against: m2)
        let keys = diff.changes.map(\.key)
        XCTAssertEqual(keys, keys.sorted())
    }

    func testDiffKeywords() {
        var m1 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m1.iptc.keywords = ["arctic", "norway"]
        var m2 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m2.iptc.keywords = ["arctic", "sweden"]

        let diff = m1.diff(against: m2)
        XCTAssertTrue(diff.modifications.contains { $0.key == "IPTC:Keywords" })
    }

    func testDiffChangeEquatable() {
        let c1 = ImageMetadata.MetadataChange(key: "Make", type: .modified, oldValue: "A", newValue: "B")
        let c2 = ImageMetadata.MetadataChange(key: "Make", type: .modified, oldValue: "A", newValue: "B")
        XCTAssertEqual(c1, c2)
    }
}

// MARK: - Thumbnail Extraction Tests

final class ThumbnailExtractionTests: XCTestCase {

    func testExtractThumbnailFromJPEG() throws {
        let jpegData = makeJPEGWithThumbnail()
        let metadata = try ImageMetadata.read(from: jpegData)

        let thumbnail = metadata.extractThumbnail()
        XCTAssertNotNil(thumbnail)

        // Verify it starts with JPEG SOI marker
        XCTAssertEqual(thumbnail?.prefix(2), Data([0xFF, 0xD8]))
    }

    func testExtractThumbnailReturnsNilWhenNoIFD1() throws {
        // Regular JPEG without thumbnail
        let exifData = TestFixtures.exifAPP1Data(byteOrder: .bigEndian, ifd0Entries: [
            (tag: ExifTag.make, stringValue: "Test"),
        ])
        let jpeg = TestFixtures.jpegWithSegment(marker: .app1, data: exifData)
        let metadata = try ImageMetadata.read(from: jpeg)

        XCTAssertNil(metadata.extractThumbnail())
    }

    func testExtractThumbnailReturnsNilWhenNoExif() throws {
        let metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        XCTAssertNil(metadata.extractThumbnail())
    }

    func testExtractThumbnailFromTIFF() throws {
        let tiffData = makeTIFFWithThumbnail()
        let metadata = try ImageMetadata.read(from: tiffData)

        let thumbnail = metadata.extractThumbnail()
        XCTAssertNotNil(thumbnail)
        XCTAssertEqual(thumbnail?.prefix(2), Data([0xFF, 0xD8]))
    }

    // MARK: - Helpers

    /// Build a JPEG with an Exif APP1 segment that includes IFD1 with an embedded thumbnail.
    private func makeJPEGWithThumbnail() -> Data {
        let thumbnailJPEG = makeTinyThumbnailJPEG()
        let exifData = buildExifWithThumbnail(byteOrder: .bigEndian, thumbnail: thumbnailJPEG)
        return TestFixtures.jpegWithSegment(marker: .app1, data: exifData)
    }

    /// Build a TIFF file with IFD0 + IFD1 (thumbnail).
    private func makeTIFFWithThumbnail() -> Data {
        let thumbnailJPEG = makeTinyThumbnailJPEG()
        return buildTIFFWithThumbnail(byteOrder: .littleEndian, thumbnail: thumbnailJPEG)
    }

    /// Generate a tiny valid JPEG to use as an embedded thumbnail.
    private func makeTinyThumbnailJPEG() -> Data {
        // Minimal valid JPEG: SOI + EOI with a small DQT/SOF/SOS in between
        // We just use SOI + some bytes + EOI as a recognizable marker
        var data = Data([0xFF, 0xD8]) // SOI
        data.append(contentsOf: [UInt8](repeating: 0x42, count: 16)) // dummy data
        data.append(contentsOf: [0xFF, 0xD9]) // EOI
        return data
    }

    /// Build an Exif APP1 payload containing IFD0 and IFD1 with a JPEG thumbnail.
    private func buildExifWithThumbnail(byteOrder: ByteOrder, thumbnail: Data) -> Data {
        var writer = BinaryWriter(capacity: 512)

        // "Exif\0\0"
        writer.writeBytes([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])

        // TIFF header (offsets are relative to this point)
        switch byteOrder {
        case .bigEndian: writer.writeBytes([0x4D, 0x4D])
        case .littleEndian: writer.writeBytes([0x49, 0x49])
        }
        writer.writeUInt16(42, endian: byteOrder)
        writer.writeUInt32(8, endian: byteOrder) // IFD0 at offset 8

        // IFD0: 1 entry (Make = "Hi\0" — 3 bytes, fits inline)
        writer.writeUInt16(1, endian: byteOrder)
        writer.writeUInt16(ExifTag.make, endian: byteOrder)
        writer.writeUInt16(TIFFDataType.ascii.rawValue, endian: byteOrder)
        writer.writeUInt32(3, endian: byteOrder) // count=3 fits inline (<=4)
        writer.writeBytes([0x48, 0x69, 0x00, 0x00]) // "Hi\0" + pad

        // Next IFD offset → IFD1
        let ifd1Offset: UInt32 = 8 + 2 + 12 + 4 // = 26
        writer.writeUInt32(ifd1Offset, endian: byteOrder)

        // IFD1: 3 entries
        writer.writeUInt16(3, endian: byteOrder)

        // Thumbnail data goes after IFD1: 26 + 2 + (3*12) + 4 = 68
        let thumbnailOffset: UInt32 = ifd1Offset + 2 + 36 + 4

        // Compression = 6 (JPEG) — short, inline
        writer.writeUInt16(ExifTag.compression, endian: byteOrder)
        writer.writeUInt16(TIFFDataType.short.rawValue, endian: byteOrder)
        writer.writeUInt32(1, endian: byteOrder)
        var c = Data(count: 4)
        if byteOrder == .bigEndian { c[0] = 0; c[1] = 6 }
        else { c[0] = 6; c[1] = 0 }
        writer.writeBytes(c)

        // JpegIFOffset — long, inline
        writer.writeUInt16(ExifTag.jpegIFOffset, endian: byteOrder)
        writer.writeUInt16(TIFFDataType.long.rawValue, endian: byteOrder)
        writer.writeUInt32(1, endian: byteOrder)
        writer.writeUInt32(thumbnailOffset, endian: byteOrder)

        // JpegIFByteCount — long, inline
        writer.writeUInt16(ExifTag.jpegIFByteCount, endian: byteOrder)
        writer.writeUInt16(TIFFDataType.long.rawValue, endian: byteOrder)
        writer.writeUInt32(1, endian: byteOrder)
        writer.writeUInt32(UInt32(thumbnail.count), endian: byteOrder)

        // No more IFDs
        writer.writeUInt32(0, endian: byteOrder)

        // Thumbnail data
        writer.writeBytes(thumbnail)

        return writer.data
    }

    /// Build a standalone TIFF file with IFD0 and IFD1 (JPEG thumbnail).
    private func buildTIFFWithThumbnail(byteOrder: ByteOrder, thumbnail: Data) -> Data {
        var writer = BinaryWriter(capacity: 512)

        // TIFF header (offsets relative to start = 0)
        switch byteOrder {
        case .bigEndian: writer.writeBytes([0x4D, 0x4D])
        case .littleEndian: writer.writeBytes([0x49, 0x49])
        }
        writer.writeUInt16(42, endian: byteOrder)
        writer.writeUInt32(8, endian: byteOrder) // IFD0 at offset 8

        // IFD0: 1 entry (Make = "Hi\0" — 3 bytes, inline)
        writer.writeUInt16(1, endian: byteOrder)
        writer.writeUInt16(ExifTag.make, endian: byteOrder)
        writer.writeUInt16(TIFFDataType.ascii.rawValue, endian: byteOrder)
        writer.writeUInt32(3, endian: byteOrder)
        writer.writeBytes([0x48, 0x69, 0x00, 0x00]) // "Hi\0" + pad

        // Next IFD offset → IFD1
        let ifd1Offset: UInt32 = 8 + 2 + 12 + 4 // = 26
        writer.writeUInt32(ifd1Offset, endian: byteOrder)

        // IFD1: 3 entries
        writer.writeUInt16(3, endian: byteOrder)
        let thumbnailOffset: UInt32 = ifd1Offset + 2 + 36 + 4

        // Compression = 6 (JPEG)
        writer.writeUInt16(ExifTag.compression, endian: byteOrder)
        writer.writeUInt16(TIFFDataType.short.rawValue, endian: byteOrder)
        writer.writeUInt32(1, endian: byteOrder)
        var c = Data(count: 4)
        if byteOrder == .bigEndian { c[0] = 0; c[1] = 6 }
        else { c[0] = 6; c[1] = 0 }
        writer.writeBytes(c)

        // JpegIFOffset
        writer.writeUInt16(ExifTag.jpegIFOffset, endian: byteOrder)
        writer.writeUInt16(TIFFDataType.long.rawValue, endian: byteOrder)
        writer.writeUInt32(1, endian: byteOrder)
        writer.writeUInt32(thumbnailOffset, endian: byteOrder)

        // JpegIFByteCount
        writer.writeUInt16(ExifTag.jpegIFByteCount, endian: byteOrder)
        writer.writeUInt16(TIFFDataType.long.rawValue, endian: byteOrder)
        writer.writeUInt32(1, endian: byteOrder)
        writer.writeUInt32(UInt32(thumbnail.count), endian: byteOrder)

        // No more IFDs
        writer.writeUInt32(0, endian: byteOrder)

        // Thumbnail data
        writer.writeBytes(thumbnail)

        return writer.data
    }
}
