import XCTest
@testable import SwiftExif

/// Subtitle-track extraction tests. Fixtures are built with ffmpeg on-demand;
/// tests `XCTSkipUnless` when ffmpeg isn't installed so machines without
/// media tooling stay green.
final class SubtitleTrackTests: XCTestCase {

    // MARK: - MP4 (3GPP Timed Text)

    func testMP4TimedTextSubtitleTrack() throws {
        let url = try generateMP4WithTimedText(language: "nor")
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.subtitleStreams.count, 1)
        let sub = m.subtitleStreams[0]
        XCTAssertEqual(sub.codec, "tx3g")
        XCTAssertEqual(sub.codecName, "3GPP Timed Text")
        XCTAssertEqual(sub.language, "nor")
        // Plain track: neither the `kind` disposition box nor the tx3g
        // forced bit is present, so the flag stays nil.
        XCTAssertNil(sub.isForced)
    }

    /// Forced disposition surfaces as `isForced = true` via the tx3g
    /// displayFlags bit 0x40000000 that ffmpeg writes for
    /// `-disposition:s:0 forced`.
    func testMP4ForcedSubtitleTrackFlag() throws {
        let url = try generateMP4WithTimedText(language: "eng", forced: true)
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.subtitleStreams.count, 1)
        XCTAssertEqual(m.subtitleStreams[0].isForced, true)
    }

    // MARK: - Matroska (SubRip)

    func testMKVSubRipSubtitleTrack() throws {
        let url = try generateMKVWithSRT(language: "swe")
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.subtitleStreams.count, 1)
        let sub = m.subtitleStreams[0]
        XCTAssertEqual(sub.codec, "S_TEXT/UTF8")
        XCTAssertEqual(sub.codecName, "SubRip (SRT)")
        XCTAssertEqual(sub.language, "swe")
    }

    // MARK: - Fixture generation

    /// Build an MP4 with an embedded `tx3g` subtitle track and a chosen
    /// ISO 639-2 language code.
    private func generateMP4WithTimedText(language: String, forced: Bool = false) throws -> URL {
        let subURL = try writeSRT()
        var args = [
            "-y", "-v", "error",
            "-f", "lavfi",
            "-i", "testsrc=size=640x360:rate=25:duration=2",
            "-i", subURL.path,
            "-c:v", "libx264", "-preset", "ultrafast",
            "-c:s", "mov_text",
            "-metadata:s:s:0", "language=\(language)",
        ]
        if forced {
            args.append(contentsOf: ["-disposition:s:0", "forced"])
        }
        return try runFFmpeg(arguments: args, suffix: ".mp4")
    }

    private func generateMKVWithSRT(language: String) throws -> URL {
        let subURL = try writeSRT()
        return try runFFmpeg(
            arguments: [
                "-y", "-v", "error",
                "-f", "lavfi",
                "-i", "testsrc=size=640x360:rate=25:duration=2",
                "-i", subURL.path,
                "-c:v", "libx264", "-preset", "ultrafast",
                "-c:s", "srt",
                "-metadata:s:s:0", "language=\(language)",
            ],
            suffix: ".mkv"
        )
    }

    private func writeSRT() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftexif-sub-\(UUID().uuidString).srt")
        let srt = "1\n00:00:00,000 --> 00:00:02,000\nHello\n"
        try srt.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func runFFmpeg(arguments: [String], suffix: String) throws -> URL {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")
                          || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg"),
                          "ffmpeg not installed; skipping subtitle fixture test")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftexif-sub-\(UUID().uuidString)\(suffix)")
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
            throw XCTSkip("ffmpeg failed to mux subtitle fixture")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
