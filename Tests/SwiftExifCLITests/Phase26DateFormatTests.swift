#if os(macOS)
import Foundation
import XCTest
@testable import swift_exif

// MARK: - Phase 26.4 — `-d` global date format

final class Phase26DateFormatTests: XCTestCase {

    func testReformatExifFormatToISO() {
        let out = reformatDateString("2024:03:15 12:30:45", pattern: "%Y-%m-%dT%H:%M:%S")
        XCTAssertEqual(out, "2024-03-15T12:30:45")
    }

    func testReformatISOToExifFormat() {
        let out = reformatDateString("2024-03-15T12:30:45Z", pattern: "%Y:%m:%d %H:%M:%S")
        XCTAssertEqual(out, "2024:03:15 12:30:45")
    }

    func testReformatExifFormatWithFShortcut() {
        let out = reformatDateString("2024:03:15 12:30:45", pattern: "%F %T")
        XCTAssertEqual(out, "2024-03-15 12:30:45")
    }

    func testReformatPreservesUnparsableInputs() {
        let out = reformatDateString("Not a date", pattern: "%Y-%m-%d")
        XCTAssertEqual(out, "Not a date")
    }

    func testReformatHandlesIPTCDateOnly() {
        let out = reformatDateString("20240315", pattern: "%Y/%m/%d")
        XCTAssertEqual(out, "2024/03/15")
    }

    func testReformatLiteralPercentEscape() {
        let out = reformatDateString("2024:03:15 12:30:45", pattern: "%Y%%")
        XCTAssertEqual(out, "2024%")
    }

    func testReformatMonthNameDirectives() {
        let out = reformatDateString("2024:03:15 12:30:45", pattern: "%b %d, %Y")
        XCTAssertEqual(out, "Mar 15, 2024")
    }

    func testIsDateTagKeyMatchesCommonDateTags() {
        XCTAssertTrue(isDateTagKey("EXIF:DateTimeOriginal"))
        XCTAssertTrue(isDateTagKey("XMP-photoshop:DateCreated"))
        XCTAssertTrue(isDateTagKey("File:FileModifyDate"))
        XCTAssertTrue(isDateTagKey("GPSDateTime"))
        XCTAssertFalse(isDateTagKey("EXIF:Make"))
        XCTAssertFalse(isDateTagKey("FileSize"))
    }

    func testApplyDateFormatTransformsOnlyDateKeys() {
        var dict: [String: String] = [
            "EXIF:DateTimeOriginal": "2024:03:15 12:30:45",
            "EXIF:Make": "Canon",
            "FileName": "DSC_0001.jpg",
            "GPSDateTime": "2024:03:15 12:30:45",
        ]
        applyDateFormat(to: &dict, pattern: "%F")
        XCTAssertEqual(dict["EXIF:DateTimeOriginal"], "2024-03-15")
        XCTAssertEqual(dict["GPSDateTime"], "2024-03-15")
        XCTAssertEqual(dict["EXIF:Make"], "Canon")
        XCTAssertEqual(dict["FileName"], "DSC_0001.jpg")
    }

    func testApplyDateFormatNoOpWithoutPattern() {
        var dict: [String: String] = ["EXIF:DateTimeOriginal": "2024:03:15 12:30:45"]
        applyDateFormat(to: &dict, pattern: nil)
        XCTAssertEqual(dict["EXIF:DateTimeOriginal"], "2024:03:15 12:30:45")
    }
}
#endif
