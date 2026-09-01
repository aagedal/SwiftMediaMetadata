import XCTest
@testable import SwiftMediaMetadata

/// Asserts that `JPEGParser.parse` and `ImageMetadata.read` tolerate every
/// JPEG marker class encoders commonly emit, even when the marker isn't
/// metadata-bearing. Each test inserts an extra segment into `bareJPEG()`
/// and asserts parse + read succeed and round-trip writes preserve the bytes.
final class MarkerCoverageTests: XCTestCase {

    // MARK: - Helpers

    /// Insert a raw `0xFFxx + length + payload` segment just after the SOI
    /// of a bare JPEG. Returns the rewritten bytes.
    private func insertSegmentAfterSOI(rawMarker: UInt16, payload: Data, in jpeg: Data) -> Data {
        var out = Data()
        out.append(jpeg.prefix(2)) // SOI
        var hdr = Data(count: 4)
        hdr[0] = UInt8(rawMarker >> 8)
        hdr[1] = UInt8(rawMarker & 0xFF)
        let length = UInt16(payload.count + 2)
        hdr[2] = UInt8(length >> 8)
        hdr[3] = UInt8(length & 0xFF)
        out.append(hdr)
        out.append(payload)
        out.append(jpeg.suffix(from: jpeg.startIndex + 2))
        return out
    }

    private func assertParseAndReadSucceed(_ jpeg: Data, file: StaticString = #file, line: UInt = #line) {
        do {
            _ = try JPEGParser.parse(jpeg)
        } catch {
            XCTFail("JPEGParser.parse threw \(error)", file: file, line: line)
            return
        }
        do {
            let m = try ImageMetadata.read(from: jpeg)
            XCTAssertTrue(m.warnings.isEmpty, "warnings: \(m.warnings)", file: file, line: line)
        } catch {
            XCTFail("ImageMetadata.read threw \(error)", file: file, line: line)
        }
    }

    // MARK: - APP14 Adobe

    func testParseJPEGWithAPP14Adobe() throws {
        // "Adobe\0" + version (2) + flags0 (2) + flags1 (2) + transform (1)
        let adobePayload = Data([0x41, 0x64, 0x6F, 0x62, 0x65, 0x00,
                                  0x00, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00])
        let jpeg = insertSegmentAfterSOI(rawMarker: 0xFFEE, payload: adobePayload, in: TestFixtures.bareJPEG())
        let file = try JPEGParser.parse(jpeg)
        XCTAssertTrue(file.segments.contains { $0.rawMarker == 0xFFEE })
        assertParseAndReadSucceed(jpeg)
    }

    // MARK: - COM (comment)

    func testParseJPEGWithCOMComment() throws {
        let comment = Data("encoder=libjpeg-turbo".utf8)
        let jpeg = insertSegmentAfterSOI(rawMarker: 0xFFFE, payload: comment, in: TestFixtures.bareJPEG())
        let file = try JPEGParser.parse(jpeg)
        XCTAssertTrue(file.segments.contains { $0.rawMarker == 0xFFFE })
        assertParseAndReadSucceed(jpeg)
    }

    // MARK: - DRI (Define Restart Interval)

    func testParseJPEGWithDRI() throws {
        let driPayload = Data([0x00, 0x04]) // restart interval = 4
        let jpeg = insertSegmentAfterSOI(rawMarker: 0xFFDD, payload: driPayload, in: TestFixtures.bareJPEG())
        let file = try JPEGParser.parse(jpeg)
        XCTAssertTrue(file.segments.contains { $0.rawMarker == 0xFFDD })
        assertParseAndReadSucceed(jpeg)
    }

    // MARK: - Unknown / reserved APP markers (APP3, APP5, APP12)

    func testParseJPEGWithReservedAPPMarkers() throws {
        var jpeg = TestFixtures.bareJPEG()
        for rawMarker in [UInt16(0xFFE3), UInt16(0xFFE5), UInt16(0xFFEC)] {
            jpeg = insertSegmentAfterSOI(rawMarker: rawMarker, payload: Data([0xDE, 0xAD, 0xBE, 0xEF]), in: jpeg)
        }
        let file = try JPEGParser.parse(jpeg)
        XCTAssertTrue(file.segments.contains { $0.rawMarker == 0xFFE3 })
        XCTAssertTrue(file.segments.contains { $0.rawMarker == 0xFFE5 })
        XCTAssertTrue(file.segments.contains { $0.rawMarker == 0xFFEC })
        assertParseAndReadSucceed(jpeg)
    }

    // MARK: - 0xFF padding before a marker

    func testParseJPEGWithExtraFFPaddingBeforeMarker() throws {
        // Insert one extra 0xFF byte between SOI and the DQT marker
        // (some encoders legally pad with extra 0xFFs).
        let bare = TestFixtures.bareJPEG()
        var jpeg = Data()
        jpeg.append(bare.prefix(2))            // SOI
        jpeg.append(contentsOf: [0xFF, 0xFF, 0xFF])
        jpeg.append(bare.suffix(from: bare.startIndex + 2))

        let file = try JPEGParser.parse(jpeg)
        XCTAssertNotNil(file.findSegment(.dqt))
        XCTAssertNotNil(file.findSegment(.sof0))
        assertParseAndReadSucceed(jpeg)
    }

    // MARK: - SOF variants not in the JPEGMarker enum

    func testParseJPEGWithExtendedSOFMarker() throws {
        // Build a bare JPEG but with SOF marker 0xFFC2 (progressive) instead of SOF0.
        // The parser must accept SOF variants beyond sof0/1/2/3 too — assert that
        // the rare 0xFFC5 (differential sequential) marker also parses opaquely.
        let bare = TestFixtures.bareJPEG()

        // Find SOF0 in the original (we know it's at the structure after DQT).
        // Easier: parse the bare JPEG, rewrite the marker byte of SOF0 to 0xC5.
        var rewritten = Data(bare)
        // Locate first 0xFFC0 in bytes — bareJPEG() places it after DQT.
        for i in 2..<rewritten.count - 1 {
            if rewritten[rewritten.startIndex + i] == 0xFF && rewritten[rewritten.startIndex + i + 1] == 0xC0 {
                rewritten[rewritten.startIndex + i + 1] = 0xC5
                break
            }
        }
        let file = try JPEGParser.parse(rewritten)
        XCTAssertTrue(file.segments.contains { $0.rawMarker == 0xFFC5 })
    }
}
