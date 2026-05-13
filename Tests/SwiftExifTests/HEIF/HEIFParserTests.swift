import XCTest
@testable import SwiftExif

final class HEIFParserTests: XCTestCase {

    func testParseMinimalHEIF() throws {
        let heif = TestFixtures.minimalHEIF()
        let file = try HEIFParser.parse(heif)

        XCTAssertEqual(file.brand, "heic")
        XCTAssertFalse(file.boxes.isEmpty)
    }

    func testHEIFBrandDetection() throws {
        let heif = TestFixtures.minimalHEIF()
        let format = FormatDetector.detect(heif)
        XCTAssertEqual(format, .heif)
    }

    func testHEIFExtensionDetection() {
        XCTAssertEqual(FormatDetector.detectFromExtension("heic"), .heif)
        XCTAssertEqual(FormatDetector.detectFromExtension("heif"), .heif)
        XCTAssertEqual(FormatDetector.detectFromExtension("HEIC"), .heif)
    }

    func testHEIFWithExif() throws {
        let heif = TestFixtures.heifWithExif(make: "Apple", model: "iPhone 16 Pro")
        let metadata = try ImageMetadata.read(from: heif)

        XCTAssertEqual(metadata.format, .heif)
        XCTAssertNotNil(metadata.exif)
        XCTAssertEqual(metadata.exif?.make, "Apple")
        XCTAssertEqual(metadata.exif?.model, "iPhone 16 Pro")
    }

    func testHEIFWithoutMetadata() throws {
        let heif = TestFixtures.minimalHEIF(exifTIFFData: nil)
        let metadata = try ImageMetadata.read(from: heif)

        XCTAssertEqual(metadata.format, .heif)
        XCTAssertNil(metadata.exif)
        XCTAssertNil(metadata.xmp)
    }

    func testInvalidHEIFThrows() {
        let garbage = Data(repeating: 0xCC, count: 20)
        XCTAssertThrowsError(try HEIFParser.parse(garbage))
    }

    func testHEIFTooSmallThrows() {
        XCTAssertThrowsError(try HEIFParser.parse(Data([0x00, 0x00])))
    }

    func testMif1BrandDetectedAsHEIF() throws {
        // Build a minimal ISOBMFF file with mif1 brand
        var writer = BinaryWriter(capacity: 64)
        let ftypPayload = Data("mif1".utf8) + Data([0x00, 0x00, 0x00, 0x00])
        writer.writeUInt32BigEndian(UInt32(8 + ftypPayload.count))
        writer.writeString("ftyp", encoding: .ascii)
        writer.writeBytes(ftypPayload)

        let format = FormatDetector.detect(writer.data)
        XCTAssertEqual(format, .heif)
    }

    /// iPhone Pro HDR HEIC and AOM-encoded HDR AVIF stills carry SMPTE ST 2086
    /// and CTA-861.3 HDR metadata as `mdcv` / `clli` properties under the
    /// `meta → iprp → ipco` hierarchy — the same box layout used in video
    /// sample entries. Verify the property walker recovers both, populating
    /// the shared `HDRMetadata` on `ImageMetadata.hdr`.
    func testHEIFExposesMdcvAndCLLIFromIpco() throws {
        // mdcv box payload (24 bytes, SMPTE ST 2086, R/G/B order per ISOBMFF):
        // BT.2020 primaries, D65 white, 1000/0.005 nits.
        var mdcv = Data()
        func appendU16(_ v: UInt16) {
            mdcv.append(UInt8(v >> 8)); mdcv.append(UInt8(v & 0xFF))
        }
        func appendU32(_ v: UInt32) {
            mdcv.append(UInt8((v >> 24) & 0xFF))
            mdcv.append(UInt8((v >> 16) & 0xFF))
            mdcv.append(UInt8((v >> 8)  & 0xFF))
            mdcv.append(UInt8(v         & 0xFF))
        }
        appendU16(35400) // red x 0.708
        appendU16(14600) // red y 0.292
        appendU16(8500)  // green x 0.170
        appendU16(39850) // green y 0.797
        appendU16(6550)  // blue x 0.131
        appendU16(2300)  // blue y 0.046
        appendU16(15635) // white x 0.3127
        appendU16(16450) // white y 0.3290
        appendU32(10_000_000) // max luminance 1000 cd/m²
        appendU32(50)         // min luminance 0.005 cd/m²

        // clli box payload (4 bytes): maxCLL 1000, maxFALL 400.
        var clli = Data()
        clli.append(UInt8(1000 >> 8)); clli.append(UInt8(1000 & 0xFF))
        clli.append(UInt8(400  >> 8)); clli.append(UInt8(400  & 0xFF))

        let heif = buildMinimalHEIFWithHDR(mdcv: mdcv, clli: clli)
        let metadata = try ImageMetadata.read(from: heif)
        XCTAssertEqual(metadata.format, .heif)
        let md = try XCTUnwrap(metadata.hdr?.masteringDisplay,
                               "expected mdcv from ipco")
        XCTAssertEqual(md.redX, 0.708, accuracy: 1e-3)
        XCTAssertEqual(md.greenY, 0.797, accuracy: 1e-3)
        XCTAssertEqual(md.blueX, 0.131, accuracy: 1e-3)
        XCTAssertEqual(md.whitePointX, 0.3127, accuracy: 1e-4)
        XCTAssertEqual(md.maxLuminance, 1000.0, accuracy: 0.5)
        XCTAssertEqual(md.minLuminance, 0.005, accuracy: 1e-4)
        let cll = try XCTUnwrap(metadata.hdr?.contentLightLevel,
                                "expected clli from ipco")
        XCTAssertEqual(cll.maxCLL, 1000)
        XCTAssertEqual(cll.maxFALL, 400)
    }

