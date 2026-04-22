#if os(macOS)
import Foundation
import XCTest

final class ArgfileTests: CLITestCase {
    func testArgfileExpansionWithReadCommand() throws {
        let dir = try makeTempDir()
        let url = try writeMinimalJPEG(in: dir)

        // Argfile: one argument per line, # comments allowed, blanks ignored.
        let argfile = dir.appendingPathComponent("args.txt")
        try """
        # comment line, should be ignored
        read

        --format
        json
        \(url.path)
        """.write(to: argfile, atomically: true, encoding: .utf8)

        let result = try CLITestHarness.run(["-@", argfile.path])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")

        let parsed = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        XCTAssertTrue(parsed is [[String: Any]], "argfile-driven read should produce JSON array")
    }

    func testArgfileCanCombineWithInlineArgs() throws {
        let dir = try makeTempDir()
        let url = try writeMinimalJPEG(in: dir)

        let argfile = dir.appendingPathComponent("flags.txt")
        try """
        --format
        json
        """.write(to: argfile, atomically: true, encoding: .utf8)

        // Inline subcommand + argfile flags + inline positional.
        let result = try CLITestHarness.run(["read", "-@", argfile.path, url.path])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        // If --format json was applied, we get a JSON array; otherwise the
        // table format would have "File" etc.
        let parsed = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        XCTAssertTrue(parsed is [[String: Any]], "expected JSON output")
    }

    func testMissingArgfileFails() throws {
        let dir = try makeTempDir()
        let missing = dir.appendingPathComponent("does-not-exist.txt")

        let result = try CLITestHarness.run(["-@", missing.path])
        XCTAssertNotEqual(result.exitCode, 0, "missing argfile should fail")
        XCTAssertTrue(
            result.stderr.contains("Argfile not found") || result.stderr.contains("not found"),
            "stderr should mention missing argfile, got: \(result.stderr)"
        )
    }
}
#endif
