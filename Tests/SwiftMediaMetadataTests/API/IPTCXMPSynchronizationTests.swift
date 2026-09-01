import XCTest
@testable import SwiftMediaMetadata

final class IPTCXMPSynchronizationTests: XCTestCase {
    func testDefaultSyncPreservesLocalizedDCTitle() throws {
        var metadata = ImageMetadata()
        try metadata.iptc.setValue("Legacy object name", for: .objectName)
        metadata.xmp = XMPData()
        let titles = [
            XMPLanguageAlternative(language: "x-default", value: "Default title"),
            XMPLanguageAlternative(language: "nb-NO", value: "Norsk tittel"),
        ]
        metadata.xmp?.setValue(
            .languageAlternative(titles),
            namespace: XMPNamespace.dc,
            property: "title"
        )

        let report = metadata.synchronizeIPTCToXMP()

        XCTAssertEqual(
            metadata.xmp?.languageAlternativeValue(namespace: XMPNamespace.dc, property: "title"),
            titles
        )
        XCTAssertFalse(report.updatedProperties.contains(XMPNamespace.dc + "title"))
    }

    func testExplicitClearRemovesStaleMirroredXMP() {
        var metadata = ImageMetadata()
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Stale headline"

        let report = metadata.synchronizeIPTCToXMP(options: .init(
            explicitlyClearedTags: [.headline]
        ))

        XCTAssertNil(metadata.xmp?.headline)
        XCTAssertEqual(report.removedProperties, [XMPNamespace.photoshop + "Headline"])
    }

    func testReplaceRemovesMappedXMPMissingFromIIM() {
        var metadata = ImageMetadata()
        metadata.xmp = XMPData()
        metadata.xmp?.city = "Oslo"

        let report = metadata.synchronizeIPTCToXMP(options: .replace)

        XCTAssertNil(metadata.xmp?.city)
        XCTAssertTrue(report.removedProperties.contains(XMPNamespace.photoshop + "City"))
    }

    func testPhotoshopEditorialRolePropertiesRemainScalar() throws {
        var metadata = ImageMetadata()
        try metadata.iptc.setValues(["Reporter", "Ignored legacy repeat"], for: .bylineTitle)
        try metadata.iptc.setValues(["Editor", "Ignored legacy repeat"], for: .writerEditor)

        metadata.synchronizeIPTCToXMP()

        XCTAssertEqual(
            metadata.xmp?.value(namespace: XMPNamespace.photoshop, property: "AuthorsPosition"),
            .simple("Reporter")
        )
        XCTAssertEqual(
            metadata.xmp?.value(namespace: XMPNamespace.photoshop, property: "CaptionWriter"),
            .simple("Editor")
        )
    }

    func testDateCreatedPreservesExistingISO8601PrecisionAndReportsConflict() throws {
        var metadata = ImageMetadata()
        try metadata.iptc.setValue("20260821", for: .dateCreated)
        try metadata.iptc.setValue("101530+0230", for: .timeCreated)
        metadata.xmp = XMPData()
        let precise = "2026-08-21T10:15:30.120+02:30"
        metadata.xmp?.setValue(
            .simple(precise),
            namespace: XMPNamespace.photoshop,
            property: "DateCreated"
        )

        let report = metadata.synchronizeIPTCToXMP()

        XCTAssertEqual(
            metadata.xmp?.simpleValue(namespace: XMPNamespace.photoshop, property: "DateCreated"),
            precise
        )
        XCTAssertEqual(report.conflicts.map(\.iptcTag), [.dateCreated])
    }

    func testDateCreatedCanExplicitlyMirrorIIM() throws {
        var metadata = ImageMetadata()
        try metadata.iptc.setValue("20260821", for: .dateCreated)
        try metadata.iptc.setValue("101530+0230", for: .timeCreated)
        metadata.xmp = XMPData()
        metadata.xmp?.setValue(
            .simple("2026-08-21T10:15:30.120+02:30"),
            namespace: XMPNamespace.photoshop,
            property: "DateCreated"
        )

        metadata.synchronizeIPTCToXMP(options: .init(dateCreatedPolicy: .mirrorIIM))

        XCTAssertEqual(
            metadata.xmp?.simpleValue(namespace: XMPNamespace.photoshop, property: "DateCreated"),
            "2026-08-21T10:15:30+02:30"
        )
    }

    func testConflictReportCapturesBothCarrierValuesBeforeMerge() throws {
        var metadata = ImageMetadata()
        try metadata.iptc.setValue("IIM headline", for: .headline)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "XMP headline"

        let report = metadata.synchronizeIPTCToXMP()

        XCTAssertEqual(metadata.xmp?.headline, "IIM headline")
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertEqual(report.conflicts[0].iptcValues, ["IIM headline"])
        XCTAssertEqual(report.conflicts[0].xmpValue, .simple("XMP headline"))
    }

    func testReverseSyncConvertsISO8601DateToIIMDateAndTime() throws {
        var metadata = ImageMetadata()
        metadata.xmp = XMPData()
        metadata.xmp?.setValue(
            .simple("2026-08-21T10:15:30.120+02:30"),
            namespace: XMPNamespace.photoshop,
            property: "DateCreated"
        )

        try metadata.synchronizeXMPToIPTC()

        XCTAssertEqual(metadata.iptc.value(for: .dateCreated), "20260821")
        XCTAssertEqual(metadata.iptc.value(for: .timeCreated), "101530+0230")
    }
}
