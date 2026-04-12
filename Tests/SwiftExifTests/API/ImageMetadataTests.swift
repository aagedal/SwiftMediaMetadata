import XCTest
@testable import SwiftExif

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

        metadata.syncXMPToIPTC()

        XCTAssertEqual(metadata.iptc.headline, "From XMP")
        XCTAssertEqual(metadata.iptc.city, "Bergen")
        XCTAssertEqual(metadata.iptc.keywords, ["xmp", "keywords"])
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
