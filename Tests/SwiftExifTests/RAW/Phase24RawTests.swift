import XCTest
@testable import SwiftExif

// MARK: - RAW long tail (Phase 24)

final class RawLongTailTests: XCTestCase {

    // MARK: - Format detection

    func testIIQDetectedFromExtension() {
        XCTAssertEqual(FormatDetector.detectFromExtension("iiq"), .raw(.iiq))
    }

    func testThreeFRDetectedFromExtension() {
        XCTAssertEqual(FormatDetector.detectFromExtension("3fr"), .raw(.threefr))
    }

    func testFFFDetectedFromExtension() {
        XCTAssertEqual(FormatDetector.detectFromExtension("fff"), .raw(.fff))
    }

    func testX3FDetectedFromExtension() {
        XCTAssertEqual(FormatDetector.detectFromExtension("x3f"), .raw(.x3f))
    }

    func testMRWDetectedFromExtension() {
        XCTAssertEqual(FormatDetector.detectFromExtension("mrw"), .raw(.mrw))
    }

    func testX3FDetectedFromMagic() {
        var data = Data()
        data.append(contentsOf: "FOVb".utf8)
        data.append(Data(repeating: 0, count: 60))
        XCTAssertEqual(FormatDetector.detect(data), .raw(.x3f))
    }

    func testMRWDetectedFromMagic() {
        var data = Data([0x00, 0x4D, 0x52, 0x4D])  // \0MRM
        data.append(Data(repeating: 0, count: 60))
        XCTAssertEqual(FormatDetector.detect(data), .raw(.mrw))
    }

    func testIIQDetectedFromMagic() {
        var data = Data(repeating: 0x49, count: 8)  // IIIIIIII
        data.append(Data(repeating: 0, count: 60))
        XCTAssertEqual(FormatDetector.detect(data), .raw(.iiq))
    }

    // MARK: - Parsing

    func testIIQParsesEmbeddedTIFF() throws {
        // Build the new-style IIQ wrapper: 8 bytes of 'I' + 4-byte little-endian
        // offset to embedded TIFF, then padding, then a TIFF block.
        let tiffBlock = TestFixtures.minimalTIFF(byteOrder: .littleEndian, entries: [
            (tag: ExifTag.make, type: .ascii, count: 9, valueData: Data("PhaseOne\0".utf8)),
        ])
        let tiffOffset: UInt32 = 64
        var iiq = Data(repeating: 0x49, count: 8)
        iiq.append(UInt8(tiffOffset & 0xFF))
        iiq.append(UInt8((tiffOffset >> 8) & 0xFF))
        iiq.append(UInt8((tiffOffset >> 16) & 0xFF))
        iiq.append(UInt8((tiffOffset >> 24) & 0xFF))
        // Pad up to tiffOffset.
        while iiq.count < Int(tiffOffset) { iiq.append(0) }
        iiq.append(tiffBlock)

        let m = try ImageMetadata.read(from: iiq, format: .raw(.iiq))
        XCTAssertEqual(m.format, .raw(.iiq))
        XCTAssertEqual(m.exif?.make, "PhaseOne")
    }

    func testMRWParsesTTWBlock() throws {
        // Build a minimal MRW: 8-byte header + TTW block containing TIFF.
        let tiffBlock = TestFixtures.minimalTIFF(byteOrder: .bigEndian, entries: [
            (tag: ExifTag.make, type: .ascii, count: 8, valueData: Data("MINOLTA\0".utf8)),
        ])
        var mrw = Data([0x00, 0x4D, 0x52, 0x4D])  // \0MRM
        // headerLen = 8 (TTW header) + tiff length
        let headerLen = 8 + tiffBlock.count
        mrw.append(UInt8((headerLen >> 24) & 0xFF))
        mrw.append(UInt8((headerLen >> 16) & 0xFF))
        mrw.append(UInt8((headerLen >> 8) & 0xFF))
        mrw.append(UInt8(headerLen & 0xFF))
        // TTW block: tag "TTW\0" + length + body.
        mrw.append(contentsOf: "\0TTW".utf8)
        let tlen = tiffBlock.count
        mrw.append(UInt8((tlen >> 24) & 0xFF))
        mrw.append(UInt8((tlen >> 16) & 0xFF))
        mrw.append(UInt8((tlen >> 8) & 0xFF))
        mrw.append(UInt8(tlen & 0xFF))
        mrw.append(tiffBlock)

        let m = try ImageMetadata.read(from: mrw, format: .raw(.mrw))
        XCTAssertEqual(m.format, .raw(.mrw))
        XCTAssertEqual(m.exif?.make, "MINOLTA")
    }

    func testX3FProducesPlaceholderMetadata() throws {
        var x3f = Data()
        x3f.append(contentsOf: "FOVb".utf8)
        x3f.append(Data(repeating: 0, count: 60))
        // X3F today produces an empty TIFFFile shell — exercise that the
        // pipeline doesn't crash and the format is preserved.
        let m = try ImageMetadata.read(from: x3f, format: .raw(.x3f))
        XCTAssertEqual(m.format, .raw(.x3f))
    }

    func testHasselblad3FRParsesAsTIFF() throws {
        let tiff = TestFixtures.minimalTIFF(byteOrder: .littleEndian, entries: [
            (tag: ExifTag.make, type: .ascii, count: 11, valueData: Data("Hasselblad\0".utf8)),
        ])
        let m = try ImageMetadata.read(from: tiff, format: .raw(.threefr))
        XCTAssertEqual(m.format, .raw(.threefr))
        XCTAssertEqual(m.exif?.make, "Hasselblad")
    }
}
