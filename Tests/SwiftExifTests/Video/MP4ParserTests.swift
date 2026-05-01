import XCTest
@testable import SwiftExif

final class MP4ParserTests: XCTestCase {

    // MARK: - Format Detection

    func testDetectMP4Format() {
        let data = buildMinimalMP4(brand: "isom")
        XCTAssertEqual(FormatDetector.detectVideo(data), .mp4)
    }

    func testDetectMOVFormat() {
        let data = buildMinimalMP4(brand: "qt  ")
        XCTAssertEqual(FormatDetector.detectVideo(data), .mov)
    }

    func testDetectM4VFormat() {
        let data = buildMinimalMP4(brand: "M4V ")
        XCTAssertEqual(FormatDetector.detectVideo(data), .m4v)
    }

    func testDetectVideoFromExtension() {
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("mp4"), .mp4)
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("mov"), .mov)
        XCTAssertEqual(FormatDetector.detectVideoFromExtension("m4v"), .m4v)
        XCTAssertNil(FormatDetector.detectVideoFromExtension("jpg"))
    }

    func testImageDetectorDoesNotMatchVideo() {
        let data = buildMinimalMP4(brand: "isom")
        XCTAssertNil(FormatDetector.detect(data)) // Image detector should not match
    }

    // MARK: - mvhd Parsing

    func testParseMVHDDuration() throws {
        let data = buildMP4WithMVHD(
            creationTime: UInt32(2082844800 + 1705312200), // 2024-01-15T10:30:00Z
            timescale: 1000,
            duration: 30000 // 30 seconds
        )
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.duration!, 30.0, accuracy: 0.01)
    }

    func testParseMVHDCreationDate() throws {
        // 2024-01-15T10:30:00Z in QuickTime epoch
        let qtSeconds: UInt32 = UInt32(2082844800 + 1705312200)
        let data = buildMP4WithMVHD(creationTime: qtSeconds, timescale: 600, duration: 18000)
        let metadata = try VideoMetadata.read(from: data)

        XCTAssertNotNil(metadata.creationDate)
        let expected = Date(timeIntervalSince1970: 1705312200)
        XCTAssertEqual(metadata.creationDate!.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Track Parsing

    func testParseVideoTrackDimensions() throws {
        let data = buildMP4WithTrack(width: 1920, height: 1080, handlerType: "vide", codec: "avc1")
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.videoWidth, 1920)
        XCTAssertEqual(metadata.videoHeight, 1080)
    }

    func testParseVideoCodec() throws {
        let data = buildMP4WithTrack(width: 3840, height: 2160, handlerType: "vide", codec: "hvc1")
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.videoCodec, "hvc1")
    }

    func testParseAudioCodec() throws {
        let data = buildMP4WithTrack(width: 0, height: 0, handlerType: "soun", codec: "mp4a")
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.audioCodec, "mp4a")
    }

    // MARK: - QuickTime Metadata (ilst)

    func testParseTitle() throws {
        let data = buildMP4WithMetadata(title: "Test Video", artist: nil, comment: nil, gps: nil)
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.title, "Test Video")
    }

    func testParseArtist() throws {
        let data = buildMP4WithMetadata(title: nil, artist: "John Doe", comment: nil, gps: nil)
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.artist, "John Doe")
    }

    func testParseComment() throws {
        let data = buildMP4WithMetadata(title: nil, artist: nil, comment: "A test comment", gps: nil)
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.comment, "A test comment")
    }

    // MARK: - GPS from ©xyz

    func testParseGPSFromXYZ() throws {
        let data = buildMP4WithMetadata(title: nil, artist: nil, comment: nil, gps: "+59.9139+010.7522/")
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.gpsLatitude!, 59.9139, accuracy: 0.0001)
        XCTAssertEqual(metadata.gpsLongitude!, 10.7522, accuracy: 0.0001)
    }

    func testParseGPSWithAltitude() {
        var metadata = VideoMetadata(format: .mp4)
        MP4Parser.parseGPSXYZ("+59.9139+010.7522+100.5/", into: &metadata)
        XCTAssertEqual(metadata.gpsLatitude!, 59.9139, accuracy: 0.0001)
        XCTAssertEqual(metadata.gpsLongitude!, 10.7522, accuracy: 0.0001)
        XCTAssertEqual(metadata.gpsAltitude!, 100.5, accuracy: 0.1)
    }

    func testParseNegativeGPS() {
        var metadata = VideoMetadata(format: .mp4)
        MP4Parser.parseGPSXYZ("-33.8688+151.2093/", into: &metadata)
        XCTAssertEqual(metadata.gpsLatitude!, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(metadata.gpsLongitude!, 151.2093, accuracy: 0.0001)
    }

    func testParseGPSBothNegative() {
        var metadata = VideoMetadata(format: .mp4)
        MP4Parser.parseGPSXYZ("-33.8688-073.9857/", into: &metadata)
        XCTAssertEqual(metadata.gpsLatitude!, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(metadata.gpsLongitude!, -73.9857, accuracy: 0.0001)
    }

    // MARK: - Error Handling

    func testGarbageDataThrows() {
        // Zero bytes parse into a single bogus zero-typed top-level box, then
        // the moov-required guard trips.
        let data = Data(repeating: 0x00, count: 50)
        XCTAssertThrowsError(try VideoMetadata.read(from: data))
    }

    func testMissingMoovThrows() {
        let data = buildMinimalMP4(brand: "isom") // ftyp only, no moov
        XCTAssertThrowsError(try VideoMetadata.read(from: data))
    }

    /// BRAW writes its full clip slate (camera_type, viewing_gamma,
    /// offspeed_frame_time, …) under moov.meta using the QuickTime
    /// non-FullBox layout. MP4Parser must (1) walk moov.meta — not just
    /// udta.meta or top-level meta, (2) detect the no-version-flags
    /// QuickTime layout, and (3) decode the typed `data` payloads (UTF-8,
    /// float32-BE, signed-int) into camera fields. This test stitches a
    /// minimal moov and asserts both the sensor-vs-project frame rates and
    /// the slate user-meta arrays land in CameraMetadata.
    func testParseBlackmagicRAWClipMetadata() throws {
        // 1) keys table — 1-based index lookup. Use just the keys we set.
        let keyList = [
            "manufacturer", "camera_type", "viewing_gamma",
            "offspeed_frame_time", "offspeed", "viewing_bmdgen",
            "braw_compression_ratio", "rotation", "lens_shading_enable",
            "tone_curve_contrast", "post_3dlut_embedded_size",
            "post_3dlut_embedded_data", "braw_codec_bitrate",
        ]
        var keysPayload = BinaryWriter(capacity: 256)
        keysPayload.writeBytes([0x00, 0x00, 0x00, 0x00]) // version+flags
        keysPayload.writeUInt32BigEndian(UInt32(keyList.count))
        for k in keyList {
            let bytes = Data(k.utf8)
            keysPayload.writeUInt32BigEndian(UInt32(8 + bytes.count))
            keysPayload.writeString("mdta", encoding: .ascii)
            keysPayload.writeBytes(bytes)
        }
        let keysBox = buildBox("keys", data: keysPayload.data)

        // 2) ilst items — each item is a box whose 4-byte type is the
        //    big-endian key index, wrapping a `data` box with type
        //    indicator + locale + payload.
        func makeItem(index: UInt32, typeIndicator: UInt32, payload: Data) -> Data {
            var d = BinaryWriter(capacity: 32 + payload.count)
            d.writeUInt32BigEndian(typeIndicator)
            d.writeUInt32BigEndian(0) // locale
            d.writeBytes(payload)
            let dataBox = buildBox("data", data: d.data)

            var itemBytes = BinaryWriter(capacity: 16 + dataBox.count)
            itemBytes.writeUInt32BigEndian(UInt32(8 + dataBox.count))
            // The "type" position carries a big-endian key index in this
            // namespace, not an ASCII FourCC.
            itemBytes.writeUInt32BigEndian(index)
            itemBytes.writeBytes(dataBox)
            return itemBytes.data
        }

        var ilstPayload = Data()
        ilstPayload.append(makeItem(index: 1, typeIndicator: 1, payload: Data("Blackmagic Design".utf8)))
        ilstPayload.append(makeItem(index: 2, typeIndicator: 1, payload: Data("Blackmagic PYXIS 12K".utf8)))
        ilstPayload.append(makeItem(index: 3, typeIndicator: 1, payload: Data("Blackmagic Design Film".utf8)))
        // float32 BE: 1/112 ≈ 0.00892857. Bit pattern of Float(0.008928571).
        let frameTime = Float(1.0 / 112.0)
        var ftBytes = frameTime.bitPattern.bigEndian
        let ftData = Data(bytes: &ftBytes, count: 4)
        ilstPayload.append(makeItem(index: 4, typeIndicator: 23, payload: ftData))
        // 16-bit signed BE: 1 (offspeed = true)
        ilstPayload.append(makeItem(index: 5, typeIndicator: 76, payload: Data([0x00, 0x01])))
        // 16-bit signed BE: 5 (color science Generation 5)
        ilstPayload.append(makeItem(index: 6, typeIndicator: 76, payload: Data([0x00, 0x05])))
        // UTF-8: "12:1"
        ilstPayload.append(makeItem(index: 7, typeIndicator: 1, payload: Data("12:1".utf8)))
        // rotation: int16 BE = 90 (degrees, plain integer — not a boolean)
        ilstPayload.append(makeItem(index: 8, typeIndicator: 76, payload: Data([0x00, 0x5A])))
        // lens_shading_enable: int16 BE = 1 (true)
        ilstPayload.append(makeItem(index: 9, typeIndicator: 76, payload: Data([0x00, 0x01])))
        // tone_curve_contrast: float32 BE = 0.5
        var contrastBE = Float(0.5).bitPattern.bigEndian
        let contrastData = Data(bytes: &contrastBE, count: 4)
        ilstPayload.append(makeItem(index: 10, typeIndicator: 23, payload: contrastData))
        // post_3dlut_embedded_size: int16 BE = 33 (a 33×33×33 LUT cube)
        ilstPayload.append(makeItem(index: 11, typeIndicator: 76, payload: Data([0x00, 0x21])))
        // post_3dlut_embedded_data: type 22 blob — 16 dummy bytes; the
        // parser must NOT serialise the bytes into a UTF-8 string, only
        // emit a "<N> bytes" marker.
        ilstPayload.append(makeItem(index: 12, typeIndicator: 22,
                                    payload: Data(repeating: 0xAB, count: 16)))
        // braw_codec_bitrate: type 77 / 4-byte unsigned. 0x90000000 has the
        // high bit set — verifies type 77 is treated as UNSIGNED, not
        // sign-extended into a negative Int64.
        ilstPayload.append(makeItem(index: 13, typeIndicator: 77,
                                    payload: Data([0x90, 0x00, 0x00, 0x00])))
        let ilstBox = buildBox("ilst", data: ilstPayload)

        // 3) hdlr advertising mdta-style metadata, then meta wrapping
        //    hdlr+keys+ilst in the QuickTime non-FullBox layout (no
        //    version+flags prefix on the meta payload).
        var hdlrPayload = BinaryWriter(capacity: 32)
        hdlrPayload.writeBytes(Data(repeating: 0, count: 4)) // FullBox header
        hdlrPayload.writeBytes(Data(repeating: 0, count: 4)) // pre_defined
        hdlrPayload.writeString("mdta", encoding: .ascii)    // handler_type
        hdlrPayload.writeBytes(Data(repeating: 0, count: 12)) // reserved
        hdlrPayload.writeBytes([0x00]) // empty name terminator
        let hdlrBox = buildBox("hdlr", data: hdlrPayload.data)

        var metaPayload = Data()
        metaPayload.append(hdlrBox)
        metaPayload.append(keysBox)
        metaPayload.append(ilstBox)
        let metaBox = buildBox("meta", data: metaPayload)

        // 4) Build moov: mvhd + minimal trak (so format detection still
        //    passes) + meta. Use the ftyp-less BRAW layout.
        var mvhd = BinaryWriter(capacity: 128)
        mvhd.writeBytes([0x00, 0x00, 0x00, 0x00])
        mvhd.writeUInt32BigEndian(0)
        mvhd.writeUInt32BigEndian(0)
        mvhd.writeUInt32BigEndian(25)    // movie timescale
        mvhd.writeUInt32BigEndian(520)   // duration → 20.8s
        mvhd.writeBytes(Data(repeating: 0, count: 80))
        let mvhdBox = buildBox("mvhd", data: mvhd.data)

        var moovPayload = Data()
        moovPayload.append(mvhdBox)
        moovPayload.append(metaBox)
        let moovBox = buildBox("moov", data: moovPayload)

        // 5) Wrap with a BRAW-style wide+mdat preamble.
        var file = BinaryWriter(capacity: moovBox.count + 32)
        file.writeUInt32BigEndian(8)
        file.writeString("wide", encoding: .ascii)
        file.writeUInt32BigEndian(8)
        file.writeString("mdat", encoding: .ascii)
        file.writeBytes(moovBox)

        let metadata = try VideoMetadata.read(from: file.data)
        let cam = try XCTUnwrap(metadata.camera)
        XCTAssertEqual(cam.deviceManufacturer, "Blackmagic Design")
        XCTAssertEqual(cam.deviceModelName, "Blackmagic PYXIS 12K")
        XCTAssertEqual(cam.captureGammaEquation, "Blackmagic Design Film")
        // Sensor capture rate from offspeed_frame_time. Project rate stays
        // at the mvhd-derived 25 (520 / 25 = 20.8s; frame rate is unset
        // here because there's no real video trak with stts).
        XCTAssertEqual(cam.captureFps ?? 0, 112.0, accuracy: 0.05)
        // Slate fields surface as parallel name/content arrays. Order
        // follows the ilst scan order (which is the index assignment order
        // above). New keys land in the integer / float / bool / blob blocks
        // depending on their declared semantics.
        XCTAssertEqual(cam.userMetaNames, [
            "offspeed", "viewing_bmdgen", "braw_compression_ratio",
            "rotation", "lens_shading_enable", "tone_curve_contrast",
            "post_3dlut_embedded_size", "post_3dlut_embedded_data",
            "braw_codec_bitrate",
        ])
        XCTAssertEqual(cam.userMetaContents, [
            "true", "Generation 5", "12:1",
            "90", "true", "0.5",
            "33", "16 bytes",
            // 0x90000000 = 2,415,919,104 — must round-trip as a positive
            // unsigned uint32, not the negative Int32 a sign-extending
            // decoder would emit.
            "2415919104",
        ])
    }

    /// Legacy QuickTime / Blackmagic RAW files have no ftyp at the top —
    /// they start with `wide` + `mdat` and place moov at the file tail.
    /// MP4Parser must tolerate that and still pull duration from mvhd.
    func testParseLegacyQuickTimeWithoutFtyp() throws {
        var writer = BinaryWriter(capacity: 256)
        // 8-byte `wide` placeholder.
        writer.writeUInt32BigEndian(8)
        writer.writeString("wide", encoding: .ascii)
        // Empty `mdat` (just a header).
        writer.writeUInt32BigEndian(8)
        writer.writeString("mdat", encoding: .ascii)
        // moov with mvhd (timescale 1000, duration 5000 → 5.0 s).
        var mvhd = BinaryWriter(capacity: 128)
        mvhd.writeBytes([0x00, 0x00, 0x00, 0x00])
        mvhd.writeUInt32BigEndian(0)
        mvhd.writeUInt32BigEndian(0)
        mvhd.writeUInt32BigEndian(1000)
        mvhd.writeUInt32BigEndian(5000)
        mvhd.writeBytes(Data(repeating: 0, count: 80))
        let mvhdBox = buildBox("mvhd", data: mvhd.data)
        let moovBox = buildBox("moov", data: mvhdBox)
        writer.writeBytes(moovBox)

        let metadata = try VideoMetadata.read(from: writer.data)
        XCTAssertEqual(metadata.duration, 5.0)
        // No ftyp → defaults to .mov so the rest of the parse can proceed.
        XCTAssertEqual(metadata.format, .mov)
    }

    /// BRAW emits three uint32 codec-config atoms inside the `brhq` sample
    /// entry's child-box list: `bfdn` (BRAW format-definition id),
    /// `ctrn` (color-transform version), `bver` (BRAW codec version).
    /// They sit alongside the moov.meta clip slate in CameraMetadata.
    func testParseBlackmagicRAWCodecAtoms() throws {
        // 1) Build the three child atoms — each is a 12-byte box wrapping
        //    one uint32 BE.
        func uint32Box(_ type: String, _ value: UInt32) -> Data {
            var w = BinaryWriter(capacity: 4)
            w.writeUInt32BigEndian(value)
            return buildBox(type, data: w.data)
        }
        let bfdnBox = uint32Box("bfdn", 1001)
        let ctrnBox = uint32Box("ctrn", 1)
        let bverBox = uint32Box("bver", 1)
        let codecChildren = bfdnBox + ctrnBox + bverBox

        // 2) Build a 78-byte VisualSampleEntry payload (zeroed — the parser
        //    only cares about width/height and the children), then prepend
        //    the brhq box header so child atoms start at +86 from box start.
        let visualFields = Data(repeating: 0, count: 78)
        let brhqEntry = buildBox("brhq", data: visualFields + codecChildren)

        // 3) stsd: FullBox header + entry_count(1) + the brhq sample entry.
        var stsdWriter = BinaryWriter(capacity: 32 + brhqEntry.count)
        stsdWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        stsdWriter.writeUInt32BigEndian(1)
        stsdWriter.writeBytes(brhqEntry)
        let stsdBox = buildBox("stsd", data: stsdWriter.data)

        // 4) Wrap stsd → stbl → minf → mdia (with a vide hdlr) → trak.
        var hdlrWriter = BinaryWriter(capacity: 32)
        hdlrWriter.writeBytes([0x00, 0x00, 0x00, 0x00]) // version + flags
        hdlrWriter.writeBytes(Data(repeating: 0, count: 4)) // pre_defined
        hdlrWriter.writeString("vide", encoding: .ascii)
        hdlrWriter.writeBytes(Data(repeating: 0, count: 12)) // reserved
        let hdlrBox = buildBox("hdlr", data: hdlrWriter.data)

        let stblBox = buildBox("stbl", data: stsdBox)
        let minfBox = buildBox("minf", data: stblBox)
        let mdiaBox = buildBox("mdia", data: hdlrBox + minfBox)
        let trakBox = buildBox("trak", data: mdiaBox)

        // 5) mvhd + trak → moov; wrap with a BRAW-style ftyp-less preamble.
        var mvhd = BinaryWriter(capacity: 128)
        mvhd.writeBytes([0x00, 0x00, 0x00, 0x00])
        mvhd.writeUInt32BigEndian(0)
        mvhd.writeUInt32BigEndian(0)
        mvhd.writeUInt32BigEndian(25)
        mvhd.writeUInt32BigEndian(125)
        mvhd.writeBytes(Data(repeating: 0, count: 80))
        let mvhdBox = buildBox("mvhd", data: mvhd.data)

        let moovBox = buildBox("moov", data: mvhdBox + trakBox)
        var file = BinaryWriter(capacity: moovBox.count + 32)
        file.writeUInt32BigEndian(8); file.writeString("wide", encoding: .ascii)
        file.writeUInt32BigEndian(8); file.writeString("mdat", encoding: .ascii)
        file.writeBytes(moovBox)

        let metadata = try VideoMetadata.read(from: file.data)
        let cam = try XCTUnwrap(metadata.camera)
        XCTAssertEqual(cam.userMetaNames, [
            "braw_codec_bfdn", "braw_codec_ctrn", "braw_codec_bver",
        ])
        XCTAssertEqual(cam.userMetaContents, ["1001", "1", "1"])
    }

    /// BRAW stores ISO / white-balance Kelvin / tint AND the lens-string
    /// fields (shutter angle, aperture, focal length, focus distance)
    /// inside each frame's `bmdf` header in mdat — not in moov.meta. The
    /// parser reads frame 0's header via the trak's stco offset and pulls
    /// the seven values; null-padded UTF-8 strings are trimmed and empty
    /// strings (no electronic lens contact) are dropped.
    func testParseBlackmagicRAWFirstFrameAttributes() throws {
        // 1) Build a BRAW frame metadata block: one bmdf box wrapping a
        //    sequence of typed sub-boxes covering all the atoms we decode.
        func uint32Box(_ type: String, _ value: UInt32) -> Data {
            var w = BinaryWriter(capacity: 4)
            w.writeUInt32BigEndian(value)
            return buildBox(type, data: w.data)
        }
        func int16Box(_ type: String, _ value: Int16) -> Data {
            var w = BinaryWriter(capacity: 2)
            w.writeUInt16BigEndian(UInt16(bitPattern: value))
            return buildBox(type, data: w.data)
        }
        // BMD pads each string field to 24 bytes with NULs. "180°" is 5
        // bytes UTF-8 (3 ASCII + 2-byte combining degree sign) → 19 NULs.
        func paddedStringBox(_ type: String, _ value: String) -> Data {
            var bytes = Data(value.utf8)
            let target = 24
            if bytes.count > target { bytes = bytes.prefix(target) }
            else { bytes.append(Data(repeating: 0, count: target - bytes.count)) }
            return buildBox(type, data: bytes)
        }
        // An empty string (e.g. focus_distance with no electronic lens):
        // 24 NULs. The parser must NOT surface this as a slate entry.
        let emptyDsnc = buildBox("dsnc", data: Data(repeating: 0, count: 24))
        // Order matches real BRAW layout: shtv → aptr → fcln → dsnc →
        // isoe → wkel → wtin.
        let frameHeader = Data(repeating: 0, count: 8)
            + paddedStringBox("shtv", "180°")
            + paddedStringBox("aptr", "f2.7")
            + paddedStringBox("fcln", "135mm")
            + emptyDsnc
            + uint32Box("isoe", 800)
            + uint32Box("wkel", 5600)
            + int16Box("wtin", 12)
        let bmdfBox = buildBox("bmdf", data: frameHeader)

        // 2) Wrap the frame block in mdat. The chunk offset stored in stco
        //    must equal the absolute file offset of bmdfBox's first byte.
        let mdatHeaderSize = 8
        // ftyp (16) + mdat-header (8) → bmdf starts at 24.
        let firstChunkOffset: UInt32 = 16 + 8
        let mdatBox = buildBox("mdat", data: bmdfBox)
        _ = mdatHeaderSize // suppress unused-warning if helpers shift

        // 3) Build a brhq video sample entry — needs the 78-byte
        //    VisualSampleEntry header; no codec children needed for this
        //    test (codec FourCC alone gates the parser).
        let visualFields = Data(repeating: 0, count: 78)
        let brhqEntry = buildBox("brhq", data: visualFields)
        var stsdWriter = BinaryWriter(capacity: 16 + brhqEntry.count)
        stsdWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        stsdWriter.writeUInt32BigEndian(1)
        stsdWriter.writeBytes(brhqEntry)
        let stsdBox = buildBox("stsd", data: stsdWriter.data)

        // 4) stco: FullBox header(4) + entry_count(4) + offsets(N×4).
        var stcoWriter = BinaryWriter(capacity: 16)
        stcoWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        stcoWriter.writeUInt32BigEndian(1)
        stcoWriter.writeUInt32BigEndian(firstChunkOffset)
        let stcoBox = buildBox("stco", data: stcoWriter.data)

        var hdlrWriter = BinaryWriter(capacity: 32)
        hdlrWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        hdlrWriter.writeBytes(Data(repeating: 0, count: 4))
        hdlrWriter.writeString("vide", encoding: .ascii)
        hdlrWriter.writeBytes(Data(repeating: 0, count: 12))
        let hdlrBox = buildBox("hdlr", data: hdlrWriter.data)

        let stblBox = buildBox("stbl", data: stsdBox + stcoBox)
        let minfBox = buildBox("minf", data: stblBox)
        let mdiaBox = buildBox("mdia", data: hdlrBox + minfBox)
        let trakBox = buildBox("trak", data: mdiaBox)

        var mvhd = BinaryWriter(capacity: 128)
        mvhd.writeBytes([0x00, 0x00, 0x00, 0x00])
        mvhd.writeUInt32BigEndian(0); mvhd.writeUInt32BigEndian(0)
        mvhd.writeUInt32BigEndian(25); mvhd.writeUInt32BigEndian(125)
        mvhd.writeBytes(Data(repeating: 0, count: 80))
        let mvhdBox = buildBox("mvhd", data: mvhd.data)
        let moovBox = buildBox("moov", data: mvhdBox + trakBox)

        // 5) Final layout: ftyp(16) + mdat(varies) + moov.
        var file = BinaryWriter(capacity: 256 + moovBox.count + mdatBox.count)
        let ftyp = Data("isom".utf8) + Data([0x00, 0x00, 0x00, 0x00])
        file.writeUInt32BigEndian(UInt32(8 + ftyp.count))
        file.writeString("ftyp", encoding: .ascii)
        file.writeBytes(ftyp)
        XCTAssertEqual(file.count, 16, "ftyp must be exactly 16 bytes for the stco offset to land inside mdat")
        file.writeBytes(mdatBox)
        file.writeBytes(moovBox)

        let metadata = try VideoMetadata.read(from: file.data)
        let cam = try XCTUnwrap(metadata.camera)
        // dsnc is empty in this fixture and must not appear in the slate;
        // the rest are surfaced in bmdf walk order.
        XCTAssertEqual(cam.userMetaNames, [
            "shutter_angle", "aperture", "focal_length",
            "iso", "white_balance_kelvin", "white_balance_tint",
        ])
        XCTAssertEqual(cam.userMetaContents, [
            "180°", "f2.7", "135mm",
            "800", "5600", "12",
        ])
    }

    /// BRAW carries per-frame gyroscope and accelerometer data as `mebx`
    /// timed-metadata tracks, declared with the namespaces
    /// `com.blackmagicdesign.motiondata.gyroscope` and `…accelerometer`.
    /// We don't decode the per-frame samples (out of scope), but we do
    /// flag presence so consumers can ask for the streams later.
    func testParseBlackmagicMotionDataTracksDetected() throws {
        // mebx sample-entry payload: 8-byte SampleEntry header (6 reserved
        // + 2 data_reference_index) followed by a `keys` child box that
        // embeds a `keyd` declaration. The parser only does a substring
        // scan for the BMD namespace, so the keyd payload can be a flat
        // bytestring — we don't need full mebx-keys structure.
        let gyroNamespace = Data("com.blackmagicdesign.motiondata.gyroscope".utf8)
        let keydBox = buildBox("keyd", data: gyroNamespace)
        let keysBox = buildBox("keys", data: keydBox)
        var mebxPayload = BinaryWriter(capacity: 8 + keysBox.count)
        mebxPayload.writeBytes(Data(repeating: 0, count: 8)) // SampleEntry reserved+data_ref_idx
        mebxPayload.writeBytes(keysBox)
        let mebxEntry = buildBox("mebx", data: mebxPayload.data)

        var stsdWriter = BinaryWriter(capacity: 16 + mebxEntry.count)
        stsdWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        stsdWriter.writeUInt32BigEndian(1)
        stsdWriter.writeBytes(mebxEntry)
        let stsdBox = buildBox("stsd", data: stsdWriter.data)

        // A `meta` handler track lands in the data-handler dispatch where
        // detectBRAWMotionTracks runs.
        var hdlrWriter = BinaryWriter(capacity: 32)
        hdlrWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        hdlrWriter.writeBytes(Data(repeating: 0, count: 4))
        hdlrWriter.writeString("meta", encoding: .ascii)
        hdlrWriter.writeBytes(Data(repeating: 0, count: 12))
        let hdlrBox = buildBox("hdlr", data: hdlrWriter.data)

        let stblBox = buildBox("stbl", data: stsdBox)
        let minfBox = buildBox("minf", data: stblBox)
        let mdiaBox = buildBox("mdia", data: hdlrBox + minfBox)
        let trakBox = buildBox("trak", data: mdiaBox)

        var mvhd = BinaryWriter(capacity: 128)
        mvhd.writeBytes([0x00, 0x00, 0x00, 0x00])
        mvhd.writeUInt32BigEndian(0); mvhd.writeUInt32BigEndian(0)
        mvhd.writeUInt32BigEndian(25); mvhd.writeUInt32BigEndian(125)
        mvhd.writeBytes(Data(repeating: 0, count: 80))
        let mvhdBox = buildBox("mvhd", data: mvhd.data)
        let moovBox = buildBox("moov", data: mvhdBox + trakBox)

        var file = BinaryWriter(capacity: moovBox.count + 32)
        file.writeUInt32BigEndian(8); file.writeString("wide", encoding: .ascii)
        file.writeUInt32BigEndian(8); file.writeString("mdat", encoding: .ascii)
        file.writeBytes(moovBox)

        let metadata = try VideoMetadata.read(from: file.data)
        let cam = try XCTUnwrap(metadata.camera)
        XCTAssertEqual(cam.userMetaNames, ["has_gyroscope_motion_data"])
        XCTAssertEqual(cam.userMetaContents, ["true"])
    }

    // MARK: - Exporter

    func testVideoMetadataBuildDictionary() throws {
        let data = buildMP4WithMVHD(creationTime: UInt32(2082844800 + 1000000), timescale: 1000, duration: 5000)
        let metadata = try VideoMetadata.read(from: data)
        let dict = VideoMetadataExporter.buildDictionary(metadata)

        XCTAssertEqual(dict["FileFormat"] as? String, "MP4")
        XCTAssertEqual(dict["Duration"] as? Double, 5.0)
    }

    func testVideoMetadataToJSON() throws {
        let data = buildMP4WithMVHD(creationTime: 0, timescale: 600, duration: 3600)
        let metadata = try VideoMetadata.read(from: data)
        let json = VideoMetadataExporter.toJSONString(metadata)
        XCTAssertTrue(json.contains("Duration"))
        XCTAssertTrue(json.contains("MP4"))
    }

    // MARK: - Chapters

    /// Nero `chpl` in a moov>udta box. MP4Box / x264 / ffmpeg all write this
    /// shape; times are 100-nanosecond ticks relative to presentation start.
    func testParseNeroCHPLChapters() throws {
        let chapters: [(start100ns: UInt64, title: String)] = [
            (0, "Opening"),
            (30_000_000, "Credits"),      // 3.0 s
            (120_000_000, "Chapter Two"), // 12.0 s
        ]
        let data = buildMP4WithCHPL(chapters)
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.chapters.count, 3)
        XCTAssertEqual(metadata.chapters[0].title, "Opening")
        XCTAssertEqual(metadata.chapters[0].startTime, 0.0, accuracy: 0.0001)
        XCTAssertEqual(metadata.chapters[1].title, "Credits")
        XCTAssertEqual(metadata.chapters[1].startTime, 3.0, accuracy: 0.0001)
        XCTAssertEqual(metadata.chapters[2].title, "Chapter Two")
        XCTAssertEqual(metadata.chapters[2].startTime, 12.0, accuracy: 0.0001)
    }

    /// Empty chpl box is tolerated (produces no chapters, no crash). Some
    /// muxers write a zero-count Nero chapter list when chapter-less media is
    /// remuxed from a container that did carry one.
    func testParseNeroCHPLEmpty() throws {
        let data = buildMP4WithCHPL([])
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertTrue(metadata.chapters.isEmpty)
    }

    /// Titles written as plain UTF-8 survive a round trip (Nero allows any
    /// byte sequence the spec treats as UTF-8; Norwegian chars are the canary).
    func testParseNeroCHPLUTF8Title() throws {
        let data = buildMP4WithCHPL([(0, "Åpning – første kapittel")])
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.chapters.first?.title, "Åpning – første kapittel")
    }

    // MARK: - Helpers

    /// Build an MP4 with ftyp + moov>mvhd + moov>udta>chpl (Nero chapter list,
    /// version 1 form).
    private func buildMP4WithCHPL(_ chapters: [(start100ns: UInt64, title: String)]) -> Data {
        var writer = BinaryWriter(capacity: 512)
        writeFtyp(&writer, brand: "isom")

        // Build mvhd
        var mvhdWriter = BinaryWriter(capacity: 128)
        mvhdWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        mvhdWriter.writeBytes(Data(repeating: 0, count: 96))
        let mvhdBox = buildBox("mvhd", data: mvhdWriter.data)

        // Build chpl payload (version 1): version/flags(4) + reserved(1) + count(4) + entries
        var chplData = Data([0x01, 0x00, 0x00, 0x00]) // version=1, flags=0
        chplData.append(0x00)                          // reserved
        let count = UInt32(chapters.count)
        chplData.append(UInt8((count >> 24) & 0xFF))
        chplData.append(UInt8((count >> 16) & 0xFF))
        chplData.append(UInt8((count >> 8) & 0xFF))
        chplData.append(UInt8(count & 0xFF))
        for (start, title) in chapters {
            for i in (0..<8).reversed() {
                chplData.append(UInt8((start >> (8 * i)) & 0xFF))
            }
            let titleBytes = Data(title.utf8)
            chplData.append(UInt8(min(titleBytes.count, 255)))
            chplData.append(titleBytes.prefix(255))
        }
        let chplBox = buildBox("chpl", data: chplData)
        let udtaBox = buildBox("udta", data: chplBox)
        let moovBox = buildBox("moov", data: mvhdBox + udtaBox)
        writer.writeBytes(moovBox)
        return writer.data
    }


    /// Build a minimal ISOBMFF file with just an ftyp box.
    private func buildMinimalMP4(brand: String) -> Data {
        var writer = BinaryWriter(capacity: 64)
        // ftyp box: size(4) + "ftyp"(4) + brand(4) + version(4)
        let ftypPayload = Data(brand.utf8) + Data([0x00, 0x00, 0x00, 0x00]) // brand + version
        writer.writeUInt32BigEndian(UInt32(8 + ftypPayload.count))
        writer.writeString("ftyp", encoding: .ascii)
        writer.writeBytes(ftypPayload)
        return writer.data
    }

    /// Build an MP4 with ftyp + moov containing mvhd.
    private func buildMP4WithMVHD(creationTime: UInt32, timescale: UInt32, duration: UInt32) -> Data {
        var writer = BinaryWriter(capacity: 256)

        // ftyp
        writeFtyp(&writer, brand: "isom")

        // Build mvhd box
        var mvhdWriter = BinaryWriter(capacity: 128)
        // FullBox: version 0 + flags
        mvhdWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        mvhdWriter.writeUInt32BigEndian(creationTime) // creation_time
        mvhdWriter.writeUInt32BigEndian(creationTime) // modification_time
        mvhdWriter.writeUInt32BigEndian(timescale)    // timescale
        mvhdWriter.writeUInt32BigEndian(duration)     // duration
        // rate(4) + volume(2) + reserved(10) + matrix(36) + pre_defined(24) + next_track_id(4) = 80
        mvhdWriter.writeBytes(Data(repeating: 0, count: 80))

        let mvhdBox = buildBox("mvhd", data: mvhdWriter.data)

        // moov wrapping mvhd
        let moovBox = buildBox("moov", data: mvhdBox)
        writer.writeBytes(moovBox)

        return writer.data
    }

    /// Build an MP4 with ftyp + moov containing a single track.
    private func buildMP4WithTrack(width: Int, height: Int, handlerType: String, codec: String) -> Data {
        var writer = BinaryWriter(capacity: 512)
        writeFtyp(&writer, brand: "isom")

        // Build mvhd
        var mvhdWriter = BinaryWriter(capacity: 128)
        mvhdWriter.writeBytes([0x00, 0x00, 0x00, 0x00]) // version + flags
        mvhdWriter.writeBytes(Data(repeating: 0, count: 96)) // minimal mvhd content
        let mvhdBox = buildBox("mvhd", data: mvhdWriter.data)

        // Build tkhd
        var tkhdWriter = BinaryWriter(capacity: 128)
        tkhdWriter.writeBytes([0x00, 0x00, 0x00, 0x03]) // version 0 + flags (enabled + in movie)
        tkhdWriter.writeBytes(Data(repeating: 0, count: 76)) // skip to width/height
        tkhdWriter.writeUInt32BigEndian(UInt32(width) << 16)  // width (16.16 fixed-point)
        tkhdWriter.writeUInt32BigEndian(UInt32(height) << 16) // height (16.16 fixed-point)
        let tkhdBox = buildBox("tkhd", data: tkhdWriter.data)

        // Build hdlr
        var hdlrWriter = BinaryWriter(capacity: 32)
        hdlrWriter.writeBytes([0x00, 0x00, 0x00, 0x00]) // version + flags
        hdlrWriter.writeBytes(Data(repeating: 0, count: 4)) // pre_defined
        hdlrWriter.writeString(handlerType, encoding: .ascii) // handler_type
        hdlrWriter.writeBytes(Data(repeating: 0, count: 12)) // reserved
        let hdlrBox = buildBox("hdlr", data: hdlrWriter.data)

        // Build stsd
        var stsdWriter = BinaryWriter(capacity: 32)
        stsdWriter.writeBytes([0x00, 0x00, 0x00, 0x00]) // version + flags
        stsdWriter.writeUInt32BigEndian(1) // entry count
        // Sample entry: size(4) + codec(4)
        stsdWriter.writeUInt32BigEndian(16) // entry size (minimal)
        stsdWriter.writeString(codec, encoding: .ascii)
        stsdWriter.writeBytes(Data(repeating: 0, count: 4)) // padding
        let stsdBox = buildBox("stsd", data: stsdWriter.data)

        let stblBox = buildBox("stbl", data: stsdBox)
        let minfBox = buildBox("minf", data: stblBox)
        let mdiaBox = buildBox("mdia", data: hdlrBox + minfBox)
        let trakBox = buildBox("trak", data: tkhdBox + mdiaBox)

        let moovBox = buildBox("moov", data: mvhdBox + trakBox)
        writer.writeBytes(moovBox)

        return writer.data
    }

    // MARK: - tkhd Display-Matrix Rotation

    func testIdentityMatrixYieldsNoRotation() throws {
        let data = buildMP4WithRotatedTrack(rotation: 0, width: 1920, height: 1080)
        let metadata = try VideoMetadata.read(from: data)
        let stream = try XCTUnwrap(metadata.videoStreams.first)
        XCTAssertNil(stream.rotation, "identity matrix must not emit a rotation side-data value")
    }

    func testPortraitPhoneVideoReportsMinus90() throws {
        // 90° clockwise (the iPhone-portrait case).
        let data = buildMP4WithRotatedTrack(rotation: -90, width: 1080, height: 1920)
        let metadata = try VideoMetadata.read(from: data)
        let stream = try XCTUnwrap(metadata.videoStreams.first)
        XCTAssertEqual(stream.rotation, -90)
    }

    func testUpsideDownReports180() throws {
        let data = buildMP4WithRotatedTrack(rotation: 180, width: 1920, height: 1080)
        let metadata = try VideoMetadata.read(from: data)
        let stream = try XCTUnwrap(metadata.videoStreams.first)
        XCTAssertNotNil(stream.rotation)
        XCTAssertEqual(abs(stream.rotation!), 180)
    }

    func testCounterClockwiseRotationReportsPositive90() throws {
        // 90° counter-clockwise → ffprobe rotation = +90.
        let data = buildMP4WithRotatedTrack(rotation: 90, width: 1080, height: 1920)
        let metadata = try VideoMetadata.read(from: data)
        let stream = try XCTUnwrap(metadata.videoStreams.first)
        XCTAssertEqual(stream.rotation, 90)
    }

    /// Build an MP4 with a single video track whose tkhd carries a 3x3
    /// transformation matrix encoding the requested rotation. Pass `0` for
    /// the identity matrix (no rotation).
    private func buildMP4WithRotatedTrack(rotation: Int, width: Int, height: Int) -> Data {
        var writer = BinaryWriter(capacity: 512)
        writeFtyp(&writer, brand: "isom")

        var mvhdWriter = BinaryWriter(capacity: 128)
        mvhdWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        mvhdWriter.writeBytes(Data(repeating: 0, count: 96))
        let mvhdBox = buildBox("mvhd", data: mvhdWriter.data)

        var tkhdWriter = BinaryWriter(capacity: 128)
        tkhdWriter.writeBytes([0x00, 0x00, 0x00, 0x03])           // version 0 + flags
        tkhdWriter.writeBytes(Data(repeating: 0, count: 36))       // creation through volume+reserved
        tkhdWriter.writeBytes(tkhdMatrixBytes(rotation: rotation)) // matrix (36 bytes)
        tkhdWriter.writeUInt32BigEndian(UInt32(width) << 16)
        tkhdWriter.writeUInt32BigEndian(UInt32(height) << 16)
        let tkhdBox = buildBox("tkhd", data: tkhdWriter.data)

        var hdlrWriter = BinaryWriter(capacity: 32)
        hdlrWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        hdlrWriter.writeBytes(Data(repeating: 0, count: 4))
        hdlrWriter.writeString("vide", encoding: .ascii)
        hdlrWriter.writeBytes(Data(repeating: 0, count: 12))
        let hdlrBox = buildBox("hdlr", data: hdlrWriter.data)

        var stsdWriter = BinaryWriter(capacity: 32)
        stsdWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        stsdWriter.writeUInt32BigEndian(1)
        stsdWriter.writeUInt32BigEndian(16)
        stsdWriter.writeString("avc1", encoding: .ascii)
        stsdWriter.writeBytes(Data(repeating: 0, count: 4))
        let stsdBox = buildBox("stsd", data: stsdWriter.data)

        let stblBox = buildBox("stbl", data: stsdBox)
        let minfBox = buildBox("minf", data: stblBox)
        let mdiaBox = buildBox("mdia", data: hdlrBox + minfBox)
        let trakBox = buildBox("trak", data: tkhdBox + mdiaBox)

        let moovBox = buildBox("moov", data: mvhdBox + trakBox)
        writer.writeBytes(moovBox)
        return writer.data
    }

    /// Encode the 9 fixed-point ints of a tkhd display matrix for the
    /// requested rotation. Values follow QuickTime convention: the upper-left
    /// 2x2 (a, b, c, d) is 16.16 fixed-point; the perspective term `w` is
    /// 2.30 fixed-point (1.0 = 0x40000000).
    private func tkhdMatrixBytes(rotation: Int) -> Data {
        var w = BinaryWriter(capacity: 36)
        let one: UInt32 = 0x00010000      // +1.0 in 16.16
        let neg: UInt32 = 0xFFFF0000      // -1.0 in 16.16
        let zero: UInt32 = 0
        let perspective: UInt32 = 0x40000000  // +1.0 in 2.30

        let a, b, c, d: UInt32
        switch rotation {
        case 90:        a = zero; b = neg;  c = one;  d = zero
        case -90:       a = zero; b = one;  c = neg;  d = zero
        case 180, -180: a = neg;  b = zero; c = zero; d = neg
        default:        a = one;  b = zero; c = zero; d = one  // identity
        }

        w.writeUInt32BigEndian(a);  w.writeUInt32BigEndian(b);  w.writeUInt32BigEndian(zero)  // u
        w.writeUInt32BigEndian(c);  w.writeUInt32BigEndian(d);  w.writeUInt32BigEndian(zero)  // v
        w.writeUInt32BigEndian(zero); w.writeUInt32BigEndian(zero); w.writeUInt32BigEndian(perspective)
        return w.data
    }

    // MARK: - HDR side-data: mdcv / clli / dvcC

    func testMasteringDisplayColorVolumeBox() throws {
        // BT.2020 primaries with 1000-nit peak, 0.005-nit floor — typical
        // Apple Pro Display XDR mastering profile.
        var w = BinaryWriter(capacity: 24)
        // R / G / B primaries in 0.00002 units (BT.2020 reference).
        w.writeUInt16BigEndian(34000); w.writeUInt16BigEndian(16000)   // R: 0.680, 0.320
        w.writeUInt16BigEndian(13250); w.writeUInt16BigEndian(34500)   // G: 0.265, 0.690
        w.writeUInt16BigEndian( 7500); w.writeUInt16BigEndian( 3000)   // B: 0.150, 0.060
        w.writeUInt16BigEndian(15635); w.writeUInt16BigEndian(16450)   // W: 0.31271, 0.32902
        w.writeUInt32BigEndian(10_000_000)  // 1000.0 cd/m^2 (in 0.0001 units)
        w.writeUInt32BigEndian(50)          // 0.005 cd/m^2
        let data = buildMP4WithVisualChildBox(boxType: "mdcv", boxData: w.data)

        let metadata = try VideoMetadata.read(from: data)
        let stream = try XCTUnwrap(metadata.videoStreams.first)
        let md = try XCTUnwrap(stream.hdr?.masteringDisplay)
        XCTAssertEqual(md.redX, 0.680, accuracy: 0.001)
        XCTAssertEqual(md.redY, 0.320, accuracy: 0.001)
        XCTAssertEqual(md.greenX, 0.265, accuracy: 0.001)
        XCTAssertEqual(md.greenY, 0.690, accuracy: 0.001)
        XCTAssertEqual(md.blueX, 0.150, accuracy: 0.001)
        XCTAssertEqual(md.blueY, 0.060, accuracy: 0.001)
        XCTAssertEqual(md.whitePointX, 0.31270, accuracy: 0.001)
        XCTAssertEqual(md.whitePointY, 0.32900, accuracy: 0.001)
        XCTAssertEqual(md.maxLuminance, 1000.0, accuracy: 0.01)
        XCTAssertEqual(md.minLuminance, 0.005, accuracy: 0.0001)
    }

    func testContentLightLevelBox() throws {
        var w = BinaryWriter(capacity: 4)
        w.writeUInt16BigEndian(1100)  // MaxCLL  — single brightest pixel
        w.writeUInt16BigEndian(400)   // MaxFALL — frame-average peak
        let data = buildMP4WithVisualChildBox(boxType: "clli", boxData: w.data)

        let metadata = try VideoMetadata.read(from: data)
        let stream = try XCTUnwrap(metadata.videoStreams.first)
        let cll = try XCTUnwrap(stream.hdr?.contentLightLevel)
        XCTAssertEqual(cll.maxCLL, 1100)
        XCTAssertEqual(cll.maxFALL, 400)
    }

    func testDolbyVisionConfigurationBox() throws {
        // Dolby Vision Profile 8.4 (HLG-compatible), version 1.0, level 4,
        // RPU + BL present (no enhancement layer), bl_compat_id = 4 (HLG).
        // Layout (24 bytes):
        //   byte 0: dv_version_major = 1
        //   byte 1: dv_version_minor = 0
        //   bytes 2-5: profile(7) | level(6) | rpu(1) | el(1) | bl(1) | bl_compat(4) | reserved(12)
        //     profile=8, level=4, rpu=1, el=0, bl=1, bl_compat=4
        //     word = (8 << 25) | (4 << 19) | (1 << 18) | (0 << 17) | (1 << 16) | (4 << 12)
        //          = 0x10260000 | 0x00050000 | 0x00004000
        //          = 0x10254000  + (0x00040000 from rpu) = ...
        // Easier to just compute it explicitly:
        let profile: UInt32 = 8
        let level: UInt32 = 4
        let word = (profile << 25) | (level << 19) | (1 << 18) | (0 << 17) | (1 << 16) | (4 << 12)
        var w = BinaryWriter(capacity: 24)
        w.writeUInt8(1)                            // dv_version_major
        w.writeUInt8(0)                            // dv_version_minor
        w.writeUInt32BigEndian(word)               // profile/level/flags/compat/reserved
        w.writeBytes(Data(repeating: 0, count: 18)) // 4×UInt32 reserved + extra padding (24 total)
        let data = buildMP4WithVisualChildBox(boxType: "dvcC", boxData: w.data)

        let metadata = try VideoMetadata.read(from: data)
        let stream = try XCTUnwrap(metadata.videoStreams.first)
        let dv = try XCTUnwrap(stream.hdr?.dolbyVision)
        XCTAssertEqual(dv.versionMajor, 1)
        XCTAssertEqual(dv.versionMinor, 0)
        XCTAssertEqual(dv.profile, 8)
        XCTAssertEqual(dv.level, 4)
        XCTAssertTrue(dv.rpuPresent)
        XCTAssertFalse(dv.elPresent)
        XCTAssertTrue(dv.blPresent)
        XCTAssertEqual(dv.blSignalCompatibilityID, 4)  // HLG-compatible
    }

    func testStreamWithoutHDRBoxesHasNilHDR() throws {
        let data = buildMP4WithTrack(width: 1920, height: 1080, handlerType: "vide", codec: "avc1")
        let metadata = try VideoMetadata.read(from: data)
        let stream = try XCTUnwrap(metadata.videoStreams.first)
        XCTAssertNil(stream.hdr, "SDR streams should not synthesize an empty HDRMetadata")
    }

    /// Build an MP4 with a single video track whose visual sample entry contains
    /// the requested child box (e.g. "mdcv", "clli", "dvcC"). The fixed-size
    /// portion of the VisualSampleEntry is constructed precisely so the parser
    /// finds its width, height, and depth fields where ISO/IEC 14496-12 §8.5.2
    /// expects them.
    private func buildMP4WithVisualChildBox(boxType: String, boxData: Data) -> Data {
        var writer = BinaryWriter(capacity: 1024)
        writeFtyp(&writer, brand: "isom")

        var mvhdWriter = BinaryWriter(capacity: 128)
        mvhdWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        mvhdWriter.writeBytes(Data(repeating: 0, count: 96))
        let mvhdBox = buildBox("mvhd", data: mvhdWriter.data)

        var tkhdWriter = BinaryWriter(capacity: 128)
        tkhdWriter.writeBytes([0x00, 0x00, 0x00, 0x03])
        tkhdWriter.writeBytes(Data(repeating: 0, count: 76))
        tkhdWriter.writeUInt32BigEndian(UInt32(1920) << 16)
        tkhdWriter.writeUInt32BigEndian(UInt32(1080) << 16)
        let tkhdBox = buildBox("tkhd", data: tkhdWriter.data)

        var hdlrWriter = BinaryWriter(capacity: 32)
        hdlrWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        hdlrWriter.writeBytes(Data(repeating: 0, count: 4))
        hdlrWriter.writeString("vide", encoding: .ascii)
        hdlrWriter.writeBytes(Data(repeating: 0, count: 12))
        let hdlrBox = buildBox("hdlr", data: hdlrWriter.data)

        // Build a properly-sized avc1 VisualSampleEntry (78 bytes payload after
        // the 8-byte box header, plus the child HDR box).
        var avc1Payload = BinaryWriter(capacity: 256)
        avc1Payload.writeBytes(Data(repeating: 0, count: 6))     // SampleEntry reserved
        avc1Payload.writeUInt16BigEndian(1)                       // data_reference_index
        avc1Payload.writeBytes(Data(repeating: 0, count: 16))    // pre_defined + reserved + pre_defined[3]
        avc1Payload.writeUInt16BigEndian(1920)                    // width
        avc1Payload.writeUInt16BigEndian(1080)                    // height
        avc1Payload.writeUInt32BigEndian(0x00480000)              // horizresolution (72 dpi)
        avc1Payload.writeUInt32BigEndian(0x00480000)              // vertresolution
        avc1Payload.writeUInt32BigEndian(0)                       // reserved
        avc1Payload.writeUInt16BigEndian(1)                       // frame_count
        avc1Payload.writeBytes(Data(repeating: 0, count: 32))    // compressorname (Pascal-padded)
        avc1Payload.writeUInt16BigEndian(0x0018)                  // depth = 24
        avc1Payload.writeUInt16BigEndian(0xFFFF)                  // pre_defined = -1
        let childBox = buildBox(boxType, data: boxData)
        avc1Payload.writeBytes(childBox)
        let avc1Box = buildBox("avc1", data: avc1Payload.data)

        var stsdWriter = BinaryWriter(capacity: 256)
        stsdWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        stsdWriter.writeUInt32BigEndian(1)                        // entry_count
        stsdWriter.writeBytes(avc1Box)
        let stsdBox = buildBox("stsd", data: stsdWriter.data)

        let stblBox = buildBox("stbl", data: stsdBox)
        let minfBox = buildBox("minf", data: stblBox)
        let mdiaBox = buildBox("mdia", data: hdlrBox + minfBox)
        let trakBox = buildBox("trak", data: tkhdBox + mdiaBox)

        let moovBox = buildBox("moov", data: mvhdBox + trakBox)
        writer.writeBytes(moovBox)
        return writer.data
    }

    /// Build an MP4 with QuickTime metadata (ilst items).
    func testParseLivePhotoContentIdentifier() throws {
        let uuid = "B12C123E-4567-89AB-CDEF-012345678901"
        let data = buildMP4WithContentIdentifier(uuid)
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.contentIdentifier, uuid)
    }

    /// Build an MP4 whose moov/udta/meta box exposes the QuickTime mdta key
    /// `com.apple.quicktime.content.identifier` — the standard Apple Live Photo identifier.
    private func buildMP4WithContentIdentifier(_ uuid: String) -> Data {
        var writer = BinaryWriter(capacity: 512)
        writeFtyp(&writer, brand: "isom")

        var mvhdWriter = BinaryWriter(capacity: 128)
        mvhdWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        mvhdWriter.writeBytes(Data(repeating: 0, count: 96))
        let mvhdBox = buildBox("mvhd", data: mvhdWriter.data)

        // keys: FullBox + entry_count + per entry (key_size, "mdta", key_value)
        let key = "com.apple.quicktime.content.identifier"
        var keysWriter = BinaryWriter(capacity: 64)
        keysWriter.writeBytes([0x00, 0x00, 0x00, 0x00]) // version + flags
        keysWriter.writeUInt32BigEndian(1)              // entry_count
        let keyBytes = Data(key.utf8)
        keysWriter.writeUInt32BigEndian(UInt32(8 + keyBytes.count)) // key_size
        keysWriter.writeString("mdta", encoding: .ascii)
        keysWriter.writeBytes(keyBytes)
        let keysBox = buildBox("keys", data: keysWriter.data)

        // ilst entry whose box type is the 4-byte BE encoding of key index 1.
        var dataPayload = BinaryWriter(capacity: 32)
        dataPayload.writeUInt32BigEndian(1) // type indicator: UTF-8
        dataPayload.writeUInt32BigEndian(0) // locale
        dataPayload.writeBytes(Data(uuid.utf8))
        let dataBox = buildBox("data", data: dataPayload.data)

        // Item box: size + 4-byte index (UInt32 BE = 1) + dataBox
        let indexBytes = Data([0x00, 0x00, 0x00, 0x01])
        var itemWriter = BinaryWriter(capacity: 8 + dataBox.count)
        itemWriter.writeUInt32BigEndian(UInt32(8 + dataBox.count))
        itemWriter.writeBytes(indexBytes)
        itemWriter.writeBytes(dataBox)
        let ilstBox = buildBox("ilst", data: itemWriter.data)

        // hdlr ("mdta")
        var hdlrWriter = BinaryWriter(capacity: 32)
        hdlrWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        hdlrWriter.writeBytes(Data(repeating: 0, count: 4))
        hdlrWriter.writeString("mdta", encoding: .ascii)
        hdlrWriter.writeBytes(Data(repeating: 0, count: 12))
        let hdlrBox = buildBox("hdlr", data: hdlrWriter.data)

        var metaPayload = Data([0x00, 0x00, 0x00, 0x00]) // version + flags
        metaPayload.append(hdlrBox)
        metaPayload.append(keysBox)
        metaPayload.append(ilstBox)

        let metaBox = buildBox("meta", data: metaPayload)
        let udtaBox = buildBox("udta", data: metaBox)
        let moovBox = buildBox("moov", data: mvhdBox + udtaBox)
        writer.writeBytes(moovBox)
        return writer.data
    }

    private func buildMP4WithMetadata(title: String?, artist: String?, comment: String?, gps: String?) -> Data {
        var writer = BinaryWriter(capacity: 512)
        writeFtyp(&writer, brand: "isom")

        // Build mvhd
        var mvhdWriter = BinaryWriter(capacity: 128)
        mvhdWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        mvhdWriter.writeBytes(Data(repeating: 0, count: 96))
        let mvhdBox = buildBox("mvhd", data: mvhdWriter.data)

        // Build ilst items
        var ilstData = Data()
        if let t = title { ilstData.append(buildILSTItem(key: "\u{00A9}nam", value: t)) }
        if let a = artist { ilstData.append(buildILSTItem(key: "\u{00A9}ART", value: a)) }
        if let c = comment { ilstData.append(buildILSTItem(key: "\u{00A9}cmt", value: c)) }
        if let g = gps { ilstData.append(buildILSTItem(key: "\u{00A9}xyz", value: g)) }

        let ilstBox = buildBox("ilst", data: ilstData)

        // meta is FullBox — 4-byte header before children
        var metaPayload = Data([0x00, 0x00, 0x00, 0x00]) // version + flags
        // hdlr box (required in meta)
        var hdlrWriter = BinaryWriter(capacity: 32)
        hdlrWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        hdlrWriter.writeBytes(Data(repeating: 0, count: 4))
        hdlrWriter.writeString("mdir", encoding: .ascii)
        hdlrWriter.writeBytes(Data(repeating: 0, count: 12))
        metaPayload.append(buildBox("hdlr", data: hdlrWriter.data))
        metaPayload.append(ilstBox)

        let metaBox = buildBox("meta", data: metaPayload)
        let udtaBox = buildBox("udta", data: metaBox)
        let moovBox = buildBox("moov", data: mvhdBox + udtaBox)
        writer.writeBytes(moovBox)

        return writer.data
    }

    /// Build an ilst item with a data sub-box.
    private func buildILSTItem(key: String, value: String) -> Data {
        // data sub-box: type_indicator(4) + locale(4) + payload
        var dataWriter = BinaryWriter(capacity: 64)
        dataWriter.writeUInt32BigEndian(1) // type indicator: UTF-8
        dataWriter.writeUInt32BigEndian(0) // locale
        dataWriter.writeBytes(Data(value.utf8))
        let dataBox = buildBox("data", data: dataWriter.data)

        // Item box: key type + data box
        return buildBoxRaw(key, data: dataBox)
    }

    private func writeFtyp(_ writer: inout BinaryWriter, brand: String) {
        let payload = Data(brand.utf8) + Data([0x00, 0x00, 0x00, 0x00])
        writer.writeUInt32BigEndian(UInt32(8 + payload.count))
        writer.writeString("ftyp", encoding: .ascii)
        writer.writeBytes(payload)
    }

    private func buildBox(_ type: String, data: Data) -> Data {
        var writer = BinaryWriter(capacity: 8 + data.count)
        writer.writeUInt32BigEndian(UInt32(8 + data.count))
        writer.writeString(type, encoding: .ascii)
        writer.writeBytes(data)
        return writer.data
    }

    /// Build a box with a raw (non-ASCII) type string, using isoLatin1 encoding.
    private func buildBoxRaw(_ type: String, data: Data) -> Data {
        var writer = BinaryWriter(capacity: 8 + data.count)
        writer.writeUInt32BigEndian(UInt32(8 + data.count))
        writer.writeString(type, encoding: .isoLatin1)
        writer.writeBytes(data)
        return writer.data
    }
}
