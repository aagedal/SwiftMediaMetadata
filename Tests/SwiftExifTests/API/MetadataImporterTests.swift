import XCTest
@testable import SwiftExif

final class MetadataImporterTests: XCTestCase {

    // MARK: - JSON Parsing

    func testParseJSON() throws {
        let json = """
        [
            {"SourceFile": "photo.jpg", "IPTC:Headline": "Test", "IPTC:City": "Oslo"},
            {"SourceFile": "photo2.jpg", "IPTC:Headline": "Other"}
        ]
        """
        let records = try MetadataImporter.parseJSON(Data(json.utf8))

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["IPTC:Headline"], "Test")
        XCTAssertEqual(records[0]["IPTC:City"], "Oslo")
        XCTAssertEqual(records[1]["IPTC:Headline"], "Other")
    }

    func testParseJSONWithArrays() throws {
        let json = """
        [{"IPTC:Keywords": ["travel", "norway", "fjord"]}]
        """
        let records = try MetadataImporter.parseJSON(Data(json.utf8))
        XCTAssertEqual(records[0]["IPTC:Keywords"], "travel;norway;fjord")
    }

    // MARK: - CSV Parsing

    func testParseCSV() throws {
        let csv = "IPTC:Headline,IPTC:City\nTest,Oslo\nOther,Bergen\n"
        let records = try MetadataImporter.parseCSV(csv)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["IPTC:Headline"], "Test")
        XCTAssertEqual(records[0]["IPTC:City"], "Oslo")
        XCTAssertEqual(records[1]["IPTC:City"], "Bergen")
    }

    func testParseCSVQuotedFields() throws {
        let csv = "IPTC:Headline,IPTC:Keywords\n\"Hello, World\",\"a;b;c\"\n"
        let records = try MetadataImporter.parseCSV(csv)

        XCTAssertEqual(records[0]["IPTC:Headline"], "Hello, World")
        XCTAssertEqual(records[0]["IPTC:Keywords"], "a;b;c")
    }

    func testParseCSVEscapedQuotes() throws {
        let csv = "IPTC:Headline\n\"She said \"\"hello\"\"\"\n"
        let records = try MetadataImporter.parseCSV(csv)

        XCTAssertEqual(records[0]["IPTC:Headline"], "She said \"hello\"")
    }

    // MARK: - Apply Record

    func testApplyIPTCFields() {
        var metadata = makeMetadata()
        let record: [String: String] = [
            "IPTC:Headline": "Breaking News",
            "IPTC:City": "Stockholm",
            "IPTC:Keywords": "news;urgent;breaking",
        ]

        MetadataImporter.apply(record, to: &metadata)

        XCTAssertEqual(metadata.iptc.headline, "Breaking News")
        XCTAssertEqual(metadata.iptc.city, "Stockholm")
        XCTAssertEqual(metadata.iptc.keywords, ["news", "urgent", "breaking"])
    }

    func testApplyXMPFields() {
        var metadata = makeMetadata()
        let record: [String: String] = [
            "XMP-dc:title": "My Photo",
            "XMP-dc:creator": "Alice;Bob",
        ]

        MetadataImporter.apply(record, to: &metadata)

        XCTAssertEqual(metadata.xmp?.title, "My Photo")
    }

    func testApplyWithFilter() {
        var metadata = makeMetadata()
        let record: [String: String] = [
            "IPTC:Headline": "Included",
            "IPTC:City": "Excluded",
        ]
        let filter = TagFilter(tags: ["IPTC:Headline"])

        MetadataImporter.apply(record, to: &metadata, filter: filter)

        XCTAssertEqual(metadata.iptc.headline, "Included")
        XCTAssertNil(metadata.iptc.city)
    }

    func testSkipExifFields() {
        var metadata = makeMetadata()
        let record: [String: String] = [
            "Make": "Canon", // EXIF — should be skipped
            "IPTC:Headline": "Applied",
        ]

        MetadataImporter.apply(record, to: &metadata)

        XCTAssertEqual(metadata.iptc.headline, "Applied")
        // Make is not writable through import — verify no crash
    }

    // MARK: - CSV Round-Trip with CSVExporter

    func testCSVExportImportRoundTrip() throws {
        let jpeg = TestFixtures.minimalJPEG()
        var original = try ImageMetadata.read(from: jpeg)
        try original.iptc.setValue("Round Trip", for: .headline)
        try original.iptc.setValue("Oslo", for: .city)

        // Export
        let csv = CSVExporter.toCSV([original])

        // Import
        let records = try MetadataImporter.parseCSV(csv)
        XCTAssertEqual(records.count, 1)

        // Apply to fresh metadata
        var target = try ImageMetadata.read(from: jpeg)
        MetadataImporter.apply(records[0], to: &target)

        XCTAssertEqual(target.iptc.value(for: .headline), "Round Trip")
        XCTAssertEqual(target.iptc.value(for: .city), "Oslo")
    }

    // MARK: - Helpers

    private func makeMetadata() -> ImageMetadata {
        let jpeg = JPEGFile(segments: [], scanData: Data())
        return ImageMetadata(container: .jpeg(jpeg), format: .jpeg, iptc: IPTCData())
    }
}
