import XCTest
@testable import SwiftExif

final class FormatDetectorTests: XCTestCase {

    func testDetectJPEG() {
        let jpeg = TestFixtures.minimalJPEG()
        XCTAssertEqual(FormatDetector.detect(jpeg), .jpeg)
    }

    func testDetectPNG() {
        let png = TestFixtures.minimalPNG()
        XCTAssertEqual(FormatDetector.detect(png), .png)
    }

    func testDetectJPEGXLContainer() {
        let jxl = TestFixtures.minimalJXL()
        XCTAssertEqual(FormatDetector.detect(jxl), .jpegXL)
    }

    func testDetectJPEGXLBareCodestream() {
        let jxl = TestFixtures.bareJXLCodestream()
        XCTAssertEqual(FormatDetector.detect(jxl), .jpegXL)
    }

    func testDetectTIFF_LE() {
        let tiff = TestFixtures.minimalTIFF(byteOrder: .littleEndian)
        XCTAssertEqual(FormatDetector.detect(tiff), .tiff)
    }

    func testDetectTIFF_BE() {
        let tiff = TestFixtures.minimalTIFF(byteOrder: .bigEndian)
        XCTAssertEqual(FormatDetector.detect(tiff), .tiff)
    }

    func testDetectCR2() {
        let cr2 = TestFixtures.minimalCR2()
        XCTAssertEqual(FormatDetector.detect(cr2), .raw(.cr2))
    }

    func testDetectAVIF() {
        let avif = TestFixtures.minimalAVIF()
        XCTAssertEqual(FormatDetector.detect(avif), .avif)
    }

    func testDetectFromExtension() {
        XCTAssertEqual(FormatDetector.detectFromExtension("jpg"), .jpeg)
        XCTAssertEqual(FormatDetector.detectFromExtension("JPEG"), .jpeg)
        XCTAssertEqual(FormatDetector.detectFromExtension("tiff"), .tiff)
        XCTAssertEqual(FormatDetector.detectFromExtension("tif"), .tiff)
        XCTAssertEqual(FormatDetector.detectFromExtension("dng"), .raw(.dng))
        XCTAssertEqual(FormatDetector.detectFromExtension("cr2"), .raw(.cr2))
        XCTAssertEqual(FormatDetector.detectFromExtension("nef"), .raw(.nef))
        XCTAssertEqual(FormatDetector.detectFromExtension("arw"), .raw(.arw))
        XCTAssertEqual(FormatDetector.detectFromExtension("jxl"), .jpegXL)
        XCTAssertEqual(FormatDetector.detectFromExtension("png"), .png)
        XCTAssertEqual(FormatDetector.detectFromExtension("avif"), .avif)
        XCTAssertNil(FormatDetector.detectFromExtension("bmp"))
    }

    func testDetectTooSmall() {
        XCTAssertNil(FormatDetector.detect(Data([0xFF])))
    }

    func testDetectUnknownFormat() {
        XCTAssertNil(FormatDetector.detect(Data(repeating: 0x00, count: 20)))
    }
}
