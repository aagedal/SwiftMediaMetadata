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
}
