import XCTest
@testable import SwiftExif

/// Smoke tests for Ogg Opus + Ogg Vorbis standalone audio files.
///
/// Fixtures are generated on-the-fly via ffmpeg when available; tests
/// `XCTSkipUnless` when ffmpeg isn't installed so CI without media tooling
/// stays green.
final class OggReaderTests: XCTestCase {

    // MARK: - Format detection

    func testOggMagicDetectsOpus() throws {
        let opus = try generateOpusFixture()
        let data = try Data(contentsOf: opus)
        XCTAssertEqual(FormatDetector.detectAudio(data), .opus)
        XCTAssertEqual(FormatDetector.detectAudioFromExtension("opus"), .opus)
    }

    func testOggMagicDetectsVorbis() throws {
        let ogg = try generateVorbisFixture()
        let data = try Data(contentsOf: ogg)
        XCTAssertEqual(FormatDetector.detectAudio(data), .oggVorbis)
        XCTAssertEqual(FormatDetector.detectAudioFromExtension("ogg"), .oggVorbis)
        XCTAssertEqual(FormatDetector.detectAudioFromExtension("oga"), .oggVorbis)
    }

    // MARK: - Opus parsing

    func testOpusStandaloneRead() throws {
        let opus = try generateOpusFixture()
        let m = try AudioMetadata.read(from: opus)
        XCTAssertEqual(m.format, .opus)
        XCTAssertEqual(m.codec, "opus")
        XCTAssertEqual(m.codecName, "Opus")
        XCTAssertEqual(m.channels, 2)
        XCTAssertEqual(m.channelLayout, "stereo")
        XCTAssertNotNil(m.sampleRate)
        XCTAssertNotNil(m.duration)
        XCTAssertEqual(m.duration ?? 0, 3.0, accuracy: 0.1)
        XCTAssertEqual(m.title, "Test Opus")
        XCTAssertEqual(m.artist, "SwiftExif")
    }

    func testOpusSurroundLayoutLabelled() throws {
        let opus = try generateOpusFixture(channels: 6, duration: 2)
        let m = try AudioMetadata.read(from: opus)
        XCTAssertEqual(m.channels, 6)
        XCTAssertEqual(m.channelLayout, "5.1")
    }

    // MARK: - Vorbis parsing

    func testVorbisStandaloneRead() throws {
        let ogg = try generateVorbisFixture()
        let m = try AudioMetadata.read(from: ogg)
        XCTAssertEqual(m.format, .oggVorbis)
        XCTAssertEqual(m.codec, "vorbis")
        XCTAssertEqual(m.codecName, "Vorbis")
        XCTAssertEqual(m.channels, 2)
        XCTAssertEqual(m.sampleRate, 48000)
        XCTAssertNotNil(m.duration)
        XCTAssertEqual(m.duration ?? 0, 3.0, accuracy: 0.2)
        XCTAssertEqual(m.title, "Test Vorbis")
    }

    // MARK: - Fixture generation via ffmpeg

    private func generateOpusFixture(channels: Int = 2, duration: Double = 3) throws -> URL {
        try runFFmpeg(
            arguments: [
                "-y", "-v", "error",
                "-f", "lavfi",
                "-i", "sine=frequency=440:duration=\(duration):sample_rate=48000",
                "-ac", "\(channels)",
                "-c:a", "libopus",
                "-b:a", "96k",
                "-metadata", "title=Test Opus",
                "-metadata", "artist=SwiftExif",
            ],
            suffix: ".opus"
        )
    }

    private func generateVorbisFixture(channels: Int = 2, duration: Double = 3) throws -> URL {
        try runFFmpeg(
            arguments: [
                "-y", "-v", "error",
                "-f", "lavfi",
                "-i", "sine=frequency=440:duration=\(duration):sample_rate=48000",
                "-ac", "\(channels)",
                "-c:a", "vorbis",
                "-strict", "experimental",
                "-b:a", "128k",
                "-metadata", "title=Test Vorbis",
                "-metadata", "artist=SwiftExif",
            ],
            suffix: ".ogg"
        )
    }

    /// Shell out to ffmpeg to generate a fresh audio fixture in a temp file.
    /// Skips the test when ffmpeg isn't on PATH.
    private func runFFmpeg(arguments: [String], suffix: String) throws -> URL {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")
                          || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg"),
                          "ffmpeg not installed; skipping Ogg fixture test")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftexif-ogg-\(UUID().uuidString)\(suffix)")
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
            throw XCTSkip("ffmpeg failed to generate fixture (encoder missing?)")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// M2TS (Blu-ray BDAV) container sniff. Synthetic — no ffmpeg needed.
final class M2TSDetectionTests: XCTestCase {

    func testM2TSMagicDetection() {
        // Build a minimal 4-packet M2TS buffer: 4-byte TP_extra_header per
        // packet, then a 188-byte TS packet (we only need the 0x47 sync byte
        // at the start of each packet — the rest is zeros).
        var data = Data(count: 192 * 4)
        for i in 0..<4 {
            data[i * 192 + 4] = 0x47
        }
        XCTAssertTrue(MPEGReader.isMPEG(data))
        XCTAssertEqual(FormatDetector.detectVideo(data), .mpg)
    }

    func testPlainTSStillDetected() {
        var data = Data(count: 188 * 4)
        for i in 0..<4 {
            data[i * 188] = 0x47
        }
        XCTAssertTrue(MPEGReader.isMPEG(data))
    }
}
