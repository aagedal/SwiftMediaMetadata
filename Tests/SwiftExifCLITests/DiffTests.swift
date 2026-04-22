#if os(macOS)
import Foundation
import XCTest

final class DiffTests: CLITestCase {
    func testDiffIdenticalFilesReportsIdentical() throws {
        let dir = try makeTempDir()
        let a = try writeMinimalJPEG(in: dir, name: "a.jpg")
        let b = try writeMinimalJPEG(in: dir, name: "b.jpg")

        let result = try CLITestHarness.run(["diff", a.path, b.path])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        // File:FileName differs (a.jpg vs b.jpg) — but otherwise these should be
        // equivalent. We accept either "identical" or a single filename
        // modification, but nothing else.
        if !result.stdout.contains("Files are identical.") {
            XCTAssertTrue(
                result.stdout.contains("FileName"),
                "unexpected diff output:\n\(result.stdout)"
            )
        }
    }

    func testDiffShowsAddedHeadline() throws {
        let dir = try makeTempDir()
        let a = try writeMinimalJPEG(in: dir, name: "a.jpg")
        let b = try writeMinimalJPEG(in: dir, name: "b.jpg")

        // Add a headline to `b` only.
        _ = try CLITestHarness.run([
            "write", "--tag", "IPTC:Headline=Only in B", b.path,
        ])

        let result = try CLITestHarness.run(["diff", a.path, b.path])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(
            result.stdout.contains("Only in B"),
            "diff should show the added headline, got:\n\(result.stdout)"
        )
        XCTAssertTrue(
            result.stdout.contains("Added") || result.stdout.contains("added"),
            "diff should label additions, got:\n\(result.stdout)"
        )
    }

    func testDiffJSONIsValidJSON() throws {
        let dir = try makeTempDir()
        let a = try writeMinimalJPEG(in: dir, name: "a.jpg")
        let b = try writeMinimalJPEG(in: dir, name: "b.jpg")

        _ = try CLITestHarness.run([
            "write", "--tag", "IPTC:Headline=B Only", b.path,
        ])

        let result = try CLITestHarness.run(["diff", "--json", a.path, b.path])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")

        let parsed = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        guard let obj = parsed as? [String: Any] else {
            XCTFail("diff --json should produce a dictionary, got: \(parsed)")
            return
        }
        XCTAssertNotNil(obj["file1"])
        XCTAssertNotNil(obj["file2"])
        XCTAssertNotNil(obj["changes"])
    }
}
#endif
