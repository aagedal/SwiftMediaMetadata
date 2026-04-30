import XCTest
@testable import SwiftExif

/// Unit tests for `MXFReader`'s descriptor- and MCA-decoding internals,
/// driven by hand-built local-set bytes. Existing coverage in
/// `VideoContainerTests` exercises the outer KLV walk + magic detection;
/// this file targets the per-descriptor parsers that turn local-tag/length
/// /value triplets into stream metadata, plus the SMPTE ST 377-4 Multi-
/// Channel Audio helpers that have no other isolated coverage.
final class MXFReaderTests: XCTestCase {

    // MARK: - A. Local-set walker (foundation)

    func testWalkLocalSetIteratesTagLengthValueTriplets() {
        var data = Data()
        data.append(localTagLV(0x0A0B, value: Data([0x11, 0x22])))
        data.append(localTagLV(0x0C0D, value: Data([0x33, 0x44, 0x55])))
        data.append(localTagLV(0x0E0F, value: Data([])))

        var seen: [(UInt16, Data)] = []
        MXFReader.walkLocalSet(data) { tag, value in
            seen.append((tag, value))
        }
        XCTAssertEqual(seen.count, 3)
        XCTAssertEqual(seen[0].0, 0x0A0B)
        XCTAssertEqual(seen[0].1, Data([0x11, 0x22]))
        XCTAssertEqual(seen[1].0, 0x0C0D)
        XCTAssertEqual(seen[1].1, Data([0x33, 0x44, 0x55]))
        XCTAssertEqual(seen[2].0, 0x0E0F)
        XCTAssertEqual(seen[2].1, Data())
    }

    func testWalkLocalSetBailsOnTruncatedLength() {
        // Tag + declared length=0xFFFF but only 3 bytes follow → bail cleanly,
        // emit no callback for the malformed triplet.
        var data = Data()
        data.append(localTagLV(0x0001, value: Data([0xAA])))
        data.append(uint16BE(0x0002))
        data.append(uint16BE(0xFFFF))
        data.append(Data([0xBB, 0xCC, 0xDD]))

        var tags: [UInt16] = []
        MXFReader.walkLocalSet(data) { tag, _ in tags.append(tag) }
        XCTAssertEqual(tags, [0x0001])
    }

    func testWalkLocalSetIgnoresTrailingBytesUnder4() {
        var data = Data()
        data.append(localTagLV(0x0001, value: Data([0xAA])))
        data.append(Data([0xFF, 0xFF, 0xFF])) // 3 stray bytes — too short for another header
        var tags: [UInt16] = []
        MXFReader.walkLocalSet(data) { tag, _ in tags.append(tag) }
        XCTAssertEqual(tags, [0x0001])
    }

    // MARK: - B. Picture descriptor — codec UL mapping

