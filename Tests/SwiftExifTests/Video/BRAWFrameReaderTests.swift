import XCTest
@testable import SwiftExif

/// Synthetic-fixture coverage for the per-frame BRAW readers. The big
/// existing first-frame test (`testParseBlackmagicRAWFirstFrameAttributes`
/// in MP4ParserTests) covers the bmdf decoder itself; these tests focus
/// on the multi-frame walker and the mebx vec3 decoder.
final class BRAWFrameReaderTests: XCTestCase {

    // MARK: - readAttributes (multi-frame bmdf walk)

    /// Build a file with three video chunks at known offsets, each
    /// carrying a distinct bmdf header, and assert readAttributes returns
    /// three frames in walk order with monotonic timestamps and the
    /// per-frame ISO values intact.
    func testReadAttributesAcrossMultipleFrames() throws {
        // Each frame's bmdf header. ISO + WB Kelvin vary per frame so we
        // can detect mis-ordering.
        let frame0 = makeBmdfBox(iso: 400, kelvin: 3200, tint: 5)
        let frame1 = makeBmdfBox(iso: 800, kelvin: 5600, tint: 10)
        let frame2 = makeBmdfBox(iso: 1600, kelvin: 6500, tint: 15)
        // Each chunk = bmdf header + a couple bytes of "image" pad so
        // every chunk has a stable size.
        let chunk0 = frame0 + Data([0x00, 0x00, 0x00, 0x00])
        let chunk1 = frame1 + Data([0x00, 0x00, 0x00, 0x00])
        let chunk2 = frame2 + Data([0x00, 0x00, 0x00, 0x00])
        let mdatPayload = chunk0 + chunk1 + chunk2
        let mdatBox = buildBox("mdat", data: mdatPayload)

        // Build the trak. Codec FourCC must start with "br" to engage
        // the BRAW path; brhq is the canonical High Quality variant.
        let visualFields = Data(repeating: 0, count: 78)
        let brhqEntry = buildBox("brhq", data: visualFields)
        var stsdW = BinaryWriter(capacity: 32 + brhqEntry.count)
        stsdW.writeBytes([0, 0, 0, 0]); stsdW.writeUInt32BigEndian(1)
        stsdW.writeBytes(brhqEntry)
        let stsdBox = buildBox("stsd", data: stsdW.data)

        // stco listing the three chunk offsets — computed from the
        // ftyp(16) + mdat header(8) prefix.
        let chunkBase: UInt32 = 16 + 8
        let off0 = chunkBase
        let off1 = off0 + UInt32(chunk0.count)
        let off2 = off1 + UInt32(chunk1.count)
        var stcoW = BinaryWriter(capacity: 32)
        stcoW.writeBytes([0, 0, 0, 0]); stcoW.writeUInt32BigEndian(3)
        stcoW.writeUInt32BigEndian(off0)
        stcoW.writeUInt32BigEndian(off1)
        stcoW.writeUInt32BigEndian(off2)
        let stcoBox = buildBox("stco", data: stcoW.data)

        // stts: 3 samples, delta = 1001 ticks each, mdhd timescale 24000
        // → 23.976 fps ≈ 41.7 ms per frame.
        var sttsW = BinaryWriter(capacity: 16)
        sttsW.writeBytes([0, 0, 0, 0]); sttsW.writeUInt32BigEndian(1)
        sttsW.writeUInt32BigEndian(3); sttsW.writeUInt32BigEndian(1001)
        let sttsBox = buildBox("stts", data: sttsW.data)

        let mdhdBox = makeMdhdBox(timescale: 24000, duration: 3003)
        let hdlrBox = makeHdlrBox(handlerType: "vide")

        let stblBox = buildBox("stbl", data: stsdBox + sttsBox + stcoBox)
        let minfBox = buildBox("minf", data: stblBox)
        let mdiaBox = buildBox("mdia", data: mdhdBox + hdlrBox + minfBox)
        let trakBox = buildBox("trak", data: mdiaBox)

        var mvhd = BinaryWriter(capacity: 128)
        mvhd.writeBytes([0, 0, 0, 0])
        mvhd.writeUInt32BigEndian(0); mvhd.writeUInt32BigEndian(0)
        mvhd.writeUInt32BigEndian(24000); mvhd.writeUInt32BigEndian(3003)
        mvhd.writeBytes(Data(repeating: 0, count: 80))
        let mvhdBox = buildBox("mvhd", data: mvhd.data)
        let moovBox = buildBox("moov", data: mvhdBox + trakBox)

        var file = BinaryWriter(capacity: mdatBox.count + moovBox.count + 32)
        let ftyp = Data("isom".utf8) + Data([0, 0, 0, 0])
        file.writeUInt32BigEndian(UInt32(8 + ftyp.count))
        file.writeString("ftyp", encoding: .ascii); file.writeBytes(ftyp)
        XCTAssertEqual(file.count, 16, "ftyp must be exactly 16 bytes")
        file.writeBytes(mdatBox)
        file.writeBytes(moovBox)

        let frames = try BRAWFrameReader.readAttributes(from: file.data)
        XCTAssertEqual(frames.count, 3)

        XCTAssertEqual(frames[0].frameIndex, 0)
        XCTAssertEqual(frames[1].frameIndex, 1)
        XCTAssertEqual(frames[2].frameIndex, 2)

        XCTAssertEqual(frames[0].timestampSeconds, 0.0, accuracy: 0.0001)
        XCTAssertEqual(frames[1].timestampSeconds, 1001.0 / 24000.0, accuracy: 0.0001)
        XCTAssertEqual(frames[2].timestampSeconds, 2002.0 / 24000.0, accuracy: 0.0001)

        XCTAssertEqual(frames[0].iso, 400)
        XCTAssertEqual(frames[1].iso, 800)
        XCTAssertEqual(frames[2].iso, 1600)
        XCTAssertEqual(frames[0].whiteBalanceKelvin, 3200)
        XCTAssertEqual(frames[1].whiteBalanceKelvin, 5600)
        XCTAssertEqual(frames[2].whiteBalanceKelvin, 6500)
    }

