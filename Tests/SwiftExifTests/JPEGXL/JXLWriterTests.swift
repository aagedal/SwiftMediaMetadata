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

    func testBareCodestreamUnchangedWhenNoMetadata() throws {
        // Writing a bare codestream with nothing to embed is a no-op: the
        // bytes must come back byte-for-byte identical (no needless wrap).
        let bare = TestFixtures.bareJXLCodestream()
        let metadata = try ImageMetadata.read(from: bare)

        let written = try metadata.writeToData()
        XCTAssertEqual(written, bare)
    }

    func testBareCodestreamWrapsIntoContainerWhenAddingMetadata() throws {
        let bare = TestFixtures.bareJXLCodestream()
        var metadata = try ImageMetadata.read(from: bare)

        // Rotating a bare-codestream JXL: the codestream has no box to hold an
        // Exif orientation tag, so the writer wraps it into container format.
        metadata.setOrientation(6)
        let written = try metadata.writeToData()

        let reparsed = try JXLParser.parse(written)
        XCTAssertTrue(reparsed.isContainer, "Bare codestream must be wrapped into container format")
        XCTAssertEqual(reparsed.findBox("jxlc")?.data, bare, "Codestream must be copied verbatim")
        XCTAssertNotNil(reparsed.findBox("Exif"), "Orientation must be stored in an Exif box")

        let remeta = try ImageMetadata.read(from: written)
        XCTAssertEqual(remeta.exif?.orientation, 6)
    }

    func testBareCodestreamWrappedOnceNotPerWrite() throws {
        // Rotating a bare JXL twice must wrap exactly once: the first write
        // wraps bare→container, the second sees a container and replaces the
        // Exif box in place — no duplicate ftyp/jxlc/Exif, no nested wrap.
        let bare = TestFixtures.bareJXLCodestream()
        var first = try ImageMetadata.read(from: bare)
        first.setOrientation(6)
        let afterFirst = try first.writeToData()

        var second = try ImageMetadata.read(from: afterFirst)
        second.setOrientation(8)
        let afterSecond = try second.writeToData()

        let reparsed = try JXLParser.parse(afterSecond)
        XCTAssertEqual(reparsed.boxes.filter { $0.type == "ftyp" }.count, 1)
        XCTAssertEqual(reparsed.boxes.filter { $0.type == "jxlc" }.count, 1)
        XCTAssertEqual(reparsed.boxes.filter { $0.type == "Exif" }.count, 1)
        XCTAssertEqual(reparsed.findBox("jxlc")?.data, bare, "Codestream must stay verbatim across re-writes")
        XCTAssertEqual(try ImageMetadata.read(from: afterSecond).exif?.orientation, 8)
    }

    func testBareCodestreamWrapsForXMPMetadata() throws {
        // The wrap is not orientation-specific: any descriptive metadata write
        // (here XMP keywords/headline) on a bare codestream wraps the same way.
        let bare = TestFixtures.bareJXLCodestream()
        var metadata = try ImageMetadata.read(from: bare)

        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Bare Wrap"
        metadata.xmp?.city = "Oslo"
        let written = try metadata.writeToData()

        let reparsed = try JXLParser.parse(written)
        XCTAssertTrue(reparsed.isContainer, "Bare codestream must be wrapped into container format")
        XCTAssertEqual(reparsed.findBox("jxlc")?.data, bare, "Codestream must be copied verbatim")
        XCTAssertNotNil(reparsed.findBox("xml "), "XMP must be stored in an xml box")

        let remeta = try ImageMetadata.read(from: written)
        XCTAssertEqual(remeta.xmp?.headline, "Bare Wrap")
        XCTAssertEqual(remeta.xmp?.city, "Oslo")
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