    /// A HEIF without `mdcv` / `clli` properties must leave `metadata.hdr` nil
    /// rather than synthesising an empty record — mirrors the SDR-vs-HDR guard
    /// used in `MatroskaReader` and `MP4VisualSampleEntry`.
    func testHEIFWithoutHDRPropertiesLeavesHDRNil() throws {
        let heif = TestFixtures.minimalHEIF()
        let metadata = try ImageMetadata.read(from: heif)
        XCTAssertNil(metadata.hdr)
    }

    /// Build a minimal HEIF: `ftyp heic` + `meta → iprp → ipco` containing the
    /// supplied `mdcv` / `clli` payloads. Mirrors `TestFixtures.minimalHEIF`'s
    /// shape but keeps the HDR-specific bits local to this test file.
    private func buildMinimalHEIFWithHDR(mdcv: Data, clli: Data) -> Data {
        func box(_ type: String, _ payload: Data) -> Data {
            var out = Data()
            let size = UInt32(8 + payload.count)
            out.append(UInt8((size >> 24) & 0xFF))
            out.append(UInt8((size >> 16) & 0xFF))
            out.append(UInt8((size >> 8)  & 0xFF))
            out.append(UInt8(size         & 0xFF))
            out.append(Data(type.utf8))
            out.append(payload)
            return out
        }
        let ftypPayload = Data("heic".utf8) + Data([0x00, 0x00, 0x00, 0x00])
        let ftyp = box("ftyp", ftypPayload)
        let ipco = box("ipco", box("mdcv", mdcv) + box("clli", clli))
        let iprp = box("iprp", ipco)
        // meta is a FullBox (4-byte version+flags) before children.
        let metaPayload = Data([0x00, 0x00, 0x00, 0x00]) + iprp
        let meta = box("meta", metaPayload)
        return ftyp + meta
    }

    func testRealHEICFileIfAvailable() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HEIF/
            .deletingLastPathComponent() // SwiftExifTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // project root
        let url = projectRoot.appendingPathComponent("TestImages/IMG_5543_upsideDownFaceThumbnailSource_1.heic")

        guard FileManager.default.fileExists(atPath: url.path) else {
            // Skip if test image not available
            return
        }

        let data = try Data(contentsOf: url)
        let heifFile = try HEIFParser.parse(data)
        XCTAssertEqual(FormatDetector.detect(data), .heif)

        // Verify iloc extraction works with raw data
        let exif = try HEIFParser.extractExif(from: heifFile, fileData: data)
        XCTAssertNotNil(exif, "Expected Exif from real HEIC file via iloc extraction")

        // Also test through the full ImageMetadata API
        let metadata = try ImageMetadata.read(from: url)
        XCTAssertEqual(metadata.format, .heif)
        XCTAssertNotNil(metadata.exif)
    }
}
