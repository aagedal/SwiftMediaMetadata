import XCTest
@testable import SwiftExif

final class JUMBFParserTests: XCTestCase {

    // MARK: - Description Box Parsing

    func testParseDescriptionBox() throws {
        // Build a jumd payload: 16-byte UUID + toggles(0x03) + label "c2pa\0"
        var data = Data()
        // UUID: "c2pa" + C2PA suffix
        data.append(contentsOf: [0x63, 0x32, 0x70, 0x61]) // "c2pa"
        data.append(contentsOf: [0x00, 0x11, 0x00, 0x10, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        data.append(0x03) // toggles: requestable + label
        data.append(contentsOf: [0x63, 0x32, 0x70, 0x61, 0x00]) // "c2pa\0"

        let desc = try JUMBFParser.parseDescription(from: data)
        XCTAssertEqual(desc.uuidPrefix, "c2pa")
        XCTAssertEqual(desc.toggles, 0x03)
        XCTAssertEqual(desc.label, "c2pa")
        XCTAssertNil(desc.id)
    }

    func testParseDescriptionWithID() throws {
        var data = Data()
        // UUID
        data.append(contentsOf: [0x63, 0x32, 0x6D, 0x61]) // "c2ma"
        data.append(contentsOf: [0x00, 0x11, 0x00, 0x10, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        data.append(0x07) // toggles: requestable + label + ID
        data.append(contentsOf: [0x74, 0x65, 0x73, 0x74, 0x00]) // "test\0"
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x2A]) // ID = 42

        let desc = try JUMBFParser.parseDescription(from: data)
        XCTAssertEqual(desc.uuidPrefix, "c2ma")
        XCTAssertEqual(desc.label, "test")
        XCTAssertEqual(desc.id, 42)
    }

    func testDescriptionTooSmallThrows() {
        let data = Data(count: 10)
        XCTAssertThrowsError(try JUMBFParser.parseDescription(from: data))
    }

    // MARK: - UUID Matching

    func testIsC2PAUUID() {
        var uuid = Data([0x63, 0x32, 0x70, 0x61]) // "c2pa"
        uuid.append(contentsOf: [0x00, 0x11, 0x00, 0x10, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        XCTAssertTrue(JUMBFParser.isC2PAUUID(uuid, prefix: "c2pa"))
        XCTAssertFalse(JUMBFParser.isC2PAUUID(uuid, prefix: "c2ma"))
    }

    func testIsC2PAUUIDWrongSuffix() {
        var uuid = Data([0x63, 0x32, 0x70, 0x61]) // "c2pa"
        uuid.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertFalse(JUMBFParser.isC2PAUUID(uuid, prefix: "c2pa"))
    }

    func testIsC2PAUUIDTooShort() {
        let uuid = Data([0x63, 0x32, 0x70, 0x61])
        XCTAssertFalse(JUMBFParser.isC2PAUUID(uuid, prefix: "c2pa"))
    }

    // MARK: - Superbox Parsing

    func testParseSuperboxWithContentBoxes() throws {
        // Build a jumb box payload: jumd + cbor content box
        var payload = Data()

        // jumd box: size(4) + "jumd"(4) + payload
        let jumdPayload = buildJUMDPayload(prefix: "c2pa", label: "c2pa")
        appendBox(to: &payload, type: "jumd", data: jumdPayload)

        // cbor content box with simple data
        let cborData = Data([0xA0]) // empty map
        appendBox(to: &payload, type: "cbor", data: cborData)

        let superbox = try JUMBFParser.parseSuperbox(from: payload)
        XCTAssertEqual(superbox.description.label, "c2pa")
        XCTAssertEqual(superbox.contentBoxes.count, 1)
        XCTAssertEqual(superbox.contentBoxes.first?.type, "cbor")
        XCTAssertEqual(superbox.children.count, 0)
    }

    func testParseSuperboxWithNestedSuperbox() throws {
        var payload = Data()

        // Outer jumd
        let outerJumd = buildJUMDPayload(prefix: "c2pa", label: "c2pa")
        appendBox(to: &payload, type: "jumd", data: outerJumd)

        // Nested jumb (child manifest)
        var nestedPayload = Data()
        let nestedJumd = buildJUMDPayload(prefix: "c2ma", label: "urn:c2pa:test")
        appendBox(to: &nestedPayload, type: "jumd", data: nestedJumd)
        appendBox(to: &payload, type: "jumb", data: nestedPayload)

        let superbox = try JUMBFParser.parseSuperbox(from: payload)
        XCTAssertEqual(superbox.description.label, "c2pa")
        XCTAssertEqual(superbox.children.count, 1)
        XCTAssertEqual(superbox.children.first?.description.label, "urn:c2pa:test")
        XCTAssertTrue(JUMBFParser.isManifest(superbox.children.first!.description))
    }

    func testMissingJUMDThrows() {
        // A box list that doesn't start with jumd
        var payload = Data()
        appendBox(to: &payload, type: "cbor", data: Data([0xA0]))
        XCTAssertThrowsError(try JUMBFParser.parseSuperbox(from: payload))
    }

    // MARK: - APP11 Reassembly

    func testReassembleSingleAPP11Segment() throws {
        // Build a single APP11 segment containing JUMBF data
        var segmentData = Data()
        segmentData.append(contentsOf: [0x4A, 0x50]) // CI: "JP"
        segmentData.append(contentsOf: [0x00, 0x01]) // Instance number: 1
        segmentData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Sequence number: 1

        // JUMBF: a jumb box containing jumd with c2pa UUID
        var jumbfPayload = Data()
        let jumd = buildJUMDPayload(prefix: "c2pa", label: "c2pa")
        appendBox(to: &jumbfPayload, type: "jumd", data: jumd)
        var jumbfData = Data()
        appendBox(to: &jumbfData, type: "jumb", data: jumbfPayload)

        segmentData.append(jumbfData)

        let segment = JPEGSegment(marker: .app11, data: segmentData)
        let result = try JUMBFParser.reassembleFromAPP11([segment])
        XCTAssertNotNil(result)
    }

    func testReassembleMultipleAPP11Segments() throws {
        // Build a JUMBF payload that would span two segments
        var jumbfPayload = Data()
        let jumd = buildJUMDPayload(prefix: "c2pa", label: "c2pa")
        appendBox(to: &jumbfPayload, type: "jumd", data: jumd)
        var fullJUMBF = Data()
        appendBox(to: &fullJUMBF, type: "jumb", data: jumbfPayload)

        let splitPoint = fullJUMBF.count / 2

        // First segment
        var seg1Data = Data()
        seg1Data.append(contentsOf: [0x4A, 0x50]) // CI
        seg1Data.append(contentsOf: [0x00, 0x01]) // Instance
        seg1Data.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Seq 1
        seg1Data.append(Data(fullJUMBF.prefix(splitPoint)))

        // Second segment
        var seg2Data = Data()
        seg2Data.append(contentsOf: [0x4A, 0x50]) // CI
        seg2Data.append(contentsOf: [0x00, 0x01]) // Instance
        seg2Data.append(contentsOf: [0x00, 0x00, 0x00, 0x02]) // Seq 2
        // Duplicate box header
        seg2Data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // LBox placeholder
        seg2Data.append(contentsOf: [0x6A, 0x75, 0x6D, 0x62]) // TBox "jumb"
        seg2Data.append(Data(fullJUMBF.suffix(from: fullJUMBF.startIndex + splitPoint)))

        let segments = [
            JPEGSegment(marker: .app11, data: seg1Data),
            JPEGSegment(marker: .app11, data: seg2Data),
        ]
        let result = try JUMBFParser.reassembleFromAPP11(segments)
        XCTAssertNotNil(result)
    }

    func testReassembleNoAPP11ReturnsNil() throws {
        let result = try JUMBFParser.reassembleFromAPP11([])
        XCTAssertNil(result)
    }

    // MARK: - Helpers

    private func buildJUMDPayload(prefix: String, label: String) -> Data {
        var data = Data()
        data.append(contentsOf: [UInt8](prefix.utf8))
        data.append(contentsOf: [0x00, 0x11, 0x00, 0x10, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        data.append(0x03) // toggles: requestable + label
        data.append(contentsOf: [UInt8](label.utf8))
        data.append(0x00) // null terminator
        return data
    }

    private func appendBox(to data: inout Data, type: String, data payload: Data) {
        let size = UInt32(8 + payload.count)
        data.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
        data.append(type.data(using: .ascii)!)
        data.append(payload)
    }
}
