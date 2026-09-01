import XCTest
@testable import SwiftMediaMetadata

/// IVF (On2 IVF) container parse tests. Like the other container readers these
/// build minimal synthetic byte streams rather than depend on external files.
///
/// Header values mirror a real AV2 export captured from an iPhone-style encoder:
/// FourCC `AV02`, 1920×1080, time base rate 59957 / scale 1000 (→ 59.957 fps),
/// and a header `frameCount` of 0 (the encoder left it unset).
final class IVFReaderTests: XCTestCase {

    // MARK: - Detection

    func testDKIFSignatureDetection() {
        let data = buildIVF(fourCC: "AV02", width: 1920, height: 1080,
                            rate: 59957, scale: 1000, declaredFrameCount: 0,
                            frames: [(0, 100)])
        XCTAssertTrue(IVFReader.isIVF(data))
        XCTAssertEqual(FormatDetector.detectVideo(data), .ivf)
    }

    func testExtensionDetection() {
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("ivf"), .ivf)
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("IVF"), .ivf)
    }

    func testRejectsNonDKIF() {
        // RIFF AVI must not be mistaken for IVF.
        var data = Data([0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(contentsOf: Array(repeating: 0x00, count: 28))
        XCTAssertFalse(IVFReader.isIVF(data))
    }

    // MARK: - AV2 happy path

    func testParseAV2BasicMetadata() throws {
        // Three frames, 100/120/140 payload bytes, timestamps 0/1/2.
        let data = buildIVF(fourCC: "AV02", width: 1920, height: 1080,
                            rate: 59957, scale: 1000, declaredFrameCount: 0,
                            frames: [(0, 100), (1, 120), (2, 140)])
        let m = try VideoMetadata.read(from: data)

        XCTAssertEqual(m.format, .ivf)
        XCTAssertEqual(m.formatLongName, "On2 IVF")
        XCTAssertEqual(m.videoWidth, 1920)
        XCTAssertEqual(m.videoHeight, 1080)
        XCTAssertEqual(m.videoCodec, "av2")
        XCTAssertEqual(m.frameRate ?? 0, 59.957, accuracy: 0.001)

        XCTAssertEqual(m.videoStreams.count, 1)
        let v = m.videoStreams[0]
        XCTAssertEqual(v.codec, "av2")
        XCTAssertEqual(v.codecName, "AV2")
        XCTAssertEqual(v.width, 1920)
        XCTAssertEqual(v.height, 1080)
        XCTAssertEqual(v.frameCount, 3) // walked, not the header's 0
        XCTAssertEqual(v.avgFrameRate ?? 0, 59.957, accuracy: 0.001)
        XCTAssertEqual(v.rFrameRate ?? 0, 59.957, accuracy: 0.001)

        XCTAssertEqual(m.streamOrder, [.video(0)])

        // duration = (lastTimestamp + 1) * scale / rate = 3 * 1000 / 59957.
        XCTAssertEqual(m.duration ?? 0, 3.0 * 1000.0 / 59957.0, accuracy: 1e-6)

        // bit rate = payload bytes (360) * 8 / duration.
        XCTAssertNotNil(m.bitRate)
        XCTAssertGreaterThan(m.bitRate ?? 0, 0)

        XCTAssertTrue(m.warnings.isEmpty, "clean stream should produce no warnings: \(m.warnings)")
    }

    // MARK: - Frame-count handling

    func testHeaderFrameCountIsIgnoredInFavourOfWalk() throws {
        // Header claims 99 frames; only 2 are actually present.
        let data = buildIVF(fourCC: "AV01", width: 640, height: 480,
                            rate: 30, scale: 1, declaredFrameCount: 99,
                            frames: [(0, 50), (1, 50)])
        let m = try VideoMetadata.read(from: data)
        XCTAssertEqual(m.videoStreams.first?.frameCount, 2)
        XCTAssertEqual(m.videoCodec, "av1")
        XCTAssertEqual(m.frameRate ?? 0, 30.0, accuracy: 0.0001)
        XCTAssertTrue(m.warnings.contains { $0.contains("99") && $0.contains("2") })
    }

    func testTruncatedTrailingFrameIsToleratedAndFlagged() throws {
        // Build two complete frames, then append a frame header whose declared
        // payload runs past EOF (a file still being encoded, or truncated).
        var data = buildIVF(fourCC: "AV02", width: 1920, height: 1080,
                            rate: 59957, scale: 1000, declaredFrameCount: 0,
                            frames: [(0, 100), (1, 100)])
        // Dangling frame header: size = 9999 but no payload follows.
        var dangling = Data()
        appendLE32(&dangling, 9999)
        appendLE64(&dangling, 2)
        data.append(dangling)

        let m = try VideoMetadata.read(from: data)
        XCTAssertEqual(m.videoStreams.first?.frameCount, 2, "only complete frames counted")
        XCTAssertTrue(m.warnings.contains { $0.lowercased().contains("incomplete") },
                      "expected truncation warning, got \(m.warnings)")
    }

    // MARK: - Codec mapping

    func testVP9AndVP8Mapping() throws {
        let vp9 = try VideoMetadata.read(from: buildIVF(
            fourCC: "VP90", width: 1280, height: 720, rate: 25, scale: 1,
            declaredFrameCount: 1, frames: [(0, 200)]))
        XCTAssertEqual(vp9.videoCodec, "vp9")
        XCTAssertEqual(vp9.videoStreams.first?.codecName, "VP9")

        let vp8 = try VideoMetadata.read(from: buildIVF(
            fourCC: "VP80", width: 320, height: 240, rate: 15, scale: 1,
            declaredFrameCount: 1, frames: [(0, 80)]))
        XCTAssertEqual(vp8.videoCodec, "vp8")
        XCTAssertEqual(vp8.videoStreams.first?.codecName, "VP8")
    }

    // MARK: - Fixture builder

    /// Build a synthetic IVF byte stream. `frames` is a list of
    /// (timestamp, payloadByteCount) pairs; payloads are zero-filled.
    private func buildIVF(fourCC: String, width: Int, height: Int,
                          rate: UInt32, scale: UInt32, declaredFrameCount: UInt32,
                          frames: [(UInt64, Int)]) -> Data {
        var data = Data()
        data.append(contentsOf: Array("DKIF".utf8))
        appendLE16(&data, 0)                    // version
        appendLE16(&data, 32)                   // header length
        data.append(contentsOf: Array(fourCC.padding(toLength: 4, withPad: " ", startingAt: 0).utf8))
        appendLE16(&data, UInt16(width))
        appendLE16(&data, UInt16(height))
        appendLE32(&data, rate)
        appendLE32(&data, scale)
        appendLE32(&data, declaredFrameCount)
        appendLE32(&data, 0)                     // reserved
        for (ts, size) in frames {
            appendLE32(&data, UInt32(size))
            appendLE64(&data, ts)
            data.append(Data(count: size))
        }
        return data
    }

    private func appendLE16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendLE32(_ data: inout Data, _ value: UInt32) {
        for i in 0 ..< 4 { data.append(UInt8((value >> (8 * i)) & 0xFF)) }
    }

    private func appendLE64(_ data: inout Data, _ value: UInt64) {
        for i in 0 ..< 8 { data.append(UInt8((value >> (8 * UInt64(i))) & 0xFF)) }
    }
}
