import XCTest
@testable import SwiftMediaMetadata

final class PhotoMetadataTests: XCTestCase {
    func testProjectionPrefersXMPAndRetainsIIMConflictCandidate() throws {
        var metadata = ImageMetadata()
        try metadata.iptc.setValue("IIM headline", for: .headline)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "XMP headline"

        let projected = metadata.photoMetadata

        XCTAssertEqual(projected.string(.headline), "XMP headline")
        XCTAssertEqual(projected[.headline]?.source, .xmp)
        XCTAssertEqual(projected[.headline]?.candidates.count, 2)
        XCTAssertEqual(projected[.headline]?.hasConflict, true)
        XCTAssertNotNil(projected.conflicts[.headline])
    }

    func testProjectionFallsBackToIIM() throws {
        var metadata = ImageMetadata()
        try metadata.iptc.setValues(["First", "Second"], for: .byline)

        let projected = metadata.photoMetadata

        XCTAssertEqual(projected.strings(.creators), ["First", "Second"])
        XCTAssertEqual(projected[.creators]?.source, .iptcIIM)
    }

    func testProjectionKeepsLosslessStructuredXMP() {
        let futureKey = "https://example.com/location/FutureField"
        let item: [String: XMPValue] = [
            XMPNamespace.iptcExt + "City": .simple("Oslo"),
            futureKey: .structure(["https://example.com/value": .simple("retained")]),
        ]
        var metadata = ImageMetadata()
        metadata.xmp = XMPData()
        metadata.xmp?.setValue(
            .structuredArray([item]),
            namespace: XMPNamespace.iptcExt,
            property: "LocationShown"
        )

        XCTAssertEqual(
            metadata.photoMetadata[.locationShown]?.value,
            .structuredArray([item])
        )
        XCTAssertEqual(
            metadata.photoMetadata.rawXMP?.structuredArrayValue(
                namespace: XMPNamespace.iptcExt,
                property: "LocationShown"
            ),
            [item]
        )
    }

    func testCanonicalMutationWritesIIMAndXMPAndPreservesPreciseDate() throws {
        var metadata = ImageMetadata()
        let preciseDate = "2026-08-21T10:15:30.120+02:30"

        let report = try metadata.applyPhotoMetadataMutation(.init(values: [
            .headline: .string("New headline"),
            .creators: .strings(["First", "Second"]),
            .dateCreated: .string(preciseDate),
        ]))

        XCTAssertEqual(metadata.iptc.headline, "New headline")
        XCTAssertEqual(metadata.iptc.bylines, ["First", "Second"])
        XCTAssertEqual(metadata.xmp?.headline, "New headline")
        XCTAssertEqual(
            metadata.xmp?.simpleValue(namespace: XMPNamespace.photoshop, property: "DateCreated"),
            preciseDate
        )
        XCTAssertEqual(metadata.iptc.dateCreated, "20260821")
        XCTAssertEqual(metadata.iptc.timeCreated, "101530+0230")
        XCTAssertTrue(report.unappliedFields.isEmpty)
    }

    func testCanonicalMutationCarriesLocalizedTitleWithoutTouchingObjectName() throws {
        var metadata = ImageMetadata()
        try metadata.iptc.setValue("Legacy object", for: .objectName)
        let titles = [
            XMPLanguageAlternative(language: "x-default", value: "Default"),
            XMPLanguageAlternative(language: "nb-NO", value: "Norsk"),
        ]

        try metadata.applyPhotoMetadataMutation(.init(values: [
            .title: .languageAlternatives(titles),
        ]))

        XCTAssertEqual(metadata.iptc.objectName, "Legacy object")
        XCTAssertEqual(
            metadata.xmp?.languageAlternativeValue(namespace: XMPNamespace.dc, property: "title"),
            titles
        )
    }

    func testCanonicalClearRemovesBothMirroredCarriers() throws {
        var metadata = ImageMetadata()
        try metadata.iptc.setValue("Old headline", for: .headline)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Old headline"

        try metadata.applyPhotoMetadataMutation(.init(clearedFields: [.headline]))

        XCTAssertNil(metadata.iptc.headline)
        XCTAssertNil(metadata.xmp?.headline)
    }
}
