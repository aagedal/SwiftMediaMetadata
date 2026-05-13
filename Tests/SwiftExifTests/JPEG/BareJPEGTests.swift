import XCTest
@testable import SwiftExif

/// Guards against regression on JPEGs that carry zero metadata segments
/// (or only the small ones Apple's `CIContext.jpegRepresentation` emits).
final class BareJPEGTests: XCTestCase {

    // MARK: - Hand-built bare JPEG (no APP markers)

    func testParseBareJPEGSucceeds() throws {
        let file = try JPEGParser.parse(TestFixtures.bareJPEG())

        XCTAssertTrue(file.segments.allSatisfy { ($0.rawMarker & 0xFFF0) != 0xFFE0 },
                      "bare JPEG must contain no APP markers")
        XCTAssertNotNil(file.findSegment(.dqt))
        XCTAssertNotNil(file.findSegment(.sof0))
        XCTAssertNotNil(file.findSegment(.dht))

        XCTAssertEqual(file.scanData.prefix(2), Data([0xFF, 0xDA]), "scanData starts at SOS")
        XCTAssertEqual(file.scanData.suffix(2), Data([0xFF, 0xD9]), "scanData ends at EOI")
    }

    func testReadMetadataBareJPEGHandBuilt() throws {
        let metadata = try ImageMetadata.read(from: TestFixtures.bareJPEG())

        XCTAssertTrue(metadata.iptc.datasets.isEmpty)
        XCTAssertNil(metadata.exif)
        XCTAssertNil(metadata.xmp)
        XCTAssertNil(metadata.c2pa)
        XCTAssertNil(metadata.iccProfile)
        XCTAssertNil(metadata.mpf)
        XCTAssertTrue(metadata.warnings.isEmpty, "unexpected warnings: \(metadata.warnings)")
    }

    func testRoundTripWriteIPTCToBareJPEG() throws {
        var metadata = try ImageMetadata.read(from: TestFixtures.bareJPEG())
        metadata.iptc.headline = "Round-trip headline"
        metadata.iptc.keywords = ["alpha", "beta"]

        let written = try metadata.writeToData()
        let reread = try ImageMetadata.read(from: written)

        XCTAssertEqual(reread.iptc.headline, "Round-trip headline")
        XCTAssertEqual(reread.iptc.keywords, ["alpha", "beta"])
    }

    func testRoundTripWriteXMPToBareJPEG() throws {
        var metadata = try ImageMetadata.read(from: TestFixtures.bareJPEG())
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Bare round-trip"
        metadata.xmp?.subject = ["round-trip", "xmp"]

        let written = try metadata.writeToData()
        let reread = try ImageMetadata.read(from: written)

        XCTAssertEqual(reread.xmp?.headline, "Bare round-trip")
        XCTAssertEqual(reread.xmp?.subject ?? [], ["round-trip", "xmp"])
    }

    // MARK: - Real CIContext-generated fixture

    func testReadMetadataBareCIContextFixture() throws {
        guard let url = Bundle.module.url(
            forResource: "bare-cicontext",
            withExtension: "jpg",
            subdirectory: "Fixtures/Resources"
        ) ?? Bundle.module.url(forResource: "bare-cicontext", withExtension: "jpg")
        else {
            XCTFail("bare-cicontext.jpg fixture not found in Bundle.module")
            return
        }
        let metadata = try ImageMetadata.read(from: url)

        // The CIContext output on macOS 26 carries an Exif APP1 segment with
        // resolution/ResolutionUnit/YCbCrPositioning entries — and nothing else
        // the metadata pipeline cares about. The bug report claimed read failure,
        // but on current macOS this round-trips cleanly. This test pins the
        // behavior so any future regression is caught immediately.
        XCTAssertNotNil(metadata.exif)
        XCTAssertNil(metadata.xmp)
        XCTAssertNil(metadata.c2pa)
        XCTAssertNil(metadata.iccProfile)
        XCTAssertNil(metadata.mpf)
        XCTAssertTrue(metadata.warnings.isEmpty, "unexpected warnings: \(metadata.warnings)")
    }

    // MARK: - LocalizedError surface

    func testMetadataErrorHasLocalizedDescription() {
        let cases: [(MetadataError, String)] = [
            (.notAJPEG, "Not a valid JPEG file (missing SOI marker)"),
            (.unexpectedEndOfData, "Unexpected end of data"),
            (.invalidSegmentLength, "Invalid JPEG segment length"),
            (.invalidMarker(0xFE), "Invalid JPEG marker: 0xFE"),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(
                (error as NSError).localizedDescription,
                expected,
                "NSError bridge should surface MetadataError.description, not the default \"(error N)\" string."
            )
        }
    }
}
