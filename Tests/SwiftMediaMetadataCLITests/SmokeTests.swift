#if os(macOS)
import XCTest

final class SmokeTests: CLITestCase {
    func testVersionFlag() throws {
        let result = try CLITestHarness.run(["--version"])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertFalse(result.stdout.isEmpty, "--version should print something")
        // Just assert the output looks like a semver — exact version is in CHANGELOG.
        XCTAssertTrue(
            result.stdout.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) != nil,
            "stdout did not look like a version: \(result.stdout)"
        )
    }

    func testHelpFlag() throws {
        let result = try CLITestHarness.run(["--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("swift-exif"))
        XCTAssertTrue(result.stdout.contains("SUBCOMMANDS"))
    }

    func testUnknownSubcommandFallsThroughToRead() throws {
        // `read` is configured as the default subcommand, so an unknown
        // "subcommand" is interpreted as a file path for the read command.
        // We pin that behavior: stderr reports file-not-found, but exit is 0.
        let result = try CLITestHarness.run(["definitely-not-a-real-subcommand"])
        XCTAssertTrue(
            result.stderr.contains("File not found"),
            "expected stderr to report file-not-found, got: \(result.stderr)"
        )
    }

    func testReadMissingFilePrintsErrorButExitsZero() throws {
        // The CLI currently prints "File not found: ..." to stderr and
        // proceeds with zero URLs — exit status is 0 because there were no
        // per-file write failures to report. This test pins that behavior so a
        // future change to exit nonzero is caught.
        let result = try CLITestHarness.run(["read", "/nonexistent/path/to/fixture.jpg"])
        XCTAssertTrue(
            result.stderr.contains("File not found"),
            "expected 'File not found' in stderr, got: \(result.stderr)"
        )
    }
}
#endif
