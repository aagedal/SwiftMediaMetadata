#if os(macOS)
import Foundation
import XCTest

final class StripTests: CLITestCase {
    func testStripIPTCRemovesHeadline() throws {
        let dir = try makeTempDir()
        let url = try writeMinimalJPEG(in: dir)

        // Write an IPTC headline first.
        var result = try CLITestHarness.run([
            "write", "--tag", "IPTC:Headline=Will be stripped", url.path,
        ])
        XCTAssertEqual(result.exitCode, 0, "write stderr: \(result.stderr)")

        var read = try CLITestHarness.run(["read", "--format", "json", url.path])
        XCTAssertTrue(
            read.stdout.contains("Will be stripped"),
            "seed write did not persist: \(read.stdout)"
        )

        // Strip IPTC.
        result = try CLITestHarness.run(["strip", "--iptc", url.path])
        XCTAssertEqual(result.exitCode, 0, "strip stderr: \(result.stderr)")
        XCTAssertTrue(
            result.stdout.contains("Stripped 1 file"),
            "unexpected strip stdout: \(result.stdout)"
        )

        read = try CLITestHarness.run(["read", "--format", "json", url.path])
        XCTAssertFalse(
            read.stdout.contains("Will be stripped"),
            "headline should be gone after --iptc strip: \(read.stdout)"
        )
    }

    func testStripRequiresAtLeastOneFlag() throws {
        let dir = try makeTempDir()
        let url = try writeMinimalJPEG(in: dir)

        let result = try CLITestHarness.run(["strip", url.path])
        XCTAssertNotEqual(result.exitCode, 0, "strip with no flags should fail")
    }

    func testStripAllWithBackupPreservesOriginal() throws {
        let dir = try makeTempDir()
        let url = try writeMinimalJPEG(in: dir)

        _ = try CLITestHarness.run([
            "write", "--tag", "IPTC:Headline=Original", url.path,
        ])

        let result = try CLITestHarness.run(["strip", "--all", "--backup", url.path])
        XCTAssertEqual(result.exitCode, 0, "strip stderr: \(result.stderr)")

        // Backup file naming is exiftool-style `<name>_original`.
        let backup = url.path + "_original"
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backup),
            "expected backup at \(backup) — existing files: " +
            "\((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])"
        )
    }
}
#endif
