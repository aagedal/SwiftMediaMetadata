import XCTest
@testable import SwiftExif

final class TIFFWriterTests: XCTestCase {

    func testExifPreserved() throws {
        let original = TestFixtures.tiffWithExif(make: "Nikon", model: "D850")
        var metadata = try ImageMetadata.read(from: original)

        XCTAssertEqual(metadata.exif?.make, "Nikon")
        XCTAssertEqual(metadata.exif?.model, "D850")

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.exif?.make, "Nikon")
        XCTAssertEqual(reparsed.exif?.model, "D850")
    }

    func testXMPRoundTrip() throws {
        let original = TestFixtures.minimalTIFF()
        var metadata = try ImageMetadata.read(from: original)

        metadata.xmp = XMPData()
        metadata.xmp?.headline = "TIFF Headline"
        metadata.xmp?.city = "Stavanger"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.xmp?.headline, "TIFF Headline")
        XCTAssertEqual(reparsed.xmp?.city, "Stavanger")
    }

    func testIPTCRoundTrip() throws {
        let original = TestFixtures.minimalTIFF()
        var metadata = try ImageMetadata.read(from: original)

        metadata.iptc.headline = "TIFF IPTC"
        metadata.iptc.keywords = ["test", "tiff"]
        metadata.iptc.city = "Tromsø"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.iptc.headline, "TIFF IPTC")
        XCTAssertEqual(reparsed.iptc.keywords, ["test", "tiff"])
        XCTAssertEqual(reparsed.iptc.city, "Tromsø")
    }

    func testXMPExistingPreserved() throws {
        let xmpXML = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
         <rdf:Description rdf:about=""
           photoshop:Headline="Existing"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let original = TestFixtures.tiffWithXMP(xml: xmpXML)
        var metadata = try ImageMetadata.read(from: original)

        XCTAssertEqual(metadata.xmp?.headline, "Existing")

        // Add IPTC and re-write
        metadata.iptc.headline = "New Headline"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.iptc.headline, "New Headline")
        // XMP should be overwritten with current value
        XCTAssertEqual(reparsed.xmp?.headline, "Existing")
    }

    func testByteOrderPreserved() throws {
        // Test with big-endian TIFF
        let original = TestFixtures.tiffWithExif(make: "Canon", model: "R5", byteOrder: .bigEndian)
        var metadata = try ImageMetadata.read(from: original)

        metadata.iptc.headline = "Big Endian"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.iptc.headline, "Big Endian")
        XCTAssertEqual(reparsed.exif?.make, "Canon")
    }

    /// Assigning a fresh `exif` (e.g. copied from another image) must write its
    /// IFD0 camera-identification tags into the destination TIFF, while leaving
    /// the destination's own structural tags (image dimensions) untouched.
    func testAssignedExifIFD0TagsAreWritten() throws {
        func u32le(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        // Destination starts with a structural tag and a stale Make.
        let original = TestFixtures.minimalTIFF(entries: [
            (tag: ExifTag.imageWidth, type: .long, count: 1, valueData: u32le(640)),
            (tag: ExifTag.make, type: .ascii, count: 4, valueData: Data("Old\0".utf8)),
        ])
        var metadata = try ImageMetadata.read(from: original)
        XCTAssertEqual(metadata.exif?.make, "Old")

        // Wholesale-assign a different camera's EXIF identification.
        metadata.exif = ExifData(byteOrder: .littleEndian)
        metadata.exif?.ifd0 = IFD(entries: [
            IFDEntry(tag: ExifTag.make, type: .ascii, count: 6, valueData: Data("Canon\0".utf8)),
            IFDEntry(tag: ExifTag.model, type: .ascii, count: 3, valueData: Data("R5\0".utf8)),
        ])

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.exif?.make, "Canon", "assigned Make must be written")
        XCTAssertEqual(reparsed.exif?.model, "R5", "assigned Model must be written")
        // Structural tag from the destination is preserved (not taken from exif).
        let width = reparsed.exif?.ifd0?.entry(for: ExifTag.imageWidth)
        XCTAssertNotNil(width, "destination structural ImageWidth must survive")
    }

    // MARK: - Raster relocation

    /// Build a little-endian raster TIFF whose IFD0 has StripOffsets /
    /// StripByteCounts / RowsPerStrip pointing at `strips` appended after the
    /// directory. Values ≤4 bytes are stored inline (per the TIFF rule), larger
    /// arrays (multi-strip) go out-of-line — mirroring a real strip-based TIFF.
    private func makeStripTIFF(width: Int, height: Int, rowsPerStrip: Int, strips: [Data]) -> Data {
        func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        let n = strips.count
        let ifdSize = 2 + 5 * 12 + 4
        // Out-of-line region holds the StripOffsets/StripByteCounts arrays only
        // when they exceed 4 bytes (n > 1); strips follow it.
        let arraysSize = n > 1 ? (n * 4) * 2 : 0
        let rasterStart = 8 + ifdSize + arraysSize
        var stripOffsets: [Int] = []
        var cur = rasterStart
        for s in strips { stripOffsets.append(cur); cur += s.count }
        let stripByteCounts = strips.map { UInt32($0.count) }

        let soArrayOffset = 8 + ifdSize
        let sbcArrayOffset = soArrayOffset + n * 4

        // (tag, type, count, valueField) — valueField is the inline 4 bytes or
        // the offset to the out-of-line array.
        let entries: [(UInt16, UInt16, UInt32, Data)] = [
            (0x0100, 3, 1, le16(UInt16(width)) + Data([0, 0])),
            (0x0101, 3, 1, le16(UInt16(height)) + Data([0, 0])),
            (0x0111, 4, UInt32(n), n == 1 ? le32(UInt32(stripOffsets[0])) : le32(UInt32(soArrayOffset))),
            (0x0116, 3, 1, le16(UInt16(rowsPerStrip)) + Data([0, 0])),
            (0x0117, 4, UInt32(n), n == 1 ? le32(stripByteCounts[0]) : le32(UInt32(sbcArrayOffset))),
        ]

        var out = Data()
        out += Data([0x49, 0x49]) + le16(42) + le32(8)
        out += le16(UInt16(entries.count))
        for (tag, type, count, value) in entries {
            out += le16(tag) + le16(type) + le32(count) + value.prefix(4)
        }
        out += le32(0) // next IFD
        if n > 1 {
            for o in stripOffsets { out += le32(UInt32(o)) }
            for c in stripByteCounts { out += le32(c) }
        }
        for s in strips { out += s }
        return out
    }

    /// Follow StripOffsets/StripByteCounts in a written TIFF and return the
    /// concatenated strip bytes.
    private func extractStrips(_ data: Data) throws -> Data {
        let file = try TIFFFileParser.parse(data)
        let ifd0 = try XCTUnwrap(file.ifd0)
        let endian = file.header.byteOrder
        let offsets = try XCTUnwrap(ifd0.entry(for: 0x0111))
        let counts = try XCTUnwrap(ifd0.entry(for: 0x0117))
        func ints(_ e: IFDEntry) -> [Int] {
            var r = BinaryReader(data: e.valueData)
            return (0..<e.count).compactMap { _ in
                e.type == .short ? (try? r.readUInt16(endian: endian)).map(Int.init)
                                 : (try? r.readUInt32(endian: endian)).map(Int.init)
            }
        }
        var raster = Data()
        let offs = ints(offsets), lens = ints(counts)
        for (i, off) in offs.enumerated() {
            raster.append(data.subdata(in: off ..< off + lens[i]))
        }
        return raster
    }

    func testSingleStripRasterPreserved() throws {
        let strip = Data((0..<48).map { UInt8($0) })
        let tiff = makeStripTIFF(width: 4, height: 4, rowsPerStrip: 4, strips: [strip])
        XCTAssertEqual(try extractStrips(tiff), strip, "fixture sanity")

        var metadata = try ImageMetadata.read(from: tiff)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "grew the metadata" // force the file layout to change
        let written = try metadata.writeToData()

        XCTAssertEqual(try extractStrips(written), strip, "raster must be copied and StripOffsets repointed")
    }

    func testMultiStripRasterPreservedInOrder() throws {
        let strip0 = Data(repeating: 0x11, count: 24)
        let strip1 = Data(repeating: 0x22, count: 24)
        let tiff = makeStripTIFF(width: 4, height: 4, rowsPerStrip: 2, strips: [strip0, strip1])
        XCTAssertEqual(try extractStrips(tiff), strip0 + strip1)

        let written = try ImageMetadata.read(from: tiff).writeToData()
        XCTAssertEqual(try extractStrips(written), strip0 + strip1,
                       "both strips must be relocated and the StripOffsets array rewritten in order")
    }

    func testExifSubIFDSerializedIntoTIFF() throws {
        let strip = Data(repeating: 0x7F, count: 48)
        let tiff = makeStripTIFF(width: 4, height: 4, rowsPerStrip: 4, strips: [strip])
        var metadata = try ImageMetadata.read(from: tiff)

        // Assign EXIF with an Exif sub-IFD (ISO lives there, not in IFD0).
        metadata.exif = ExifData(byteOrder: .littleEndian)
        metadata.exif?.ifd0 = IFD(entries: [
            IFDEntry(tag: ExifTag.make, type: .ascii, count: 6, valueData: Data("Canon\0".utf8)),
        ])
        metadata.exif?.exifIFD = IFD(entries: [
            IFDEntry(tag: ExifTag.isoSpeedRatings, type: .short, count: 1,
                     valueData: Data([0x90, 0x01])), // ISO 400, little-endian
        ])
        let written = try metadata.writeToData()

        let reread = try ImageMetadata.read(from: written)
        XCTAssertEqual(reread.exif?.make, "Canon")
        XCTAssertEqual(reread.exif?.exifIFD?.entry(for: ExifTag.isoSpeedRatings)?.uint16Value(endian: .littleEndian), 400,
                       "Exif sub-IFD must be serialized and its pointer relocated")
        XCTAssertEqual(try extractStrips(written), strip, "raster intact alongside sub-IFD")
    }

    func testAllMetadataTogether() throws {
        let original = TestFixtures.tiffWithExif(make: "Sony", model: "A7")
        var metadata = try ImageMetadata.read(from: original)

        metadata.iptc.headline = "Combined Test"
        metadata.iptc.keywords = ["sony", "test"]
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "XMP Headline"
        metadata.xmp?.city = "Tokyo"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.exif?.make, "Sony")
        XCTAssertEqual(reparsed.iptc.headline, "Combined Test")
        XCTAssertEqual(reparsed.iptc.keywords, ["sony", "test"])
        XCTAssertEqual(reparsed.xmp?.headline, "XMP Headline")
        XCTAssertEqual(reparsed.xmp?.city, "Tokyo")
    }
}
