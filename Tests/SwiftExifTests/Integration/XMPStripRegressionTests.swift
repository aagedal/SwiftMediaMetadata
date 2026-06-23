import XCTest
@testable import SwiftExif

/// Regression: writing metadata with `xmp == nil` must REMOVE an existing
/// embedded XMP packet, not silently preserve it. Previously the JPEG/PNG/JXL
/// writers only wrote XMP when present and had no else-branch to drop a
/// stripped packet, so "remove all metadata" left the original XMP behind.
final class XMPStripRegressionTests: XCTestCase {

    func testJPEGStripXMPRemovesSegment() throws {
        // Build a JPEG that carries an XMP packet.
        let jpegFile = try JPEGParser.parse(TestFixtures.minimalJPEG())
        var metadata = ImageMetadata(container: .jpeg(jpegFile), format: .jpeg)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "To be stripped"
        metadata.xmp?.subject = ["keyword", "another"]
        let withXMP = try metadata.writeToData()

        // Sanity: the XMP really is embedded.
        let parsedWith = try JPEGParser.parse(withXMP)
        XCTAssertTrue(parsedWith.segments.contains { $0.isXMP }, "fixture should embed an XMP segment")
        XCTAssertEqual(try ImageMetadata.read(from: withXMP).xmp?.headline, "To be stripped")

        // Strip XMP and write again.
        var stripped = try ImageMetadata.read(from: withXMP)
        stripped.stripXMP()
        let withoutXMP = try stripped.writeToData()

        // The APP1 XMP segment must be gone, and the field must not read back.
        let parsedWithout = try JPEGParser.parse(withoutXMP)
        XCTAssertFalse(parsedWithout.segments.contains { $0.isXMP }, "XMP segment should be removed after strip")
        XCTAssertNil(try ImageMetadata.read(from: withoutXMP).xmp?.headline)
    }

    func testPNGStripXMPRemovesChunk() throws {
        let original = TestFixtures.pngWithExif(make: "PNG Cam", model: "P-1")
        var metadata = try ImageMetadata.read(from: original)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "PNG XMP"
        let withXMP = try metadata.writeToData()
        XCTAssertEqual(try ImageMetadata.read(from: withXMP).xmp?.headline, "PNG XMP")

        var stripped = try ImageMetadata.read(from: withXMP)
        stripped.stripXMP()
        let withoutXMP = try stripped.writeToData()

        XCTAssertNil(try ImageMetadata.read(from: withoutXMP).xmp?.headline)
        // Exif must survive an XMP-only strip.
        XCTAssertEqual(try ImageMetadata.read(from: withoutXMP).exif?.make, "PNG Cam")
    }

    func testJXLStripXMPRemovesBox() throws {
        let original = TestFixtures.jxlWithExif(make: "JXL Cam")
        var metadata = try ImageMetadata.read(from: original)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "JXL XMP"
        let withXMP = try metadata.writeToData()
        XCTAssertEqual(try ImageMetadata.read(from: withXMP).xmp?.headline, "JXL XMP")

        var stripped = try ImageMetadata.read(from: withXMP)
        stripped.stripXMP()
        let withoutXMP = try stripped.writeToData()

        XCTAssertNil(try ImageMetadata.read(from: withoutXMP).xmp?.headline)
        XCTAssertEqual(try ImageMetadata.read(from: withoutXMP).exif?.make, "JXL Cam")
    }
}
