import XCTest
@testable import SwiftExif

final class WebPParserTests: XCTestCase {

    func testParseMinimalWebP() throws {
        let webp = TestFixtures.minimalWebP()
        let file = try WebPParser.parse(webp)

        XCTAssertFalse(file.chunks.isEmpty)
        XCTAssertNotNil(file.findChunk("VP8 "))
    }

    func testParseWebPWithVP8X() throws {
        let webp = TestFixtures.webpWithExif(make: "Canon")
        let file = try WebPParser.parse(webp)

        XCTAssertNotNil(file.findChunk("VP8X"))
        XCTAssertNotNil(file.findChunk("EXIF"))
    }

    func testWebPWithExif() throws {
        let webp = TestFixtures.webpWithExif(make: "Sony", model: "A7R V")
        let metadata = try ImageMetadata.read(from: webp)

        XCTAssertEqual(metadata.format, .webp)
        XCTAssertNotNil(metadata.exif)
        XCTAssertEqual(metadata.exif?.make, "Sony")
        XCTAssertEqual(metadata.exif?.model, "A7R V")
    }

    func testWebPWithoutMetadata() throws {
        let webp = TestFixtures.minimalWebP()
        let metadata = try ImageMetadata.read(from: webp)

        XCTAssertEqual(metadata.format, .webp)
        XCTAssertNil(metadata.exif)
        XCTAssertNil(metadata.xmp)
    }

    func testInvalidWebPThrows() {
        let garbage = Data(repeating: 0xCC, count: 20)
        XCTAssertThrowsError(try WebPParser.parse(garbage))
    }

    func testWebPTooSmallThrows() {
        XCTAssertThrowsError(try WebPParser.parse(Data([0x52, 0x49])))
    }

    func testWebPMissingWebPSignatureThrows() {
        // Valid RIFF header but wrong form type
        var data = Data("RIFF".utf8)
        data.append(contentsOf: [0x04, 0x00, 0x00, 0x00]) // size
        data.append(contentsOf: "AVI ".utf8) // Not WEBP
        XCTAssertThrowsError(try WebPParser.parse(data))
    }

    func testFormatDetectionFromMagicBytes() {
        let webp = TestFixtures.minimalWebP()
        let format = FormatDetector.detect(webp)
        XCTAssertEqual(format, .webp)
    }

    func testFormatDetectionFromExtension() {
        let format = FormatDetector.detectFromExtension("webp")
        XCTAssertEqual(format, .webp)
    }

    func testChunkPaddingHandled() throws {
        // Create WebP with odd-sized EXIF chunk to test padding
        let oddExif = Data(repeating: 0x42, count: 11) // Odd length
        let webp = TestFixtures.minimalWebP(exifTIFFData: oddExif)
        let file = try WebPParser.parse(webp)

        // Should still parse all chunks (VP8X, VP8, EXIF)
        XCTAssertNotNil(file.findChunk("VP8X"))
        XCTAssertNotNil(file.findChunk("VP8 "))
        XCTAssertNotNil(file.findChunk("EXIF"))
    }

    func testWebPWithXMP() throws {
        let xmpXML = """
        <?xml version="1.0"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
              photoshop:Headline="WebP Test"
              photoshop:City="Oslo"/>
          </rdf:RDF>
        </x:xmpmeta>
        """
        let webp = TestFixtures.minimalWebP(xmpData: Data(xmpXML.utf8))
        let metadata = try ImageMetadata.read(from: webp)

        XCTAssertEqual(metadata.format, .webp)
        XCTAssertEqual(metadata.xmp?.headline, "WebP Test")
        XCTAssertEqual(metadata.xmp?.city, "Oslo")
    }
}
