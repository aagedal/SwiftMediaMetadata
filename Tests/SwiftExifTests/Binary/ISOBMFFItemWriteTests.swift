import XCTest
@testable import SwiftExif

/// Verifies that writing EXIF/XMP into an ISOBMFF still (AVIF/HEIC) stores them
/// as spec-conformant metadata *items* (`iinf`/`infe` + `iloc` + `iref cdsc`,
/// payload in `idat`) rather than `iprp/ipco` properties, and that doing so
/// keeps the primary image item's `iloc` offset pointing at its raster after
/// the meta box grows — including when `mdat` uses a 64-bit size header (as
/// Apple/`sips`-written files do).
final class ISOBMFFItemWriteTests: XCTestCase {

    // 20 recognizable raster bytes the "image item" points at.
    private let imageBytes = Data((0..<20).map { UInt8(0xA0 &+ $0) })

    /// Build a realistic HEIC: `ftyp` + `meta`(hdlr, pitm→1, iinf[hvc1 item 1],
    /// iprp/ipco[ispe], iloc[item 1 → mdat via construction method 0]) + `mdat`
    /// (64-bit header) holding `imageBytes`.
    private func buildRealisticHEIC() -> Data {
        func u16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
        func u32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
        func box(_ type: String, _ payload: Data) -> Data { u32(UInt32(8 + payload.count)) + Data(type.utf8) + payload }

        let ftyp = box("ftyp", Data("heic".utf8) + u32(0))

        let hdlr = box("hdlr", u32(0) + u32(0) + Data("pict".utf8) + Data(repeating: 0, count: 12) + Data([0]))
        let pitm = box("pitm", u32(0) + u16(1)) // version 0, item_ID 1
        let infe = box("infe", u32(0x02000000) + u16(1) + u16(0) + Data("hvc1".utf8) + Data([0]))
        let iinf = box("iinf", u32(0) + u16(1) + infe)
        let ispe = box("ispe", u32(0) + u32(4) + u32(4))
        let ipco = box("ipco", ispe)
        let iprp = box("iprp", ipco)

        // iloc version 1, offsetSize=4 lengthSize=4 baseOffset=0, 1 item, method 0.
        // Offset is the absolute file position of imageBytes; fill once known.
        func makeIloc(imageOffset: UInt32) -> Data {
            var p = u32(0x01000000)          // version 1, flags 0
            p += Data([0x44])                // offsetSize=4, lengthSize=4
            p += Data([0x00])                // baseOffsetSize=0, indexSize=0
            p += u16(1)                      // item_count
            p += u16(1)                      // item_ID = 1
            p += u16(0)                      // construction_method 0
            p += u16(0)                      // data_reference_index
            p += u16(1)                      // extent_count
            p += u32(imageOffset)            // extent_offset
            p += u32(UInt32(imageBytes.count)) // extent_length
            return box("iloc", p)
        }

        // The iloc field widths are fixed, so meta size is independent of the
        // offset value — build once with a placeholder to size everything.
        func metaPayload(iloc: Data) -> Data {
            u32(0) /* FullBox version/flags */ + hdlr + pitm + iinf + iprp + iloc
        }
        let metaSizePlaceholder = metaPayload(iloc: makeIloc(imageOffset: 0))
        let metaTotal = 8 + metaSizePlaceholder.count
        let mdatHeaderSize = 16 // 64-bit size header
        let imageOffset = UInt32(ftyp.count + metaTotal + mdatHeaderSize)

        let meta = box("meta", metaPayload(iloc: makeIloc(imageOffset: imageOffset)))
        // mdat with a 64-bit extended size header.
        let mdat = u32(1) + Data("mdat".utf8) + Data([0,0,0,0]) + u32(UInt32(16 + imageBytes.count)) + imageBytes

        return ftyp + meta + mdat
    }

    /// Read the image item's raster back out of a written file by walking its
    /// top-level boxes and following the construction-method-0 `iloc` offset.
    private func rasterFromImageItem(_ data: Data) throws -> Data {
        let boxes = try ISOBMFFBoxReader.parseBoxes(from: data)
        let meta = try XCTUnwrap(boxes.first { $0.type == "meta" })
        let children = try ISOBMFFMetadata.parseMetaChildren(meta.data)
        let iloc = try XCTUnwrap(children.first { $0.type == "iloc" })
        // Parse just enough of the version-1 iloc to reach item 1's single extent.
        var r = BinaryReader(data: iloc.data)
        _ = try r.readUInt32BigEndian()                  // version/flags
        _ = try r.readUInt8(); _ = try r.readUInt8()     // size bytes
        _ = try r.readUInt16BigEndian()                  // item_count
        _ = try r.readUInt16BigEndian()                  // item_ID
        _ = try r.readUInt16BigEndian()                  // construction_method
        _ = try r.readUInt16BigEndian()                  // data_reference_index
        _ = try r.readUInt16BigEndian()                  // extent_count
        let offset = Int(try r.readUInt32BigEndian())
        let length = Int(try r.readUInt32BigEndian())
        return data.subdata(in: offset ..< offset + length)
    }

