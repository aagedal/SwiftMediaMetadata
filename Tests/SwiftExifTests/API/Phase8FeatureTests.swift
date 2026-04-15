import XCTest
@testable import SwiftExif

// MARK: - SubSecTime and OffsetTime Tag Tests

final class SubSecTimeTests: XCTestCase {

    private func makeExifWithSubSec() -> ExifData {
        let byteOrder = ByteOrder.bigEndian

        let dateStr = "2024:06:15 14:30:45\0"
        let dateEntry = IFDEntry(tag: ExifTag.dateTimeOriginal, type: .ascii,
                                 count: UInt32(dateStr.utf8.count), valueData: Data(dateStr.utf8))

        let subSec = "123\0"
        let subSecEntry = IFDEntry(tag: ExifTag.subSecTimeOriginal, type: .ascii,
                                   count: UInt32(subSec.utf8.count), valueData: Data(subSec.utf8))

        let offset = "+02:00\0"
        let offsetEntry = IFDEntry(tag: ExifTag.offsetTimeOriginal, type: .ascii,
                                   count: UInt32(offset.utf8.count), valueData: Data(offset.utf8))

        let subSecTime = "456\0"
        let subSecTimeEntry = IFDEntry(tag: ExifTag.subSecTime, type: .ascii,
                                       count: UInt32(subSecTime.utf8.count), valueData: Data(subSecTime.utf8))

        let offsetTime = "-05:30\0"
        let offsetTimeEntry = IFDEntry(tag: ExifTag.offsetTime, type: .ascii,
                                       count: UInt32(offsetTime.utf8.count), valueData: Data(offsetTime.utf8))

        let subSecDig = "789\0"
        let subSecDigEntry = IFDEntry(tag: ExifTag.subSecTimeDigitized, type: .ascii,
                                      count: UInt32(subSecDig.utf8.count), valueData: Data(subSecDig.utf8))

        let offsetDig = "+09:00\0"
        let offsetDigEntry = IFDEntry(tag: ExifTag.offsetTimeDigitized, type: .ascii,
                                      count: UInt32(offsetDig.utf8.count), valueData: Data(offsetDig.utf8))

        let exifIFD = IFD(entries: [dateEntry, subSecEntry, offsetEntry,
                                    subSecTimeEntry, offsetTimeEntry,
                                    subSecDigEntry, offsetDigEntry])

        var exif = ExifData(byteOrder: byteOrder)
        exif.exifIFD = exifIFD
        return exif
    }

    func testSubSecTimeOriginalAccessor() {
        let exif = makeExifWithSubSec()
        XCTAssertEqual(exif.subSecTimeOriginal, "123")
    }

    func testSubSecTimeAccessor() {
        let exif = makeExifWithSubSec()
        XCTAssertEqual(exif.subSecTime, "456")
    }

    func testSubSecTimeDigitizedAccessor() {
        let exif = makeExifWithSubSec()
        XCTAssertEqual(exif.subSecTimeDigitized, "789")
    }

    func testOffsetTimeOriginalAccessor() {
        let exif = makeExifWithSubSec()
        XCTAssertEqual(exif.offsetTimeOriginal, "+02:00")
    }

    func testOffsetTimeAccessor() {
        let exif = makeExifWithSubSec()
        XCTAssertEqual(exif.offsetTime, "-05:30")
    }

    func testOffsetTimeDigitizedAccessor() {
        let exif = makeExifWithSubSec()
        XCTAssertEqual(exif.offsetTimeDigitized, "+09:00")
    }

    func testSubSecTimeExportedInDictionary() {
        let exif = makeExifWithSubSec()
        let metadata = ImageMetadata(format: .jpeg, exif: exif)
        let dict = MetadataExporter.buildDictionary(metadata)

        XCTAssertEqual(dict["SubSecTimeOriginal"] as? String, "123")
        XCTAssertEqual(dict["SubSecTime"] as? String, "456")
        XCTAssertEqual(dict["SubSecTimeDigitized"] as? String, "789")
        XCTAssertEqual(dict["OffsetTimeOriginal"] as? String, "+02:00")
        XCTAssertEqual(dict["OffsetTime"] as? String, "-05:30")
        XCTAssertEqual(dict["OffsetTimeDigitized"] as? String, "+09:00")
    }