    func testParsePictureDescriptorMapsAVCULToAvc1() {
        let body = localTagLV(0x3201, value: pictureCodingUL(kind: 0x04, variant: 0x31))
        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.codec, "avc1")
        XCTAssertEqual(stream.codecName, "H.264 / AVC")
    }

    func testParsePictureDescriptorMapsHEVCULToHvc1() {
        let body = localTagLV(0x3201, value: pictureCodingUL(kind: 0x04, variant: 0x32))
        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.codec, "hvc1")
        XCTAssertEqual(stream.codecName, "H.265 / HEVC")
    }

    func testParsePictureDescriptorMapsProResUL() {
        let body = localTagLV(0x3201, value: pictureCodingUL(kind: 0x04, variant: 0x41))
        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.codec, "apch")
        XCTAssertEqual(stream.codecName, "Apple ProRes")
    }

    func testParsePictureDescriptorMapsJPEG2000UL() {
        let body = localTagLV(0x3201, value: pictureCodingUL(kind: 0x04, variant: 0x0A))
        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.codec, "j2k")
        XCTAssertEqual(stream.codecName, "JPEG 2000")
    }

    func testParsePictureDescriptorMapsMPEG2UL() {
        let body = localTagLV(0x3201, value: pictureCodingUL(kind: 0x04, variant: 0x01))
        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.codec, "mpeg2video")
        XCTAssertEqual(stream.codecName, "MPEG-2 Video")
    }

    func testParsePictureDescriptorDetectsAVCIntraHigh10() {
        // AVC-Intra ULs use kind=0x02, variant=0x32, byte14 high nibble 0x20.
        let ul = pictureCodingUL(kind: 0x02, variant: 0x32, byte14: 0x21)
        let body = localTagLV(0x3201, value: ul)
        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.codec, "avc1")
        XCTAssertEqual(stream.profile, "High 10 Intra")
    }

    func testParsePictureDescriptorDetectsAVCIntraHigh422() {
        let ul = pictureCodingUL(kind: 0x02, variant: 0x32, byte14: 0x33)
        let body = localTagLV(0x3201, value: ul)
        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.codec, "avc1")
        XCTAssertEqual(stream.profile, "High 4:2:2 Intra")
    }

    // MARK: - C. Picture descriptor — dimensions, frame rate, duration

    func testParsePictureDescriptorReadsStoredAndDisplayDimensions() {
        var body = Data()
        body.append(localTagLV(0x3203, value: uint32BE(1920))) // StoredWidth
        body.append(localTagLV(0x3202, value: uint32BE(1080))) // StoredHeight
        body.append(localTagLV(0x3209, value: uint32BE(1920))) // DisplayWidth
        body.append(localTagLV(0x3208, value: uint32BE(1080))) // DisplayHeight

        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.width, 1920)
        XCTAssertEqual(stream.height, 1080)
        XCTAssertEqual(stream.displayWidth, 1920)
        XCTAssertEqual(stream.displayHeight, 1080)
    }

    func testParsePictureDescriptorComputesFrameRateFromSampleRateRational() {
        let body = localTagLV(0x3001, value: rational(30000, 1001))

        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertNotNil(stream.frameRate)
        XCTAssertEqual(stream.frameRate ?? 0, 29.97, accuracy: 0.01)
    }

    func testParsePictureDescriptorComputesDurationFromContainerDurationAndFrameRate() {
        var body = Data()
        body.append(localTagLV(0x3001, value: rational(25, 1)))           // 25 fps
        body.append(localTagLV(0x3002, value: uint64BE(2500)))            // 2500 frames

        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertNotNil(stream.duration)
        XCTAssertEqual(stream.duration ?? 0, 100.0, accuracy: 0.001)
        XCTAssertEqual(duration ?? 0, 100.0, accuracy: 0.001)
        XCTAssertEqual(stream.frameCount, 2500)
    }

    func testParsePictureDescriptorDoesNotSetDurationWhenSampleRateMissing() {
        let body = localTagLV(0x3002, value: uint64BE(1000))

        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertNil(stream.duration)
        XCTAssertNil(duration)
        XCTAssertNil(stream.frameCount)
    }

    // MARK: - D. Picture descriptor — frame layout / field order

    func testParsePictureDescriptorMapsProgressiveLayout() {
        var body = Data()
        body.append(localTagLV(0x3202, value: uint32BE(1080)))
        body.append(localTagLV(0x320C, value: Data([0x00]))) // FrameLayout=0

        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.fieldOrder, .progressive)
        XCTAssertEqual(stream.height, 1080)
    }

    func testParsePictureDescriptorMapsInterlacedTFFFromDominance() {
        var body = Data()
        body.append(localTagLV(0x3202, value: uint32BE(540)))   // field height
        body.append(localTagLV(0x320C, value: Data([0x01])))    // FrameLayout=SeparateFields
        body.append(localTagLV(0x3212, value: Data([0x01])))    // FieldDominance=top-first

        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.fieldOrder, .topFieldFirst)
        XCTAssertEqual(stream.height, 1080) // doubled to frame height
    }

    func testParsePictureDescriptorMapsInterlacedBFFFromDominance() {
        var body = Data()
        body.append(localTagLV(0x3202, value: uint32BE(288)))
        body.append(localTagLV(0x320C, value: Data([0x01])))
        body.append(localTagLV(0x3212, value: Data([0x02])))

        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.fieldOrder, .bottomFieldFirst)
        XCTAssertEqual(stream.height, 576)
    }

    func testParsePictureDescriptorDefaultsInterlacedToTFFWithoutDominance() {
        var body = Data()
        body.append(localTagLV(0x3202, value: uint32BE(540)))
        body.append(localTagLV(0x320C, value: Data([0x01])))

        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.fieldOrder, .topFieldFirst)
    }

    func testParsePictureDescriptorMapsPsFAsProgressive() {
        var body = Data()
        body.append(localTagLV(0x3202, value: uint32BE(540)))
        body.append(localTagLV(0x320C, value: Data([0x04]))) // FrameLayout=4 (PsF)

        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.fieldOrder, .progressive)
        XCTAssertEqual(stream.height, 1080) // PsF doubles height too
    }

    // MARK: - E. Picture descriptor — chroma subsampling

    func testParsePictureDescriptorDerives420From2x2() {
        let body = chromaBody(horizontal: 2, vertical: 2)
        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.chromaSubsampling, "4:2:0")
    }

    func testParsePictureDescriptorDerives422From2x1() {
        let body = chromaBody(horizontal: 2, vertical: 1)
        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.chromaSubsampling, "4:2:2")
    }

    func testParsePictureDescriptorDerives444From1x1() {
        let body = chromaBody(horizontal: 1, vertical: 1)
        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.chromaSubsampling, "4:4:4")
    }

    func testParsePictureDescriptorLeavesChromaNilForUnknownSubsampling() {
        let body = chromaBody(horizontal: 4, vertical: 1)
        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertNil(stream.chromaSubsampling)
    }

    // MARK: - F. Picture descriptor — aspect ratio override

    func testParsePictureDescriptorOverridesDARWhenAspectRatioPresent() {
        // Anamorphic SD: 1440×1080 storage, declared DAR 16:9 → SAR (16×1080)
        // / (9×1440) = 17280/12960 → reduced to 4:3.
        var body = Data()
        body.append(localTagLV(0x3203, value: uint32BE(1440)))
        body.append(localTagLV(0x3202, value: uint32BE(1080)))
        body.append(localTagLV(0x320E, value: rational(16, 9)))

        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.displayHeight, 1080)
        XCTAssertEqual(stream.displayWidth, 1920) // 1080 * 16 / 9
        if let par = stream.pixelAspectRatio {
            XCTAssertEqual(par.0, 4)
            XCTAssertEqual(par.1, 3)
        } else {
            XCTFail("expected pixelAspectRatio derived from DAR override")
        }
    }

    func testParsePictureDescriptorSkipsAspectRatioOverrideWhenZero() {
        var body = Data()
        body.append(localTagLV(0x3203, value: uint32BE(1920)))
        body.append(localTagLV(0x3202, value: uint32BE(1080)))
        body.append(localTagLV(0x320E, value: rational(0, 0)))

        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertNil(stream.pixelAspectRatio)
    }

    // MARK: - G. Picture descriptor — color UL mapping + bit depth

    func testParsePictureDescriptorMapsBT709ColorULs() {
        var body = Data()
        body.append(localTagLV(0x321A, value: colorUL(byte14: 0x01))) // primaries → 1 (BT.709)
        body.append(localTagLV(0x3210, value: colorUL(byte14: 0x01))) // transfer → 1
        body.append(localTagLV(0x3219, value: colorUL(byte14: 0x01))) // matrix → 1

        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.colorInfo?.primaries, 1)
        XCTAssertEqual(stream.colorInfo?.transfer, 1)
        XCTAssertEqual(stream.colorInfo?.matrix, 1)
    }

    func testParsePictureDescriptorMapsBT2020PQColorULs() {
        var body = Data()
        body.append(localTagLV(0x321A, value: colorUL(byte14: 0x06))) // primaries → 9
        body.append(localTagLV(0x3210, value: colorUL(byte14: 0x08))) // transfer → 16 (PQ)
        body.append(localTagLV(0x3219, value: colorUL(byte14: 0x06))) // matrix → 9

        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.colorInfo?.primaries, 9)
        XCTAssertEqual(stream.colorInfo?.transfer, 16)
        XCTAssertEqual(stream.colorInfo?.matrix, 9)
    }

    func testParsePictureDescriptorMapsHLGTransfer() {
        let body = localTagLV(0x3210, value: colorUL(byte14: 0x0B))
        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.colorInfo?.transfer, 18)
    }

    func testParsePictureDescriptorReadsBitDepth() {
        let body = localTagLV(0x3301, value: uint32BE(10))
        var stream = VideoStream(index: 0)
        var duration: TimeInterval? = nil
        MXFReader.parsePictureDescriptor(body, into: &stream, duration: &duration)
        XCTAssertEqual(stream.bitDepth, 10)
    }

    // MARK: - H. Sound descriptor

    func testParseSoundDescriptorReadsRationalSampleRate() {
        let body = localTagLV(0x3D03, value: rational(48000, 1))
        var stream = AudioStream(index: 0)
        MXFReader.parseSoundDescriptor(body, into: &stream)
        XCTAssertEqual(stream.sampleRate, 48000)
    }

    func testParseSoundDescriptorReadsChannelsAndBitDepth() {
        var body = Data()
        body.append(localTagLV(0x3D07, value: uint32BE(2)))
        body.append(localTagLV(0x3D01, value: uint32BE(24)))
        var stream = AudioStream(index: 0)
        MXFReader.parseSoundDescriptor(body, into: &stream)
        XCTAssertEqual(stream.channels, 2)
        XCTAssertEqual(stream.bitDepth, 24)
    }

    func testParseSoundDescriptorMapsPCMUL() {
        // kind=0x02 variant=0x02 → ("pcm_s16le", "PCM (WAVE/AES-3)").
        let body = localTagLV(0x3D06, value: pictureCodingUL(kind: 0x02, variant: 0x02))
        var stream = AudioStream(index: 0)
        MXFReader.parseSoundDescriptor(body, into: &stream)
        XCTAssertEqual(stream.codec, "pcm_s16le")
        XCTAssertEqual(stream.codecName, "PCM (WAVE/AES-3)")
    }

    func testParseSoundDescriptorDefaultsChannelLayoutFromSixChannels() {
        let body = localTagLV(0x3D07, value: uint32BE(6))
        var stream = AudioStream(index: 0)
        MXFReader.parseSoundDescriptor(body, into: &stream)
        XCTAssertEqual(stream.channelLayout, "5.1")
    }

    func testParseSoundDescriptorDefaultsChannelLayoutFromOneChannel() {
        let body = localTagLV(0x3D07, value: uint32BE(1))
        var stream = AudioStream(index: 0)
        MXFReader.parseSoundDescriptor(body, into: &stream)
        XCTAssertEqual(stream.channelLayout, "mono")
    }

    func testParseSoundDescriptorDefaultsChannelLayoutFromEightChannels() {
        let body = localTagLV(0x3D07, value: uint32BE(8))
        var stream = AudioStream(index: 0)
        MXFReader.parseSoundDescriptor(body, into: &stream)
        XCTAssertEqual(stream.channelLayout, "7.1")
    }

    // MARK: - I. Timecode component (SMPTE 12M)

    func testParseTimecodeComponentNonDropFrame() {
        var body = Data()
        body.append(localTagLV(0x1501, value: int64BE(3600)))     // start
        body.append(localTagLV(0x1502, value: uint16BE(24)))      // base
        body.append(localTagLV(0x1503, value: Data([0])))         // drop=false
        XCTAssertEqual(MXFReader.parseTimecodeComponent(body), "00:02:30:00")
    }

    func testParseTimecodeComponentDropFrame2997() {
        // 17982 frames at base=30 with drop=true is exactly framesPer10Min →
        // SMPTE 12M correction yields 18000 → "00:10:00;00".
        var body = Data()
        body.append(localTagLV(0x1501, value: int64BE(17982)))
        body.append(localTagLV(0x1502, value: uint16BE(30)))
        body.append(localTagLV(0x1503, value: Data([1])))
        XCTAssertEqual(MXFReader.parseTimecodeComponent(body), "00:10:00;00")
    }

    func testParseTimecodeComponentReturnsNilWhenBaseMissing() {
        let body = localTagLV(0x1501, value: int64BE(0))
        XCTAssertNil(MXFReader.parseTimecodeComponent(body))
    }

    func testParseTimecodeComponentReturnsNilWhenStartNegative() {
        var body = Data()
        body.append(localTagLV(0x1501, value: int64BE(-1)))
        body.append(localTagLV(0x1502, value: uint16BE(25)))
        XCTAssertNil(MXFReader.parseTimecodeComponent(body))
    }

    // MARK: - J. Set duration & track edit rate

    func testParseSetDurationReturnsLargestValue() {
        var body = Data()
        body.append(localTagLV(0x0202, value: uint64BE(100)))
        body.append(localTagLV(0x0202, value: uint64BE(2500)))
        body.append(localTagLV(0x0202, value: uint64BE(900)))
        XCTAssertEqual(MXFReader.parseSetDuration(body), 2500)
    }

    func testParseSetDurationReturnsNilWhenZero() {
        let body = localTagLV(0x0202, value: uint64BE(0))
        XCTAssertNil(MXFReader.parseSetDuration(body))
    }

    func testParseSetDurationIgnoresOversizedValuesAtIntMax() {
        // Value with the high bit set is > UInt64(Int.max) and must be rejected.
        let body = localTagLV(0x0202, value: uint64BE(0x8000_0000_0000_0001))
        XCTAssertNil(MXFReader.parseSetDuration(body))
    }

    func testParseTrackEditRateReadsRational() {
        let body = localTagLV(0x4B01, value: rational(25, 1))
        let rate = MXFReader.parseTrackEditRate(body)
        XCTAssertEqual(rate?.num, 25)
        XCTAssertEqual(rate?.den, 1)
    }

    func testParseTrackEditRateReturnsNilWithDenZero() {
        let body = localTagLV(0x4B01, value: rational(25, 0))
        XCTAssertNil(MXFReader.parseTrackEditRate(body))
    }

    // MARK: - K. BER length edge cases

    func testBERLengthZero() throws {
        var reader = BinaryReader(data: Data([0x00]))
        XCTAssertEqual(try MXFReader.readBERLength(&reader), 0)
    }

    func testBERLengthBoundary7F() throws {
        var reader = BinaryReader(data: Data([0x7F]))
        XCTAssertEqual(try MXFReader.readBERLength(&reader), 0x7F)
    }

    func testBERLengthSingleByteLongForm() throws {
        var reader = BinaryReader(data: Data([0x81, 0xFF]))
        XCTAssertEqual(try MXFReader.readBERLength(&reader), 0xFF)
    }

    func testBERLengthFourByteLongForm() throws {
        var reader = BinaryReader(data: Data([0x84, 0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(try MXFReader.readBERLength(&reader), 0x01020304)
    }

    // MARK: - L. MCA — KLV-key recognition

    func testMCASubDescriptorKindRecognizesChannelLabelKey() {
        let key = mcaSubDescriptorKey(byte14: 0x6B)
        XCTAssertEqual(MXFReader.mcaSubDescriptorKind(key), 0x6B)
    }

    func testMCASubDescriptorKindRecognizesSoundfieldGroupKey() {
        let key = mcaSubDescriptorKey(byte14: 0x6C)
        XCTAssertEqual(MXFReader.mcaSubDescriptorKind(key), 0x6C)
    }

    func testMCASubDescriptorKindRecognizesGroupOfGroupsKey() {
        let key = mcaSubDescriptorKey(byte14: 0x6D)
        XCTAssertEqual(MXFReader.mcaSubDescriptorKind(key), 0x6D)
    }

    func testMCASubDescriptorKindRejectsSoundDescriptorByte14() {
        let key = mcaSubDescriptorKey(byte14: 0x42)
        XCTAssertNil(MXFReader.mcaSubDescriptorKind(key))
    }

    func testIsPrimerPackKeyRecognizesPrefix() {
        let key: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
            0x0D, 0x01, 0x02, 0x01, 0x01, 0x05, 0x01, 0x00,
        ]
        XCTAssertTrue(MXFReader.isPrimerPackKey(Data(key)))

        var bad = key
        bad[0] = 0x07
        XCTAssertFalse(MXFReader.isPrimerPackKey(Data(bad)))
    }

    // MARK: - M. MCA — value decoding helpers

    func testDecodeUUIDDecodesSixteenBytes() {
        let uuid = UUID()
        let bytes = uuidData(uuid)
        XCTAssertEqual(MXFReader.decodeUUID(bytes), uuid)
    }

    func testDecodeUUIDArrayParsesCountAndItems() {
        let u1 = UUID(), u2 = UUID()
        var data = Data()
        data.append(uint32BE(2))
        data.append(uint32BE(16))
        data.append(uuidData(u1))
        data.append(uuidData(u2))
        XCTAssertEqual(MXFReader.decodeUUIDArray(data), [u1, u2])
    }

    func testDecodeUUIDArrayRejectsWrongItemLength() {
        var data = Data()
        data.append(uint32BE(2))
        data.append(uint32BE(8))
        data.append(Data(repeating: 0xAA, count: 16))
        XCTAssertEqual(MXFReader.decodeUUIDArray(data), [])
    }

    func testDecodeUUIDArrayCapsAtSafetyLimit() {
        // Declare 5000 items — well over the 4096 cap — and provide enough
        // valid UUID bytes that the parser would otherwise read all 5000.
        let count: UInt32 = 5000
        var data = Data()
        data.append(uint32BE(count))
        data.append(uint32BE(16))
        for _ in 0..<Int(count) {
            data.append(uuidData(UUID()))
        }
        let result = MXFReader.decodeUUIDArray(data)
        XCTAssertLessThanOrEqual(result.count, 4096)
        XCTAssertEqual(result.count, 4096)
    }

    func testDecodeUUIDArrayHandlesTruncatedTail() {
        // Declared count of 3 but only 2 UUIDs in the body → return the 2
        // we can read, no crash.
        var data = Data()
        data.append(uint32BE(3))
        data.append(uint32BE(16))
        data.append(uuidData(UUID()))
        data.append(uuidData(UUID()))
        XCTAssertEqual(MXFReader.decodeUUIDArray(data).count, 2)
    }

    func testDecodeUTF16BEStringStripsTrailingNUL() {
        let input = utf16BE("chL", appendNUL: true)
        XCTAssertEqual(MXFReader.decodeUTF16BEString(input), "chL")
    }

    func testDecodeUTF16BEStringHandlesNULOnly() {
        // 2 NUL bytes only → empty string (after NUL stripping).
        XCTAssertEqual(MXFReader.decodeUTF16BEString(Data([0x00, 0x00])), "")
    }

    func testDecodeUTF16BEStringRejectsSingleByte() {
        XCTAssertNil(MXFReader.decodeUTF16BEString(Data([0x00])))
    }

    func testDecodeASCIIOrUTF8StripsTrailingNULs() {
        let input = Data("en".utf8) + Data([0x00, 0x00, 0x00])
        XCTAssertEqual(MXFReader.decodeASCIIOrUTF8(input), "en")
    }

    func testDecodeASCIIOrUTF8ReturnsNilForAllNUL() {
        XCTAssertNil(MXFReader.decodeASCIIOrUTF8(Data([0x00, 0x00, 0x00])))
    }

    // MARK: - N. MCA — Primer Pack

    func testPrimerContextIngestsTagToULMappings() {
        // Mix one v0x0D (legacy ChannelID) and one v0x0E (bmxtools TagSymbol)
        // entry to prove the Primer accepts both dictionary versions.
        let primerBody = primerEntries([
            (0xA001, mcaPropertyULv0xD(body: (0x03, 0x02, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00))), // mcaChannelID
            (0xA002, mcaPropertyULv0xE(body: (0x01, 0x03, 0x07, 0x01, 0x02, 0x00, 0x00, 0x00))), // mcaTagSymbol
        ])
        var primer = MXFReader.PrimerContext()
        primer.ingest(primerBody)
        XCTAssertEqual(primer.property(for: 0xA001), .mcaChannelID)
        XCTAssertEqual(primer.property(for: 0xA002), .mcaTagSymbol)
    }

    func testPrimerContextRejectsWrongItemLength() {
        var data = Data()
        data.append(uint32BE(1))
        data.append(uint32BE(20)) // wrong (must be 18)
        data.append(uint16BE(0xA001))
        data.append(mcaPropertyULv0xE(body: (0x01, 0x03, 0x07, 0x01, 0x02, 0x00, 0x00, 0x00)))
        data.append(Data([0xFF, 0xFF])) // padding to make item physically 20 bytes
        var primer = MXFReader.PrimerContext()
        primer.ingest(data)
        XCTAssertNil(primer.property(for: 0xA001))
    }

    func testPrimerContextSubDescriptorsTagDefaultsTo0x3F01() {
        let primer = MXFReader.PrimerContext()
        XCTAssertFalse(primer.subDescriptorsTagWasMapped)
        XCTAssertEqual(primer.subDescriptorsTag(), 0x3F01)
    }

    func testPrimerContextSubDescriptorsTagRespectsExplicitMapping() {
        let primerBody = primerEntries([
            (0x3FCC, mcaPropertyULuniversal(
                body: (0x06, 0x01, 0x01, 0x04, 0x06, 0x10, 0x00, 0x00))) // SubDescriptors UL
        ])
        var primer = MXFReader.PrimerContext()
        primer.ingest(primerBody)
        XCTAssertTrue(primer.subDescriptorsTagWasMapped)
        XCTAssertEqual(primer.subDescriptorsTag(), 0x3FCC)
    }

    // MARK: - O. MCA — `mcaProperty(forUL:)` registry

    func testMCAPropertyRecognizesUniversalInstanceUID() {
        let ul = mcaPropertyULuniversal(body: (0x01, 0x01, 0x15, 0x02, 0x00, 0x00, 0x00, 0x00))
        XCTAssertEqual(MXFReader.mcaProperty(forUL: ul), .instanceUID)
    }

    func testMCAPropertyRecognizesUniversalSubDescriptors() {
        let ul = mcaPropertyULuniversal(body: (0x06, 0x01, 0x01, 0x04, 0x06, 0x10, 0x00, 0x00))
        XCTAssertEqual(MXFReader.mcaProperty(forUL: ul), .subDescriptors)
    }

    func testMCAPropertyRecognizesV0xDLegacyULs() {
        // Spot-check the eight v0x0D body patterns.
        let cases: [((UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8), MXFReader.MCAProperty)] = [
            ((0x03, 0x02, 0x01, 0x02, 0x01, 0x00, 0x00, 0x00), .mcaLabelDictionaryID),
            ((0x03, 0x02, 0x01, 0x02, 0x03, 0x00, 0x00, 0x00), .mcaTagSymbol),
            ((0x03, 0x02, 0x01, 0x02, 0x04, 0x00, 0x00, 0x00), .mcaTagName),
            ((0x03, 0x02, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00), .mcaChannelID),
            ((0x01, 0x01, 0x15, 0x10, 0x00, 0x00, 0x00, 0x00), .mcaLinkID),
            ((0x01, 0x01, 0x15, 0x11, 0x00, 0x00, 0x00, 0x00), .soundfieldGroupLinkID),
            ((0x01, 0x04, 0x15, 0x12, 0x00, 0x00, 0x00, 0x00), .groupOfGroupsLinkID),
            ((0x03, 0x01, 0x01, 0x02, 0x03, 0x15, 0x00, 0x00), .rfc5646SpokenLanguage),
        ]
        for (body, expected) in cases {
            XCTAssertEqual(MXFReader.mcaProperty(forUL: mcaPropertyULv0xD(body: body)), expected,
                           "v0x0D body \(body) should map to \(expected)")
        }
    }

    func testMCAPropertyRecognizesV0xEBmxtoolsULs() {
        let cases: [((UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8), MXFReader.MCAProperty)] = [
            ((0x01, 0x03, 0x07, 0x01, 0x01, 0x00, 0x00, 0x00), .mcaLabelDictionaryID),
            ((0x01, 0x03, 0x07, 0x01, 0x02, 0x00, 0x00, 0x00), .mcaTagSymbol),
            ((0x01, 0x03, 0x07, 0x01, 0x03, 0x00, 0x00, 0x00), .mcaTagName),
            ((0x01, 0x03, 0x07, 0x01, 0x04, 0x00, 0x00, 0x00), .groupOfGroupsLinkID),
            ((0x01, 0x03, 0x07, 0x01, 0x05, 0x00, 0x00, 0x00), .mcaLinkID),
            ((0x01, 0x03, 0x07, 0x01, 0x06, 0x00, 0x00, 0x00), .soundfieldGroupLinkID),
            ((0x01, 0x03, 0x07, 0x01, 0x07, 0x00, 0x00, 0x00), .mcaChannelID),
        ]
        for (body, expected) in cases {
            XCTAssertEqual(MXFReader.mcaProperty(forUL: mcaPropertyULv0xE(body: body)), expected,
                           "v0x0E body \(body) should map to \(expected)")
        }
    }

    func testMCAPropertyRejectsNonSMPTEPrefix() {
        var ul = mcaPropertyULv0xE(body: (0x01, 0x03, 0x07, 0x01, 0x02, 0x00, 0x00, 0x00))
        ul[0] = 0x07 // break SMPTE prefix
        XCTAssertNil(MXFReader.mcaProperty(forUL: ul))
    }

    func testMCAPropertyRejectsUnknownBody() {
        let ul = mcaPropertyULv0xE(body: (0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x00, 0x00, 0x00))
        XCTAssertNil(MXFReader.mcaProperty(forUL: ul))
    }

    // MARK: - P. MCA — `parseMCASubDescriptor`

    func testParseMCASubDescriptorReadsLinkIDSymbolAndName() throws {
        let primerBody = primerEntries([
            (0xFF01, mcaPropertyULv0xE(body: (0x01, 0x03, 0x07, 0x01, 0x02, 0x00, 0x00, 0x00))), // tagSymbol
            (0xFF02, mcaPropertyULv0xE(body: (0x01, 0x03, 0x07, 0x01, 0x03, 0x00, 0x00, 0x00))), // tagName
            (0xFF03, mcaPropertyULv0xE(body: (0x01, 0x03, 0x07, 0x01, 0x05, 0x00, 0x00, 0x00))), // mcaLinkID
        ])
        var primer = MXFReader.PrimerContext()
        primer.ingest(primerBody)

        let instance = UUID()
        let link = UUID()
        var body = Data()
        body.append(localTagLV(0x3C0A, value: uuidData(instance)))
        body.append(localTagLV(0xFF01, value: utf16BE("chL", appendNUL: true)))
        body.append(localTagLV(0xFF02, value: utf16BE("Left", appendNUL: true)))
        body.append(localTagLV(0xFF03, value: uuidData(link)))

        let parsed = try XCTUnwrap(MXFReader.parseMCASubDescriptor(body, kind: 0x6B, primer: primer))
        XCTAssertEqual(parsed.instanceUID, instance)
        XCTAssertEqual(parsed.linkID, link)
        XCTAssertEqual(parsed.symbol, "chL")
        XCTAssertEqual(parsed.name, "Left")
    }

    func testParseMCASubDescriptorIgnoresUnmappedTags() {
        let primer = MXFReader.PrimerContext()
        var body = Data()
        body.append(localTagLV(0x3C0A, value: uuidData(UUID())))
        body.append(localTagLV(0xFF99, value: Data([0x01, 0x02, 0x03])))
        let parsed = MXFReader.parseMCASubDescriptor(body, kind: 0x6B, primer: primer)
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.symbol)
        XCTAssertNil(parsed?.name)
    }

    func testParseMCASubDescriptorReturnsNilWithoutInstanceUID() {
        let primer = MXFReader.PrimerContext()
        let body = localTagLV(0xFF01, value: utf16BE("chL", appendNUL: true))
        XCTAssertNil(MXFReader.parseMCASubDescriptor(body, kind: 0x6B, primer: primer))
    }

    func testParseMCASubDescriptorDecodesGroupOfGroupsLinkIDsArray() {
        let primerBody = primerEntries([
            (0xFFAA, mcaPropertyULv0xE(body: (0x01, 0x03, 0x07, 0x01, 0x04, 0x00, 0x00, 0x00))), // groupOfGroupsLinkID
        ])
        var primer = MXFReader.PrimerContext()
        primer.ingest(primerBody)

        let g1 = UUID(), g2 = UUID()
        var arr = Data()
        arr.append(uint32BE(2))
        arr.append(uint32BE(16))
        arr.append(uuidData(g1))
        arr.append(uuidData(g2))

        var body = Data()
        body.append(localTagLV(0x3C0A, value: uuidData(UUID())))
        body.append(localTagLV(0xFFAA, value: arr))

        let parsed = MXFReader.parseMCASubDescriptor(body, kind: 0x6C, primer: primer)
        XCTAssertEqual(parsed?.groupOfGroupsLinkIDs, [g1, g2])
    }

    // MARK: - Q. MCA — SubDescriptors UID extraction

    func testExtractSubDescriptorUIDsUsesPrimerMappedTag() {
        let primerBody = primerEntries([
            (0x4ABC, mcaPropertyULuniversal(
                body: (0x06, 0x01, 0x01, 0x04, 0x06, 0x10, 0x00, 0x00))) // SubDescriptors UL
        ])
        var primer = MXFReader.PrimerContext()
        primer.ingest(primerBody)

        let u1 = UUID(), u2 = UUID()
        var arr = Data()
        arr.append(uint32BE(2))
        arr.append(uint32BE(16))
        arr.append(uuidData(u1))
        arr.append(uuidData(u2))
        let body = localTagLV(0x4ABC, value: arr)

        XCTAssertEqual(MXFReader.extractSubDescriptorUIDs(from: body, primer: primer), [u1, u2])
    }

    func testExtractSubDescriptorUIDsFallsBackTo0x3F01WithoutPrimerMapping() {
        let primer = MXFReader.PrimerContext()
        let u1 = UUID()
        var arr = Data()
        arr.append(uint32BE(1))
        arr.append(uint32BE(16))
        arr.append(uuidData(u1))
        let body = localTagLV(0x3F01, value: arr)
        XCTAssertEqual(MXFReader.extractSubDescriptorUIDs(from: body, primer: primer), [u1])
    }

    // MARK: - R. MCA — assembly

    func testAssembleAudioLabelingResolvesChannelToTrackIndex() {
        let chUID = UUID()
        var fields = MXFReader.MCASetFields()
        fields.instanceUID = chUID
        fields.symbol = "chL"
        fields.name = "Left"

        var state = MXFReader.MCAState()
        state.channels[chUID] = fields
        state.soundDescriptorSubUIDs = [[chUID]]

        let labeling = MXFReader.assembleAudioLabeling(state: state)
        XCTAssertEqual(labeling.channels.count, 1)
        XCTAssertEqual(labeling.channels.first?.trackIndex, 0)
        XCTAssertEqual(labeling.channels.first?.symbol, "chL")
        XCTAssertEqual(labeling.channels.first?.name, "Left")
    }

    func testAssembleAudioLabelingPicksUpUnreferencedChannels() {
        let chUID = UUID()
        var fields = MXFReader.MCASetFields()
        fields.instanceUID = chUID
        fields.symbol = "chR"

        var state = MXFReader.MCAState()
        state.channels[chUID] = fields
        // No soundDescriptorSubUIDs entries → channel reachable only via fallback.

        let labeling = MXFReader.assembleAudioLabeling(state: state)
        XCTAssertEqual(labeling.channels.count, 1)
        XCTAssertNil(labeling.channels.first?.trackIndex)
        XCTAssertEqual(labeling.channels.first?.symbol, "chR")
    }

    func testAssembleAudioLabelingDeduplicatesAcrossTracksByLinkUID() {
        let chUID = UUID()
        var fields = MXFReader.MCASetFields()
        fields.instanceUID = chUID
        fields.symbol = "chC"

        var state = MXFReader.MCAState()
        state.channels[chUID] = fields
        // Same UID listed in two tracks' SubDescriptors arrays.
        state.soundDescriptorSubUIDs = [[chUID], [chUID]]

        let labeling = MXFReader.assembleAudioLabeling(state: state)
        XCTAssertEqual(labeling.channels.count, 1)
        XCTAssertEqual(labeling.channels.first?.trackIndex, 0)
    }

    // MARK: - Helpers

    private func localTagLV(_ tag: UInt16, value: Data) -> Data {
        precondition(value.count <= 0xFFFF)
        var out = Data()
        out.append(uint16BE(tag))
        out.append(uint16BE(UInt16(value.count)))
        out.append(value)
        return out
    }

    private func uint16BE(_ v: UInt16) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 2)
    }

    private func uint32BE(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 4)
    }

    private func uint64BE(_ v: UInt64) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 8)
    }

    private func int64BE(_ v: Int64) -> Data {
        return uint64BE(UInt64(bitPattern: v))
    }

    private func rational(_ num: UInt32, _ den: UInt32) -> Data {
        return uint32BE(num) + uint32BE(den)
    }

    private func uuidData(_ uuid: UUID) -> Data {
        let t = uuid.uuid
        return Data([
            t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7,
            t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15,
        ])
    }

    private func utf16BE(_ s: String, appendNUL: Bool = false) -> Data {
        var out = Data()
        for unit in s.utf16 {
            out.append(uint16BE(unit))
        }
        if appendNUL { out.append(contentsOf: [0x00, 0x00]) }
        return out
    }

    /// 16-byte picture/sound essence-coding UL with `kind` at byte 11,
    /// `variant` at byte 13, and `byte14` at byte 14 — the offsets read by
    /// `codecNameForUL` and `parsePictureDescriptor`'s AVC-Intra branch.
    private func pictureCodingUL(kind: UInt8, variant: UInt8, byte14: UInt8 = 0x00) -> Data {
        var bytes: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x01,
            0x04, 0x01, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00,
        ]
        bytes[11] = kind
        bytes[13] = variant
        bytes[14] = byte14
        return Data(bytes)
    }

    /// 16-byte color UL — only `byte14` matters for `colorULCode`.
    private func colorUL(byte14: UInt8) -> Data {
        var bytes: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x06,
            0x04, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00,
        ]
        bytes[14] = byte14
        return Data(bytes)
    }

    /// MCA subdescriptor KLV key (16 bytes) with an arbitrary `byte14`
    /// identifying the kind.
    private func mcaSubDescriptorKey(byte14: UInt8) -> Data {
        Data([
            0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01,
            0x0D, 0x01, 0x01, 0x01, 0x01, 0x01, byte14, 0x00,
        ])
    }

    /// 16-byte SMPTE UL where bytes 8..15 are a v0x0D dictionary body.
    /// First 8 bytes match `06 0E 2B 34 01 01 01 0D` (any SMPTE prefix that
    /// passes the `06 0E 2B 34` check used by `mcaProperty(forUL:)`).
    private func mcaPropertyULv0xD(body: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> Data {
        Data([
            0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x0D,
            body.0, body.1, body.2, body.3,
            body.4, body.5, body.6, body.7,
        ])
    }

    /// 16-byte SMPTE UL where bytes 8..15 are a v0x0E (bmxtools) body.
    private func mcaPropertyULv0xE(body: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> Data {
        Data([
            0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x02,
            body.0, body.1, body.2, body.3,
            body.4, body.5, body.6, body.7,
        ])
    }

    /// 16-byte SMPTE UL for the universal InstanceUID / SubDescriptors patterns.
    private func mcaPropertyULuniversal(body: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> Data {
        Data([
            0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x02,
            body.0, body.1, body.2, body.3,
            body.4, body.5, body.6, body.7,
        ])
    }

    /// Build a Primer Pack body from `(localTag, propertyUL)` entries.
    /// Layout: UInt32 count, UInt32 itemLen=18, count × (UInt16 tag + 16 UL).
    private func primerEntries(_ entries: [(UInt16, Data)]) -> Data {
        var out = Data()
        out.append(uint32BE(UInt32(entries.count)))
        out.append(uint32BE(18))
        for (tag, ul) in entries {
            precondition(ul.count == 16)
            out.append(uint16BE(tag))
            out.append(ul)
        }
        return out
    }

    /// Picture descriptor body carrying just chroma subsampling tags.
    private func chromaBody(horizontal: UInt32, vertical: UInt32) -> Data {
        var body = Data()
        body.append(localTagLV(0x3302, value: uint32BE(horizontal)))
        body.append(localTagLV(0x3308, value: uint32BE(vertical)))
        return body
    }
}
