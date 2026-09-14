import XCTest
@testable import SwiftMediaMetadata

final class RTMDReaderTests: XCTestCase {

    /// Pins the memory fix's important behavior: track discovery must cross a
    /// non-empty, leading mdat to find a tail-placed moov, while the stco
    /// offset must still address the RTMD sample in the original file buffer.
    func testDiscoversTailMoovAndReadsSampleFromSkippedMdat() throws {
        let sample = makeRTMDSample(iso: 800)
        let mdat = box("mdat", payload: sample)
        let moov = box("moov", payload: makeRTMDTrack(sampleSize: sample.count, sampleOffset: 8))
        let file = mdat + moov

        XCTAssertTrue(RTMDReader.hasRTMDTrack(in: file))

        let attributes = try RTMDReader.readAttributes(from: file)
        XCTAssertEqual(attributes.count, 1)
        XCTAssertEqual(attributes[0].frameIndex, 0)
        XCTAssertEqual(attributes[0].timestampSeconds, 0)
        XCTAssertEqual(attributes[0].iso, 800)

        let snapshot = try XCTUnwrap(RTMDReader.firstFrameSnapshot(from: file))
        XCTAssertEqual(snapshot.iso, 800)
    }

    func testDiscoversRTMDTrackWhenMdatFollowsMoov() {
        let sample = makeRTMDSample(iso: 1_250)
        let provisionalTrack = makeRTMDTrack(sampleSize: sample.count, sampleOffset: 0)
        let moovSize = box("moov", payload: provisionalTrack).count
        let sampleOffset = moovSize + 8
        let moov = box(
            "moov",
            payload: makeRTMDTrack(sampleSize: sample.count, sampleOffset: sampleOffset)
        )
        let file = moov + box("mdat", payload: sample)

        XCTAssertTrue(RTMDReader.hasRTMDTrack(in: file))
        XCTAssertEqual(RTMDReader.firstFrameSnapshot(from: file)?.iso, 1_250)
    }

    func testRejectsTrackWithNonRTMDCodec() {
        let sample = makeRTMDSample(iso: 400)
        let track = makeRTMDTrack(
            sampleSize: sample.count,
            sampleOffset: 8,
            codec: "mett"
        )
        let file = box("mdat", payload: sample) + box("moov", payload: track)

        XCTAssertFalse(RTMDReader.hasRTMDTrack(in: file))
        XCTAssertNil(RTMDReader.firstFrameSnapshot(from: file))
    }

    func testSkippingParserPreservesNonMdatBoxesAndLargeSizeFlag() throws {
        let ftyp = box("ftyp", payload: Data("isom".utf8))
        let mdat = largeBox("mdat", payload: Data(repeating: 0xA5, count: 1_024))
        let moov = box("moov", payload: box("free", payload: Data([1, 2, 3])))
        let file = ftyp + mdat + moov

        let ordinary = try ISOBMFFBoxReader.parseBoxes(from: file)
        let skipping = try ISOBMFFBoxReader.parseTopLevelBoxesSkippingMdat(file)

        XCTAssertEqual(skipping.map(\.type), ordinary.map(\.type))
        XCTAssertEqual(skipping[0], ordinary[0])
        XCTAssertTrue(skipping[1].data.isEmpty)
        XCTAssertTrue(skipping[1].usesLargeSize)
        XCTAssertEqual(skipping[2], ordinary[2])
    }

    private func makeRTMDSample(iso: UInt32) -> Data {
        var writer = BinaryWriter(capacity: 10)
        writer.writeUInt16BigEndian(2) // RTMD header length
        writer.writeUInt16BigEndian(0xE301) // preferred ISO tag
        writer.writeUInt16BigEndian(4)
        writer.writeUInt32BigEndian(iso)
        return writer.data
    }

    private func makeRTMDTrack(
        sampleSize: Int,
        sampleOffset: Int,
        codec: String = "rtmd"
    ) -> Data {
        precondition(sampleSize <= Int(UInt32.max))
        precondition(sampleOffset <= Int(UInt32.max))

        var hdlr = BinaryWriter(capacity: 24)
        hdlr.writeBytes(Data(repeating: 0, count: 8))
        hdlr.writeString("meta", encoding: .ascii)
        hdlr.writeBytes(Data(repeating: 0, count: 12))

        var stsd = BinaryWriter(capacity: 24)
        stsd.writeBytes(Data(repeating: 0, count: 4))
        stsd.writeUInt32BigEndian(1)
        stsd.writeUInt32BigEndian(16)
        stsd.writeString(codec, encoding: .ascii)
        stsd.writeBytes(Data(repeating: 0, count: 4))

        var stts = BinaryWriter(capacity: 16)
        stts.writeBytes(Data(repeating: 0, count: 4))
        stts.writeUInt32BigEndian(1)
        stts.writeUInt32BigEndian(1)
        stts.writeUInt32BigEndian(1_000)

        var stsz = BinaryWriter(capacity: 16)
        stsz.writeBytes(Data(repeating: 0, count: 4))
        stsz.writeUInt32BigEndian(UInt32(sampleSize))
        stsz.writeUInt32BigEndian(1)

        var stsc = BinaryWriter(capacity: 20)
        stsc.writeBytes(Data(repeating: 0, count: 4))
        stsc.writeUInt32BigEndian(1)
        stsc.writeUInt32BigEndian(1)
        stsc.writeUInt32BigEndian(1)
        stsc.writeUInt32BigEndian(1)

        var stco = BinaryWriter(capacity: 12)
        stco.writeBytes(Data(repeating: 0, count: 4))
        stco.writeUInt32BigEndian(1)
        stco.writeUInt32BigEndian(UInt32(sampleOffset))

        var mdhd = BinaryWriter(capacity: 24)
        mdhd.writeBytes(Data(repeating: 0, count: 12))
        mdhd.writeUInt32BigEndian(1_000)
        mdhd.writeUInt32BigEndian(1_000)
        mdhd.writeBytes(Data(repeating: 0, count: 4))

        let stbl = box(
            "stbl",
            payload: box("stsd", payload: stsd.data)
                + box("stts", payload: stts.data)
                + box("stsz", payload: stsz.data)
                + box("stsc", payload: stsc.data)
                + box("stco", payload: stco.data)
        )
        let minf = box("minf", payload: stbl)
        let mdia = box(
            "mdia",
            payload: box("mdhd", payload: mdhd.data)
                + box("hdlr", payload: hdlr.data)
                + minf
        )
        return box("trak", payload: mdia)
    }

    private func box(_ type: String, payload: Data) -> Data {
        precondition(type.utf8.count == 4)
        precondition(payload.count <= Int(UInt32.max) - 8)
        var writer = BinaryWriter(capacity: 8 + payload.count)
        writer.writeUInt32BigEndian(UInt32(8 + payload.count))
        writer.writeString(type, encoding: .ascii)
        writer.writeBytes(payload)
        return writer.data
    }

    private func largeBox(_ type: String, payload: Data) -> Data {
        precondition(type.utf8.count == 4)
        var writer = BinaryWriter(capacity: 16 + payload.count)
        writer.writeUInt32BigEndian(1)
        writer.writeString(type, encoding: .ascii)
        writer.writeUInt64BigEndian(UInt64(16 + payload.count))
        writer.writeBytes(payload)
        return writer.data
    }
}
