import XCTest
@testable import SwiftExif

/// Regression guard for the CR3 write offset fix-up.
///
/// CR3 stores absolute file offsets in each track's `co64` chunk table and in
/// the Canon `CTBO` box. When writing metadata resizes the `moov` box, `mdat`
/// (and the boxes around it) move, and those offset tables must be rewritten —
/// otherwise the embedded JPEG/preview/CTMD become unreadable. The synthetic
/// CR3 in `CR3ParserTests` has neither table, so it can't catch that class of
/// corruption; this builds a file that does.
final class CR3WriterOffsetTests: XCTestCase {

    private static func box(_ type: String, _ payload: Data) -> Data {
        var w = BinaryWriter(capacity: payload.count + 8)
        w.writeUInt32BigEndian(UInt32(8 + payload.count))
        w.writeString(type, encoding: .ascii)
        w.writeBytes(payload)
        return w.data
    }

    private static func cmtTIFF(_ entries: [IFDEntry]) -> Data {
        var exif = ExifData(byteOrder: .littleEndian)
        exif.ifd0 = IFD(entries: entries.sorted { $0.tag < $1.tag })
        return ExifWriter.writeTIFF(exif)
    }

    private static func u64BE(_ data: Data, _ pos: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[data.startIndex + pos + i]) }
        return v
    }

    /// Build a CR3 with a real `co64` chunk table and a `CTBO` box, write new
    /// metadata (which resizes `moov`), and assert both tables still point at
    /// the correct, relocated bytes.
    func testWriteFixesChunkAndCTBOOffsets() throws {
        let marker = Data([0xFF, 0xD8, 0xCA, 0xFE, 0xBA, 0xBE, 0xFF, 0xD9])

        func makeString(_ s: String) -> Data { Data((s + "\0").utf8) }
        let cmt1 = Self.cmtTIFF([
            IFDEntry(tag: ExifTag.make, type: .ascii, count: 6, valueData: makeString("Canon")),
            IFDEntry(tag: ExifTag.model, type: .ascii, count: 13, valueData: makeString("Canon EOS R5")),
        ])

        // CTBO: count=2, entries (index, offset, size) — offsets patched below.
        var ctboW = BinaryWriter()
        ctboW.writeUInt32BigEndian(2)
        for idx in 1...2 {
            ctboW.writeUInt32BigEndian(UInt32(idx))
            ctboW.writeUInt64BigEndian(0) // offset placeholder
            ctboW.writeUInt64BigEndian(0) // size placeholder
        }
        let canonPayload = Data(CanonUUID.canonMetadata)
            + Self.box("CTBO", ctboW.data)
            + Self.box("CMT1", cmt1)
        let canonUUID = Self.box("uuid", canonPayload)

        // trak → mdia → minf → stbl → co64 (one chunk, offset patched below).
        var co64W = BinaryWriter()
        co64W.writeUInt32BigEndian(0)  // version + flags
        co64W.writeUInt32BigEndian(1)  // entry count
        co64W.writeUInt64BigEndian(0)  // chunk offset placeholder
        let stbl = Self.box("stbl", Self.box("co64", co64W.data))
        let trak = Self.box("trak", Self.box("mdia", Self.box("minf", stbl)))

        let moov = Self.box("moov", canonUUID + trak)
        let ftyp = Self.box("ftyp", Data("crx ".utf8) + Data([0, 0, 0, 0]) + Data("crx ".utf8))

        let xmpXML = "<?xpacket begin='\u{FEFF}'?><x:xmpmeta xmlns:x='adobe:ns:meta/'></x:xmpmeta><?xpacket end='w'?>"
        let xmpBox = Self.box("uuid", Data(CanonUUID.xmpUUID) + Data(xmpXML.utf8))
        let mdat = Self.box("mdat", marker + Data(repeating: 0, count: 64))

        var file = ftyp + moov + xmpBox + mdat

        // Patch the absolute offsets now that the layout is known.
        let xmpOff = ftyp.count + moov.count
        let mdatOff = xmpOff + xmpBox.count
        let markerAbs = mdatOff + 8 // mdat payload starts after the 8-byte header

        func patchU64(_ data: inout Data, at pos: Int, _ value: UInt64) {
            for i in 0..<8 {
                data[data.startIndex + pos + i] = UInt8((value >> (8 * (7 - i))) & 0xFF)
            }
        }
        // co64: payload = type(already consumed) ... we locate by the 'co64' tag.
        let co64Tag = file.range(of: Data("co64".utf8))!
        patchU64(&file, at: co64Tag.upperBound + 8, markerAbs.u64) // skip version/flags(4)+count(4)

        // CTBO entries: after the 'CTBO' tag comes count(4), then entries.
        let ctboTag = file.range(of: Data("CTBO".utf8))!
        let entry1 = ctboTag.upperBound + 4      // skip count
        patchU64(&file, at: entry1 + 4, UInt64(xmpOff))            // idx(4) then offset
        patchU64(&file, at: entry1 + 12, UInt64(xmpBox.count))     // then size
        let entry2 = entry1 + 20
        patchU64(&file, at: entry2 + 4, UInt64(mdatOff))
        patchU64(&file, at: entry2 + 12, UInt64(mdat.count))

        // Sanity: the original points where we said.
        XCTAssertEqual(Self.u64BE(file, co64Tag.upperBound + 8), UInt64(markerAbs))
        XCTAssertEqual(file.subdata(in: markerAbs ..< markerAbs + 2), Data([0xFF, 0xD8]))

        // --- Read, modify (forces a CMT/moov resize), write ---
        var md = try ImageMetadata.read(from: file, format: .raw(.cr3))
        var entries = md.exif?.ifd0?.entries ?? []
        entries.append(IFDEntry(tag: ExifTag.artist, type: .ascii,
                                count: 20, valueData: Data("A Much Longer Name\0".utf8)))
        md.exif?.ifd0 = IFD(entries: entries.sorted { $0.tag < $1.tag })
        let out = try md.writeToData()

        // The write must have actually moved mdat (else the test is vacuous).
        let outMdatTag = out.range(of: Data("mdat".utf8))!
        let newMdatBoxStart = outMdatTag.lowerBound - 4
        let newMarkerAbs = newMdatBoxStart + 8
        XCTAssertNotEqual(newMarkerAbs, markerAbs, "moov should have resized, moving mdat")

        // 1. co64 now points at the relocated marker, and the marker is really there.
        let outCo64 = out.range(of: Data("co64".utf8))!
        XCTAssertEqual(Self.u64BE(out, outCo64.upperBound + 8), UInt64(newMarkerAbs))
        XCTAssertEqual(out.subdata(in: newMarkerAbs ..< newMarkerAbs + 8), marker,
                       "co64 must point at the intact chunk marker after writing")

        // 2. CTBO's mdat entry points at the relocated mdat box.
        let outCtbo = out.range(of: Data("CTBO".utf8))!
        let outEntry2 = outCtbo.upperBound + 4 + 20
        XCTAssertEqual(Self.u64BE(out, outEntry2 + 4), UInt64(newMdatBoxStart),
                       "CTBO mdat offset must track the relocated mdat box")

        // 3. The file still reads back cleanly with the new metadata.
        let reread = try ImageMetadata.read(from: out, format: .raw(.cr3))
        XCTAssertEqual(reread.exif?.make, "Canon")
        XCTAssertEqual(
            reread.exif?.artist?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
            "A Much Longer Name"
        )
    }
}

private extension Int {
    var u64: UInt64 { UInt64(self) }
}
