import XCTest
@testable import SwiftExif

/// Matroska container parse tests. Fixtures are built with ffmpeg on-demand;
/// tests `XCTSkipUnless` when ffmpeg isn't installed.
final class MatroskaReaderTests: XCTestCase {

    /// EBML `Name` (0x536E) is valid on every TrackEntry, not only subtitle
    /// tracks. MatroskaReader used to populate it only on subtitle streams
    /// and silently drop it for video / audio tracks.
    func testMKVTrackTitlesPopulatedForVideoAndAudio() throws {
        let url = try generateMKVWithTitles(
            videoTitle: "Main Camera",
            audioTitle: "Dialog Track"
        )
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.videoStreams.count, 1)
        XCTAssertEqual(m.audioStreams.count, 1)
        XCTAssertEqual(m.videoStreams[0].title, "Main Camera")
        XCTAssertEqual(m.audioStreams[0].title, "Dialog Track")
    }

    // MARK: - Fixtures

    private func generateMKVWithTitles(videoTitle: String, audioTitle: String) throws -> URL {
        try runFFmpeg(
            arguments: [
                "-y", "-v", "error",
                "-f", "lavfi",
                "-i", "testsrc=size=160x120:rate=10:duration=1",
                "-f", "lavfi",
                "-i", "sine=frequency=440:duration=1",
                "-c:v", "libx264", "-preset", "ultrafast",
                "-c:a", "aac",
                "-metadata:s:v:0", "title=\(videoTitle)",
                "-metadata:s:a:0", "title=\(audioTitle)",
            ],
            suffix: ".mkv"
        )
    }

    private func runFFmpeg(arguments: [String], suffix: String) throws -> URL {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")
                          || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg"),
                          "ffmpeg not installed; skipping MKV fixture test")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftexif-mkv-\(UUID().uuidString)\(suffix)")
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
            throw XCTSkip("ffmpeg failed to mux MKV fixture")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
