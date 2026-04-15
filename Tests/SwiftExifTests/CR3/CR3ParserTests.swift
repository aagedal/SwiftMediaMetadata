import XCTest
@testable import SwiftExif

final class CR3ParserTests: XCTestCase {

    // MARK: - Synthetic CR3 Builder

    /// Build a minimal valid CR3 file with metadata in CMT boxes.
    static func buildSyntheticCR3(
        make: String = "Canon",
        model: String = "Canon EOS R5",
        dateTimeOriginal: String? = nil,
        gpsLatitude: Double? = nil,
        gpsLongitude: Double? = nil
    ) -> Data {
        var writer = BinaryWriter(capacity: 4096)

        // ftyp box
        let ftypPayload = Data("crx ".utf8) + Data([0, 0, 0, 0]) + Data("crx ".utf8)
        writeSyntheticBox(&writer, type: "ftyp", data: ftypPayload)

        // moov box containing Canon metadata uuid
        let moovPayload = buildMoovPayload(
            make: make, model: model, dateTimeOriginal: dateTimeOriginal,
            gpsLatitude: gpsLatitude, gpsLongitude: gpsLongitude
        )
        writeSyntheticBox(&writer, type: "moov", data: moovPayload)

        // XMP uuid box
        let xmpXML = """
        <?xpacket begin='\u{FEFF}' id='W5M0MpCehiHzreSzNTczkc9d'?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
         xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:creator><rdf:Seq><rdf:li>Test Photographer</rdf:li></rdf:Seq></dc:creator>
        </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end='w'?>
        """
        var xmpPayload = Data(CR3UUID.xmpUUID)
        xmpPayload.append(Data(xmpXML.utf8))
        writeSyntheticBox(&writer, type: "uuid", data: xmpPayload)

        // Minimal mdat
        writeSyntheticBox(&writer, type: "mdat", data: Data([0xFF, 0xD8, 0xFF, 0xD9]))

        return writer.data
    }

    private static func buildMoovPayload(
        make: String, model: String, dateTimeOriginal: String?,
        gpsLatitude: Double?, gpsLongitude: Double?
    ) -> Data {
        var moovWriter = BinaryWriter(capacity: 2048)

        // Canon metadata uuid container
        var metaWriter = BinaryWriter(capacity: 1024)

        // CMT1: IFD0 with Make and Model
        let cmt1 = buildCMT1(make: make, model: model)
        writeSyntheticBox(&metaWriter, type: "CMT1", data: cmt1)

        // CMT2: ExifIFD with DateTimeOriginal
        if let dto = dateTimeOriginal {
            let cmt2 = buildCMT2(dateTimeOriginal: dto)
            writeSyntheticBox(&metaWriter, type: "CMT2", data: cmt2)
        }

        // CMT4: GPS IFD
        if let lat = gpsLatitude, let lon = gpsLongitude {
            let cmt4 = buildCMT4(latitude: lat, longitude: lon)
            writeSyntheticBox(&metaWriter, type: "CMT4", data: cmt4)
        }

        // Wrap in uuid box with Canon metadata UUID
        var uuidPayload = Data(CR3UUID.canonMetadata)
        uuidPayload.append(metaWriter.data)
        writeSyntheticBox(&moovWriter, type: "uuid", data: uuidPayload)

        return moovWriter.data
    }

    private static func buildCMT1(make: String, model: String) -> Data {
        // Build a minimal TIFF with IFD0 containing Make and Model
        var exifData = ExifData(byteOrder: .littleEndian)
        let makeStr = make + "\0"
        let modelStr = model + "\0"

        var entries: [IFDEntry] = [
            IFDEntry(tag: ExifTag.make, type: .ascii, count: UInt32(makeStr.utf8.count), valueData: Data(makeStr.utf8)),
            IFDEntry(tag: ExifTag.model, type: .ascii, count: UInt32(modelStr.utf8.count), valueData: Data(modelStr.utf8)),
        ]
        entries.sort { $0.tag < $1.tag }
        exifData.ifd0 = IFD(entries: entries)
        return ExifWriter.writeTIFF(exifData)
    }

    private static func buildCMT2(dateTimeOriginal: String) -> Data {
        var exifData = ExifData(byteOrder: .littleEndian)
        let str = dateTimeOriginal + "\0"
        let entries = [
            IFDEntry(tag: ExifTag.dateTimeOriginal, type: .ascii, count: UInt32(str.utf8.count), valueData: Data(str.utf8)),
        ]
        exifData.ifd0 = IFD(entries: entries)
        return ExifWriter.writeTIFF(exifData)
    }

