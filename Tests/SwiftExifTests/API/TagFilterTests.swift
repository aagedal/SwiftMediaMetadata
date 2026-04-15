import XCTest
@testable import SwiftExif

final class TagFilterTests: XCTestCase {

    // MARK: - Pattern Matching

    func testExactMatch() {
        let filter = TagFilter(tags: ["Make"])
        XCTAssertTrue(filter.matches(key: "Make"))
        XCTAssertFalse(filter.matches(key: "Model"))
    }

    func testPrefixWildcard() {
        let filter = TagFilter(tags: ["IPTC:*"])
        XCTAssertTrue(filter.matches(key: "IPTC:Headline"))
        XCTAssertTrue(filter.matches(key: "IPTC:Keywords"))
        XCTAssertFalse(filter.matches(key: "Make"))
        XCTAssertFalse(filter.matches(key: "XMP-dc:title"))
    }

    func testSuffixWildcard() {
        let filter = TagFilter(tags: ["*Keywords*"])
        XCTAssertTrue(filter.matches(key: "IPTC:Keywords"))
        XCTAssertFalse(filter.matches(key: "IPTC:Headline"))
    }

    func testQuestionMarkWildcard() {
        let filter = TagFilter(tags: ["IS?"])
        XCTAssertTrue(filter.matches(key: "ISO"))
        XCTAssertFalse(filter.matches(key: "IPTC:Headline"))
    }

    func testCaseInsensitive() {
        let filter = TagFilter(tags: ["make"])
        XCTAssertTrue(filter.matches(key: "Make"))
    }

    // MARK: - Exclusion

    func testExcludePattern() {
        let filter = TagFilter(excludeTags: ["MakerNote:*"])
        XCTAssertTrue(filter.matches(key: "Make"))
        XCTAssertTrue(filter.matches(key: "IPTC:Headline"))
        XCTAssertFalse(filter.matches(key: "MakerNote:SerialNumber"))
    }

    func testCombinedIncludeExclude() {
        // Include all IPTC, but exclude Keywords
        let filter = TagFilter(tags: ["IPTC:*"], excludeTags: ["IPTC:Keywords"])
        XCTAssertTrue(filter.matches(key: "IPTC:Headline"))
        XCTAssertTrue(filter.matches(key: "IPTC:City"))
        XCTAssertFalse(filter.matches(key: "IPTC:Keywords"))
        XCTAssertFalse(filter.matches(key: "Make")) // not in includes
    }

    func testEmptyFilterPassesAll() {
        let filter = TagFilter(tags: [], excludeTags: [])
        XCTAssertTrue(filter.isEmpty)
        XCTAssertTrue(filter.matches(key: "Make"))
        XCTAssertTrue(filter.matches(key: "IPTC:Headline"))
        XCTAssertTrue(filter.matches(key: "MakerNote:Foo"))
    }

    // MARK: - Apply to Dictionary

    func testApplyToDictionary() {
        let dict: [String: Any] = [
            "Make": "Canon",
            "Model": "EOS R5",
            "IPTC:Headline": "Test",
            "IPTC:Keywords": ["a", "b"],
            "MakerNote:Serial": "123",
        ]
        let filter = TagFilter(tags: ["IPTC:*"])
        let result = filter.apply(to: dict)

        XCTAssertEqual(result.count, 2)
        XCTAssertNotNil(result["IPTC:Headline"])
        XCTAssertNotNil(result["IPTC:Keywords"])
        XCTAssertNil(result["Make"])
    }

    func testApplyExcludeToDict() {
        let dict: [String: Any] = [
            "Make": "Canon",
            "IPTC:Headline": "Test",
            "MakerNote:Serial": "123",
        ]
        let filter = TagFilter(excludeTags: ["MakerNote:*"])
        let result = filter.apply(to: dict)

        XCTAssertEqual(result.count, 2)
        XCTAssertNil(result["MakerNote:Serial"])
    }

    // MARK: - Integration with MetadataExporter

    func testFilteredDictionary() throws {
        let jpeg = TestFixtures.minimalJPEG()
        var metadata = try ImageMetadata.read(from: jpeg)
        try metadata.iptc.setValue("Test Headline", for: .headline)
        try metadata.iptc.setValue("Test City", for: .city)

        let filter = TagFilter(tags: ["IPTC:*"])
        let dict = MetadataExporter.filteredDictionary(metadata, filter: filter)

        XCTAssertNotNil(dict["IPTC:Headline"])
        XCTAssertNil(dict["FileFormat"]) // excluded by filter
    }

    // MARK: - removeMatchingTags

    func testRemoveMatchingTags() throws {
        let jpeg = TestFixtures.minimalJPEG()
        var metadata = try ImageMetadata.read(from: jpeg)
        try metadata.iptc.setValue("Headline", for: .headline)
        try metadata.iptc.setValue("City", for: .city)
        if metadata.xmp == nil { metadata.xmp = XMPData() }
        metadata.xmp?.title = "XMP Title"

        let filter = TagFilter(tags: ["IPTC:*"])
        let removed = metadata.removeMatchingTags(filter)

        XCTAssertGreaterThan(removed, 0)
        XCTAssertNil(metadata.iptc.value(for: .headline))
        XCTAssertEqual(metadata.xmp?.title, "XMP Title") // XMP not affected
    }

    // MARK: - Multiple Include Patterns

    func testMultipleIncludes() {
        let filter = TagFilter(tags: ["IPTC:*", "Make", "Model"])
        XCTAssertTrue(filter.matches(key: "Make"))
        XCTAssertTrue(filter.matches(key: "Model"))
        XCTAssertTrue(filter.matches(key: "IPTC:Headline"))
        XCTAssertFalse(filter.matches(key: "ISO"))
    }

    // MARK: - CSVExporter with Filter

    func testCSVExportWithFilter() throws {
        let jpeg = TestFixtures.minimalJPEG()
        var metadata = try ImageMetadata.read(from: jpeg)
        try metadata.iptc.setValue("Test", for: .headline)

        let filter = TagFilter(tags: ["IPTC:*"])
        let csv = CSVExporter.toCSV([metadata], filter: filter)

        XCTAssertTrue(csv.contains("IPTC:Headline"))
        XCTAssertFalse(csv.contains("FileFormat"))
    }
}
