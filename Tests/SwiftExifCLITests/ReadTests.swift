#if os(macOS)
import Foundation
import XCTest

final class ReadTests: CLITestCase {
    func testReadTableFormatOnMinimalJPEG() throws {
        let dir = try makeTempDir()
        let url = try writeMinimalJPEG(in: dir)

        let result = try CLITestHarness.run(["read", url.path])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        // Table output always includes at least File:* tags.
        XCTAssertTrue(
            result.stdout.contains("FileName") || result.stdout.contains("File:FileName"),
            "expected FileName in output, got:\n\(result.stdout)"
        )
    }

    func testReadJSONFormatProducesValidJSON() throws {
        let dir = try makeTempDir()
        let url = try writeMinimalJPEG(in: dir)

        let result = try CLITestHarness.run(["read", "--format", "json", url.path])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")

        let data = Data(result.stdout.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let array = parsed as? [[String: Any]] else {
            XCTFail("Expected JSON array of objects, got: \(parsed)")
            return
        }
        XCTAssertEqual(array.count, 1)
        XCTAssertFalse(array[0].isEmpty, "first entry should not be empty")
    }

    func testReadCSVFormatHasHeaderRow() throws {
        let dir = try makeTempDir()
        let url = try writeMinimalJPEG(in: dir)

        let result = try CLITestHarness.run(["read", "--format", "csv", url.path])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")

        let lines = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 2, "expected header + 1 data row")
        XCTAssertTrue(lines[0].contains(","), "header line should be comma-delimited")
    }

    func testReadWithFieldsFilterLimitsOutput() throws {
        let dir = try makeTempDir()
        let url = try writeMinimalJPEG(in: dir)

        // The print-readable output uses "File:FileName" as the key, so the
        // --fields filter has to match that exact string.
        let result = try CLITestHarness.run([
            "read", "--format", "json", "--fields", "File:FileName", url.path,
        ])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")

        let array = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]
        XCTAssertEqual(array?.count, 1)
        XCTAssertEqual(array?.first?.keys.sorted(), ["File:FileName"])
    }
}
#endif
