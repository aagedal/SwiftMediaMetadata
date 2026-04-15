import XCTest
@testable import SwiftExif

final class Phase12FeatureTests: XCTestCase {

    // MARK: - Extended RAW Format Detection

    func testDetectRAFFromExtension() {
        XCTAssertEqual(FormatDetector.detectFromExtension("raf"), .raw(.raf))
    }

    func testDetectRW2FromExtension() {
        XCTAssertEqual(FormatDetector.detectFromExtension("rw2"), .raw(.rw2))
    }

    func testDetectORFFromExtension() {
        XCTAssertEqual(FormatDetector.detectFromExtension("orf"), .raw(.orf))
    }

    func testDetectPEFFromExtension() {
        XCTAssertEqual(FormatDetector.detectFromExtension("pef"), .raw(.pef))
    }

    func testRawFormatEnumCases() {
        let allCases = ImageFormat.RawFormat.allCases
        XCTAssertTrue(allCases.contains(.raf))
        XCTAssertTrue(allCases.contains(.rw2))
        XCTAssertTrue(allCases.contains(.orf))
        XCTAssertTrue(allCases.contains(.pef))
        XCTAssertEqual(allCases.count, 9) // dng, cr2, cr3, nef, arw, raf, rw2, orf, pef
    }

    // MARK: - RAF Magic Byte Detection

    func testDetectRAFFromMagicBytes() {
        let data = TestFixtures.minimalRAF()
        XCTAssertEqual(FormatDetector.detect(data), .raw(.raf))
    }

    func testRAFDetectedByRAWParser() {
        let data = TestFixtures.minimalRAF()
        let format = RAWFileParser.detectRAWFormat(data)
        XCTAssertEqual(format, .raf)
    }

    // MARK: - RW2 Magic Byte Detection

    func testDetectRW2FromMagicBytes() {
        let data = TestFixtures.minimalRW2()
        XCTAssertEqual(FormatDetector.detect(data), .raw(.rw2))
    }

    func testRW2DetectedByRAWParser() {
        let data = TestFixtures.minimalRW2()
        let format = RAWFileParser.detectRAWFormat(data)
        XCTAssertEqual(format, .rw2)
    }

    // MARK: - ORF Detection via Make Tag

    func testDetectORFFromMakeTag() {
        let data = TestFixtures.tiffWithExif(make: "OLYMPUS CORPORATION", model: "E-M1X")
        XCTAssertEqual(FormatDetector.detect(data), .raw(.orf))
    }

    // MARK: - PEF Detection via Make Tag

    func testDetectPEFFromMakeTag() {
        let data = TestFixtures.tiffWithExif(make: "PENTAX", model: "K-1 Mark II")
        XCTAssertEqual(FormatDetector.detect(data), .raw(.pef))
    }

    func testDetectPEFFromRicoh() {
        let data = TestFixtures.tiffWithExif(make: "RICOH IMAGING", model: "PENTAX K-3 III")
        XCTAssertEqual(FormatDetector.detect(data), .raw(.pef))
    }

    // MARK: - ORF/PEF Read via ImageMetadata

    func testReadORFAsImageMetadata() throws {
        let data = TestFixtures.tiffWithExif(make: "OLYMPUS CORPORATION", model: "E-M1X")
        let metadata = try ImageMetadata.read(from: data, format: .raw(.orf))

        XCTAssertEqual(metadata.format, .raw(.orf))
        XCTAssertEqual(metadata.exif?.make, "OLYMPUS CORPORATION")
        XCTAssertEqual(metadata.exif?.model, "E-M1X")
    }

    func testReadPEFAsImageMetadata() throws {
        let data = TestFixtures.tiffWithExif(make: "PENTAX", model: "K-1 Mark II")
        let metadata = try ImageMetadata.read(from: data, format: .raw(.pef))

        XCTAssertEqual(metadata.format, .raw(.pef))
        XCTAssertEqual(metadata.exif?.make, "PENTAX")
    }

    // MARK: - RW2 Parsing

    func testParseRW2() throws {
        let data = TestFixtures.minimalRW2(make: "Panasonic", model: "DC-GH6")
        let tiff = try RAWFileParser.parse(data, format: .rw2)
        let exif = try TIFFFileParser.extractExif(from: tiff, data: tiff.rawData)

        XCTAssertEqual(exif?.make, "Panasonic")
        XCTAssertEqual(exif?.model, "DC-GH6")
    }

    func testReadRW2AsImageMetadata() throws {
        let data = TestFixtures.minimalRW2(make: "Panasonic", model: "DC-GH6")
        let metadata = try ImageMetadata.read(from: data, format: .raw(.rw2))

        XCTAssertEqual(metadata.format, .raw(.rw2))
        XCTAssertEqual(metadata.exif?.make, "Panasonic")
    }

    // MARK: - RAF Parsing

    func testParseRAF() throws {
        let data = TestFixtures.minimalRAF(make: "FUJIFILM", model: "X-T5")
        let tiff = try RAWFileParser.parse(data, format: .raf)
        let exif = try TIFFFileParser.extractExif(from: tiff, data: tiff.rawData)

        XCTAssertEqual(exif?.make, "FUJIFILM")
        XCTAssertEqual(exif?.model, "X-T5")
    }

