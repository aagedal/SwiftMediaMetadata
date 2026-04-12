import XCTest
@testable import SwiftExif

final class IPTCTagTests: XCTestCase {

    func testTagRecordAndDataSet() {
        XCTAssertEqual(IPTCTag.headline.record, 2)
        XCTAssertEqual(IPTCTag.headline.dataSet, 105)
        XCTAssertEqual(IPTCTag.keywords.record, 2)
        XCTAssertEqual(IPTCTag.keywords.dataSet, 25)
        XCTAssertEqual(IPTCTag.codedCharacterSet.record, 1)
        XCTAssertEqual(IPTCTag.codedCharacterSet.dataSet, 90)
    }

    func testAllJournalismFieldsHaveMetadata() {
        let journalismTags: [IPTCTag] = [
            .objectName, .keywords, .specialInstructions, .dateCreated, .timeCreated,
            .byline, .bylineTitle, .city, .sublocation, .provinceState,
            .countryPrimaryLocationCode, .countryPrimaryLocationName,
            .headline, .credit, .source, .copyrightNotice, .captionAbstract,
            .writerEditor, .originatingProgram, .programVersion,
        ]

        for tag in journalismTags {
            XCTAssertNotEqual(tag.name, "Unknown(\(tag.record):\(tag.dataSet))", "Tag \(tag) missing metadata")
            XCTAssertNotNil(tag.maxLength, "Tag \(tag) missing maxLength")
        }
    }

    func testRepeatableTags() {
        XCTAssertTrue(IPTCTag.keywords.isRepeatable)
        XCTAssertTrue(IPTCTag.byline.isRepeatable)
        XCTAssertTrue(IPTCTag.bylineTitle.isRepeatable)
        XCTAssertTrue(IPTCTag.supplementalCategories.isRepeatable)
        XCTAssertTrue(IPTCTag.contact.isRepeatable)
        XCTAssertTrue(IPTCTag.writerEditor.isRepeatable)

        XCTAssertFalse(IPTCTag.headline.isRepeatable)
        XCTAssertFalse(IPTCTag.captionAbstract.isRepeatable)
        XCTAssertFalse(IPTCTag.city.isRepeatable)
    }

    func testMaxLengths() {
        XCTAssertEqual(IPTCTag.keywords.maxLength, 64)
        XCTAssertEqual(IPTCTag.headline.maxLength, 256)
        XCTAssertEqual(IPTCTag.captionAbstract.maxLength, 2000)
        XCTAssertEqual(IPTCTag.byline.maxLength, 32)
        XCTAssertEqual(IPTCTag.city.maxLength, 32)
        XCTAssertEqual(IPTCTag.countryPrimaryLocationCode.maxLength, 3)
        XCTAssertEqual(IPTCTag.copyrightNotice.maxLength, 128)
    }

    func testInitFromNotation() {
        let tag = IPTCTag("2:25")
        XCTAssertNotNil(tag)
        XCTAssertEqual(tag?.record, 2)
        XCTAssertEqual(tag?.dataSet, 25)
        XCTAssertEqual(tag, IPTCTag.keywords)
    }

    func testInitFromNotationInvalid() {
        XCTAssertNil(IPTCTag("invalid"))
        XCTAssertNil(IPTCTag("2"))
        XCTAssertNil(IPTCTag(""))
        XCTAssertNil(IPTCTag("abc:def"))
    }

    func testDescription() {
        let desc = IPTCTag.headline.description
        XCTAssertTrue(desc.contains("Headline"))
        XCTAssertTrue(desc.contains("2:"))
    }

    func testComparable() {
        XCTAssertTrue(IPTCTag.codedCharacterSet < IPTCTag.objectName) // Record 1 < Record 2
        XCTAssertTrue(IPTCTag.objectName < IPTCTag.keywords) // Dataset 5 < 25
        XCTAssertTrue(IPTCTag.keywords < IPTCTag.headline) // Dataset 25 < 105
    }

    func testUnknownTag() {
        let tag = IPTCTag(record: 2, dataSet: 250)
        XCTAssertTrue(tag.name.contains("Unknown"))
        XCTAssertNil(tag.maxLength)
        XCTAssertFalse(tag.isRepeatable)
    }

    func testDataTypes() {
        XCTAssertEqual(IPTCTag.headline.dataType, .string)
        XCTAssertEqual(IPTCTag.dateCreated.dataType, .digits)
        XCTAssertEqual(IPTCTag.applicationRecordVersion.dataType, .int16u)
        XCTAssertEqual(IPTCTag.codedCharacterSet.dataType, .binary)
    }
}
