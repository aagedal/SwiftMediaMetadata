#if os(macOS)
import Foundation
import XCTest

final class CopyTests: CLITestCase {
    func testCopyIPTCBetweenFiles() throws {
        let dir = try makeTempDir()
        let source = try writeMinimalJPEG(in: dir, name: "source.jpg")
        let dest = try writeMinimalJPEG(in: dir, name: "dest.jpg")

        // Put metadata only on the source.
        var result = try CLITestHarness.run([
            "write",
            "--tag", "IPTC:Headline=Copied Headline",
            "--tag", "IPTC:By-line=Jane Photographer",
            source.path,
        ])
        XCTAssertEqual(result.exitCode, 0, "seed stderr: \(result.stderr)")

        // Copy metadata source → dest.
        result = try CLITestHarness.run([
            "copy", "--from", source.path, dest.path,
        ])
        XCTAssertEqual(result.exitCode, 0, "copy stderr: \(result.stderr)")
        XCTAssertTrue(
            result.stdout.contains("Copied 1 file"),
            "unexpected copy stdout: \(result.stdout)"
        )

        let read = try CLITestHarness.run(["read", "--format", "json", dest.path])
        XCTAssertEqual(read.exitCode, 0, "stderr: \(read.stderr)")
        XCTAssertTrue(read.stdout.contains("Copied Headline"))
        XCTAssertTrue(read.stdout.contains("Jane Photographer"))
    }

    func testCopyWithMissingSourceFails() throws {
        let dir = try makeTempDir()
        let dest = try writeMinimalJPEG(in: dir, name: "dest.jpg")

        let result = try CLITestHarness.run([
            "copy", "--from", dir.appendingPathComponent("nope.jpg").path, dest.path,
        ])
        XCTAssertNotEqual(result.exitCode, 0, "missing source should fail")
    }
}
#endif
