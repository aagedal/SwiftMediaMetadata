import XCTest
@testable import SwiftExif

/// Unit tests for the pixel-format string derivation that fills in ffprobe's
/// `pix_fmt` field when the container doesn't carry one directly.
final class PixelFormatDerivationTests: XCTestCase {

    // MARK: - Standard YUV chroma / depth matrix

    func test420_8bit() {
        XCTAssertEqual(
            PixelFormatDerivation.derive(chromaSubsampling: "4:2:0", bitDepth: 8, fullRange: nil, codec: "avc1"),
            "yuv420p"
        )
    }

    func test420_10bit() {
        XCTAssertEqual(
            PixelFormatDerivation.derive(chromaSubsampling: "4:2:0", bitDepth: 10, fullRange: false, codec: "hvc1"),
            "yuv420p10le"
        )
    }

    func test422_8bit() {
        XCTAssertEqual(
            PixelFormatDerivation.derive(chromaSubsampling: "4:2:2", bitDepth: 8, fullRange: nil, codec: "apcn"),
            "yuv422p"
        )
    }

    func test444_12bit() {
        XCTAssertEqual(
            PixelFormatDerivation.derive(chromaSubsampling: "4:4:4", bitDepth: 12, fullRange: nil, codec: "av01"),
            "yuv444p12le"
        )
    }

    // MARK: - JPEG full-range variant

    func testFullRange420MapsToYuvj420p() {
        XCTAssertEqual(
            PixelFormatDerivation.derive(chromaSubsampling: "4:2:0", bitDepth: 8, fullRange: true, codec: "mjpg"),
            "yuvj420p"
        )
    }

    func testFullRange10bitDoesNotUseJPEGLabel() {
        // ffprobe keeps the limited-range base name for 10/12-bit and surfaces
        // full-range via a separate color_range flag. Mirror that.
        XCTAssertEqual(
            PixelFormatDerivation.derive(chromaSubsampling: "4:2:0", bitDepth: 10, fullRange: true, codec: "hvc1"),
            "yuv420p10le"
        )
    }

    // MARK: - Monochrome

    func testMonochrome8bit() {
        XCTAssertEqual(
            PixelFormatDerivation.derive(chromaSubsampling: "4:0:0", bitDepth: 8, fullRange: nil, codec: "hvc1"),
            "gray"
        )
    }

    func testMonochrome10bit() {
        XCTAssertEqual(
            PixelFormatDerivation.derive(chromaSubsampling: "4:0:0", bitDepth: 10, fullRange: nil, codec: "hvc1"),
            "gray10le"
        )
    }

    // MARK: - Defaulting behaviour

    func testMissingBitDepthDefaultsTo8() {
        XCTAssertEqual(
            PixelFormatDerivation.derive(chromaSubsampling: "4:2:0", bitDepth: nil, fullRange: nil, codec: "avc1"),
            "yuv420p"
        )
    }

    func testMissingChromaReturnsNil() {
        XCTAssertNil(
            PixelFormatDerivation.derive(chromaSubsampling: nil, bitDepth: 8, fullRange: nil, codec: "avc1")
        )
    }
}