    func testExifTagNameLookup() {
        XCTAssertEqual(ExifTag.name(for: 0x9290, ifd: .exifIFD), "SubSecTime")
        XCTAssertEqual(ExifTag.name(for: 0x9291, ifd: .exifIFD), "SubSecTimeOriginal")
        XCTAssertEqual(ExifTag.name(for: 0x9292, ifd: .exifIFD), "SubSecTimeDigitized")
        XCTAssertEqual(ExifTag.name(for: 0x9010, ifd: .exifIFD), "OffsetTime")
        XCTAssertEqual(ExifTag.name(for: 0x9011, ifd: .exifIFD), "OffsetTimeOriginal")
        XCTAssertEqual(ExifTag.name(for: 0x9012, ifd: .exifIFD), "OffsetTimeDigitized")
    }

    func testExifTagReverseLookup() {
        XCTAssertEqual(ExifTag.tagID(for: "SubSecTime", ifd: .exifIFD), 0x9290)
        XCTAssertEqual(ExifTag.tagID(for: "OffsetTimeOriginal", ifd: .exifIFD), 0x9011)
        XCTAssertNil(ExifTag.tagID(for: "NonExistentTag", ifd: .exifIFD))
    }
}

// MARK: - Timezone Offset Parsing Tests

final class TimezoneParsingTests: XCTestCase {

    func testParsePositiveOffset() {
        let offset = ImageMetadata.parseTimezoneOffset("+02:00")
        XCTAssertEqual(offset, 7200)
    }

    func testParseNegativeOffset() {
        let offset = ImageMetadata.parseTimezoneOffset("-05:30")
        XCTAssertEqual(offset, -19800)
    }

    func testParseZeroOffset() {
        let offset = ImageMetadata.parseTimezoneOffset("+00:00")
        XCTAssertEqual(offset, 0)
    }

    func testParseInvalidOffset() {
        XCTAssertNil(ImageMetadata.parseTimezoneOffset("abc"))
        XCTAssertNil(ImageMetadata.parseTimezoneOffset("+2"))
    }
}

// MARK: - Individual Tag Deletion Tests

final class TagDeletionTests: XCTestCase {

    private func makeMetadataWithTags() -> ImageMetadata {
        let byteOrder = ByteOrder.bigEndian

        // IFD0
        let makeData = Data("Canon\0".utf8)
        let makeEntry = IFDEntry(tag: ExifTag.make, type: .ascii, count: UInt32(makeData.count), valueData: makeData)
        let modelData = Data("EOS R5\0".utf8)
        let modelEntry = IFDEntry(tag: ExifTag.model, type: .ascii, count: UInt32(modelData.count), valueData: modelData)
        let ifd0 = IFD(entries: [makeEntry, modelEntry])

        // Exif Sub-IFD
        var isoData = Data([0x01, 0x90, 0x00, 0x00]) // ISO 400 big-endian
        let isoEntry = IFDEntry(tag: ExifTag.isoSpeedRatings, type: .short, count: 1, valueData: isoData)
        let dateStr = "2024:06:15 14:30:45\0"
        let dateEntry = IFDEntry(tag: ExifTag.dateTimeOriginal, type: .ascii,
                                 count: UInt32(dateStr.utf8.count), valueData: Data(dateStr.utf8))
        let exifIFD = IFD(entries: [isoEntry, dateEntry])

        // GPS IFD
        let latRefData = Data("N\0".utf8)
        let latRefEntry = IFDEntry(tag: ExifTag.gpsLatitudeRef, type: .ascii, count: 2, valueData: latRefData)
        let gpsIFD = IFD(entries: [latRefEntry])

        var exif = ExifData(byteOrder: byteOrder)
        exif.ifd0 = ifd0
        exif.exifIFD = exifIFD
        exif.gpsIFD = gpsIFD

        // IPTC
        var iptc = IPTCData()
        try? iptc.setValue("Test Headline", for: .headline)
        try? iptc.setValue("Test City", for: .city)
        iptc.keywords = ["photo", "test"]

        // XMP
        var xmp = XMPData()
        xmp.title = "Test Title"
        xmp.description = "Test Description"

        return ImageMetadata(format: .jpeg, iptc: iptc, exif: exif, xmp: xmp)
    }

