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

    func testMissingFtypThrows() {
        let data = Data(repeating: 0x00, count: 50)
        XCTAssertThrowsError(try VideoMetadata.read(from: data))
    }

    func testMissingMoovThrows() {
        let data = buildMinimalMP4(brand: "isom") // ftyp only, no moov
        XCTAssertThrowsError(try VideoMetadata.read(from: data))
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

    // MARK: - Helpers

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

    /// Build an MP4 with QuickTime metadata (ilst items).
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
