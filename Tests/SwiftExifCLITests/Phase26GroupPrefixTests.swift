#if os(macOS)
import Foundation
import XCTest
@testable import swift_exif

// MARK: - Phase 26 — `-G` group prefixing

final class Phase26GroupPrefixTests: XCTestCase {

    func testBareEXIFKeysPrefixedWithEXIF() {
        let dict: [String: String] = ["Make": "Canon", "Model": "EOS 5D", "ISO": "400"]
        let out = applyGroupPrefix(to: dict, defaultGroup: "EXIF")
        XCTAssertEqual(out["EXIF:Make"], "Canon")
        XCTAssertEqual(out["EXIF:Model"], "EOS 5D")
        XCTAssertEqual(out["EXIF:ISO"], "400")
        XCTAssertNil(out["Make"])
    }

    func testFileSystemKeysRouteToFileGroup() {
        let dict: [String: String] = [
            "FileFormat": "JPEG",
            "FileName": "DSC_0001.jpg",
            "ImageWidth": "6000",
        ]
        let out = applyGroupPrefix(to: dict, defaultGroup: "EXIF")
        XCTAssertEqual(out["File:FileFormat"], "JPEG")
        XCTAssertEqual(out["File:FileName"], "DSC_0001.jpg")
        XCTAssertEqual(out["File:ImageWidth"], "6000")
    }

    func testAlreadyPrefixedKeysLeftAlone() {
        let dict: [String: String] = [
            "IPTC:Headline": "Wire photo",
            "Composite:Aperture": "5.6",
            "ICCProfile:ColorSpace": "RGB",
            "MakerNote:LensType": "EF 50mm",
        ]
        let out = applyGroupPrefix(to: dict, defaultGroup: "EXIF")
        XCTAssertEqual(out["IPTC:Headline"], "Wire photo")
        XCTAssertEqual(out["Composite:Aperture"], "5.6")
        XCTAssertEqual(out["ICCProfile:ColorSpace"], "RGB")
        XCTAssertEqual(out["MakerNote:LensType"], "EF 50mm")
        // No double-prefixing.
        XCTAssertNil(out["EXIF:IPTC:Headline"])
    }

    func testXMPKeysWithHyphenPrefixLeftAlone() {
        let dict: [String: String] = [
            "XMP-dc:title": "Test",
            "XMP-photoshop:DateCreated": "2024:03:15",
        ]
        let out = applyGroupPrefix(to: dict, defaultGroup: "EXIF")
        XCTAssertEqual(out["XMP-dc:title"], "Test")
        XCTAssertEqual(out["XMP-photoshop:DateCreated"], "2024:03:15")
        XCTAssertNil(out["EXIF:XMP-dc:title"])
    }

    func testDefaultGroupIsConfigurable() {
        let dict: [String: String] = ["Title": "Song", "Artist": "Band", "Bitrate": "320"]
        let out = applyGroupPrefix(to: dict, defaultGroup: "Audio")
        XCTAssertEqual(out["Audio:Title"], "Song")
        XCTAssertEqual(out["Audio:Artist"], "Band")
        XCTAssertEqual(out["Audio:Bitrate"], "320")
    }

    func testPreservesAnyValueType() {
        let dict: [String: Any] = [
            "Make": "Canon",
            "PixelXDimension": 6000,
            "GPSLatitude": 47.123,
            "Keywords": ["news", "photojournalism"],
        ]
        let out = applyGroupPrefix(to: dict, defaultGroup: "EXIF")
        XCTAssertEqual(out["EXIF:Make"] as? String, "Canon")
        XCTAssertEqual(out["EXIF:PixelXDimension"] as? Int, 6000)
        XCTAssertEqual(out["EXIF:GPSLatitude"] as? Double, 47.123)
        XCTAssertEqual(out["EXIF:Keywords"] as? [String], ["news", "photojournalism"])
    }
}
#endif