    // MARK: - EXIF Tag Deletion

    func testRemoveExifTagFromIFD0() {
        var metadata = makeMetadataWithTags()
        XCTAssertNotNil(metadata.exif?.make)

        let removed = metadata.removeExifTag(ExifTag.make)
        XCTAssertTrue(removed)
        XCTAssertNil(metadata.exif?.make)
        // Model should still be there
        XCTAssertNotNil(metadata.exif?.model)
    }

    func testRemoveExifSubIFDTag() {
        var metadata = makeMetadataWithTags()
        XCTAssertNotNil(metadata.exif?.isoSpeed)

        let removed = metadata.removeExifSubIFDTag(ExifTag.isoSpeedRatings)
        XCTAssertTrue(removed)
        XCTAssertNil(metadata.exif?.isoSpeed)
        // DateTimeOriginal should still be there
        XCTAssertNotNil(metadata.exif?.dateTimeOriginal)
    }

    func testRemoveGPSTag() {
        var metadata = makeMetadataWithTags()
        XCTAssertNotNil(metadata.exif?.gpsIFD?.entry(for: ExifTag.gpsLatitudeRef))

        let removed = metadata.removeGPSTag(ExifTag.gpsLatitudeRef)
        XCTAssertTrue(removed)
        XCTAssertNil(metadata.exif?.gpsIFD?.entry(for: ExifTag.gpsLatitudeRef))
    }

    func testRemoveNonExistentExifTagReturnsFalse() {
        var metadata = makeMetadataWithTags()
        let removed = metadata.removeExifTag(ExifTag.copyright) // not set
        XCTAssertFalse(removed)
    }

    // MARK: - IPTC Tag Deletion

    func testRemoveIPTCTag() {
        var metadata = makeMetadataWithTags()
        XCTAssertEqual(metadata.iptc.headline, "Test Headline")

        let removed = metadata.removeIPTCTag(.headline)
        XCTAssertTrue(removed)
        XCTAssertNil(metadata.iptc.headline)
        // City should still be there
        XCTAssertEqual(metadata.iptc.city, "Test City")
    }

    func testRemoveIPTCKeywords() {
        var metadata = makeMetadataWithTags()
        XCTAssertEqual(metadata.iptc.keywords.count, 2)

        let removed = metadata.removeIPTCTag(.keywords)
        XCTAssertTrue(removed)
        XCTAssertTrue(metadata.iptc.keywords.isEmpty)
    }

    func testRemoveNonExistentIPTCTagReturnsFalse() {
        var metadata = makeMetadataWithTags()
        let removed = metadata.removeIPTCTag(.source) // not set
        XCTAssertFalse(removed)
    }

    // MARK: - XMP Property Deletion

    func testRemoveXMPProperty() {
        var metadata = makeMetadataWithTags()
        XCTAssertEqual(metadata.xmp?.title, "Test Title")

        let removed = metadata.removeXMPProperty(namespace: XMPNamespace.dc, property: "title")
        XCTAssertTrue(removed)
        XCTAssertNil(metadata.xmp?.title)
        // Description should still be there
        XCTAssertEqual(metadata.xmp?.description, "Test Description")
    }

    func testRemoveNonExistentXMPPropertyReturnsFalse() {
        var metadata = makeMetadataWithTags()
        let removed = metadata.removeXMPProperty(namespace: XMPNamespace.dc, property: "rights")
        XCTAssertFalse(removed)
    }

    // MARK: - Qualified Name Tag Deletion

