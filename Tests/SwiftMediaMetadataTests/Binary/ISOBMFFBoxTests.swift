import XCTest
@testable import SwiftMediaMetadata

final class ISOBMFFBoxTests: XCTestCase {

    func testParseSimpleBox() throws {
        var writer = BinaryWriter(capacity: 32)
        writer.writeUInt32BigEndian(12) // size = 12 (8 header + 4 payload)
        writer.writeString("test", encoding: .ascii)
        writer.writeBytes([0x01, 0x02, 0x03, 0x04])

        let boxes = try ISOBMFFBoxReader.parseBoxes(from: writer.data)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].type, "test")
        XCTAssertEqual(boxes[0].data, Data([0x01, 0x02, 0x03, 0x04]))
    }

    func testParseMultipleBoxes() throws {
        var writer = BinaryWriter(capacity: 64)
        // Box 1
        writer.writeUInt32BigEndian(12)
        writer.writeString("aaaa", encoding: .ascii)
        writer.writeBytes([0x01, 0x02, 0x03, 0x04])
        // Box 2
        writer.writeUInt32BigEndian(10)
        writer.writeString("bbbb", encoding: .ascii)
        writer.writeBytes([0x05, 0x06])

        let boxes = try ISOBMFFBoxReader.parseBoxes(from: writer.data)
        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes[0].type, "aaaa")
        XCTAssertEqual(boxes[1].type, "bbbb")
    }

    func testParseEmptyPayloadBox() throws {
        var writer = BinaryWriter(capacity: 16)
        writer.writeUInt32BigEndian(8) // size = 8 (header only, no payload)
        writer.writeString("emty", encoding: .ascii)

        let boxes = try ISOBMFFBoxReader.parseBoxes(from: writer.data)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].type, "emty")
        XCTAssertTrue(boxes[0].data.isEmpty)
    }

    func testParseBoxToEnd() throws {
        // size=0 means "to end of data"
        var writer = BinaryWriter(capacity: 32)
        writer.writeUInt32BigEndian(0) // size = 0 (extends to end)
        writer.writeString("last", encoding: .ascii)
        writer.writeBytes([0xAA, 0xBB, 0xCC])

        let boxes = try ISOBMFFBoxReader.parseBoxes(from: writer.data)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].type, "last")
        XCTAssertEqual(boxes[0].data, Data([0xAA, 0xBB, 0xCC]))
    }

    func testParseExtendedSizeBox() throws {
        // size=1 means extended size (UInt64 follows type)
        var writer = BinaryWriter(capacity: 32)
        writer.writeUInt32BigEndian(1) // size field = 1 (use extended)
        writer.writeString("ext ", encoding: .ascii)
        writer.writeUInt64BigEndian(20) // extended size = 20 (16 header + 4 payload)
        writer.writeBytes([0xDE, 0xAD, 0xBE, 0xEF])

        let boxes = try ISOBMFFBoxReader.parseBoxes(from: writer.data)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].type, "ext ")
        XCTAssertEqual(boxes[0].data, Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testEmptyInput() throws {
        let boxes = try ISOBMFFBoxReader.parseBoxes(from: Data())
        XCTAssertTrue(boxes.isEmpty)
    }

    // Regression for an integer-overflow trap in the box-bounds check. A box
    // using extended size (size32 == 1) can declare a 64-bit size near Int.max.
    // The cast `Int(size64)` is already guarded against trapping, but the
    // subsequent bounds check `reader.offset + payloadSize <= endOffset` would
    // itself overflow Int and trap whenever the box does not start at offset 0
    // (so `reader.offset` > 16). A leading 8-byte box pushes the offset up, then
    // the oversized extended box triggers the overflow. The parser must reject
    // it gracefully instead of crashing the process.
    func testParseRejectsOverflowingExtendedSize() throws {
        var writer = BinaryWriter(capacity: 32)
        // Box 1: harmless 8-byte header-only box to advance the read offset > 16.
        writer.writeUInt32BigEndian(8)
        writer.writeString("free", encoding: .ascii)
        // Box 2: extended size declaring ~Int.max bytes of payload.
        writer.writeUInt32BigEndian(1)
        writer.writeString("ext ", encoding: .ascii)
        writer.writeUInt64BigEndian(UInt64(Int.max))

        // Must return without trapping; the oversized box is dropped.
        let boxes = try ISOBMFFBoxReader.parseBoxes(from: writer.data)
        XCTAssertEqual(boxes.map(\.type), ["free"])

        // Same overflow path in the mdat-skipping top-level parser.
        let skipping = try ISOBMFFBoxReader.parseTopLevelBoxesSkippingMdat(writer.data)
        XCTAssertEqual(skipping.map(\.type), ["free"])
    }

    // Regression for the stack-overflow DoS in `ISOBMFFMetadata.findBox`:
    // a crafted chain of 8-byte container boxes used to recurse without
    // bound. Wrappers use `moov` (a real container in the allowlist) so
    // the depth cap, not the leaf-skip allowlist, is what stops descent.
    func testFindBoxRejectsDeeplyNestedContainers() throws {
        let nestingLevels = 5000

        // Innermost 8-byte empty "leaf" box.
        var inner = Data()
        do {
            var w = BinaryWriter(capacity: 8)
            w.writeUInt32BigEndian(8)
            w.writeString("leaf", encoding: .ascii)
            inner = w.data
        }

        // Wrap N times from the inside out, each wrapper a `moov` container.
        for _ in 0..<nestingLevels {
            let newSize = inner.count + 8
            XCTAssertLessThanOrEqual(newSize, Int(UInt32.max))
            var w = BinaryWriter(capacity: newSize)
            w.writeUInt32BigEndian(UInt32(newSize))
            w.writeString("moov", encoding: .ascii)
            w.writeBytes(inner)
            inner = w.data
        }

        let outer = try ISOBMFFBoxReader.parseBoxes(from: inner)
        XCTAssertEqual(outer.count, 1)
        XCTAssertEqual(outer[0].type, "moov")

        // Type absent from the tree: returns nil, and crucially returns at
        // all (a stack overflow here would terminate the process).
        XCTAssertNil(ISOBMFFMetadata.findBox(type: "zzzz", in: outer))

        // The innermost "leaf" sits `nestingLevels` deep — far past
        // `maxRecursionDepth`. The depth cap must stop descent before
        // reaching it. Pins the cap so a regression that silently lifts
        // it is caught.
        XCTAssertNil(ISOBMFFMetadata.findBox(type: "leaf", in: outer))
    }

    // findBox must descend into known container box types so that real
    // ISOBMFF layouts (e.g. moov → udta → Exif) still resolve.
    func testFindBoxDescendsIntoKnownContainers() throws {
        let exifPayload = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let exifBox = makeBox(type: "Exif", payload: exifPayload)
        let udtaBox = makeBox(type: "udta", payload: exifBox)
        let moovBox = makeBox(type: "moov", payload: udtaBox)

        let outer = try ISOBMFFBoxReader.parseBoxes(from: moovBox)
        let found = ISOBMFFMetadata.findBox(type: "Exif", in: outer)
        XCTAssertEqual(found?.type, "Exif")
        XCTAssertEqual(found?.data, exifPayload)
    }

    // findBox must NOT descend into leaf boxes whose payloads are opaque
    // (mdat, Exif, iloc, ipma, ispe, colr, hvcC, …). Hide a well-formed
    // fake Exif child inside an mdat: the previous unconditional descent
    // would have surfaced it; the leaf-skip allowlist must treat mdat as
    // opaque.
    func testFindBoxDoesNotDescendIntoLeafBoxes() throws {
        let fakeExif = makeBox(type: "Exif", payload: Data([0x00, 0x00, 0x00, 0x00]))
        let mdatBox = makeBox(type: "mdat", payload: fakeExif)

        let outer = try ISOBMFFBoxReader.parseBoxes(from: mdatBox)
        XCTAssertEqual(outer.count, 1)
        XCTAssertEqual(outer[0].type, "mdat")
        XCTAssertNil(ISOBMFFMetadata.findBox(type: "Exif", in: outer))
    }

    private func makeBox(type: String, payload: Data) -> Data {
        precondition(type.utf8.count == 4)
        let total = 8 + payload.count
        precondition(total <= Int(UInt32.max))
        var w = BinaryWriter(capacity: total)
        w.writeUInt32BigEndian(UInt32(total))
        w.writeString(type, encoding: .ascii)
        w.writeBytes(payload)
        return w.data
    }
}
