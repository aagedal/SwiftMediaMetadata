import XCTest
@testable import SwiftExif

final class GIFParserTests: XCTestCase {

    // MARK: - Headers and signatures

    func testParseMinimalGIF89a() throws {
        let data = TestFixtures.minimalGIF()
        let file = try GIFParser.parse(data)

        XCTAssertEqual(file.width, 1)
        XCTAssertEqual(file.height, 1)

        var sawHeader = false
        var sawTrailer = false
        var sawLSD = false
        for block in file.blocks {
            switch block.type {
            case .header(let v):
                XCTAssertEqual(v, "89a")
                sawHeader = true
            case .logicalScreenDescriptor:
                sawLSD = true
            case .trailer:
                sawTrailer = true
            default: break
            }
        }
        XCTAssertTrue(sawHeader, "missing header block")
        XCTAssertTrue(sawLSD, "missing LSD block")
        XCTAssertTrue(sawTrailer, "missing trailer block")
    }

    func testParseGIF87a() throws {
        let data = TestFixtures.minimalGIF(version: "87a")
        let file = try GIFParser.parse(data)

        guard case .header(let v) = file.blocks.first?.type else {
            return XCTFail("expected header block first")
        }
        XCTAssertEqual(v, "87a")
    }

    func testTooSmallThrows() {
        let tiny = Data([0x47, 0x49, 0x46]) // 3 bytes
        XCTAssertThrowsError(try GIFParser.parse(tiny)) { error in
            guard case MetadataError.invalidGIF = error else {
                return XCTFail("expected invalidGIF, got \(error)")
            }
        }
    }

    func testInvalidSignatureThrows() {
        let garbage = Data(repeating: 0x00, count: 20)
        XCTAssertThrowsError(try GIFParser.parse(garbage)) { error in
            guard case MetadataError.invalidGIF = error else {
                return XCTFail("expected invalidGIF, got \(error)")
            }
        }
    }

    func testTruncatedLSDThrows() {
        // Header + 3 bytes of LSD (need 7)
        var data = Data("GIF89a".utf8)
        data.append(contentsOf: [0x01, 0x00, 0x01])
        XCTAssertThrowsError(try GIFParser.parse(data)) { error in
            guard case MetadataError.invalidGIF = error else {
                return XCTFail("expected invalidGIF, got \(error)")
            }
        }
    }

    func testTruncatedGlobalColorTableThrows() {
        // Packed byte 0x80 sets GCT flag with 0 size bits → 3 * 2 = 6 bytes of GCT.
        // Provide LSD but no GCT bytes after.
        var data = Data("GIF89a".utf8)
        data.append(contentsOf: [0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00])
        XCTAssertThrowsError(try GIFParser.parse(data)) { error in
            guard case MetadataError.invalidGIF = error else {
                return XCTFail("expected invalidGIF, got \(error)")
            }
        }
    }

    // MARK: - Sub-block hardening (regression for commit 591d590)

    /// Comment-extension path uses readSubBlocks which already had a guard, but
    /// confirm a truncated comment doesn't crash the parser regardless.
    func testTruncatedCommentSubBlockDoesNotCrash() {
        // Comment extension: 0x21 0xFE then a sub-block claiming 255 bytes but
        // only ~5 follow before the buffer ends (no trailer).
        var data = Data("GIF89a".utf8)
        data.append(contentsOf: [0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]) // LSD
        data.append(contentsOf: [0x21, 0xFE, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05])
        XCTAssertNoThrow(try GIFParser.parse(data))
    }

    /// Image-data path is the load-bearing one: pre-fix, `data[start..<off]`
    /// would trap when skipSubBlocks overshot data.count. Post-fix, off clamps
    /// to data.count and the slice is safe. See GIFParser.swift:184.
    func testTruncatedSubBlockInImageDataDoesNotCrash() {
        var data = Data("GIF89a".utf8)
        data.append(contentsOf: [0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]) // LSD (1×1, no GCT)
        data.append(0x2C) // Image Descriptor introducer
        // 9-byte image descriptor: left=0, top=0, w=1, h=1, packed=0 (no LCT)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
        data.append(0x00) // LZW minimum code size
        data.append(0xFF) // sub-block claims 255 bytes
        data.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05]) // only 5 follow
        // No trailer — buffer ends here. Pre-fix this would trap; post-fix the
        // parser tolerates the truncation and returns a partial GIFFile.
        XCTAssertNoThrow(try GIFParser.parse(data))
    }

    // MARK: - Comment extension

    func testCommentExtensionRoundTrip() throws {
        let comment = "Tromsø, Norge — test comment"
        let data = TestFixtures.minimalGIF(extraBlocks: [TestFixtures.gifCommentBlock(comment)])
        let file = try GIFParser.parse(data)

        XCTAssertEqual(file.comments, [comment])
    }

    // MARK: - XMP application extension

    func testApplicationExtensionXMPFound() throws {
        let xml = makeXMPXML(headline: "GIF Test", city: "Oslo")
        let data = TestFixtures.gifWithXMP(xml: xml)
        let file = try GIFParser.parse(data)

        XCTAssertNotNil(file.findXMPExtension(), "XMP Application Extension should be present")
        let xmp = try GIFParser.extractXMP(from: file)
        XCTAssertNotNil(xmp)
        XCTAssertEqual(xmp?.headline, "GIF Test")
        XCTAssertEqual(xmp?.city, "Oslo")
    }

    func testImageMetadataReadGIFXMP() throws {
        let xml = makeXMPXML(headline: "Headline 89a", city: "Bergen")
        let data = TestFixtures.gifWithXMP(xml: xml)
        let metadata = try ImageMetadata.read(from: data)

        XCTAssertEqual(metadata.format, .gif)
        XCTAssertNotNil(metadata.xmp)
        XCTAssertEqual(metadata.xmp?.headline, "Headline 89a")
        XCTAssertEqual(metadata.xmp?.city, "Bergen")
    }

    // MARK: - Helpers

    private func makeXMPXML(headline: String, city: String) -> String {
        """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                   xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
            <rdf:Description rdf:about=""
                             photoshop:Headline="\(headline)"
                             photoshop:City="\(city)"/>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }
}
