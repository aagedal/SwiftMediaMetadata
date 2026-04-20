import XCTest
@testable import SwiftExif

/// Smoke tests for the new video container detectors (MKV/WebM/AVI/MPEG).
///
/// These construct minimal synthetic containers rather than depend on external
/// files. The full decoder is exercised via files under
/// `/Users/…/Movies/TestVideo/` in developer smoke tests outside CI.
final class VideoFormatDetectionTests: XCTestCase {

    // MARK: - Extension mapping

    func testExtensionDetectionCoversAllFormats() {
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("mkv"), .mkv)
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("webm"), .webm)
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("avi"), .avi)
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("mpg"), .mpg)
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("mpeg"), .mpg)
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("ts"), .mpg)
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("m2ts"), .mpg)
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("mts"), .mpg)
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("vob"), .mpg)
    }

    // MARK: - Magic-byte detection

    func testEBMLMagicDetectsMatroska() {
        // Minimal EBML header: 1A 45 DF A3 + length VINT + payload with DocType "matroska".
        var data = Data([0x1A, 0x45, 0xDF, 0xA3])
        // Length = 0x80 | 0x1A (fits in 1 byte, payload 26 bytes).
        data.append(0x9A) // VINT size = 26
        // Minimal DocType field "matroska" inside the header — ignored by the magic check.
        data.append(contentsOf: Array(repeating: 0x00, count: 26))
        XCTAssertTrue(MatroskaReader.isMatroska(data))
    }

    func testEBMLMagicFallsBackToMKVWhenDocTypeUnknown() throws {
        // A minimal EBML file we can at least detect as .mkv (parser may still
        // fail downstream — detection is a separate concern).
        var data = Data([0x1A, 0x45, 0xDF, 0xA3])
        data.append(0x80) // empty header
        data.append(contentsOf: Data(count: 64))
        XCTAssertEqual(FormatDetector.detectVideo(data), .mkv)
    }

    func testRIFFAVIDetection() {
        var data = Data([0x52, 0x49, 0x46, 0x46])   // "RIFF"
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        data.append(contentsOf: [0x41, 0x56, 0x49, 0x20]) // "AVI "
        XCTAssertTrue(AVIReader.isAVI(data))
        XCTAssertEqual(FormatDetector.detectVideo(data), .avi)
    }

    func testRIFFAVIRejectsWebP() {
        // RIFF + "WEBP" is a WebP image, not an AVI.
        var data = Data([0x52, 0x49, 0x46, 0x46])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        data.append(contentsOf: [0x57, 0x45, 0x42, 0x50]) // "WEBP"
        XCTAssertFalse(AVIReader.isAVI(data))
    }

    func testMPEGProgramStreamDetection() {
        // Pack header start code 0x00 0x00 0x01 0xBA followed by stuffing.
        var data = Data([0x00, 0x00, 0x01, 0xBA])
        data.append(contentsOf: Data(count: 32))
        XCTAssertTrue(MPEGReader.isMPEG(data))
        XCTAssertEqual(FormatDetector.detectVideo(data), .mpg)
    }

    func testMPEGTransportStreamDetection() {
        // TS needs 0x47 sync at offsets 0, 188, 376, 564.
        var data = Data(count: 188 * 4 + 4)
        data[0] = 0x47
        data[188] = 0x47
        data[376] = 0x47
        data[564] = 0x47
        XCTAssertTrue(MPEGReader.isMPEG(data))
    }

    func testRandomBytesAreNotDetected() {
        XCTAssertFalse(MatroskaReader.isMatroska(Data(count: 64)))
        XCTAssertFalse(AVIReader.isAVI(Data(count: 64)))
        XCTAssertFalse(MPEGReader.isMPEG(Data(count: 64)))
    }
}