    /// readAttributes throws when the file isn't BRAW (no `br*` codec).
    func testReadAttributesNonBRAWThrows() throws {
        let file = buildAVCWrapper()
        XCTAssertThrowsError(try BRAWFrameReader.readAttributes(from: file))
    }

    // MARK: - readMotionSamples (mebx vec3 walker)

    /// Build an mebx track with three samples (each [size=20][mogy][3×f32 LE])
    /// and assert vec3s + timestamps round-trip.
    func testReadGyroscopeMotionSamples() throws {
        let vecs: [(Float, Float, Float)] = [
            (-0.005593, -0.004719, 0.004697),
            (-0.006924, -0.001999, 0.001088),
            (-0.003728, -0.007796, 0.000020),
        ]
        let samples = vecs.map { v in makeMebxSample(keyID: "mogy", x: v.0, y: v.1, z: v.2) }
        let mdatPayload = samples.reduce(Data(), +)
        let mdatBox = buildBox("mdat", data: mdatPayload)

        // First chunk offset = 16 (ftyp) + 8 (mdat header) = 24.
        let firstOff: UInt32 = 16 + 8
        let trakBox = makeMebxTrak(
            namespace: "com.blackmagicdesign.motiondata.gyroscope",
            firstChunkOffset: firstOff,
            sampleCount: 3,
            sampleSize: 20,
            // mdhd timescale 1000; sample delta 1 → samples at 0, 1, 2 ms.
            mdhdTimescale: 1000,
            sttsDelta: 1
        )

        let mvhdBox = makeMvhdBox(timescale: 1000, duration: 3)
        let moovBox = buildBox("moov", data: mvhdBox + trakBox)

        var file = BinaryWriter(capacity: 256 + mdatBox.count + moovBox.count)
        let ftyp = Data("isom".utf8) + Data([0, 0, 0, 0])
        file.writeUInt32BigEndian(UInt32(8 + ftyp.count))
        file.writeString("ftyp", encoding: .ascii); file.writeBytes(ftyp)
        XCTAssertEqual(file.count, 16)
        file.writeBytes(mdatBox); file.writeBytes(moovBox)

        let result = try BRAWFrameReader.readMotionSamples(from: file.data, stream: .gyroscope)
        XCTAssertEqual(result.count, 3)
        for (i, expected) in vecs.enumerated() {
            XCTAssertEqual(result[i].x, expected.0, accuracy: 1e-6, "x mismatch on sample \(i)")
            XCTAssertEqual(result[i].y, expected.1, accuracy: 1e-6, "y mismatch on sample \(i)")
            XCTAssertEqual(result[i].z, expected.2, accuracy: 1e-6, "z mismatch on sample \(i)")
            XCTAssertEqual(result[i].timestampSeconds, Double(i) / 1000.0, accuracy: 1e-9)
        }
    }

