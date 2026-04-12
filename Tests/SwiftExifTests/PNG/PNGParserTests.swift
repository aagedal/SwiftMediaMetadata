import XCTest
@testable import SwiftExif

final class PNGParserTests: XCTestCase {

    func testParseMinimalPNG() throws {
        let png = TestFixtures.minimalPNG()
        let file = try PNGParser.parse(png)

        // IHDR + IDAT + IEND minimum
        XCTAssertGreaterThanOrEqual(file.chunks.count, 3)
        XCTAssertEqual(file.chunks.first?.type, "IHDR")
        XCTAssertEqual(file.chunks.last?.type, "IEND")
    }

    func testPNGCRC32Validation() throws {
        let png = TestFixtures.minimalPNG()
        let file = try PNGParser.parse(png)

        // All chunks should have valid CRC
        for chunk in file.chunks {
            let computed = CRC32.compute(type: chunk.type, data: chunk.data)
            XCTAssertEqual(chunk.crc, computed, "CRC mismatch for chunk: \(chunk.type)")
        }
    }

    func testPNGCorruptCRCThrows() {
        var png = TestFixtures.minimalPNG()
        // Corrupt the CRC of the first chunk (IHDR) by flipping a byte near the end
        // The CRC is 4 bytes at position: 8 (sig) + 4 (len) + 4 (type) + 13 (IHDR data) = offset 29
        let crcOffset = 8 + 4 + 4 + 13
        if crcOffset < png.count {
            png[png.startIndex + crcOffset] ^= 0xFF
        }
        XCTAssertThrowsError(try PNGParser.parse(png)) { error in
            if case MetadataError.crcMismatch = error {
                // Expected
            } else {
                XCTFail("Expected crcMismatch error, got: \(error)")
            }
        }
    }

    func testExtractExifFromPNG() throws {
        let png = TestFixtures.pngWithExif(make: "Fuji", model: "X-T5")
        let metadata = try ImageMetadata.read(from: png)

        XCTAssertEqual(metadata.format, .png)
        XCTAssertNotNil(metadata.exif)
        XCTAssertEqual(metadata.exif?.make, "Fuji")
        XCTAssertEqual(metadata.exif?.model, "X-T5")
    }

    func testPNGWithExifChunk() throws {
        let png = TestFixtures.pngWithExif()
        let file = try PNGParser.parse(png)

        let exifChunk = file.findChunk("eXIf")
        XCTAssertNotNil(exifChunk)
    }

    func testPNGFindChunks() throws {
        let png = TestFixtures.minimalPNG()
        let file = try PNGParser.parse(png)

        XCTAssertNotNil(file.findChunk("IHDR"))
        XCTAssertNotNil(file.findChunk("IDAT"))
        XCTAssertNotNil(file.findChunk("IEND"))
        XCTAssertNil(file.findChunk("eXIf"))
    }

    func testInvalidPNGSignatureThrows() {
        let garbage = Data(repeating: 0x00, count: 20)
        XCTAssertThrowsError(try PNGParser.parse(garbage)) { error in
            if case MetadataError.invalidPNG = error {
                // Expected
            } else {
                XCTFail("Expected invalidPNG error, got: \(error)")
            }
        }
    }

    func testPNGTooSmallThrows() {
        XCTAssertThrowsError(try PNGParser.parse(Data([0x89, 0x50])))
    }
}
