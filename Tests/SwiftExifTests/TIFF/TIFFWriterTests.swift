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

    // MARK: - SubIFD (0x014A) relocation

    private func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }

    /// Serialize one little-endian IFD: returns (bytes, [slot offsets of entries
    /// whose value must be patched with an absolute file offset later]). Each
    /// entry is (tag, type, count, inlineValueOr4ByteOffset). The IFD's
    /// next-pointer is written as `nextIFD`.
    private func encodeIFD(_ entries: [(UInt16, UInt16, UInt32, Data)], nextIFD: UInt32 = 0) -> Data {
        var out = le16(UInt16(entries.count))
        for (tag, type, count, value) in entries {
            var v = value.prefix(4); while v.count < 4 { v.append(0) }
            out += le16(tag) + le16(type) + le32(count) + Data(v)
        }
        out += le32(nextIFD)
        return out
    }

    /// Build a multi-IFD TIFF: IFD0 (small preview strip) carries a SubIFDs
    /// (0x014A) array pointing at `subStrips.count` child IFDs, each a
    /// single-strip raster. Returns the file plus the raw sub-strip data so a
    /// round-trip can assert byte-identical survival.
    private func makeSubIFDTIFF(subStrips: [Data]) -> Data {
        // Layout: header(8) | IFD0 | SubIFDs offset array | [child IFD + its strip]* | IFD0 strip
        // A single SubIFD offset is stored inline in the 0x014A value (TIFF rule
        // for totalSize ≤ 4), so the out-of-line array is emitted only when n > 1.
        let n = subStrips.count
        let ifd0EntryCount = 6 // width,height,stripOffsets,stripByteCounts,rowsPerStrip,subIFDs
        let ifd0Size = 2 + ifd0EntryCount * 12 + 4
        let subArrayOffset = 8 + ifd0Size
        let subArraySize = n > 1 ? n * 4 : 0
        var cursor = subArrayOffset + subArraySize

        // Each child IFD has: width,height,stripOffsets,stripByteCounts,rowsPerStrip (5 entries).
        let childIFDSize = 2 + 5 * 12 + 4
        var childIFDOffsets: [UInt32] = []
        var childBlocks = Data()
        for strip in subStrips {
            let childOffset = cursor
            let stripOffset = childOffset + childIFDSize
            childIFDOffsets.append(UInt32(childOffset))
            let childIFD = encodeIFD([
                (0x0100, 3, 1, le16(8)),
                (0x0101, 3, 1, le16(UInt16(strip.count))),
                (0x0111, 4, 1, le32(UInt32(stripOffset))),
                (0x0117, 4, 1, le32(UInt32(strip.count))),
                (0x0116, 3, 1, le16(UInt16(strip.count))),
            ])
            childBlocks += childIFD + strip
            cursor += childIFDSize + strip.count
        }

        // IFD0's own tiny preview strip after all the child blocks.
        let ifd0Strip = Data((0..<8).map { UInt8(0xA0 + $0) })
        let ifd0StripOffset = cursor

        let ifd0 = encodeIFD([
            (0x0100, 3, 1, le16(8)),
            (0x0101, 3, 1, le16(1)),
            (0x0111, 4, 1, le32(UInt32(ifd0StripOffset))),
            (0x0117, 4, 1, le32(UInt32(ifd0Strip.count))),
            (0x0116, 3, 1, le16(1)),
            // SubIFDs: a single offset is inline; multiple offsets live in the
            // out-of-line array at `subArrayOffset`.
            (0x014A, 4, UInt32(n), n > 1 ? le32(UInt32(subArrayOffset)) : le32(childIFDOffsets[0])),
        ])

        var out = Data()
        out += Data([0x49, 0x49]) + le16(42) + le32(8)
        out += ifd0
        if n > 1 { for o in childIFDOffsets { out += le32(o) } }
        out += childBlocks
        out += ifd0Strip
        return out
    }

    /// Resolve the SubIFDs (0x014A) array in a written TIFF and return each
    /// child IFD's single-strip raster, in array order.
    private func extractSubIFDStrips(_ data: Data) throws -> [Data] {
        let file = try TIFFFileParser.parse(data)
        let endian = file.header.byteOrder
        let ifd0 = try XCTUnwrap(file.ifd0)
        let sub = try XCTUnwrap(ifd0.entry(for: 0x014A), "SubIFDs pointer must survive")
        XCTAssertEqual(sub.type, .long, "relocated SubIFDs offsets must be written as LONG")
        var subReader = BinaryReader(data: sub.valueData)
        let childOffsets = (0..<sub.count).compactMap { _ in (try? subReader.readUInt32(endian: endian)).map(Int.init) }
        var strips: [Data] = []
        for off in childOffsets {
            let (child, _) = try IFDParser.parseIFD(data: data, tiffStart: 0, offset: off, endian: endian)
            let so = try XCTUnwrap(child.entry(for: 0x0111)?.uint32Value(endian: endian))
            let bc = try XCTUnwrap(child.entry(for: 0x0117)?.uint32Value(endian: endian))
            strips.append(data.subdata(in: Int(so) ..< Int(so) + Int(bc)))
        }
        return strips
    }

    func testSubIFDArrayAndChildRastersPreserved() throws {
        let sub0 = Data((0..<32).map { UInt8($0) })
        let sub1 = Data((0..<48).map { UInt8(0x40 + $0) })
        let tiff = makeSubIFDTIFF(subStrips: [sub0, sub1])
        XCTAssertEqual(try extractSubIFDStrips(tiff), [sub0, sub1], "fixture sanity")

        var metadata = try ImageMetadata.read(from: tiff)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "force a layout change" // grow IFD0 so offsets must move
        let written = try metadata.writeToData()

        XCTAssertEqual(try extractSubIFDStrips(written), [sub0, sub1],
                       "each SubIFD child raster must be relocated byte-identically with its 0x014A offset repointed in order")
        // The relocated child offsets must point forward into the new file (no
        // dangling/stale offset carried from the source layout).
        let file = try TIFFFileParser.parse(written)
        let sub = try XCTUnwrap(file.ifd0?.entry(for: 0x014A))
        var r = BinaryReader(data: sub.valueData)
        let offs = (0..<sub.count).compactMap { _ in (try? r.readUInt32(endian: file.header.byteOrder)).map(Int.init) }
        XCTAssertEqual(offs.count, 2)
        for o in offs { XCTAssertGreaterThan(o, 0); XCTAssertLessThan(o, written.count) }
    }

    func testSingleSubIFDPreserved() throws {
        let sub0 = Data(repeating: 0x5A, count: 40)
        let tiff = makeSubIFDTIFF(subStrips: [sub0])
        let written = try ImageMetadata.read(from: tiff).writeToData()
        XCTAssertEqual(try extractSubIFDStrips(written), [sub0],
                       "a single inline SubIFD offset must relocate its child raster")
    }

    // MARK: - Interop IFD (0xA005) relocation

    /// Build a TIFF whose Exif sub-IFD (0x8769) contains an Interop pointer
    /// (0xA005) referencing a small Interop IFD (InteroperabilityIndex "R98").
    /// Verifies the nested pointer survives a round-trip even though the Exif
    /// IFD is relocated.
    private func makeInteropTIFF() -> Data {
        // Layout: header(8) | IFD0 | Exif IFD | Interop IFD | IFD0 strip
        let ifd0Size = 2 + 3 * 12 + 4 // width,height,exifPointer
        let exifIFDSize = 2 + 2 * 12 + 4 // isoSpeed, interopPointer
        let interopIFDSize = 2 + 1 * 12 + 4 // InteroperabilityIndex

        let exifOffset = 8 + ifd0Size
        let interopOffset = exifOffset + exifIFDSize
        let stripOffset = interopOffset + interopIFDSize
        let strip = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let interopIFD = encodeIFD([
            (0x0001, 2, 4, Data("R98\0".utf8)), // InteroperabilityIndex, inline ASCII
        ])
        let exifIFD = encodeIFD([
            (0x8827, 3, 1, le16(800)),                    // ISOSpeedRatings
            (0xA005, 4, 1, le32(UInt32(interopOffset))),  // Interop pointer
        ])
        let ifd0 = encodeIFD([
            (0x0100, 3, 1, le16(2)),
            (0x0101, 3, 1, le16(2)),
            (0x8769, 4, 1, le32(UInt32(exifOffset))),     // Exif pointer
        ])
        // No StripOffsets in IFD0 here — strip presence is irrelevant to the test.
        var out = Data()
        out += Data([0x49, 0x49]) + le16(42) + le32(8)
        out += ifd0 + exifIFD + interopIFD + strip
        return out
    }

    func testInteropIFDInsideExifRoundTrip() throws {
        let tiff = makeInteropTIFF()
        var metadata = try ImageMetadata.read(from: tiff)
        // Sanity: the assigned exif round-trips the Exif sub-IFD.
        XCTAssertEqual(metadata.exif?.exifIFD?.entry(for: ExifTag.isoSpeedRatings)?.uint16Value(endian: .littleEndian), 800)

        metadata.xmp = XMPData()
        metadata.xmp?.headline = "grow it" // force a layout change so offsets must move
        let written = try metadata.writeToData()

        // Walk IFD0 → Exif → Interop in the written file by following offsets.
        let file = try TIFFFileParser.parse(written)
        let endian = file.header.byteOrder
        let exifPtr = try XCTUnwrap(file.ifd0?.entry(for: ExifTag.exifIFDPointer)?.uint32Value(endian: endian))
        let (exif, _) = try IFDParser.parseIFD(data: written, tiffStart: 0, offset: Int(exifPtr), endian: endian)
        XCTAssertEqual(exif.entry(for: ExifTag.isoSpeedRatings)?.uint16Value(endian: endian), 800,
                       "Exif sub-IFD must survive")
        let interopPtr = try XCTUnwrap(exif.entry(for: ExifTag.interopIFDPointer)?.uint32Value(endian: endian),
                                       "Interop pointer (0xA005) must survive inside the relocated Exif IFD")
        XCTAssertGreaterThan(Int(interopPtr), 0)
        XCTAssertLessThan(Int(interopPtr), written.count, "relocated Interop offset must be in-bounds")
        let (interop, _) = try IFDParser.parseIFD(data: written, tiffStart: 0, offset: Int(interopPtr), endian: endian)
        XCTAssertEqual(interop.entry(for: 0x0001)?.stringValue(endian: endian), "R98",
                       "the relocated Interop IFD's contents must be intact")
    }

    /// A pointer whose offset is out of bounds must be dropped (not crash, not
    /// emit a dangling offset).
    func testMalformedInteropPointerDropped() throws {
        var tiff = makeInteropTIFF()
        // Corrupt the Exif IFD's Interop pointer to an absurd offset by rewriting
        // the whole file through a parse that keeps the bogus value: simplest is
        // to point Interop past EOF. Locate the 0xA005 entry's value slot.
        // The Exif IFD starts at 8 + (2 + 3*12 + 4) = 50; entries at 52.
        // 0xA005 is the 2nd entry → 52 + 12 = 64; its 4-byte value at 64 + 8 = 72.
        let valueSlot = 72
        tiff.replaceSubrange(valueSlot ..< valueSlot + 4, with: le32(0xFFFFFFF0))
        // Reading must still succeed; writing must not crash and must drop the
        // unrelocatable Interop pointer rather than emit a dangling offset.
        let metadata = try ImageMetadata.read(from: tiff)
        let written = try metadata.writeToData()
        let file = try TIFFFileParser.parse(written)
        let endian = file.header.byteOrder
        if let exifPtr = file.ifd0?.entry(for: ExifTag.exifIFDPointer)?.uint32Value(endian: endian) {
            let (exif, _) = try IFDParser.parseIFD(data: written, tiffStart: 0, offset: Int(exifPtr), endian: endian)
            XCTAssertNil(exif.entry(for: ExifTag.interopIFDPointer),
                         "an out-of-bounds Interop pointer must be dropped, not relocated")
            // ISO still survives.
            XCTAssertEqual(exif.entry(for: ExifTag.isoSpeedRatings)?.uint16Value(endian: endian), 800)
        }
    }

    // MARK: - MakerNote relocation warning

    func testMakerNoteRelocationEmitsWarning() throws {
        let strip = Data(repeating: 0x7F, count: 16)
        let tiff = makeStripTIFF(width: 4, height: 4, rowsPerStrip: 4, strips: [strip])
        var metadata = try ImageMetadata.read(from: tiff)

        // Assign an Exif sub-IFD carrying a MakerNote (lives in the Exif IFD).
        metadata.exif = ExifData(byteOrder: .littleEndian)
        metadata.exif?.exifIFD = IFD(entries: [
            IFDEntry(tag: ExifTag.makerNote, type: .undefined, count: 8,
                     valueData: Data([0, 1, 2, 3, 4, 5, 6, 7])),
        ])

        let (_, warnings) = try metadata.writeToDataWithWarnings()
        XCTAssertTrue(warnings.contains { $0.contains("MakerNote") && $0.contains("0x927C") },
                      "relocating a MakerNote must surface a non-fatal warning")
    }

    func testNoMakerNoteNoWarning() throws {
        let strip = Data(repeating: 0x10, count: 16)
        let tiff = makeStripTIFF(width: 4, height: 4, rowsPerStrip: 4, strips: [strip])
        var metadata = try ImageMetadata.read(from: tiff)
        metadata.xmp = XMPData(); metadata.xmp?.headline = "no makernote here"

        let (_, warnings) = try metadata.writeToDataWithWarnings()
        XCTAssertTrue(warnings.isEmpty, "a MakerNote-free write must not warn")
    }

    /// Build a little-endian TIFF whose Exif IFD carries a Canon-style absolute
    /// MakerNote: a bare IFD at the note's start with one out-of-line value whose
    /// offset field is TIFF-absolute (points at the value bytes inside the file).
    /// Returns the file bytes; the value reads "CANONSER" at its absolute offset.
    private func makeCanonMakerNoteTIFF() -> Data {
        let make = Data("Canon\u{0}".utf8)            // 6 bytes (out-of-line)
        let strip = Data([0xDE, 0xAD, 0xBE, 0xEF])

        // IFD0: width,height,Make,StripOffsets,RowsPerStrip,StripByteCounts,ExifPointer
        let ifd0Count = 7
        let ifd0Size = 2 + ifd0Count * 12 + 4
        let makeOffset = 8 + ifd0Size
        let exifIFDOffset = makeOffset + make.count

        // Exif IFD: just the MakerNote (1 entry).
        let exifIFDSize = 2 + 1 * 12 + 4
        let makerNoteOffset = exifIFDOffset + exifIFDSize

        // MakerNote: count(2)+entry(12)+next(4) = 18, then 8-byte value.
        let makerNoteValueAbsolute = makerNoteOffset + 18
        let makerNoteLen = 18 + 8
        let stripOffset = makerNoteOffset + makerNoteLen

        var out = Data()
        out += Data([0x49, 0x49]) + le16(42) + le32(8)        // TIFF header → IFD0 @ 8
        out += encodeIFD([
            (0x0100, 3, 1, le16(2)),
            (0x0101, 3, 1, le16(2)),
            (0x010F, 2, UInt32(make.count), le32(UInt32(makeOffset))),
            (0x0111, 4, 1, le32(UInt32(stripOffset))),
            (0x0116, 3, 1, le16(2)),
            (0x0117, 4, 1, le32(UInt32(strip.count))),
            (0x8769, 4, 1, le32(UInt32(exifIFDOffset))),
        ])
        XCTAssertEqual(out.count, makeOffset)
        out += make
        // Exif IFD
        out += encodeIFD([
            (0x927C, 7, UInt32(makerNoteLen), le32(UInt32(makerNoteOffset))),
        ])
        XCTAssertEqual(out.count, makerNoteOffset)
        // MakerNote: bare IFD with one out-of-line ASCII value (absolute offset).
        out += encodeIFD([
            (0x0006, 2, 8, le32(UInt32(makerNoteValueAbsolute))),
        ])
        out += Data("CANONSER".utf8)
        XCTAssertEqual(out.count, stripOffset)
        out += strip
        return out
    }

    func testAbsoluteMakerNoteFixedUpNoWarning() throws {
        let tiff = makeCanonMakerNoteTIFF()
        let metadata = try ImageMetadata.read(from: tiff)
        XCTAssertEqual(metadata.exif?.make, "Canon")

        let (written, warnings) = try metadata.writeToDataWithWarnings()
        XCTAssertFalse(warnings.contains { $0.contains("MakerNote") },
                       "a recognized absolute MakerNote must be fixed up, not warned about")

        // Re-read: the relocated MakerNote's internal absolute offset must now
        // resolve, in the *written* file, to the original value bytes.
        let reread = try ImageMetadata.read(from: written)
        let mn = try XCTUnwrap(reread.exif?.exifIFD?.entry(for: ExifTag.makerNote))
        // Internal value-offset field sits at byte 10 of the MakerNote IFD.
        let s = mn.valueData.startIndex + 10
        let ptr = Int(UInt32(mn.valueData[s]) | (UInt32(mn.valueData[s + 1]) << 8)
                      | (UInt32(mn.valueData[s + 2]) << 16) | (UInt32(mn.valueData[s + 3]) << 24))
        XCTAssertLessThanOrEqual(ptr + 8, written.count)
        let resolved = written.subdata(in: (written.startIndex + ptr) ..< (written.startIndex + ptr + 8))
        XCTAssertEqual(resolved, Data("CANONSER".utf8),
                       "patched MakerNote offset must resolve to the original value in the new file")
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
