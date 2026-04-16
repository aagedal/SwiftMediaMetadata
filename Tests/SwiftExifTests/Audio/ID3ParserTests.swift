import XCTest
@testable import SwiftExif

final class ID3ParserTests: XCTestCase {

    func testSyncsafeEncoding() {
        // 0x00003FFF = 16383 -> syncsafe: 0x00 0x00 0x7F 0x7F
        let encoded = ID3Parser.encodeSyncsafe(16383)
        XCTAssertEqual(encoded, [0x00, 0x00, 0x7F, 0x7F])

        let decoded = ID3Parser.decodeSyncsafe(0x00, 0x00, 0x7F, 0x7F)
        XCTAssertEqual(decoded, 16383)
    }

    func testSyncsafeRoundTrip() {
        for value in [0, 1, 127, 128, 255, 1000, 100000, 0x0FFFFFFF] {
            let bytes = ID3Parser.encodeSyncsafe(value)
            let decoded = ID3Parser.decodeSyncsafe(bytes[0], bytes[1], bytes[2], bytes[3])
            XCTAssertEqual(decoded, value, "Round-trip failed for \(value)")
        }
    }

    func testParseMinimalID3v2() throws {
        // Build a minimal ID3v2.3 tag with just a TIT2 frame
        let titleFrame = ID3Writer.buildTextFrame("TIT2", text: "Test Song")
        let tagSize = titleFrame.count

        var data = Data()
        data.append(contentsOf: [0x49, 0x44, 0x33]) // "ID3"
        data.append(contentsOf: [0x03, 0x00])         // v2.3
        data.append(0x00)                              // flags
        data.append(contentsOf: ID3Parser.encodeSyncsafe(tagSize))
        data.append(titleFrame)
        // Add some fake audio data
        data.append(Data(repeating: 0xFF, count: 100))

        let metadata = try ID3Parser.parse(data)
        XCTAssertEqual(metadata.title, "Test Song")
        XCTAssertEqual(metadata.format, .mp3)
    }

    func testParseID3v1() throws {
        var data = Data(repeating: 0xFF, count: 200) // Fake audio
        // Append ID3v1 tag at the end
        data.append(Data("TAG".utf8)) // "TAG"
        data.append(Data("Test Title".utf8).padded(to: 30))
        data.append(Data("Test Artist".utf8).padded(to: 30))
        data.append(Data("Test Album".utf8).padded(to: 30))
        data.append(Data("2024".utf8)) // year (4 bytes)
        // Comment (28 bytes) + null + track number
        var commentData = Data("Comment".utf8.prefix(28))
        while commentData.count < 28 { commentData.append(0) }
        data.append(commentData)
        data.append(0x00) // null (ID3v1.1 indicator)
        data.append(0x05) // Track 5
        data.append(0x11) // Genre: 0x11 = 17 = Rock

        let metadata = try ID3Parser.parse(data)
        XCTAssertEqual(metadata.title, "Test Title")
        XCTAssertEqual(metadata.artist, "Test Artist")
        XCTAssertEqual(metadata.album, "Test Album")
        XCTAssertEqual(metadata.year, "2024")
        XCTAssertEqual(metadata.trackNumber, 5)
    }

    func testDecodeTextFrame() {
        // UTF-8 encoding (0x03) + "Hello"
        let data = Data([0x03]) + Data("Hello".utf8)
        let result = ID3Parser.decodeTextFrame(data)
        XCTAssertEqual(result, "Hello")
    }

    func testDecodeLatin1TextFrame() {
        // ISO-8859-1 encoding (0x00) + "Cafe\u{e9}"
        let data = Data([0x00, 0x43, 0x61, 0x66, 0xE9]) // "Cafe" + e-acute in Latin-1
        let result = ID3Parser.decodeTextFrame(data)
        XCTAssertEqual(result, "Caf\u{e9}")
    }
}

private extension Data {
    func padded(to length: Int) -> Data {
        var d = self
        while d.count < length { d.append(0) }
        return Data(d.prefix(length))
    }
}
