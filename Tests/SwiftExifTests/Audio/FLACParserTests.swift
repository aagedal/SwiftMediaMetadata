import XCTest
@testable import SwiftExif

final class FLACParserTests: XCTestCase {

    func testParseMinimalFLAC() throws {
        // Build a minimal FLAC file
        var data = Data([0x66, 0x4C, 0x61, 0x43]) // "fLaC"

        // STREAMINFO block (type 0, 34 bytes)
        let streamInfoData = buildStreamInfo(sampleRate: 44100, channels: 2, totalSamples: 441000)
        data.append(0x00) // type 0, not last
        data.append(contentsOf: encode24BE(streamInfoData.count))
        data.append(streamInfoData)

        // VORBIS_COMMENT block (type 4)
        var vc = VorbisComment(vendor: "TestEncoder")
        vc.setValue("Test Song", for: "TITLE")
        vc.setValue("Test Artist", for: "ARTIST")
        let vcData = vc.serialize()
        data.append(0x84) // type 4, last block
        data.append(contentsOf: encode24BE(vcData.count))
        data.append(vcData)

        // Fake audio frames
        data.append(Data(repeating: 0xFF, count: 100))

        let metadata = try FLACParser.parse(data)
        XCTAssertEqual(metadata.format, .flac)
        XCTAssertEqual(metadata.title, "Test Song")
        XCTAssertEqual(metadata.artist, "Test Artist")
        XCTAssertEqual(metadata.sampleRate, 44100)
        XCTAssertEqual(metadata.channels, 2)
        XCTAssertNotNil(metadata.duration)
        if let dur = metadata.duration {
            XCTAssertEqual(dur, 10.0, accuracy: 0.1) // 441000 / 44100 = 10s
        }
    }

    func testInvalidMagicThrows() {
        let data = Data([0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try FLACParser.parse(data))
    }

    // MARK: - Helpers

    private func buildStreamInfo(sampleRate: Int, channels: Int, totalSamples: UInt64) -> Data {
        // STREAMINFO: 34 bytes
        // Bytes 0-3: min/max block size
        // Bytes 4-6: min frame size (3 bytes)
        // Bytes 7-9: max frame size (3 bytes)
        // Bytes 10-13: sample rate (20 bits) | channels-1 (3 bits) | bps-1 (5 bits) | total samples high (4 bits)
        // Bytes 14-17: total samples low (32 bits)
        // Bytes 18-33: MD5 signature (16 bytes)
        var data = Data(repeating: 0, count: 34)

        // min/max block size
        data[0] = 0x10; data[1] = 0x00 // min block size 4096
        data[2] = 0x10; data[3] = 0x00 // max block size 4096

        // Sample rate (20 bits), channels-1 (3 bits), bps-1 (5 bits)
        let sr = sampleRate
        let ch = channels - 1
        let bps = 16 - 1 // 16-bit

        data[10] = UInt8((sr >> 12) & 0xFF)
        data[11] = UInt8((sr >> 4) & 0xFF)
        data[12] = UInt8(((sr & 0x0F) << 4) | ((ch & 0x07) << 1) | ((bps >> 4) & 0x01))
        data[13] = UInt8((bps & 0x0F) << 4) | UInt8((totalSamples >> 32) & 0x0F)
        data[14] = UInt8((totalSamples >> 24) & 0xFF)
        data[15] = UInt8((totalSamples >> 16) & 0xFF)
        data[16] = UInt8((totalSamples >> 8) & 0xFF)
        data[17] = UInt8(totalSamples & 0xFF)

        return data
    }

    private func encode24BE(_ value: Int) -> [UInt8] {
        [UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