    func testRemoveTagByQualifiedNameEXIF() {
        var metadata = makeMetadataWithTags()
        let removed = metadata.removeTag("EXIF:Make")
        XCTAssertTrue(removed)
        XCTAssertNil(metadata.exif?.make)
    }

    func testRemoveTagByQualifiedNameExifIFD() {
        var metadata = makeMetadataWithTags()
        let removed = metadata.removeTag("ExifIFD:DateTimeOriginal")
        XCTAssertTrue(removed)
        XCTAssertNil(metadata.exif?.dateTimeOriginal)
    }

    func testRemoveTagByQualifiedNameGPS() {
        var metadata = makeMetadataWithTags()
        let removed = metadata.removeTag("GPS:GPSLatitudeRef")
        XCTAssertTrue(removed)
        XCTAssertNil(metadata.exif?.gpsIFD?.entry(for: ExifTag.gpsLatitudeRef))
    }

    func testRemoveTagByQualifiedNameIPTC() {
        var metadata = makeMetadataWithTags()
        let removed = metadata.removeTag("IPTC:Headline")
        XCTAssertTrue(removed)
        XCTAssertNil(metadata.iptc.headline)
    }

    func testRemoveTagByQualifiedNameXMP() {
        var metadata = makeMetadataWithTags()
        let removed = metadata.removeTag("XMP-dc:title")
        XCTAssertTrue(removed)
        XCTAssertNil(metadata.xmp?.title)
    }

    func testRemoveTagByInvalidQualifiedNameReturnsFalse() {
        var metadata = makeMetadataWithTags()
        XCTAssertFalse(metadata.removeTag("INVALID:Something"))
        XCTAssertFalse(metadata.removeTag("EXIF:NonExistentTag"))
        XCTAssertFalse(metadata.removeTag("IPTC:NonExistentTag"))
    }
}

// MARK: - Safe Write Tests

final class SafeWriteTests: XCTestCase {

    private func makeMinimalJPEG() -> Data {
        // Minimal valid JPEG: SOI + EOI
        return Data([0xFF, 0xD8, 0xFF, 0xD9])
    }

    private func createTempDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    func testWriteOptionsDefaults() {
        let opts = ImageMetadata.WriteOptions.default
        XCTAssertTrue(opts.atomic)
        XCTAssertFalse(opts.createBackup)
        XCTAssertEqual(opts.backupSuffix, "_original")
    }

    func testWriteOptionsSafe() {
        let opts = ImageMetadata.WriteOptions.safe
        XCTAssertTrue(opts.atomic)
        XCTAssertTrue(opts.createBackup)
    }

    func testBackupURLGeneration() {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        let backup = ImageMetadata.backupURL(for: url)
        XCTAssertEqual(backup.lastPathComponent, "photo.jpg_original")
    }

    func testBackupURLCustomSuffix() {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        let backup = ImageMetadata.backupURL(for: url, suffix: ".bak")
        XCTAssertEqual(backup.lastPathComponent, "photo.jpg.bak")
    }

    func testAtomicWriteCreatesFile() throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jpegData = makeMinimalJPEG()
        let fileURL = tempDir.appendingPathComponent("test.jpg")
        try jpegData.write(to: fileURL)

