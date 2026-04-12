import XCTest
@testable import SwiftExif

final class JXLWriterTests: XCTestCase {

    func testRoundTripPreservesBoxes() throws {
        let original = TestFixtures.minimalJXL(boxes: [
            (type: "jxlc", data: Data([0x01, 0x02, 0x03])),
        ])
        let file = try JXLParser.parse(original)
        let written = try JXLWriter.write(file)
        let reparsed = try JXLParser.parse(written)

        XCTAssertEqual(file.boxes.count, reparsed.boxes.count)
        for (a, b) in zip(file.boxes, reparsed.boxes) {
            XCTAssertEqual(a.type, b.type)
            XCTAssertEqual(a.data, b.data)
        }
    }

    func testExifRoundTrip() throws {
        let original = TestFixtures.jxlWithExif(make: "JXL Cam", model: "JXL-1")
        var metadata = try ImageMetadata.read(from: original)

        XCTAssertEqual(metadata.exif?.make, "JXL Cam")

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.exif?.make, "JXL Cam")
        XCTAssertEqual(reparsed.exif?.model, "JXL-1")
    }

    func testXMPRoundTrip() throws {
        let original = TestFixtures.minimalJXL()
        var metadata = try ImageMetadata.read(from: original)

        metadata.xmp = XMPData()
        metadata.xmp?.headline = "JXL Headline"
        metadata.xmp?.city = "Oslo"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.xmp?.headline, "JXL Headline")
        XCTAssertEqual(reparsed.xmp?.city, "Oslo")
    }

    func testBareCodestreamThrows() throws {
        let bare = TestFixtures.bareJXLCodestream()
        let metadata = try ImageMetadata.read(from: bare)

        XCTAssertThrowsError(try metadata.writeToData()) { error in
            guard let metaError = error as? MetadataError,
                  case .writeNotSupported = metaError else {
                XCTFail("Expected writeNotSupported error, got: \(error)")
                return
            }
        }
    }

    func testAddExifToEmpty() throws {
        let original = TestFixtures.minimalJXL()
        var metadata = try ImageMetadata.read(from: original)
        XCTAssertNil(metadata.exif)

        metadata.exif = ExifData(byteOrder: .bigEndian)
        metadata.exif?.ifd0 = IFD(entries: [
            IFDEntry(tag: ExifTag.make, type: .ascii, count: 7, valueData: Data("NewCam\0".utf8)),
        ])

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)
        XCTAssertEqual(reparsed.exif?.make, "NewCam")
    }

    func testCodestreamPreserved() throws {
        let codestream = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let original = TestFixtures.minimalJXL(boxes: [(type: "jxlc", data: codestream)])
        var metadata = try ImageMetadata.read(from: original)

        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Added"

        let written = try metadata.writeToData()
        let reparsed = try JXLParser.parse(written)
        let jxlcBox = reparsed.findBox("jxlc")

        XCTAssertEqual(jxlcBox?.data, codestream, "Codestream data must be preserved")
    }
}
