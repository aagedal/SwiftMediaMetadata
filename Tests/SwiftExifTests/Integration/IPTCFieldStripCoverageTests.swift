import XCTest
@testable import SwiftExif

/// Exhaustive coverage for "Remove All IPTC Metadata": populate every IPTC
/// descriptive field the app writes (plus the XMP mirror the app keeps in sync),
/// then strip IPTC+XMP exactly the way the app does — `iptc = IPTCData()` and
/// `xmp = nil` — and assert nothing survives in either block.
final class IPTCFieldStripCoverageTests: XCTestCase {

    func testStripRemovesEveryIPTCFieldTheAppUses() throws {
        let jpegFile = try JPEGParser.parse(TestFixtures.minimalJPEG())
        var metadata = ImageMetadata(container: .jpeg(jpegFile), format: .jpeg)

        // ── Populate the full IPTC descriptive surface ──────────────────────
        var iptc = IPTCData()
        iptc.headline = "Headline"
        iptc.caption = "A caption / description"
        iptc.bylines = ["Truls Aagedal", "Second Author"]
        iptc.keywords = ["keyword", "another keyword", "snøskred"]
        iptc.city = "Tromsø"
        iptc.sublocation = "Storgata"
        iptc.provinceState = "Troms"
        iptc.countryName = "Norge"
        iptc.countryCode = "NOR"
        iptc.credit = "TV 2"
        iptc.source = "NTB"
        iptc.copyright = "© Truls Aagedal / TV 2"
        iptc.dateCreated = "20260319"
        iptc.timeCreated = "101647+0100"
        iptc.specialInstructions = "Kreditering påkrevet"
        iptc.objectName = "Title / object name"
        iptc.writerEditor = "Desk Editor"
        iptc.jobId = "2026-06-23_TRA_001"
        iptc.originatingProgram = "Aagedal Photo Agent"
        iptc.programVersion = "2.0"
        iptc.bylineTitles = ["Photographer"]
        iptc.urgency = 5
        iptc.category = "NEW"
        iptc.supplementalCategories = ["Sports", "Politics"]
        iptc.contacts = ["test@example.com"]
        iptc.editStatus = "Final"
        iptc.languageIdentifier = "nb"
        iptc.releaseDate = "20260320"
        iptc.releaseTime = "000000+0100"
        iptc.expirationDate = "20270320"
        iptc.expirationTime = "235959+0100"
        metadata.iptc = iptc

        // ── Populate the XMP mirror the app keeps alongside IPTC ────────────
        var xmp = XMPData()
        xmp.title = "Title / object name"
        xmp.description = "A caption / description"
        xmp.extendedDescription = "Extended description"
        xmp.creator = ["Truls Aagedal"]
        xmp.subject = ["keyword", "another keyword", "snøskred"]
        xmp.rights = "© Truls Aagedal / TV 2"
        xmp.headline = "Headline"
        xmp.city = "Tromsø"
        xmp.state = "Troms"
        xmp.country = "Norge"
        xmp.credit = "TV 2"
        xmp.source = "NTB"
        xmp.jobId = "2026-06-23_TRA_001"
        xmp.rating = 4
        xmp.label = "Red"
        xmp.createDate = "2026-03-19T10:16:47+01:00"
        xmp.personInImage = ["Person A", "Person B"]
        xmp.digitalSourceType = "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture"
        xmp.event = "Spellemannprisen"
        metadata.xmp = xmp

        // Sanity: everything is really embedded before the strip.
        let populated = try metadata.writeToData()
        let beforeIPTC = try ImageMetadata.read(from: populated).iptc
        XCTAssertFalse(beforeIPTC.datasets.isEmpty, "fixture should embed IPTC datasets")
        XCTAssertEqual(beforeIPTC.headline, "Headline")
        XCTAssertEqual(beforeIPTC.keywords, ["keyword", "another keyword", "snøskred"])
        XCTAssertTrue(try JPEGParser.parse(populated).segments.contains { $0.isXMP })

        // ── Strip exactly like BrowserViewModel → writeEngine.stripIPTCAndXMP ─
        var stripped = try ImageMetadata.read(from: populated)
        stripped.iptc = IPTCData()
        stripped.xmp = nil
        let cleaned = try stripped.writeToData()

        // ── Assert: no IPTC dataset and no XMP packet survive ───────────────
        let afterIPTC = try ImageMetadata.read(from: cleaned).iptc
        XCTAssertTrue(afterIPTC.datasets.isEmpty,
                      "every IPTC dataset should be gone, found: \(afterIPTC.datasets.map(\.tag))")
        XCTAssertFalse(try JPEGParser.parse(cleaned).segments.contains { $0.isXMP },
                       "XMP segment should be removed")

        // Defense in depth: every individual field the app uses reads empty.
        XCTAssertNil(afterIPTC.headline)
        XCTAssertNil(afterIPTC.caption)
        XCTAssertNil(afterIPTC.byline)
        XCTAssertEqual(afterIPTC.bylines, [])
        XCTAssertEqual(afterIPTC.keywords, [])
        XCTAssertNil(afterIPTC.city)
        XCTAssertNil(afterIPTC.sublocation)
        XCTAssertNil(afterIPTC.provinceState)
        XCTAssertNil(afterIPTC.countryName)
        XCTAssertNil(afterIPTC.countryCode)
        XCTAssertNil(afterIPTC.credit)
        XCTAssertNil(afterIPTC.source)
        XCTAssertNil(afterIPTC.copyright)
        XCTAssertNil(afterIPTC.dateCreated)
        XCTAssertNil(afterIPTC.timeCreated)
        XCTAssertNil(afterIPTC.specialInstructions)
        XCTAssertNil(afterIPTC.objectName)
        XCTAssertNil(afterIPTC.writerEditor)
        XCTAssertNil(afterIPTC.jobId)
        XCTAssertNil(afterIPTC.originatingProgram)
        XCTAssertNil(afterIPTC.programVersion)
        XCTAssertNil(afterIPTC.bylineTitle)
        XCTAssertNil(afterIPTC.urgency)
        XCTAssertNil(afterIPTC.category)
        XCTAssertEqual(afterIPTC.supplementalCategories, [])
        XCTAssertEqual(afterIPTC.contacts, [])
        XCTAssertNil(afterIPTC.editStatus)
        XCTAssertNil(afterIPTC.languageIdentifier)
        XCTAssertNil(afterIPTC.releaseDate)
        XCTAssertNil(afterIPTC.releaseTime)
        XCTAssertNil(afterIPTC.expirationDate)
        XCTAssertNil(afterIPTC.expirationTime)

        let afterXMP = try ImageMetadata.read(from: cleaned).xmp
        XCTAssertNil(afterXMP?.headline)
        XCTAssertNil(afterXMP?.title)
        XCTAssertNil(afterXMP?.description)
        XCTAssertEqual(afterXMP?.subject ?? [], [])
        XCTAssertEqual(afterXMP?.creator ?? [], [])
        XCTAssertEqual(afterXMP?.personInImage ?? [], [])
    }
}