    func testExifStoredAsItemAndImageOffsetFixedUp() throws {
        let heic = buildRealisticHEIC()
        // Sanity: the fixture itself points at the right raster.
        XCTAssertEqual(try rasterFromImageItem(heic), imageBytes)

        var metadata = try ImageMetadata.read(from: heic)
        XCTAssertNil(metadata.exif, "fixture starts with no EXIF")

        metadata.exif = ExifData(byteOrder: .bigEndian)
        metadata.exif?.ifd0 = IFD(entries: [
            IFDEntry(tag: ExifTag.make, type: .ascii, count: 6, valueData: Data("Canon\0".utf8)),
            IFDEntry(tag: ExifTag.model, type: .ascii, count: 3, valueData: Data("R5\0".utf8)),
        ])
        let written = try metadata.writeToData()

        // 1. Round-trips through SwiftExif.
        let reread = try ImageMetadata.read(from: written)
        XCTAssertEqual(reread.exif?.make, "Canon")
        XCTAssertEqual(reread.exif?.model, "R5")

        // 2. The raster is still reachable at the (now shifted) iloc offset.
        XCTAssertEqual(try rasterFromImageItem(written), imageBytes,
                       "image item offset must be patched for the grown meta box")

        // 3. EXIF lives in an `Exif` item, NOT an `ipco` property.
        let boxes = try ISOBMFFBoxReader.parseBoxes(from: written)
        let meta = try XCTUnwrap(boxes.first { $0.type == "meta" })
        let children = try ISOBMFFMetadata.parseMetaChildren(meta.data)
        let iinf = try XCTUnwrap(children.first { $0.type == "iinf" })
        XCTAssertTrue(iinf.data.range(of: Data("Exif".utf8)) != nil, "expected an Exif infe entry")
        XCTAssertNotNil(children.first { $0.type == "idat" }, "EXIF payload should be in idat")
        XCTAssertNotNil(children.first { $0.type == "iref" }, "expected an iref cdsc link")
        let iprp = try XCTUnwrap(children.first { $0.type == "iprp" })
        let ipco = try XCTUnwrap(try ISOBMFFBoxReader.parseBoxes(from: iprp.data).first { $0.type == "ipco" })
        let ipcoProps = try ISOBMFFBoxReader.parseBoxes(from: ipco.data)
        XCTAssertFalse(ipcoProps.contains { $0.type == "Exif" }, "EXIF must not be an ipco property")

        // 4. The 64-bit mdat header is preserved (so absolute offsets stay valid).
        let mdat = try XCTUnwrap(boxes.first { $0.type == "mdat" })
        XCTAssertTrue(mdat.usesLargeSize, "mdat 64-bit size header must be preserved")
    }

    func testXMPStoredAsMimeItem() throws {
        let heic = buildRealisticHEIC()
        var metadata = try ImageMetadata.read(from: heic)
        metadata.xmp = XMPData()
        metadata.xmp?.setValue(.simple("Jane"), namespace: XMPNamespace.dc, property: "creator")

        let written = try metadata.writeToData()
        let reread = try ImageMetadata.read(from: written)
        XCTAssertEqual(reread.xmp?.simpleValue(namespace: XMPNamespace.dc, property: "creator"), "Jane")
        // Raster intact.
        XCTAssertEqual(try rasterFromImageItem(written), imageBytes)
    }

    func testRemovingExifDropsTheItemButKeepsRaster() throws {
        let heic = buildRealisticHEIC()
        var metadata = try ImageMetadata.read(from: heic)
        metadata.exif = ExifData(byteOrder: .bigEndian)
        metadata.exif?.ifd0 = IFD(entries: [
            IFDEntry(tag: ExifTag.make, type: .ascii, count: 6, valueData: Data("Canon\0".utf8)),
        ])
        let withExif = try metadata.writeToData()
        XCTAssertEqual(try ImageMetadata.read(from: withExif).exif?.make, "Canon")

        // Now strip it.
        var stripMeta = try ImageMetadata.read(from: withExif)
        stripMeta.exif = nil
        let stripped = try stripMeta.writeToData()

        XCTAssertNil(try ImageMetadata.read(from: stripped).exif)
        XCTAssertEqual(try rasterFromImageItem(stripped), imageBytes, "raster must survive removal")
        let children = try ISOBMFFMetadata.parseMetaChildren(
            try XCTUnwrap(try ISOBMFFBoxReader.parseBoxes(from: stripped).first { $0.type == "meta" }).data)
        let iinf = try XCTUnwrap(children.first { $0.type == "iinf" })
        XCTAssertNil(iinf.data.range(of: Data("Exif".utf8)), "Exif infe should be gone after removal")
    }
}
