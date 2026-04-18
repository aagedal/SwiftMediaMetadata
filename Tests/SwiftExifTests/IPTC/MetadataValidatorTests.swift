import XCTest
@testable import SwiftExif

final class MetadataValidatorTests: XCTestCase {

    // MARK: - News Wire Profile

    func testNewsWireValidWithAllRequiredFields() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.headline = "Breaking News"
        metadata.iptc.caption = "A major event occurred today."
        metadata.iptc.byline = "John Doe"
        metadata.iptc.credit = "AP"
        metadata.iptc.city = "Oslo"
        metadata.iptc.countryName = "Norway"
        metadata.iptc.dateCreated = "20260415"
        metadata.iptc.copyright = "2026 AP"
        metadata.iptc.keywords = ["news", "event"]

        let result = MetadataValidator.newsWire.validate(metadata)
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testNewsWireMissingHeadline() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.caption = "A caption"
        metadata.iptc.byline = "John Doe"
        metadata.iptc.credit = "AP"
        metadata.iptc.city = "Oslo"
        metadata.iptc.countryName = "Norway"
        metadata.iptc.dateCreated = "20260415"
        metadata.iptc.copyright = "2026 AP"
        metadata.iptc.keywords = ["news"]

        let result = MetadataValidator.newsWire.validate(metadata)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.field == "IPTC:Headline" })
    }

    func testNewsWireMissingMultipleFields() {
        let metadata = ImageMetadata.empty()

        let result = MetadataValidator.newsWire.validate(metadata)
        XCTAssertFalse(result.isValid)
        // Should have errors for all required fields
        XCTAssertTrue(result.errors.count >= 9)
    }

    func testNewsWireWarningsForRecommendedFields() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.headline = "Breaking News"
        metadata.iptc.caption = "A major event."
        metadata.iptc.byline = "John Doe"
        metadata.iptc.credit = "AP"
        metadata.iptc.city = "Oslo"
        metadata.iptc.countryName = "Norway"
        metadata.iptc.dateCreated = "20260415"
        metadata.iptc.copyright = "2026 AP"
        metadata.iptc.keywords = ["news"]
        // Omit recommended: source, province-state, country code, etc.

        let result = MetadataValidator.newsWire.validate(metadata)
        XCTAssertTrue(result.isValid) // warnings don't make it invalid
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.field == "IPTC:Source" })
    }

    // MARK: - Stock Photo Profile

    func testStockPhotoMinimumKeywords() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.headline = "Sunset Over Mountains"
        metadata.iptc.caption = "Beautiful sunset."
        metadata.iptc.byline = "Jane Smith"
        metadata.iptc.copyright = "2026 Jane Smith"
        metadata.iptc.keywords = ["sunset", "mountains"] // Only 2, needs ≥3

        let result = MetadataValidator.stockPhoto.validate(metadata)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.field == "IPTC:Keywords" && $0.message.contains("3") })
    }

    func testStockPhotoValidWith3Keywords() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.headline = "Sunset Over Mountains"
        metadata.iptc.caption = "Beautiful sunset."
        metadata.iptc.byline = "Jane Smith"
        metadata.iptc.copyright = "2026 Jane Smith"
        metadata.iptc.keywords = ["sunset", "mountains", "landscape"]

        let result = MetadataValidator.stockPhoto.validate(metadata)
        XCTAssertTrue(result.isValid)
    }

    // MARK: - Editorial Profile

    func testEditorialValid() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.headline = "Feature Story"
        metadata.iptc.caption = "An in-depth look at life in Oslo."
        metadata.iptc.byline = "Per Hansen"
        metadata.iptc.credit = "Aftenposten"

        let result = MetadataValidator.editorial.validate(metadata)
        XCTAssertTrue(result.isValid)
    }

    func testEditorialMissingCredit() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.headline = "Feature Story"
        metadata.iptc.caption = "A caption."
        metadata.iptc.byline = "Per Hansen"

        let result = MetadataValidator.editorial.validate(metadata)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.field == "IPTC:Credit" })
    }

    // MARK: - Format Validation: Urgency

    func testValidUrgency() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.urgency = 1
        let result = MetadataValidator(enforceFormats: true).validate(metadata)
        XCTAssertTrue(result.errors.filter { $0.field == "IPTC:Urgency" }.isEmpty)
    }

    func testUrgencyTooHigh() {
        var metadata = ImageMetadata.empty()
        try? metadata.iptc.setValue("9", for: .urgency)
        let result = MetadataValidator(enforceFormats: true).validate(metadata)
        XCTAssertTrue(result.errors.contains { $0.field == "IPTC:Urgency" })
    }

    func testUrgencyZero() {
        var metadata = ImageMetadata.empty()
        try? metadata.iptc.setValue("0", for: .urgency)
        let result = MetadataValidator(enforceFormats: true).validate(metadata)
        XCTAssertTrue(result.errors.contains { $0.field == "IPTC:Urgency" })
    }

    // MARK: - Format Validation: DateCreated

    func testValidDateCreated() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.dateCreated = "20260415"
        let result = MetadataValidator(enforceFormats: true).validate(metadata)
        XCTAssertTrue(result.errors.filter { $0.field == "IPTC:DateCreated" }.isEmpty)
    }

    func testInvalidDateCreatedTooShort() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.dateCreated = "2026041"
        let result = MetadataValidator(enforceFormats: true).validate(metadata)
        XCTAssertTrue(result.errors.contains { $0.field == "IPTC:DateCreated" })
    }

    func testInvalidDateCreatedBadMonth() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.dateCreated = "20261315"
        let result = MetadataValidator(enforceFormats: true).validate(metadata)
        XCTAssertTrue(result.errors.contains { $0.field == "IPTC:DateCreated" })
    }

    func testInvalidDateCreatedLetters() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.dateCreated = "2026-04-15"
        let result = MetadataValidator(enforceFormats: true).validate(metadata)
        XCTAssertTrue(result.errors.contains { $0.field == "IPTC:DateCreated" })
    }

    // MARK: - Format Validation: TimeCreated

    func testValidTimeCreated() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.timeCreated = "143000+0200"
        let result = MetadataValidator(enforceFormats: true).validate(metadata)
        XCTAssertTrue(result.errors.filter { $0.field == "IPTC:TimeCreated" }.isEmpty)
    }

    func testValidTimeCreatedShort() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.timeCreated = "143000"
        let result = MetadataValidator(enforceFormats: true).validate(metadata)
        XCTAssertTrue(result.errors.filter { $0.field == "IPTC:TimeCreated" }.isEmpty)
    }

    func testInvalidTimeCreated() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.timeCreated = "25:00:00"
        let result = MetadataValidator(enforceFormats: true).validate(metadata)
        XCTAssertTrue(result.errors.contains { $0.field == "IPTC:TimeCreated" })
    }

    // MARK: - Format Validation: CountryCode

    func testValidCountryCode() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.countryCode = "NOR"
        let result = MetadataValidator(enforceFormats: true).validate(metadata)
        XCTAssertTrue(result.errors.filter { $0.field == "IPTC:Country-PrimaryLocationCode" }.isEmpty)
    }

    func testInvalidCountryCodeLowercase() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.countryCode = "nor"
        let result = MetadataValidator(enforceFormats: true).validate(metadata)
        XCTAssertTrue(result.errors.contains { $0.field == "IPTC:Country-PrimaryLocationCode" })
    }

    func testInvalidCountryCodeTooShort() {
        var metadata = ImageMetadata.empty()
        metadata.iptc.countryCode = "NO"
        let result = MetadataValidator(enforceFormats: true).validate(metadata)
        XCTAssertTrue(result.errors.contains { $0.field == "IPTC:Country-PrimaryLocationCode" })
    }

    // MARK: - Format Validation: ObjectCycle

    func testValidObjectCycle() {
        for cycle in ["a", "p", "b"] {
            var metadata = ImageMetadata.empty()
            try? metadata.iptc.setValue(cycle, for: .objectCycle)
            let result = MetadataValidator(enforceFormats: true).validate(metadata)
            XCTAssertTrue(result.errors.filter { $0.field == "IPTC:ObjectCycle" }.isEmpty,
                          "ObjectCycle '\(cycle)' should be valid")
        }
    }

    func testInvalidObjectCycle() {
        var metadata = ImageMetadata.empty()
        try? metadata.iptc.setValue("x", for: .objectCycle)
        let result = MetadataValidator(enforceFormats: true).validate(metadata)
        XCTAssertTrue(result.errors.contains { $0.field == "IPTC:ObjectCycle" })
    }

    // MARK: - Custom Validator

    func testCustomValidator() {
        let validator = MetadataValidator(
            requiredFields: ["IPTC:Headline", "IPTC:By-line"],
            minimumKeywords: 5
        )

        var metadata = ImageMetadata.empty()
        metadata.iptc.headline = "Test"
        metadata.iptc.byline = "Tester"
        metadata.iptc.keywords = ["a", "b", "c"]

        let result = validator.validate(metadata)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.field == "IPTC:Keywords" && $0.message.contains("5") })
    }

    // MARK: - ValidationResult

    func testValidationResultCounts() {
        let result = ValidationResult(issues: [
            ValidationIssue(field: "F1", message: "missing", severity: .error),
            ValidationIssue(field: "F2", message: "missing", severity: .error),
            ValidationIssue(field: "F3", message: "recommended", severity: .warning),
        ])

        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors.count, 2)
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testValidationResultNoErrorsIsValid() {
        let result = ValidationResult(issues: [
            ValidationIssue(field: "F1", message: "recommended", severity: .warning),
        ])

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.errors.count, 0)
        XCTAssertEqual(result.warnings.count, 1)
    }

    // MARK: - XMP Rights

    func testXMPUsageTerms() {
        var xmp = XMPData()
        XCTAssertNil(xmp.usageTerms)

        xmp.usageTerms = "For editorial use only"
        XCTAssertEqual(xmp.usageTerms, "For editorial use only")

        xmp.usageTerms = nil
        XCTAssertNil(xmp.usageTerms)
    }

    func testXMPWebStatement() {
        var xmp = XMPData()
        XCTAssertNil(xmp.webStatement)

        xmp.webStatement = "https://example.com/license"
        XCTAssertEqual(xmp.webStatement, "https://example.com/license")

        xmp.webStatement = nil
        XCTAssertNil(xmp.webStatement)
    }

    // MARK: - IPTCData New Convenience Properties

    func testBylineTitle() {
        var iptc = IPTCData()
        XCTAssertNil(iptc.bylineTitle)

        iptc.bylineTitle = "Chief Photographer"
        XCTAssertEqual(iptc.bylineTitle, "Chief Photographer")

        iptc.bylineTitles = ["Photographer", "Editor"]
        XCTAssertEqual(iptc.bylineTitles, ["Photographer", "Editor"])
    }

    func testUrgencyProperty() {
        var iptc = IPTCData()
        XCTAssertNil(iptc.urgency)

        iptc.urgency = 3
        XCTAssertEqual(iptc.urgency, 3)
        XCTAssertEqual(iptc.value(for: .urgency), "3")

        iptc.urgency = nil
        XCTAssertNil(iptc.urgency)
    }

    func testCategoryAndSupplemental() {
        var iptc = IPTCData()
        iptc.category = "SPO"
        XCTAssertEqual(iptc.category, "SPO")

        iptc.supplementalCategories = ["Football", "Premier League"]
        XCTAssertEqual(iptc.supplementalCategories, ["Football", "Premier League"])
    }

    func testContacts() {
        var iptc = IPTCData()
        iptc.contacts = ["photo@agency.com", "+47 123 456"]
        XCTAssertEqual(iptc.contacts, ["photo@agency.com", "+47 123 456"])
    }

    func testEditStatus() {
        var iptc = IPTCData()
        iptc.editStatus = "Updated"
        XCTAssertEqual(iptc.editStatus, "Updated")
    }

    func testLanguageIdentifier() {
        var iptc = IPTCData()
        iptc.languageIdentifier = "nor"
        XCTAssertEqual(iptc.languageIdentifier, "nor")
    }

    func testReleaseDateAndTime() {
        var iptc = IPTCData()
        iptc.releaseDate = "20260415"
        iptc.releaseTime = "120000+0200"
        XCTAssertEqual(iptc.releaseDate, "20260415")
        XCTAssertEqual(iptc.releaseTime, "120000+0200")
    }

    func testExpirationDateAndTime() {
        var iptc = IPTCData()
        iptc.expirationDate = "20260430"
        iptc.expirationTime = "235959+0000"
        XCTAssertEqual(iptc.expirationDate, "20260430")
        XCTAssertEqual(iptc.expirationTime, "235959+0000")
    }

    // MARK: - Minimum Rating (Phase A3)

    private func makeSubmissionReady() -> ImageMetadata {
        var m = ImageMetadata.empty()
        m.iptc.headline = "Breaking News"
        m.iptc.caption = "A major event occurred today."
        m.iptc.byline = "John Doe"
        m.iptc.credit = "AP"
        return m
    }

    func testQualityReviewRejectsBelowThreshold() {
        var metadata = makeSubmissionReady()
        var xmp = XMPData()
        xmp.rating = 2
        metadata.xmp = xmp

        let result = MetadataValidator.qualityReview.validate(metadata)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.field == "XMP-xmp:Rating" })
    }

    func testQualityReviewAcceptsAboveThreshold() {
        var metadata = makeSubmissionReady()
        var xmp = XMPData()
        xmp.rating = 4
        metadata.xmp = xmp

        let result = MetadataValidator.qualityReview.validate(metadata)
        XCTAssertTrue(result.isValid, "got issues: \(result.issues)")
    }

    func testQualityReviewRejectsWhenRatingMissing() {
        let metadata = makeSubmissionReady()
        let result = MetadataValidator.qualityReview.validate(metadata)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.field == "XMP-xmp:Rating" })
    }

    func testMinimumRatingNilProfileIgnoresRating() {
        // newsWire has no minimumRating — a zero-star photo should not error on rating.
        var metadata = makeSubmissionReady()
        metadata.iptc.city = "Oslo"
        metadata.iptc.countryName = "Norway"
        metadata.iptc.dateCreated = "20260415"
        metadata.iptc.copyright = "2026 AP"
        metadata.iptc.keywords = ["news"]

        let result = MetadataValidator.newsWire.validate(metadata)
        XCTAssertFalse(result.errors.contains { $0.field == "XMP-xmp:Rating" })
    }
}
