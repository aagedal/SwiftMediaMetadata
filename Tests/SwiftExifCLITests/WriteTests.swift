#if os(macOS)
import Foundation
import XCTest

final class WriteTests: CLITestCase {
    func testWriteIPTCHeadlineThenReadBack() throws {
        let dir = try makeTempDir()
        let url = try writeMinimalJPEG(in: dir)

        let write = try CLITestHarness.run([
            "write", "--tag", "IPTC:Headline=Breaking News", url.path,
        ])
        XCTAssertEqual(write.exitCode, 0, "stderr: \(write.stderr)")
        XCTAssertTrue(write.stdout.contains("Updated 1 file"), "got: \(write.stdout)")

        let read = try CLITestHarness.run(["read", "--format", "json", url.path])
        XCTAssertEqual(read.exitCode, 0, "stderr: \(read.stderr)")
        XCTAssertTrue(
            read.stdout.contains("Breaking News"),
            "expected 'Breaking News' in read output, got:\n\(read.stdout)"
        )
    }

    func testAppendKeywordsViaPlusEquals() throws {
        let dir = try makeTempDir()
        let url = try writeMinimalJPEG(in: dir)

        // Seed with one keyword, then append two more.
        var result = try CLITestHarness.run([
            "write", "--tag", "IPTC:Keywords=news", url.path,
        ])
        XCTAssertEqual(result.exitCode, 0, "seed stderr: \(result.stderr)")

        result = try CLITestHarness.run([
            "write", "--tag", "IPTC:Keywords+=sports; politics", url.path,
        ])
        XCTAssertEqual(result.exitCode, 0, "append stderr: \(result.stderr)")

        let read = try CLITestHarness.run(["read", "--format", "json", url.path])
        XCTAssertEqual(read.exitCode, 0, "read stderr: \(read.stderr)")
        for expected in ["news", "sports", "politics"] {
            XCTAssertTrue(
                read.stdout.contains(expected),
                "expected keyword '\(expected)' in output, got:\n\(read.stdout)"
            )
        }
    }

    func testWriteWithoutTagFails() throws {
        let dir = try makeTempDir()
        let url = try writeMinimalJPEG(in: dir)

        let result = try CLITestHarness.run(["write", url.path])
        XCTAssertNotEqual(result.exitCode, 0, "missing --tag should fail validation")
        XCTAssertTrue(
            result.stderr.contains("tag") || result.stderr.contains("Tag"),
            "stderr should mention tag requirement: \(result.stderr)"
        )
    }
}
#endif