    func testReadRAFAsImageMetadata() throws {
        let data = TestFixtures.minimalRAF(make: "FUJIFILM", model: "X-T5")
        let metadata = try ImageMetadata.read(from: data, format: .raw(.raf))

        XCTAssertEqual(metadata.format, .raw(.raf))
        XCTAssertEqual(metadata.exif?.make, "FUJIFILM")
    }

    // MARK: - Video Metadata Writing (MP4)

    func testVideoWriteRoundTrip() throws {
        let original = buildMP4WithMetadata(title: "Original Title", artist: "Original Artist")
        var metadata = try VideoMetadata.read(from: original)

        metadata.title = "Updated Title"
        metadata.artist = "Updated Artist"
        metadata.comment = "New Comment"

        let written = try metadata.writeToData()
        let readBack = try VideoMetadata.read(from: written)

        XCTAssertEqual(readBack.title, "Updated Title")
        XCTAssertEqual(readBack.artist, "Updated Artist")
        XCTAssertEqual(readBack.comment, "New Comment")
    }

    func testVideoWriteGPS() throws {
        let original = buildMP4WithMetadata(title: nil, artist: nil)
        var metadata = try VideoMetadata.read(from: original)

        metadata.gpsLatitude = 59.9139
        metadata.gpsLongitude = 10.7522

        let written = try metadata.writeToData()
        let readBack = try VideoMetadata.read(from: written)

        XCTAssertEqual(readBack.gpsLatitude!, 59.9139, accuracy: 0.001)
        XCTAssertEqual(readBack.gpsLongitude!, 10.7522, accuracy: 0.001)
    }

    func testVideoWriteGPSWithAltitude() throws {
        let original = buildMP4WithMetadata(title: nil, artist: nil)
        var metadata = try VideoMetadata.read(from: original)

        metadata.gpsLatitude = -33.8688
        metadata.gpsLongitude = 151.2093
        metadata.gpsAltitude = 42.5

        let written = try metadata.writeToData()
        let readBack = try VideoMetadata.read(from: written)

        XCTAssertEqual(readBack.gpsLatitude!, -33.8688, accuracy: 0.001)
        XCTAssertEqual(readBack.gpsLongitude!, 151.2093, accuracy: 0.001)
        XCTAssertEqual(readBack.gpsAltitude!, 42.5, accuracy: 0.1)
    }

    func testVideoStripMetadata() throws {
        let original = buildMP4WithMetadata(title: "Video Title", artist: "Video Artist")
        var metadata = try VideoMetadata.read(from: original)

        XCTAssertEqual(metadata.title, "Video Title")
        metadata.stripMetadata()

        let written = try metadata.writeToData()
        let readBack = try VideoMetadata.read(from: written)

        XCTAssertNil(readBack.title)
        XCTAssertNil(readBack.artist)
    }

    func testVideoWritePreservesFormat() throws {
        let original = buildMP4WithMetadata(title: "Test", artist: nil, brand: "qt  ")
        var metadata = try VideoMetadata.read(from: original)

        metadata.title = "Updated"
        let written = try metadata.writeToData()
        let readBack = try VideoMetadata.read(from: written)

        XCTAssertEqual(readBack.format, .mov)
        XCTAssertEqual(readBack.title, "Updated")
    }

    func testVideoWriteToNewMetadata() throws {
        // Start with a video that has no metadata (no udta/ilst)
        let original = buildBareMP4()
        var metadata = try VideoMetadata.read(from: original)

        XCTAssertNil(metadata.title)

        metadata.title = "Brand New Title"
        metadata.artist = "New Artist"

        let written = try metadata.writeToData()
        let readBack = try VideoMetadata.read(from: written)

        XCTAssertEqual(readBack.title, "Brand New Title")
        XCTAssertEqual(readBack.artist, "New Artist")
    }

    func testVideoWriteNordic() throws {
        let original = buildMP4WithMetadata(title: nil, artist: nil)
        var metadata = try VideoMetadata.read(from: original)

        metadata.title = "Tromsø vinterfestival"
        metadata.artist = "Björk Guðmundsdóttir"
        metadata.comment = "Ærø Kommune, Østfold"

        let written = try metadata.writeToData()
        let readBack = try VideoMetadata.read(from: written)

        XCTAssertEqual(readBack.title, "Tromsø vinterfestival")
        XCTAssertEqual(readBack.artist, "Björk Guðmundsdóttir")
        XCTAssertEqual(readBack.comment, "Ærø Kommune, Østfold")
    }

    func testVideoWriteWithoutOriginalDataThrows() {
        var metadata = VideoMetadata(format: .mp4)
        metadata.title = "Test"

        XCTAssertThrowsError(try metadata.writeToData()) { error in
            let desc = (error as? MetadataError)?.description ?? ""
            XCTAssertTrue(desc.contains("No original video data"))
        }
    }

