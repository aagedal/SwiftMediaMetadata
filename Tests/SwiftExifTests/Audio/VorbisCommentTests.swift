import XCTest
@testable import SwiftExif

final class VorbisCommentTests: XCTestCase {

    func testParseAndSerializeRoundTrip() throws {
        var vc = VorbisComment(vendor: "TestVendor")
        vc.setValue("Test Title", for: "TITLE")
        vc.setValue("Test Artist", for: "ARTIST")

        let serialized = vc.serialize()
        let reparsed = try VorbisComment.parse(serialized)

        XCTAssertEqual(reparsed.vendor, "TestVendor")
        XCTAssertEqual(reparsed.value(for: "TITLE"), "Test Title")
        XCTAssertEqual(reparsed.value(for: "ARTIST"), "Test Artist")
    }

    func testCaseInsensitiveLookup() {
        var vc = VorbisComment()
        vc.setValue("Test", for: "TITLE")
        XCTAssertEqual(vc.value(for: "title"), "Test")
        XCTAssertEqual(vc.value(for: "Title"), "Test")
        XCTAssertEqual(vc.value(for: "TITLE"), "Test")
    }

    func testRemoveValue() {
        var vc = VorbisComment()
        vc.setValue("Test", for: "TITLE")
        vc.removeValue(for: "title")
        XCTAssertNil(vc.value(for: "TITLE"))
    }

    func testSetValueReplaces() {
        var vc = VorbisComment()
        vc.setValue("Old", for: "TITLE")
        vc.setValue("New", for: "TITLE")
        XCTAssertEqual(vc.value(for: "TITLE"), "New")
        XCTAssertEqual(vc.comments.count, 1)
    }
}