    private static func buildCMT4(latitude: Double, longitude: Double) -> Data {
        let trackpoint = GPXTrackpoint(latitude: latitude, longitude: longitude, timestamp: Date())
        let gpsIFD = GPXGeotagger.buildGPSIFD(from: trackpoint, byteOrder: .littleEndian)
        var exifData = ExifData(byteOrder: .littleEndian)
        exifData.ifd0 = gpsIFD
        return ExifWriter.writeTIFF(exifData)
    }

    private static func writeSyntheticBox(_ writer: inout BinaryWriter, type: String, data: Data) {
        writer.writeUInt32BigEndian(UInt32(8 + data.count))
        writer.writeString(type, encoding: .ascii)
        writer.writeBytes(data)
    }

    // MARK: - Format Detection

    func testDetectCR3Format() {
        let cr3Data = Self.buildSyntheticCR3()
        let format = FormatDetector.detect(cr3Data)
        XCTAssertEqual(format, .raw(.cr3))
    }

    func testDetectCR3FromExtension() {
        let format = FormatDetector.detectFromExtension("cr3")
        XCTAssertEqual(format, .raw(.cr3))
    }

    // MARK: - Parsing

    func testParseSyntheticCR3() throws {
        let cr3Data = Self.buildSyntheticCR3()
        let metadata = try ImageMetadata.read(from: cr3Data, format: .raw(.cr3))

        XCTAssertEqual(metadata.format, .raw(.cr3))
        XCTAssertEqual(metadata.exif?.make, "Canon")
        XCTAssertEqual(metadata.exif?.model, "Canon EOS R5")
    }

    func testParseCR3WithDateTimeOriginal() throws {
        let cr3Data = Self.buildSyntheticCR3(dateTimeOriginal: "2026:04:15 14:30:00")
        let metadata = try ImageMetadata.read(from: cr3Data, format: .raw(.cr3))

        XCTAssertEqual(metadata.exif?.dateTimeOriginal, "2026:04:15 14:30:00")
    }

    func testParseCR3WithGPS() throws {
        let cr3Data = Self.buildSyntheticCR3(gpsLatitude: 59.9139, gpsLongitude: 10.7522)
        let metadata = try ImageMetadata.read(from: cr3Data, format: .raw(.cr3))

        XCTAssertNotNil(metadata.exif?.gpsLatitude)
        XCTAssertNotNil(metadata.exif?.gpsLongitude)
        XCTAssertEqual(metadata.exif?.gpsLatitude ?? 0, 59.9139, accuracy: 0.01)
        XCTAssertEqual(metadata.exif?.gpsLongitude ?? 0, 10.7522, accuracy: 0.01)
    }

    func testParseCR3ExtractsXMP() throws {
        let cr3Data = Self.buildSyntheticCR3()
        let metadata = try ImageMetadata.read(from: cr3Data, format: .raw(.cr3))

        XCTAssertNotNil(metadata.xmp)
        XCTAssertEqual(metadata.xmp?.creator, ["Test Photographer"])
    }

    // MARK: - Round-Trip Writing

    func testCR3RoundTrip() throws {
        let cr3Data = Self.buildSyntheticCR3()
        var metadata = try ImageMetadata.read(from: cr3Data, format: .raw(.cr3))

        // Modify metadata
        metadata.setGPS(latitude: 40.7128, longitude: -74.0060)

        // Write back
        let written = try metadata.writeToData()

        // Re-read
        let reread = try ImageMetadata.read(from: written, format: .raw(.cr3))
        XCTAssertEqual(reread.exif?.make, "Canon")
        XCTAssertEqual(reread.exif?.gpsLatitude ?? 0, 40.7128, accuracy: 0.01)
        XCTAssertEqual(reread.exif?.gpsLongitude ?? 0, -74.0060, accuracy: 0.01)
    }

    func testCR3XMPRoundTrip() throws {
        let cr3Data = Self.buildSyntheticCR3()
        var metadata = try ImageMetadata.read(from: cr3Data, format: .raw(.cr3))

        metadata.xmp?.headline = "Test Headline"

        let written = try metadata.writeToData()
        let reread = try ImageMetadata.read(from: written, format: .raw(.cr3))
        XCTAssertEqual(reread.xmp?.headline, "Test Headline")
    }

    // MARK: - Container

    func testCR3ContainerType() throws {
        let cr3Data = Self.buildSyntheticCR3()
        let metadata = try ImageMetadata.read(from: cr3Data, format: .raw(.cr3))

        if case .cr3 = metadata.container {
            // OK
        } else {
            XCTFail("Expected .cr3 container")
        }
    }
}