    /// Asking for the accelerometer stream when only gyroscope is present
    /// should return an empty array (not throw, not return wrong data).
    func testReadMotionSamplesAccelerometerAbsent() throws {
        let samples = [makeMebxSample(keyID: "mogy", x: 0, y: 0, z: 0)]
        let mdatBox = buildBox("mdat", data: samples.reduce(Data(), +))
        let trakBox = makeMebxTrak(
            namespace: "com.blackmagicdesign.motiondata.gyroscope",
            firstChunkOffset: 16 + 8,
            sampleCount: 1,
            sampleSize: 20,
            mdhdTimescale: 1000,
            sttsDelta: 1
        )
        let moovBox = buildBox("moov", data: makeMvhdBox(timescale: 1000, duration: 1) + trakBox)

        var file = BinaryWriter(capacity: 128 + mdatBox.count + moovBox.count)
        let ftyp = Data("isom".utf8) + Data([0, 0, 0, 0])
        file.writeUInt32BigEndian(UInt32(8 + ftyp.count))
        file.writeString("ftyp", encoding: .ascii); file.writeBytes(ftyp)
        file.writeBytes(mdatBox); file.writeBytes(moovBox)

        let result = try BRAWFrameReader.readMotionSamples(from: file.data, stream: .accelerometer)
        XCTAssertEqual(result, [])
    }

