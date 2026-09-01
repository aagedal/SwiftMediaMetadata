import XCTest
@testable import SwiftMediaMetadata

final class XMPLosslessMutationTests: XCTestCase {
    func testCreatorContactSetterPreservesUnknownFieldsAndClearsKnownFields() {
        let unknownKey = "https://example.com/contact/PreferredChannel"
        let cityKey = XMPNamespace.iptcCore + "CiAdrCity"
        var xmp = XMPData()
        xmp.setValue(
            .structure([
                cityKey: .simple("Old city"),
                unknownKey: .array(["email", "phone"]),
            ]),
            namespace: XMPNamespace.iptcCore,
            property: "CreatorContactInfo"
        )

        xmp.creatorContactInfo = IPTCCreatorContactInfo(emailWork: "desk@example.com")

        let fields = xmp.structureValue(
            namespace: XMPNamespace.iptcCore,
            property: "CreatorContactInfo"
        )
        XCTAssertNil(fields?[cityKey])
        XCTAssertEqual(fields?[unknownKey], .array(["email", "phone"]))
        XCTAssertEqual(fields?[XMPNamespace.iptcCore + "CiEmailWork"], .simple("desk@example.com"))
    }

    func testLocationSetterPreservesUnknownSiblingFieldsByItem() {
        let unknownKey = "https://example.com/location/VenueCode"
        var xmp = XMPData()
        xmp.setValue(
            .structuredArray([[
                XMPNamespace.iptcExt + "City": .simple("Old city"),
                unknownKey: .simple("NO-OSL-001"),
            ]]),
            namespace: XMPNamespace.iptcExt,
            property: "LocationShown"
        )

        xmp.locationShown = [IPTCLocation(city: "Oslo", countryCode: "NOR")]

        let item = xmp.structuredArrayValue(
            namespace: XMPNamespace.iptcExt,
            property: "LocationShown"
        )?.first
        XCTAssertEqual(item?[unknownKey], .simple("NO-OSL-001"))
        XCTAssertEqual(item?[XMPNamespace.iptcExt + "City"], .simple("Oslo"))
        XCTAssertEqual(item?[XMPNamespace.iptcExt + "CountryCode"], .simple("NOR"))
    }

    func testPLUSImageSupplierSetterPreservesUnknownFieldsAndWritesSequence() {
        let unknownKey = "https://example.com/plus/AccountTier"
        var xmp = XMPData()
        xmp.setValue(
            .structuredArray([[
                XMPNamespace.plus + "ImageSupplierName": .simple("Old agency"),
                unknownKey: .simple("wire"),
            ]]),
            namespace: XMPNamespace.plus,
            property: "ImageSupplier"
        )

        xmp.imageSupplier = [IPTCImageSupplier(
            imageSupplierID: "agency-1",
            imageSupplierName: "News Agency"
        )]

        let item = xmp.structuredArrayValue(
            namespace: XMPNamespace.plus,
            property: "ImageSupplier"
        )?.first
        XCTAssertEqual(item?[unknownKey], .simple("wire"))
        XCTAssertTrue(XMPWriter.generateXML(xmp).contains("<rdf:Seq>"))
    }

    func testGenericStructuredArrayPatchRetainsUnmentionedCVTermMembers() {
        let namespace = XMPNamespace.iptcExt
        let property = "Genre"
        let idKey = namespace + "CvId"
        let labelKey = namespace + "CvTermName"
        let futureKey = "https://example.com/cv/FutureQualifier"
        var xmp = XMPData()
        xmp.setValue(
            .structuredArray([[
                idKey: .simple("old-id"),
                labelKey: .langAlternative("Old label"),
                futureKey: .structure(["https://example.com/cv/value": .simple("retained")]),
            ]]),
            namespace: namespace,
            property: property
        )

        XCTAssertTrue(xmp.patchStructuredArrayItem(
            namespace: namespace,
            property: property,
            at: 0,
            with: XMPStructurePatch(
                values: [idKey: .simple("new-id")],
                removedKeys: [labelKey]
            )
        ))

        let item = xmp.structuredArrayValue(namespace: namespace, property: property)?.first
        XCTAssertEqual(item?[idKey], .simple("new-id"))
        XCTAssertNil(item?[labelKey])
        XCTAssertEqual(
            item?[futureKey],
            .structure(["https://example.com/cv/value": .simple("retained")])
        )
    }
}
