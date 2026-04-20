import XCTest
@testable import SwiftExif

/// AVI container parse tests. Fixtures are built with ffmpeg on-demand;
/// tests `XCTSkipUnless` when ffmpeg isn't installed.
final class AVIReaderTests: XCTestCase {

    /// WAVEFORMATEX `nAvgBytesPerSec` surfaces as `AudioStream.bitRate` in
    /// bits-per-second. For pcm_s16le at 8 kHz mono 16-bit the field is
    /// 16000 bytes/s → 128000 bps.
    func testAVIAudioBitRateFromWAVEFORMATEX() throws {
        let url = try generateAVIWithPCMAudio(sampleRate: 8000, channels: 1)
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.format, .avi)
        XCTAssertEqual(m.audioStreams.count, 1)
        XCTAssertEqual(m.audioStreams[0].sampleRate, 8000)
        XCTAssertEqual(m.audioStreams[0].channels, 1)
        XCTAssertEqual(m.audioStreams[0].bitDepth, 16)
        XCTAssertEqual(m.audioStreams[0].bitRate, 128_000)
    }

    /// AVI `txts` streams carry optional subtitle tracks. The reader lifts the
    /// codec from strh.fccHandler (here "DXSB" = DivX XSUB bitmap subtitles)
    /// and the duration from dwLength * dwScale / dwRate.
    func testAVISubtitleTrackFromTxtsStream() throws {
        let data = buildAVIWithSubtitle(fccHandler: "DXSB",
                                        dwScale: 1,
                                        dwRate: 10,
                                        dwLength: 50) // 5 seconds at 10 Hz timebase
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftexif-avi-sub-\(UUID().uuidString).avi")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.format, .avi)
        XCTAssertEqual(m.subtitleStreams.count, 1)
        let sub = m.subtitleStreams[0]
        XCTAssertEqual(sub.codec, "DXSB")
        XCTAssertEqual(sub.codecName, "DivX Subtitles (XSUB)")
        XCTAssertEqual(sub.duration ?? 0, 5.0, accuracy: 0.001)
    }

    // MARK: - Fixtures

    private func generateAVIWithPCMAudio(sampleRate: Int, channels: Int) throws -> URL {
        try runFFmpeg(
            arguments: [
                "-y", "-v", "error",
                "-f", "lavfi",
                "-i", "testsrc=size=160x120:rate=10:duration=1",
                "-f", "lavfi",
                "-i", "sine=frequency=1000:duration=1",
                "-c:v", "mjpeg",
                "-c:a", "pcm_s16le",
                "-ar", "\(sampleRate)", "-ac", "\(channels)",
            ],
            suffix: ".avi"
        )
    }

    private func runFFmpeg(arguments: [String], suffix: String) throws -> URL {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")
                          || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg"),
                          "ffmpeg not installed; skipping AVI fixture test")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftexif-avi-\(UUID().uuidString)\(suffix)")
        let process = Process()
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") {
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        }
        process.arguments = arguments + [url.path]
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("ffmpeg failed to mux AVI fixture")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Build a minimal RIFF AVI byte stream with a single `txts` subtitle
    /// stream. No movi chunk — the reader only walks hdrl for stream metadata.
    private func buildAVIWithSubtitle(fccHandler: String,
                                      dwScale: UInt32,
                                      dwRate: UInt32,
                                      dwLength: UInt32) -> Data {
        // strh payload (56 bytes): fccType + fccHandler + dwFlags + wPriority +
        // wLanguage + dwInitialFrames + dwScale + dwRate + dwStart + dwLength + …
        var strh = Data(count: 56)
        strh.replaceSubrange(0..<4, with: Array("txts".utf8))
        strh.replaceSubrange(4..<8, with: Array(fccHandler.padding(toLength: 4, withPad: " ", startingAt: 0).utf8))
        writeLE32(&strh, at: 20, dwScale)
        writeLE32(&strh, at: 24, dwRate)
        writeLE32(&strh, at: 32, dwLength)
        let strhChunk = riffChunk(id: "strh", payload: strh)

        // Empty strf — the reader only requires its presence.
        let strfChunk = riffChunk(id: "strf", payload: Data())

        var strlBody = Data()
        strlBody.append(Array("strl".utf8), count: 4)
        strlBody.append(strhChunk)
        strlBody.append(strfChunk)
        let strlChunk = riffChunk(id: "LIST", payload: strlBody)

        // Minimal avih (40 bytes all-zero — widths, fps, frame count all 0).
        let avihChunk = riffChunk(id: "avih", payload: Data(count: 40))

        var hdrlBody = Data()
        hdrlBody.append(Array("hdrl".utf8), count: 4)
        hdrlBody.append(avihChunk)
        hdrlBody.append(strlChunk)
        let hdrlChunk = riffChunk(id: "LIST", payload: hdrlBody)

        var riffBody = Data()
        riffBody.append(Array("AVI ".utf8), count: 4)
        riffBody.append(hdrlChunk)

        var riff = Data()
        riff.append(Array("RIFF".utf8), count: 4)
        var size = UInt32(riffBody.count)
        riff.append(Data(bytes: &size, count: 4))
        riff.append(riffBody)
        return riff
    }

    private func riffChunk(id: String, payload: Data) -> Data {
        var chunk = Data()
        chunk.append(Array(id.utf8), count: 4)
        var size = UInt32(payload.count)
        chunk.append(Data(bytes: &size, count: 4))
        chunk.append(payload)
        if payload.count & 1 == 1 { chunk.append(0x00) } // RIFF pad
        return chunk
    }

    private func writeLE32(_ data: inout Data, at offset: Int, _ value: UInt32) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
