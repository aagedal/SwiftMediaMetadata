import XCTest
@testable import SwiftMediaMetadata

final class ImageMetadataTests: XCTestCase {

    func testReadFromJPEGData() throws {
        var iptc = IPTCData()
        iptc.headline = "Test"
        iptc.keywords = ["a", "b"]

        let jpeg = TestFixtures.jpegWithIPTC(datasets: iptc.datasets)
        let metadata = try ImageMetadata.read(from: jpeg)

        XCTAssertEqual(metadata.iptc.headline, "Test")
        XCTAssertEqual(metadata.iptc.keywords, ["a", "b"])
    }

    func testModifyAndWriteBack() throws {
        var iptc = IPTCData()
        iptc.headline = "Original"
        let jpeg = TestFixtures.jpegWithIPTC(datasets: iptc.datasets)

        var metadata = try ImageMetadata.read(from: jpeg)
        metadata.iptc.headline = "Modified"
        metadata.iptc.keywords = ["new", "keywords"]

        let modifiedData = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: modifiedData)

        XCTAssertEqual(reparsed.iptc.headline, "Modified")
        XCTAssertEqual(reparsed.iptc.keywords, ["new", "keywords"])
    }

    /// Regression: star-rating a JPEG whose IPTC By-line was authored over the
    /// 32-byte spec limit (common in agency/wire photos) must succeed. The write
    /// re-serializes the whole IPTC block, so an over-length pre-existing field
    /// used to abort the unrelated rating edit. It must now round-trip intact
    /// and surface a non-fatal warning instead.
    func testWritePreservesOverLengthIPTCWhenSettingRating() throws {
        var iptc = IPTCData()
        let overLongByline = "Alessandro Bremec / ipa-agency.net" // 34 bytes > 32
        iptc.byline = overLongByline
        let jpeg = TestFixtures.jpegWithIPTC(datasets: iptc.datasets)

        var metadata = try ImageMetadata.read(from: jpeg)
        XCTAssertEqual(metadata.iptc.byline, overLongByline)

        // Set an XMP star rating, exactly as a photo app would.
        if metadata.xmp == nil { metadata.xmp = XMPData() }
        metadata.xmp?.setValue(.simple("4"),
                               namespace: "http://ns.adobe.com/xap/1.0/", property: "Rating")

        let (data, warnings) = try metadata.writeToDataWithWarnings()
        let reparsed = try ImageMetadata.read(from: data)

        XCTAssertEqual(reparsed.iptc.byline, overLongByline, "Over-length By-line must be preserved")
        XCTAssertEqual(reparsed.xmp?.simpleValue(namespace: "http://ns.adobe.com/xap/1.0/",
                                                 property: "Rating"), "4")
        XCTAssertTrue(warnings.contains { $0.contains("By-line") },
                      "Expected a non-fatal over-length warning, got \(warnings)")
    }

    func testAddIPTCToJPEGWithNone() throws {
        let jpeg = TestFixtures.minimalJPEG()
        var metadata = try ImageMetadata.read(from: jpeg)

        XCTAssertNil(metadata.iptc.headline)

        metadata.iptc.headline = "Added Headline"
        metadata.iptc.byline = "Photographer"

        let modifiedData = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: modifiedData)

        XCTAssertEqual(reparsed.iptc.headline, "Added Headline")
        XCTAssertEqual(reparsed.iptc.byline, "Photographer")
    }

    func testIPTCToXMPSync() throws {
        var metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        metadata.iptc.headline = "Sync Test"
        metadata.iptc.city = "Oslo"
        metadata.iptc.keywords = ["test", "sync"]
        metadata.iptc.bylines = ["Photographer"]
        metadata.iptc.copyright = "© 2026"
        metadata.iptc.caption = "A test caption"
        metadata.iptc.countryName = "Norway"

        metadata.syncIPTCToXMP()

        XCTAssertNotNil(metadata.xmp)
        XCTAssertEqual(metadata.xmp?.headline, "Sync Test")
        XCTAssertEqual(metadata.xmp?.city, "Oslo")
        XCTAssertEqual(metadata.xmp?.subject, ["test", "sync"])
        XCTAssertEqual(metadata.xmp?.creator, ["Photographer"])
        XCTAssertEqual(metadata.xmp?.rights, "© 2026")
        XCTAssertEqual(metadata.xmp?.description, "A test caption")
        XCTAssertEqual(metadata.xmp?.country, "Norway")
    }

    func testXMPToIPTCSync() throws {
        var metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "From XMP"
        metadata.xmp?.city = "Bergen"
        metadata.xmp?.subject = ["xmp", "keywords"]

        try metadata.syncXMPToIPTC()

        XCTAssertEqual(metadata.iptc.headline, "From XMP")
        XCTAssertEqual(metadata.iptc.city, "Bergen")
        XCTAssertEqual(metadata.iptc.keywords, ["xmp", "keywords"])
    }

    func testNoWarningsWhenClean() throws {
        let jpeg = TestFixtures.minimalJPEG()
        let metadata = try ImageMetadata.read(from: jpeg)
        XCTAssertTrue(metadata.warnings.isEmpty)
    }

    func testCorruptedC2PAProducesWarning() throws {
        // Build APP11 segment with valid framing but a jumb box whose
        // first child is "free" instead of "jumd" — triggers parseSuperbox error
        var segmentData = Data()
        segmentData.append(contentsOf: [0x4A, 0x50])             // "JP" common identifier
        segmentData.append(contentsOf: [0x00, 0x01])             // instance number 1
        segmentData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // sequence number 1
        // JUMBF payload: a "jumb" box containing a "free" box (no jumd descriptor)
        segmentData.append(contentsOf: [0x00, 0x00, 0x00, 0x14]) // jumb size = 20
        segmentData.append(contentsOf: [0x6A, 0x75, 0x6D, 0x62]) // "jumb"
        segmentData.append(contentsOf: [0x00, 0x00, 0x00, 0x08]) // free size = 8
        segmentData.append(contentsOf: [0x66, 0x72, 0x65, 0x65]) // "free"
        segmentData.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // padding

        let jpeg = TestFixtures.jpegWithSegment(marker: .app11, data: segmentData)
        let metadata = try ImageMetadata.read(from: jpeg)

        // Read should succeed — other metadata is fine
        XCTAssertNil(metadata.c2pa)
        // But the warning should tell us C2PA parsing failed
        XCTAssertFalse(metadata.warnings.isEmpty, "Expected a C2PA warning for corrupted data")
        XCTAssertTrue(metadata.warnings.first?.contains("C2PA") == true)
    }

    func testImageDataPreserved() throws {
        let original = TestFixtures.minimalJPEG()
        let originalFile = try JPEGParser.parse(original)

        var metadata = try ImageMetadata.read(from: original)
        metadata.iptc.headline = "Metadata Added"
        metadata.iptc.keywords = ["one", "two", "three"]
        metadata.iptc.caption = "A longer caption for the test image"

        let modified = try metadata.writeToData()
        let modifiedFile = try JPEGParser.parse(modified)

        // Scan data (image) must be identical
        XCTAssertEqual(originalFile.scanData, modifiedFile.scanData)
    }
}
