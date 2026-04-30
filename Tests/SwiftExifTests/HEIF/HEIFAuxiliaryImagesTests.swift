import XCTest
@testable import SwiftExif

final class HEIFAuxiliaryImagesTests: XCTestCase {

    func testEnumerateHDRGainMap() throws {
        let urn = "urn:com:apple:photo:2020:aux:hdrgainmap"
        let data = buildHEIFFixture(auxItemID: 2, primaryItemID: 1, auxURN: urn)
        let heif = try HEIFParser.parse(data)
        let images = try HEIFAuxiliaryImages.enumerate(from: heif, fileData: data)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.itemID, 2)
        XCTAssertEqual(images.first?.primaryItemID, 1)
        XCTAssertEqual(images.first?.auxType, urn)
        XCTAssertEqual(images.first?.kind, .hdrGainMap)
    }

    func testEnumerateDepth() throws {
        let urn = "urn:com:apple:photo:2018:aux:disparity"
        let data = buildHEIFFixture(auxItemID: 3, primaryItemID: 1, auxURN: urn)
        let heif = try HEIFParser.parse(data)
        let images = try HEIFAuxiliaryImages.enumerate(from: heif, fileData: data)
        XCTAssertEqual(images.count, 1)
        // "disparity" doesn't match the depth/alpha keyword set; landing in `.other` is fine —
        // the URN is the load-bearing field, not the kind.
        XCTAssertEqual(images.first?.auxType, urn)
    }

    func testEnumerateStandardDepthURN() throws {
        // ISO/IEC 23008-12 standard URN suffix `:auxid:2` → depth.
        let urn = "urn:mpeg:hevc:2015:auxid:2"
        let data = buildHEIFFixture(auxItemID: 4, primaryItemID: 1, auxURN: urn)
        let heif = try HEIFParser.parse(data)
        let images = try HEIFAuxiliaryImages.enumerate(from: heif, fileData: data)
        XCTAssertEqual(images.first?.kind, .depth)
    }

    func testNoAuxlReferences() throws {
        let data = buildHEIFFixture(auxItemID: nil, primaryItemID: 1, auxURN: "")
        let heif = try HEIFParser.parse(data)
        let images = try HEIFAuxiliaryImages.enumerate(from: heif, fileData: data)
        XCTAssertEqual(images, [])
    }

    // MARK: - Fixture builder

    /// Build a minimal HEIF fixture with optional iref/auxl + iprp/ipco/auxC + iprp/ipma.
    /// Skips iinf (the auxiliary-image enumerator only needs iref + iprp).
    private func buildHEIFFixture(auxItemID: UInt32?, primaryItemID: UInt32, auxURN: String) -> Data {
        var meta = Data([0x00, 0x00, 0x00, 0x00]) // FullBox header

        if let auxID = auxItemID {
            // iref (FullBox version 0): auxl box (UInt16 from_id + UInt16 count + UInt16 to_id)
            var auxl = BinaryWriter(capacity: 8)
            auxl.writeUInt16BigEndian(UInt16(auxID))
            auxl.writeUInt16BigEndian(1)
            auxl.writeUInt16BigEndian(UInt16(primaryItemID))
            let auxlBox = makeBox("auxl", payload: auxl.data)

            var irefPayload = Data([0x00, 0x00, 0x00, 0x00]) // version 0 + flags
            irefPayload.append(auxlBox)
            meta.append(makeBox("iref", payload: irefPayload))

            // iprp { ipco { auxC }, ipma }
            var auxCPayload = Data([0x00, 0x00, 0x00, 0x00]) // version + flags
            auxCPayload.append(Data(auxURN.utf8))
            auxCPayload.append(0x00) // null terminator
            let auxCBox = makeBox("auxC", payload: auxCPayload)

            let ipcoBox = makeBox("ipco", payload: auxCBox)

            // ipma version 0 flags 0: 8-bit indices, 16-bit item_ids
            var ipma = BinaryWriter(capacity: 16)
            ipma.writeBytes([0x00, 0x00, 0x00, 0x00]) // version + flags
            ipma.writeUInt32BigEndian(1)              // entry_count
            ipma.writeUInt16BigEndian(UInt16(auxID))  // item_ID
            ipma.writeUInt8(1)                        // association_count
            ipma.writeUInt8(0x01)                     // property_index 1 (essential bit clear)
            let ipmaBox = makeBox("ipma", payload: ipma.data)

            var iprpPayload = Data()
            iprpPayload.append(ipcoBox)
            iprpPayload.append(ipmaBox)
            meta.append(makeBox("iprp", payload: iprpPayload))
        }

        var data = Data()
        data.append(makeBox("ftyp", payload: Data("heicheic".utf8) + Data([0x00, 0x00, 0x00, 0x00])))
        data.append(makeBox("meta", payload: meta))
        return data
    }

    private func makeBox(_ type: String, payload: Data) -> Data {
        var writer = BinaryWriter(capacity: 8 + payload.count)
        writer.writeUInt32BigEndian(UInt32(8 + payload.count))
        writer.writeString(type, encoding: .ascii)
        writer.writeBytes(payload)
        return writer.data
    }
}