    func testVideoStripGPS() throws {
        let original = buildMP4WithMetadata(title: "Keep This", artist: nil, gps: "+59.9139+010.7522/")
        var metadata = try VideoMetadata.read(from: original)

        XCTAssertNotNil(metadata.gpsLatitude)
        XCTAssertEqual(metadata.title, "Keep This")

        metadata.stripGPS()

        let written = try metadata.writeToData()
        let readBack = try VideoMetadata.read(from: written)

        XCTAssertNil(readBack.gpsLatitude)
        XCTAssertNil(readBack.gpsLongitude)
        XCTAssertEqual(readBack.title, "Keep This") // Preserved
    }

    func testVideoWritePreservesDuration() throws {
        let original = buildMP4WithDuration(seconds: 42.0, timescale: 1000)
        var metadata = try VideoMetadata.read(from: original)

        XCTAssertEqual(metadata.duration!, 42.0, accuracy: 0.01)

        metadata.title = "New Title"
        let written = try metadata.writeToData()
        let readBack = try VideoMetadata.read(from: written)

        XCTAssertEqual(readBack.duration!, 42.0, accuracy: 0.01)
        XCTAssertEqual(readBack.title, "New Title")
    }

    // MARK: - Video Helper Functions

    private func buildMP4WithMetadata(title: String?, artist: String?, brand: String = "isom", gps: String? = nil) -> Data {
        var writer = BinaryWriter(capacity: 512)
        writeFtyp(&writer, brand: brand)

        // Build mvhd
        var mvhdWriter = BinaryWriter(capacity: 128)
        mvhdWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        mvhdWriter.writeBytes(Data(repeating: 0, count: 96))
        let mvhdBox = buildBox("mvhd", data: mvhdWriter.data)

        // Build ilst items
        var ilstData = Data()
        if let t = title { ilstData.append(buildILSTItem(key: "\u{00A9}nam", value: t)) }
        if let a = artist { ilstData.append(buildILSTItem(key: "\u{00A9}ART", value: a)) }
        if let g = gps { ilstData.append(buildILSTItem(key: "\u{00A9}xyz", value: g)) }
        let ilstBox = buildBox("ilst", data: ilstData)

        var metaPayload = Data([0x00, 0x00, 0x00, 0x00])
        var hdlrWriter = BinaryWriter(capacity: 32)
        hdlrWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        hdlrWriter.writeBytes(Data(repeating: 0, count: 4))
        hdlrWriter.writeString("mdir", encoding: .ascii)
        hdlrWriter.writeBytes(Data(repeating: 0, count: 12))
        hdlrWriter.writeUInt8(0)
        metaPayload.append(buildBox("hdlr", data: hdlrWriter.data))
        metaPayload.append(ilstBox)

        let metaBox = buildBox("meta", data: metaPayload)
        let udtaBox = buildBox("udta", data: metaBox)
        let moovBox = buildBox("moov", data: mvhdBox + udtaBox)
        writer.writeBytes(moovBox)

        return writer.data
    }

    private func buildBareMP4() -> Data {
        var writer = BinaryWriter(capacity: 256)
        writeFtyp(&writer, brand: "isom")

        var mvhdWriter = BinaryWriter(capacity: 128)
        mvhdWriter.writeBytes([0x00, 0x00, 0x00, 0x00])
        mvhdWriter.writeBytes(Data(repeating: 0, count: 96))
        let mvhdBox = buildBox("mvhd", data: mvhdWriter.data)
        let moovBox = buildBox("moov", data: mvhdBox)
        writer.writeBytes(moovBox)

        return writer.data
    }

    private func buildMP4WithDuration(seconds: Double, timescale: UInt32) -> Data {
        var writer = BinaryWriter(capacity: 256)
        writeFtyp(&writer, brand: "isom")

        var mvhdWriter = BinaryWriter(capacity: 128)
        mvhdWriter.writeBytes([0x00, 0x00, 0x00, 0x00]) // version + flags
        mvhdWriter.writeUInt32BigEndian(0) // creation_time
        mvhdWriter.writeUInt32BigEndian(0) // modification_time
        mvhdWriter.writeUInt32BigEndian(timescale)
        mvhdWriter.writeUInt32BigEndian(UInt32(seconds * Double(timescale)))
        mvhdWriter.writeBytes(Data(repeating: 0, count: 80))
        let mvhdBox = buildBox("mvhd", data: mvhdWriter.data)
        let moovBox = buildBox("moov", data: mvhdBox)
        writer.writeBytes(moovBox)

        return writer.data
    }

    private func buildILSTItem(key: String, value: String) -> Data {
        var dataWriter = BinaryWriter(capacity: 64)
        dataWriter.writeUInt32BigEndian(1) // UTF-8
        dataWriter.writeUInt32BigEndian(0) // locale
        dataWriter.writeBytes(Data(value.utf8))
        let dataBox = buildBox("data", data: dataWriter.data)
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

    private func buildBoxRaw(_ type: String, data: Data) -> Data {
        var writer = BinaryWriter(capacity: 8 + data.count)
        writer.writeUInt32BigEndian(UInt32(8 + data.count))
        writer.writeString(type, encoding: .isoLatin1)
        writer.writeBytes(data)
        return writer.data
    }
}
