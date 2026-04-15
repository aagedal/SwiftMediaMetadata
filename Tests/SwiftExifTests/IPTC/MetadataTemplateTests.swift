import XCTest
@testable import SwiftExif

final class MetadataTemplateTests: XCTestCase {

    // MARK: - Apply Template

    func testApplyNewsTemplate() throws {
        var metadata = ImageMetadata.empty()
        try MetadataTemplate.news.apply(to: &metadata)

        XCTAssertEqual(metadata.iptc.bylineTitle, "Staff Photographer")
        XCTAssertEqual(metadata.iptc.urgency, 5)
        XCTAssertEqual(metadata.iptc.value(for: .objectCycle), "a")
        XCTAssertEqual(metadata.iptc.editStatus, "New")
    }

    func testApplyStockTemplate() throws {
        var metadata = ImageMetadata.empty()
        try MetadataTemplate.stock.apply(to: &metadata)

        XCTAssertEqual(metadata.iptc.category, "STK")
        XCTAssertEqual(metadata.iptc.supplementalCategories, ["Stock", "Commercial"])
        XCTAssertEqual(metadata.iptc.editStatus, "Final")
    }

    func testApplyEditorialTemplate() throws {
        var metadata = ImageMetadata.empty()
        try MetadataTemplate.editorial.apply(to: &metadata)

        XCTAssertEqual(metadata.iptc.urgency, 5)
        XCTAssertEqual(metadata.iptc.value(for: .objectCycle), "b")
        XCTAssertEqual(metadata.iptc.editStatus, "New")
    }

    // MARK: - Overwrite Behavior

    func testApplyWithoutOverwritePreservesExisting() throws {
        var metadata = ImageMetadata.empty()
        metadata.iptc.bylineTitle = "Photographer"
        metadata.iptc.urgency = 1

        try MetadataTemplate.news.apply(to: &metadata, overwrite: false)

        // Existing values preserved
        XCTAssertEqual(metadata.iptc.bylineTitle, "Photographer")
        XCTAssertEqual(metadata.iptc.urgency, 1)
        // Missing values filled in
        XCTAssertEqual(metadata.iptc.editStatus, "New")
    }

    func testApplyWithOverwriteReplacesExisting() throws {
        var metadata = ImageMetadata.empty()
        metadata.iptc.bylineTitle = "Photographer"
        metadata.iptc.urgency = 1

        try MetadataTemplate.news.apply(to: &metadata, overwrite: true)

        // Values replaced by template
        XCTAssertEqual(metadata.iptc.bylineTitle, "Staff Photographer")
        XCTAssertEqual(metadata.iptc.urgency, 5)
    }

    // MARK: - XMP Sync

    func testTemplateApplySyncsToXMP() throws {
        var metadata = ImageMetadata.empty()
        metadata.iptc.headline = "Test Headline"
        try MetadataTemplate.news.apply(to: &metadata)

        // IPTC→XMP sync should have set XMP headline
        XCTAssertEqual(metadata.xmp?.headline, "Test Headline")
    }

    // MARK: - Custom Template

    func testCustomTemplate() throws {
        let template = MetadataTemplate(
            name: "NTB",
            iptcFields: [
                .credit: "NTB Scanpix",
                .source: "NTB",
                .countryPrimaryLocationCode: "NOR",
                .countryPrimaryLocationName: "Norway",
            ]
        )

        var metadata = ImageMetadata.empty()
        try template.apply(to: &metadata)

        XCTAssertEqual(metadata.iptc.credit, "NTB Scanpix")
        XCTAssertEqual(metadata.iptc.source, "NTB")
        XCTAssertEqual(metadata.iptc.countryCode, "NOR")
        XCTAssertEqual(metadata.iptc.countryName, "Norway")
    }

    func testCustomTemplateWithArrayFields() throws {
        let template = MetadataTemplate(
            name: "Custom",
            iptcArrayFields: [
                .keywords: ["news", "breaking", "photography"],
                .supplementalCategories: ["PressPhoto"],
            ]
        )

        var metadata = ImageMetadata.empty()
        try template.apply(to: &metadata)

        XCTAssertEqual(metadata.iptc.keywords, ["news", "breaking", "photography"])
        XCTAssertEqual(metadata.iptc.supplementalCategories, ["PressPhoto"])
    }

    func testCustomTemplateArrayPreservesExisting() throws {
        let template = MetadataTemplate(
            name: "Custom",
            iptcArrayFields: [
                .keywords: ["template-keyword"],
            ]
        )

        var metadata = ImageMetadata.empty()
        metadata.iptc.keywords = ["existing"]

        try template.apply(to: &metadata, overwrite: false)
        XCTAssertEqual(metadata.iptc.keywords, ["existing"])

        try template.apply(to: &metadata, overwrite: true)
        XCTAssertEqual(metadata.iptc.keywords, ["template-keyword"])
    }

    // MARK: - XMP Rights via Template

    func testNewsTemplateUsageTerms() throws {
        var metadata = ImageMetadata.empty()
        try MetadataTemplate.news.apply(to: &metadata)

        XCTAssertEqual(metadata.xmp?.usageTerms, "For editorial use only")
    }

    func testStockTemplateUsageTerms() throws {
        var metadata = ImageMetadata.empty()
        try MetadataTemplate.stock.apply(to: &metadata)

        XCTAssertEqual(metadata.xmp?.usageTerms, "Licensed for commercial use")
    }
}

// MARK: - Test Helpers

extension ImageMetadata {
    static func empty() -> ImageMetadata {
        ImageMetadata()
    }
}
