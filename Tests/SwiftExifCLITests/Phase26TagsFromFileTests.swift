#if os(macOS)
import Foundation
import XCTest
@testable import swift_exif

// MARK: - Phase 26 — `-tagsFromFile` template expansion (`--map`)

final class Phase26TagsFromFileTests: XCTestCase {

    // MARK: parser

    func testParseMappingsAcceptsAngleSeparator() throws {
        let parsed = try parseTagMappings(["IPTC:Caption-Abstract>XMP-dc:description"])
        XCTAssertEqual(parsed, [
            TagMapping(src: "IPTC:Caption-Abstract", dst: "XMP-dc:description"),
        ])
    }

    func testParseMappingsAcceptsEqualsSeparator() throws {
        let parsed = try parseTagMappings(["IPTC:Headline=XMP-dc:title"])
        XCTAssertEqual(parsed, [
            TagMapping(src: "IPTC:Headline", dst: "XMP-dc:title"),
        ])
    }

    func testParseMappingsTrimsWhitespace() throws {
        let parsed = try parseTagMappings(["  IPTC:Headline  >  XMP-dc:title  "])
        XCTAssertEqual(parsed, [
            TagMapping(src: "IPTC:Headline", dst: "XMP-dc:title"),
        ])
    }

    func testParseMappingsRejectsMissingSeparator() {
        XCTAssertThrowsError(try parseTagMappings(["IPTC:Headline"]))
    }

    func testParseMappingsRejectsEmptySide() {
        XCTAssertThrowsError(try parseTagMappings([">XMP-dc:title"]))
        XCTAssertThrowsError(try parseTagMappings(["IPTC:Headline>"]))
    }

    func testParseMappingsHandlesMultipleEntries() throws {
        let parsed = try parseTagMappings([
            "IPTC:Headline>XMP-dc:title",
            "IPTC:Caption-Abstract=XMP-dc:description",
        ])
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].dst, "XMP-dc:title")
        XCTAssertEqual(parsed[1].dst, "XMP-dc:description")
    }
}

// MARK: - End-to-end copy with --map

final class Phase26TagsFromFileEndToEndTests: CLITestCase {

    func testCopyWithMapRoutesIPTCToXMP() throws {
        let dir = try makeTempDir()
        let source = try writeMinimalJPEG(in: dir, name: "source.jpg")
        let dest = try writeMinimalJPEG(in: dir, name: "dest.jpg")

        // Seed the source with IPTC fields only — XMP stays empty.
        var result = try CLITestHarness.run([
            "write",
            "--tag", "IPTC:Headline=Wire photo",
            "--tag", "IPTC:Caption-Abstract=A short caption.",
            source.path,
        ])
        XCTAssertEqual(result.exitCode, 0, "seed stderr: \(result.stderr)")

        // Map IPTC → XMP namespaces during copy. The bulk-copy path is
        // suppressed because --map is provided without --tags/--groups.
        result = try CLITestHarness.run([
            "copy",
            "--from", source.path,
            "--map", "IPTC:Headline>XMP-dc:title",
            "--map", "IPTC:Caption-Abstract>XMP-dc:description",
            dest.path,
        ])
        XCTAssertEqual(result.exitCode, 0, "copy stderr: \(result.stderr)")

        let read = try CLITestHarness.run(["read", "--format", "json", dest.path])
        XCTAssertEqual(read.exitCode, 0, "stderr: \(read.stderr)")
        XCTAssertTrue(read.stdout.contains("XMP-dc:title"),
                      "XMP-dc:title missing from:\n\(read.stdout)")
        XCTAssertTrue(read.stdout.contains("Wire photo"))
        XCTAssertTrue(read.stdout.contains("A short caption."))
    }

    func testCopyWithMapSkipsMissingSourceTag() throws {
        let dir = try makeTempDir()
        let source = try writeMinimalJPEG(in: dir, name: "source.jpg")
        let dest = try writeMinimalJPEG(in: dir, name: "dest.jpg")

        // Source has Headline but not Caption-Abstract — Caption mapping
        // should silently be a no-op, not an error.
        var result = try CLITestHarness.run([
            "write",
            "--tag", "IPTC:Headline=Just the headline",
            source.path,
        ])
        XCTAssertEqual(result.exitCode, 0, "seed stderr: \(result.stderr)")

        result = try CLITestHarness.run([
            "copy",
            "--from", source.path,
            "--map", "IPTC:Headline>XMP-dc:title",
            "--map", "IPTC:Caption-Abstract>XMP-dc:description",
            dest.path,
        ])
        XCTAssertEqual(result.exitCode, 0, "copy stderr: \(result.stderr)")

        let read = try CLITestHarness.run(["read", "--format", "json", dest.path])
        XCTAssertEqual(read.exitCode, 0, "stderr: \(read.stderr)")
        XCTAssertTrue(read.stdout.contains("Just the headline"))
        // No description should have been written.
        XCTAssertFalse(read.stdout.contains("XMP-dc:description"),
                       "unexpected XMP-dc:description in:\n\(read.stdout)")
    }
}
#endif
