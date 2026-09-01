import XCTest
@testable import SwiftMediaMetadata

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

    func testSonyAuthoredRenderedTIFFRemainsTIFF() {
        let tiff = TestFixtures.tiffWithExif(make: "SONY", model: "ILCE-7RM5")
        XCTAssertEqual(FormatDetector.detect(tiff), .tiff)
    }

    func testARWExtensionDisambiguatesAmbiguousTIFFBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("format-detector-\(UUID().uuidString)")
            .appendingPathExtension("arw")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestFixtures.tiffWithExif(make: "SONY", model: "ILCE-7RM5").write(to: url)

        let metadata = try ImageMetadata.read(from: url)
        XCTAssertEqual(metadata.format, .raw(.arw))
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
        XCTAssertEqual(FormatDetector.detectFromExtension("nrw"), .raw(.nrw))
        XCTAssertEqual(FormatDetector.detectFromExtension("arw"), .raw(.arw))
        XCTAssertEqual(FormatDetector.detectFromExtension("srw"), .raw(.srw))
        XCTAssertEqual(FormatDetector.detectFromExtension("raw"), .raw(.raw))
        XCTAssertEqual(FormatDetector.detectFromExtension("jxl"), .jpegXL)
        XCTAssertEqual(FormatDetector.detectFromExtension("png"), .png)
        XCTAssertEqual(FormatDetector.detectFromExtension("avif"), .avif)
        XCTAssertEqual(FormatDetector.detectFromExtension("bmp"), .bmp)
        XCTAssertEqual(FormatDetector.detectFromExtension("gif"), .gif)
        XCTAssertEqual(FormatDetector.detectFromExtension("svg"), .svg)
        XCTAssertNil(FormatDetector.detectFromExtension("xyz"))
    }

    func testDetectTooSmall() {
        XCTAssertNil(FormatDetector.detect(Data([0xFF])))
    }

    func testDetectUnknownFormat() {
        XCTAssertNil(FormatDetector.detect(Data(repeating: 0x00, count: 20)))
    }

    // MARK: - Audio Detection

    func testDetectMP3WithID3() {
        var data = Data([0x49, 0x44, 0x33]) // "ID3"
        data.append(Data(repeating: 0, count: 20))
        XCTAssertEqual(FormatDetector.detectAudio(data), .mp3)
    }

    func testDetectFLAC() {
        var data = Data([0x66, 0x4C, 0x61, 0x43]) // "fLaC"
        data.append(Data(repeating: 0, count: 20))
        XCTAssertEqual(FormatDetector.detectAudio(data), .flac)
    }

    func testDetectAudioFromExtension() {
        XCTAssertEqual(FormatDetector.detectAudioFromExtension("mp3"), .mp3)
        XCTAssertEqual(FormatDetector.detectAudioFromExtension("flac"), .flac)
        XCTAssertEqual(FormatDetector.detectAudioFromExtension("m4a"), .m4a)
        XCTAssertEqual(FormatDetector.detectAudioFromExtension("wav"), .wav)
        XCTAssertEqual(FormatDetector.detectAudioFromExtension("aiff"), .aiff)
    }

    // MARK: - GPR (GoPro) vs DNG

    /// Synthetic DNG (TIFF + DNGVersion) with the given Make.
    private func dngFixture(make: String) -> Data {
        let makeData = Data(make.utf8) + Data([0x00])
        return TestFixtures.minimalTIFF(byteOrder: .littleEndian, entries: [
            (tag: 0x010F, type: .ascii, count: UInt32(makeData.count), valueData: makeData), // Make
            (tag: 0xC612, type: .byte, count: 4, valueData: Data([1, 4, 0, 0])),             // DNGVersion
        ])
    }

    func testGoProDNGDetectedAsGPR() {
        XCTAssertEqual(FormatDetector.detect(dngFixture(make: "GoPro")), .raw(.gpr))
    }

    func testNonGoProDNGStaysDNG() {
        XCTAssertEqual(FormatDetector.detect(dngFixture(make: "Canon")), .raw(.dng))
    }

    func testGPRExtension() {
        XCTAssertEqual(FormatDetector.detectFromExtension("gpr"), .raw(.gpr))
        XCTAssertEqual(FormatDetector.detectFromExtension("GPR"), .raw(.gpr))
    }
}