    /// A sample with the wrong key id (mismatch with the requested
    /// stream) should make the walker bail at that sample — partial read
    /// is more useful than a corrupt one.
    func testReadMotionSamplesBailsOnKeyIDMismatch() throws {
        // Two valid gyro samples followed by a bogus accel-key sample.
        var samples = [
            makeMebxSample(keyID: "mogy", x: 1.0, y: 2.0, z: 3.0),
            makeMebxSample(keyID: "mogy", x: 4.0, y: 5.0, z: 6.0),
            makeMebxSample(keyID: "moac", x: 7.0, y: 8.0, z: 9.0), // wrong key
        ]
        let mdatBox = buildBox("mdat", data: samples.reduce(Data(), +))
        let trakBox = makeMebxTrak(
            namespace: "com.blackmagicdesign.motiondata.gyroscope",
            firstChunkOffset: 16 + 8,
            sampleCount: 3,
            sampleSize: 20,
            mdhdTimescale: 1000,
            sttsDelta: 1
        )
        let moovBox = buildBox("moov", data: makeMvhdBox(timescale: 1000, duration: 3) + trakBox)
        var file = BinaryWriter(capacity: 256 + mdatBox.count + moovBox.count)
        let ftyp = Data("isom".utf8) + Data([0, 0, 0, 0])
        file.writeUInt32BigEndian(UInt32(8 + ftyp.count))
        file.writeString("ftyp", encoding: .ascii); file.writeBytes(ftyp)
        file.writeBytes(mdatBox); file.writeBytes(moovBox)
        _ = samples // silence unused-warning for the array literal

        let result = try BRAWFrameReader.readMotionSamples(from: file.data, stream: .gyroscope)
        XCTAssertEqual(result.count, 2, "must stop at the mismatched sample")
        XCTAssertEqual(result[0].x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(result[1].y, 5.0, accuracy: 1e-6)
    }

    // MARK: - Synthetic-fixture builders

    private func makeBmdfBox(iso: UInt32, kelvin: UInt32, tint: Int16) -> Data {
        // bmdf box: 8-byte lead-in pad, then isoe / wkel / wtin atoms.
        // Mirrors the real BMD layout closely enough to engage every
        // path in MP4Parser.decodeBRAWFrameHeader.
        var isoeBody = BinaryWriter(capacity: 4); isoeBody.writeUInt32BigEndian(iso)
        let isoeBox = buildBox("isoe", data: isoeBody.data)
        var wkelBody = BinaryWriter(capacity: 4); wkelBody.writeUInt32BigEndian(kelvin)
        let wkelBox = buildBox("wkel", data: wkelBody.data)
        var wtinBody = BinaryWriter(capacity: 2)
        wtinBody.writeUInt16BigEndian(UInt16(bitPattern: tint))
        let wtinBox = buildBox("wtin", data: wtinBody.data)
        let payload = Data(repeating: 0, count: 8) + isoeBox + wkelBox + wtinBox
        return buildBox("bmdf", data: payload)
    }

    /// Emit one mebx sample: [uint32 BE size=20][4-byte ASCII key][3× float32 LE].
    private func makeMebxSample(keyID: String, x: Float, y: Float, z: Float) -> Data {
        var w = BinaryWriter(capacity: 20)
        w.writeUInt32BigEndian(20)
        w.writeString(keyID, encoding: .ascii)
        // Apple QT writes timed-metadata vec3 as little-endian; BMD
        // followed suit despite the rest of the container being BE.
        w.writeUInt32LittleEndian(x.bitPattern)
        w.writeUInt32LittleEndian(y.bitPattern)
        w.writeUInt32LittleEndian(z.bitPattern)
        return w.data
    }

    private func makeMebxTrak(
        namespace: String,
        firstChunkOffset: UInt32,
        sampleCount: UInt32,
        sampleSize: UInt32,
        mdhdTimescale: UInt32,
        sttsDelta: UInt32
    ) -> Data {
        // mebx sample entry payload: 8-byte SampleEntry header + a `keys`
        // child wrapping a `keyd` declaration with the BMD namespace.
        let nsBytes = Data(namespace.utf8)
        let keydBox = buildBox("keyd", data: nsBytes)
        let keysBox = buildBox("keys", data: keydBox)
        let mebxPayload = Data(repeating: 0, count: 8) + keysBox
        let mebxEntry = buildBox("mebx", data: mebxPayload)

        var stsdW = BinaryWriter(capacity: 16 + mebxEntry.count)
        stsdW.writeBytes([0, 0, 0, 0]); stsdW.writeUInt32BigEndian(1)
        stsdW.writeBytes(mebxEntry)
        let stsdBox = buildBox("stsd", data: stsdW.data)

        // stts: single entry, all samples uniform.
        var sttsW = BinaryWriter(capacity: 16)
        sttsW.writeBytes([0, 0, 0, 0]); sttsW.writeUInt32BigEndian(1)
        sttsW.writeUInt32BigEndian(sampleCount)
        sttsW.writeUInt32BigEndian(sttsDelta)
        let sttsBox = buildBox("stts", data: sttsW.data)

        // stsz: uniform size.
        var stszW = BinaryWriter(capacity: 12)
        stszW.writeBytes([0, 0, 0, 0])
        stszW.writeUInt32BigEndian(sampleSize)
        stszW.writeUInt32BigEndian(sampleCount)
        let stszBox = buildBox("stsz", data: stszW.data)

        // stsc: one entry — chunk 1 holds all `sampleCount` samples,
        // sample description index 1.
        var stscW = BinaryWriter(capacity: 16)
        stscW.writeBytes([0, 0, 0, 0]); stscW.writeUInt32BigEndian(1)
        stscW.writeUInt32BigEndian(1); stscW.writeUInt32BigEndian(sampleCount)
        stscW.writeUInt32BigEndian(1)
        let stscBox = buildBox("stsc", data: stscW.data)

        // stco: one chunk at firstChunkOffset.
        var stcoW = BinaryWriter(capacity: 12)
        stcoW.writeBytes([0, 0, 0, 0]); stcoW.writeUInt32BigEndian(1)
        stcoW.writeUInt32BigEndian(firstChunkOffset)
        let stcoBox = buildBox("stco", data: stcoW.data)

        let stblBox = buildBox("stbl", data: stsdBox + sttsBox + stszBox + stscBox + stcoBox)
        let minfBox = buildBox("minf", data: stblBox)

        let mdhdBox = makeMdhdBox(timescale: mdhdTimescale, duration: UInt32(sampleCount))
        // mebx tracks use handler "meta" so the mebx detector engages.
        let hdlrBox = makeHdlrBox(handlerType: "meta")
        let mdiaBox = buildBox("mdia", data: mdhdBox + hdlrBox + minfBox)
        return buildBox("trak", data: mdiaBox)
    }

    private func makeMdhdBox(timescale: UInt32, duration: UInt32) -> Data {
        // mdhd v0: version+flags(4) + creation(4) + modification(4) +
        //          timescale(4) + duration(4) + language(2) + reserved(2)
        var w = BinaryWriter(capacity: 24)
        w.writeBytes([0, 0, 0, 0])           // v0 + flags
        w.writeUInt32BigEndian(0)            // creation
        w.writeUInt32BigEndian(0)            // modification
        w.writeUInt32BigEndian(timescale)
        w.writeUInt32BigEndian(duration)
        w.writeBytes(Data(repeating: 0, count: 4)) // language + reserved
        return buildBox("mdhd", data: w.data)
    }

    private func makeMvhdBox(timescale: UInt32, duration: UInt32) -> Data {
        var mvhd = BinaryWriter(capacity: 128)
        mvhd.writeBytes([0, 0, 0, 0])
        mvhd.writeUInt32BigEndian(0); mvhd.writeUInt32BigEndian(0)
        mvhd.writeUInt32BigEndian(timescale); mvhd.writeUInt32BigEndian(duration)
        mvhd.writeBytes(Data(repeating: 0, count: 80))
        return buildBox("mvhd", data: mvhd.data)
    }

    private func makeHdlrBox(handlerType: String) -> Data {
        var w = BinaryWriter(capacity: 32)
        w.writeBytes([0, 0, 0, 0])
        w.writeBytes(Data(repeating: 0, count: 4))
        w.writeString(handlerType, encoding: .ascii)
        w.writeBytes(Data(repeating: 0, count: 12))
        return buildBox("hdlr", data: w.data)
    }

    /// Build a minimal mp4 with a single avc1 video track — used for the
    /// "non-BRAW throws" assertion.
    private func buildAVCWrapper() -> Data {
        let visualFields = Data(repeating: 0, count: 78)
        let avc1Entry = buildBox("avc1", data: visualFields)
        var stsdW = BinaryWriter(capacity: 16 + avc1Entry.count)
        stsdW.writeBytes([0, 0, 0, 0]); stsdW.writeUInt32BigEndian(1)
        stsdW.writeBytes(avc1Entry)
        let stsdBox = buildBox("stsd", data: stsdW.data)
        let stblBox = buildBox("stbl", data: stsdBox)
        let minfBox = buildBox("minf", data: stblBox)
        let hdlrBox = makeHdlrBox(handlerType: "vide")
        let mdhdBox = makeMdhdBox(timescale: 24000, duration: 1001)
        let mdiaBox = buildBox("mdia", data: mdhdBox + hdlrBox + minfBox)
        let trakBox = buildBox("trak", data: mdiaBox)
        let moovBox = buildBox("moov", data: makeMvhdBox(timescale: 24000, duration: 1001) + trakBox)
        var file = BinaryWriter(capacity: 128 + moovBox.count)
        let ftyp = Data("isom".utf8) + Data([0, 0, 0, 0])
        file.writeUInt32BigEndian(UInt32(8 + ftyp.count))
        file.writeString("ftyp", encoding: .ascii); file.writeBytes(ftyp)
        file.writeBytes(moovBox)
        return file.data
    }

    private func buildBox(_ type: String, data: Data) -> Data {
        var w = BinaryWriter(capacity: 8 + data.count)
        w.writeUInt32BigEndian(UInt32(8 + data.count))
        w.writeString(type, encoding: .ascii)
        w.writeBytes(data)
        return w.data
    }
}