        var metadata = try ImageMetadata.read(from: fileURL)
        metadata.iptc.headline = "Atomic Test"
        try metadata.write(to: fileURL, options: .default)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let reread = try ImageMetadata.read(from: fileURL)
        XCTAssertEqual(reread.iptc.headline, "Atomic Test")
    }

    func testWriteWithBackupCreatesBackupFile() throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jpegData = makeMinimalJPEG()
        let fileURL = tempDir.appendingPathComponent("test.jpg")
        try jpegData.write(to: fileURL)

        let originalData = try Data(contentsOf: fileURL)

        var metadata = try ImageMetadata.read(from: fileURL)
        metadata.iptc.headline = "Backup Test"
        try metadata.write(to: fileURL, options: .safe)

        // Original should be modified
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Backup should exist
        let backupURL = ImageMetadata.backupURL(for: fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        // Backup should contain the original data
        let backupData = try Data(contentsOf: backupURL)
        XCTAssertEqual(backupData, originalData)
    }

    func testWriteWithBackupCustomSuffix() throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jpegData = makeMinimalJPEG()
        let fileURL = tempDir.appendingPathComponent("test.jpg")
        try jpegData.write(to: fileURL)

        var metadata = try ImageMetadata.read(from: fileURL)
        let options = ImageMetadata.WriteOptions(atomic: true, createBackup: true, backupSuffix: ".bak")
        try metadata.write(to: fileURL, options: options)

        let backupURL = ImageMetadata.backupURL(for: fileURL, suffix: ".bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testNonAtomicWrite() throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jpegData = makeMinimalJPEG()
        let fileURL = tempDir.appendingPathComponent("test.jpg")
        try jpegData.write(to: fileURL)

        var metadata = try ImageMetadata.read(from: fileURL)
        metadata.iptc.headline = "Non-Atomic"
        let options = ImageMetadata.WriteOptions(atomic: false, createBackup: false)
        try metadata.write(to: fileURL, options: options)

        let reread = try ImageMetadata.read(from: fileURL)
        XCTAssertEqual(reread.iptc.headline, "Non-Atomic")
    }

    func testWriteToNewFileNoBackupNeeded() throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jpegData = makeMinimalJPEG()
        let sourceURL = tempDir.appendingPathComponent("source.jpg")
        try jpegData.write(to: sourceURL)

        let metadata = try ImageMetadata.read(from: sourceURL)
        let destURL = tempDir.appendingPathComponent("new.jpg")
        try metadata.write(to: destURL, options: .safe)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        // No backup since original didn't exist at destURL
        let backupURL = ImageMetadata.backupURL(for: destURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }
}

// MARK: - IFD Helper Tests

final class IFDHelperTests: XCTestCase {

    func testRemovingEntry() {
        let entry1 = IFDEntry(tag: 0x0100, type: .short, count: 1, valueData: Data([0, 1, 0, 0]))
        let entry2 = IFDEntry(tag: 0x0101, type: .short, count: 1, valueData: Data([0, 2, 0, 0]))
        let ifd = IFD(entries: [entry1, entry2])

        let result = ifd.removingEntry(for: 0x0100)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].tag, 0x0101)
    }

    func testRemovingNonExistentEntry() {
        let entry1 = IFDEntry(tag: 0x0100, type: .short, count: 1, valueData: Data([0, 1, 0, 0]))
        let ifd = IFD(entries: [entry1])

        let result = ifd.removingEntry(for: 0x9999)
        XCTAssertEqual(result.entries.count, 1)
    }

    func testHasEntry() {
        let entry = IFDEntry(tag: 0x0100, type: .short, count: 1, valueData: Data([0, 1, 0, 0]))
        let ifd = IFD(entries: [entry])

        XCTAssertTrue(ifd.hasEntry(for: 0x0100))
        XCTAssertFalse(ifd.hasEntry(for: 0x0101))
    }
}

// MARK: - IPTC & XMP Reverse Lookup Tests

final class ReverseLookupTests: XCTestCase {

    func testIPTCByName() {
        XCTAssertEqual(IPTCTag.byName("Headline"), .headline)
        XCTAssertEqual(IPTCTag.byName("Keywords"), .keywords)
        XCTAssertEqual(IPTCTag.byName("City"), .city)
        XCTAssertEqual(IPTCTag.byName("By-line"), .byline)
        XCTAssertNil(IPTCTag.byName("NonExistent"))
    }

    func testXMPNamespaceForPrefix() {
        XCTAssertEqual(XMPNamespace.namespace(for: "dc"), XMPNamespace.dc)
        XCTAssertEqual(XMPNamespace.namespace(for: "photoshop"), XMPNamespace.photoshop)
        XCTAssertEqual(XMPNamespace.namespace(for: "Iptc4xmpCore"), XMPNamespace.iptcCore)
        XCTAssertNil(XMPNamespace.namespace(for: "nonexistent"))
    }
}
