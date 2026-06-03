import XCTest
import Foundation
@testable import SwiftExif

/// Regression tests for DNG tag extraction.
///
/// Complements the symbolic-constant tests in `Phase21FeatureTests`: these build
/// fixtures using **literal on-disk tag IDs** so they fail if a `DNGTag` constant
/// regresses (several were historically wrong and silently dropped fields). They
/// also exercise the generalized numeric-array reader, which previously hard-
/// required `count == 2` and so missed `ActiveArea` (count 4).
final class DNGTagExtractionTests: XCTestCase {

    // MARK: - Little-endian value encoders

    private func le16(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }
    private func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
    private func leDouble(_ v: Double) -> Data {
        let bits = v.bitPattern
        var d = Data()
        for i in 0..<8 { d.append(UInt8((bits >> (8 * UInt64(i))) & 0xFF)) }
        return d
    }
    private func ascii(_ s: String) -> Data {
        Data(s.utf8) + Data([0x00])
    }

    private typealias Entry = (tag: UInt16, type: TIFFDataType, count: UInt32, valueData: Data)

    /// Build a synthetic DNG (TIFF + DNGVersion 0xC612) carrying the given extra
    /// entries. Extra entries use literal hex tag IDs on purpose.
    private func makeDNG(make: String = "GoPro", extra: [Entry]) -> Data {
        var entries: [Entry] = [
            (0x010F, .ascii, UInt32(make.utf8.count + 1), ascii(make)),  // Make
            (0xC612, .byte, 4, Data([1, 4, 0, 0])),                      // DNGVersion
        ]
        entries.append(contentsOf: extra)
        return TestFixtures.minimalTIFF(byteOrder: .littleEndian, entries: entries)
    }

    // MARK: - Corrected constants + relaxed guards (literal tag IDs)

    func testReadsPreviouslyDroppedFields() throws {
        let data = makeDNG(extra: [
            (0xC6F8, .ascii, 6, ascii("GoPro")),                                 // ProfileName
            (0xC615, .ascii, 6, ascii("HERO0")),                                 // LocalizedCameraModel
            (0xC61F, .short, 2, le16(0) + le16(0)),                              // DefaultCropOrigin
            (0xC620, .long, 2, le32(5568) + le32(4872)),                        // DefaultCropSize
            (0xC68D, .long, 4, le32(0) + le32(0) + le32(4872) + le32(5568)),    // ActiveArea (count 4)
            (0xC61A, .short, 4, le16(12) + le16(12) + le16(12) + le16(12)),     // BlackLevel
            (0xC61D, .short, 1, le16(4095)),                                    // WhiteLevel
            (0xC761, .double, 2, leDouble(0.0037) + leDouble(1.17e-06)),        // NoiseProfile
            (0xC741, .undefined, 16, Data(repeating: 0xAB, count: 16)),         // OpcodeList2
            (0xC6FD, .long, 1, le32(0)),                                        // ProfileEmbedPolicy
            (0xC616, .byte, 3, Data([0, 1, 2])),                               // CFAPlaneColor
        ])

        let tiff = try TIFFFileParser.parse(data)
        let dng = try XCTUnwrap(DNGMetadataReader.read(from: tiff))

        XCTAssertEqual(dng.profileName, "GoPro")
        XCTAssertEqual(dng.localizedCameraModel, "HERO0")
        XCTAssertEqual(dng.defaultCropOrigin, [0, 0])
        XCTAssertEqual(dng.defaultCropSize, [5568, 4872])
        XCTAssertEqual(dng.activeArea, [0, 0, 4872, 5568])           // count-4 guard relaxed
        XCTAssertEqual(dng.blackLevel, [12, 12, 12, 12])
        XCTAssertEqual(dng.whiteLevel, [4095])
        XCTAssertEqual(dng.noiseProfile?.count, 2)
        XCTAssertEqual(dng.opcodeList2Size, 16)
        XCTAssertEqual(dng.profileEmbedPolicy, 0)
        XCTAssertEqual(dng.cfaPlaneColor, "Red,Green,Blue")
    }

    // MARK: - Print conversions

    func testCalibrationIlluminantNames() {
        let m = ImageMetadata()  // illuminant conversion doesn't consult metadata
        XCTAssertEqual(PrintConverter.convertValue(key: "DNG:CalibrationIlluminant1", value: 3, metadata: m), "Tungsten")
        XCTAssertEqual(PrintConverter.convertValue(key: "DNG:CalibrationIlluminant2", value: 23, metadata: m), "D50")
    }

    func testCompressionJBIG() {
        XCTAssertEqual(PrintConverter.compression(9), "JBIG B&W")
    }

    func testPhotometricCFA() {
        XCTAssertEqual(PrintConverter.photometricInterpretation(32803), "Color Filter Array")
    }
}
