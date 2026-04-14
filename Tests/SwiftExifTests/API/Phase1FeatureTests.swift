import XCTest
@testable import SwiftExif

final class MetadataStrippingTests: XCTestCase {

    func testStripAllMetadata() throws {
        var metadata = try makeMetadataWithAllTypes()
        XCTAssertNotNil(metadata.exif)
        XCTAssertNotNil(metadata.xmp)
        XCTAssertFalse(metadata.iptc.datasets.isEmpty)

        metadata.stripAllMetadata()

        XCTAssertNil(metadata.exif)
        XCTAssertNil(metadata.xmp)
        XCTAssertNil(metadata.c2pa)
        XCTAssertTrue(metadata.iptc.datasets.isEmpty)
    }

    func testStripExifOnly() throws {
        var metadata = try makeMetadataWithAllTypes()
        metadata.stripExif()

        XCTAssertNil(metadata.exif)
        XCTAssertNotNil(metadata.xmp)
        XCTAssertEqual(metadata.iptc.headline, "Test Headline")
    }

    func testStripIPTCOnly() throws {
        var metadata = try makeMetadataWithAllTypes()
        metadata.stripIPTC()

        XCTAssertTrue(metadata.iptc.datasets.isEmpty)
        XCTAssertNotNil(metadata.exif)
        XCTAssertNotNil(metadata.xmp)
    }

    func testStripXMPOnly() throws {
        var metadata = try makeMetadataWithAllTypes()
        metadata.stripXMP()

        XCTAssertNil(metadata.xmp)
        XCTAssertNotNil(metadata.exif)
        XCTAssertEqual(metadata.iptc.headline, "Test Headline")
    }

    func testStripGPS() throws {
        // Build metadata with GPS data
        var exif = ExifData(byteOrder: .bigEndian)
        let latRef = IFDEntry(tag: ExifTag.gpsLatitudeRef, type: .ascii, count: 2, valueData: Data("N\0".utf8))
        exif.gpsIFD = IFD(entries: [latRef])

        var metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg, exif: exif)
        XCTAssertNotNil(metadata.exif?.gpsIFD)

        metadata.stripGPS()

        XCTAssertNil(metadata.exif?.gpsIFD)
        XCTAssertNotNil(metadata.exif) // Non-GPS exif preserved
    }

    func testStripAndWriteBack() throws {
        var iptc = IPTCData()
        iptc.headline = "To Be Stripped"
        let jpeg = TestFixtures.jpegWithIPTC(datasets: iptc.datasets)

        var metadata = try ImageMetadata.read(from: jpeg)
        metadata.stripIPTC()

        let data = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: data)
        XCTAssertNil(reparsed.iptc.headline)
    }

    func testStripC2PA() throws {
        var metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        metadata.c2pa = C2PAData(manifests: [])
        XCTAssertNotNil(metadata.c2pa)

        metadata.stripC2PA()
        XCTAssertNil(metadata.c2pa)
    }

    private func makeMetadataWithAllTypes() throws -> ImageMetadata {
        var metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        metadata.iptc.headline = "Test Headline"
        metadata.iptc.city = "Oslo"
        metadata.exif = ExifData(byteOrder: .bigEndian)
        metadata.exif?.ifd0 = IFD(entries: [
            IFDEntry(tag: ExifTag.make, type: .ascii, count: 5, valueData: Data("Test\0".utf8)),
        ])
        metadata.xmp = XMPData()
        metadata.xmp?.title = "Test Title"
        return metadata
    }
}

final class MetadataExporterTests: XCTestCase {

    func testJSONExportContainsIPTC() throws {
        var iptc = IPTCData()
        iptc.headline = "Breaking News"
        iptc.city = "Tromsø"
        iptc.keywords = ["arctic", "norway"]
        let jpeg = TestFixtures.jpegWithIPTC(datasets: iptc.datasets)

        let metadata = try ImageMetadata.read(from: jpeg)
        let jsonData = MetadataExporter.toJSON(metadata)
        let json = try JSONSerialization.jsonObject(with: jsonData) as! [[String: Any]]

        XCTAssertEqual(json.count, 1)
        let entry = json[0]
        XCTAssertEqual(entry["IPTC:Headline"] as? String, "Breaking News")
        XCTAssertEqual(entry["IPTC:City"] as? String, "Tromsø")
        XCTAssertEqual(entry["IPTC:Keywords"] as? [String], ["arctic", "norway"])
        XCTAssertEqual(entry["FileFormat"] as? String, "JPEG")
    }

    func testJSONStringOutput() throws {
        var metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        metadata.iptc.headline = "Test"
        let str = MetadataExporter.toJSONString(metadata)
        XCTAssertTrue(str.contains("Test"))
        XCTAssertTrue(str.contains("IPTC:Headline"))
    }

    func testXMLExportContainsFields() throws {
        var metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        metadata.iptc.headline = "XML Test"
        metadata.iptc.city = "Bergen"

        let xml = MetadataExporter.toXML(metadata)
        XCTAssertTrue(xml.contains("XML Test"))
        XCTAssertTrue(xml.contains("Bergen"))
        XCTAssertTrue(xml.hasPrefix("<?xml"))
    }

    func testMultipleFilesJSON() throws {
        var m1 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m1.iptc.headline = "First"
        var m2 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m2.iptc.headline = "Second"

        let jsonData = MetadataExporter.toJSON([m1, m2])
        let json = try JSONSerialization.jsonObject(with: jsonData) as! [[String: Any]]
        XCTAssertEqual(json.count, 2)
        XCTAssertEqual(json[0]["IPTC:Headline"] as? String, "First")
        XCTAssertEqual(json[1]["IPTC:Headline"] as? String, "Second")
    }

    func testExifFieldsInJSON() throws {
        let exifData = TestFixtures.exifAPP1Data(byteOrder: .bigEndian, ifd0Entries: [
            (tag: ExifTag.make, stringValue: "Nikon"),
            (tag: ExifTag.model, stringValue: "Z9"),
        ])
        let jpeg = TestFixtures.jpegWithSegment(marker: .app1, data: exifData)
        let metadata = try ImageMetadata.read(from: jpeg)

        let dict = MetadataExporter.buildDictionary(metadata)
        XCTAssertEqual(dict["Make"] as? String, "Nikon")
        XCTAssertEqual(dict["Model"] as? String, "Z9")
    }

    func testXMPFieldsInJSON() throws {
        var metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "XMP Headline"
        metadata.xmp?.city = "Stockholm"

        let dict = MetadataExporter.buildDictionary(metadata)
        XCTAssertEqual(dict["XMP-photoshop:Headline"] as? String, "XMP Headline")
        XCTAssertEqual(dict["XMP-photoshop:City"] as? String, "Stockholm")
    }

    func testXMLEscapesSpecialCharacters() throws {
        var metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        metadata.iptc.headline = "Test <>&\""

        let xml = MetadataExporter.toXML(metadata)
        XCTAssertTrue(xml.contains("&lt;"))
        XCTAssertTrue(xml.contains("&gt;"))
        XCTAssertTrue(xml.contains("&amp;"))
    }
}

final class LegacyEncodingTests: XCTestCase {

    func testReadISO88591IPTC() throws {
        // Build IPTC data in ISO-8859-1 (no CodedCharacterSet tag)
        // "Tromsø" in ISO-8859-1: 54 72 6F 6D 73 F8
        let tromsoLatin1 = Data([0x54, 0x72, 0x6F, 0x6D, 0x73, 0xF8])
        let datasets = [
            IPTCDataSet(tag: .city, rawValue: tromsoLatin1),
        ]

        // Build raw IPTC binary manually (no UTF-8 charset tag)
        let rawIPTC = buildRawIPTC(datasets: datasets)
        let iptc = try IPTCReader.read(from: rawIPTC)

        // Should be detected as ISO-8859-1 (bytes 0x80-0x9F not present, non-UTF8)
        // But since 0xF8 is valid Latin-1 and NOT valid as a standalone UTF-8 byte,
        // the heuristic should pick ISO-8859-1
        XCTAssertEqual(iptc.value(for: .city), "Tromsø")
    }

    func testReadWindowsCP1252IPTC() throws {
        // Build IPTC data in Windows-1252
        // Windows-1252 has characters in 0x80-0x9F range that ISO-8859-1 doesn't
        // 0x93 = left double quotation mark in CP1252
        let cp1252Text = Data([0x93, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x94]) // "Hello"
        let datasets = [
            IPTCDataSet(tag: .headline, rawValue: cp1252Text),
        ]

        let rawIPTC = buildRawIPTC(datasets: datasets)
        let iptc = try IPTCReader.read(from: rawIPTC)

        XCTAssertEqual(iptc.encoding, .windowsCP1252)
        let headline = iptc.value(for: .headline)
        XCTAssertNotNil(headline)
        XCTAssertTrue(headline!.contains("Hello"))
    }

    func testUTF8WithoutCharsetTagDetected() throws {
        // "Tromsø" in UTF-8: 54 72 6F 6D 73 C3 B8
        let tromsoUTF8 = Data([0x54, 0x72, 0x6F, 0x6D, 0x73, 0xC3, 0xB8])
        let datasets = [
            IPTCDataSet(tag: .city, rawValue: tromsoUTF8),
        ]

        let rawIPTC = buildRawIPTC(datasets: datasets)
        let iptc = try IPTCReader.read(from: rawIPTC)

        // Should detect as UTF-8 even without CodedCharacterSet tag
        XCTAssertEqual(iptc.encoding, .utf8)
        XCTAssertEqual(iptc.value(for: .city), "Tromsø")
    }

    func testWriterConvertsLatin1ToUTF8() throws {
        // Create IPTC data with ISO-8859-1 encoding
        let tromsoLatin1 = Data([0x54, 0x72, 0x6F, 0x6D, 0x73, 0xF8])
        let datasets = [
            IPTCDataSet(tag: .city, rawValue: tromsoLatin1),
        ]
        let iptc = IPTCData(datasets: datasets, encoding: .isoLatin1)

        // Write should convert to UTF-8
        let written = try IPTCWriter.write(iptc)

        // Re-read and verify it's now UTF-8
        let reparsed = try IPTCReader.read(from: written)
        XCTAssertEqual(reparsed.encoding, .utf8)
        XCTAssertEqual(reparsed.value(for: .city), "Tromsø")
    }

    func testWriterConvertsCP1252ToUTF8() throws {
        let cp1252Text = Data([0x93, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x94]) // "Hello"
        let datasets = [
            IPTCDataSet(tag: .headline, rawValue: cp1252Text),
        ]
        let iptc = IPTCData(datasets: datasets, encoding: .windowsCP1252)

        let written = try IPTCWriter.write(iptc)
        let reparsed = try IPTCReader.read(from: written)

        XCTAssertEqual(reparsed.encoding, .utf8)
        let headline = reparsed.value(for: .headline)
        XCTAssertNotNil(headline)
        XCTAssertTrue(headline!.contains("Hello"))
    }

    func testASCIIOnlyDefaultsToUTF8() throws {
        let asciiText = Data("Hello World".utf8)
        let datasets = [
            IPTCDataSet(tag: .headline, rawValue: asciiText),
        ]

        let rawIPTC = buildRawIPTC(datasets: datasets)
        let iptc = try IPTCReader.read(from: rawIPTC)

        // Pure ASCII — encoding defaults to UTF-8
        XCTAssertEqual(iptc.encoding, .utf8)
        XCTAssertEqual(iptc.value(for: .headline), "Hello World")
    }

    /// Build raw IPTC binary without any CodedCharacterSet tag.
    private func buildRawIPTC(datasets: [IPTCDataSet]) -> Data {
        var writer = BinaryWriter(capacity: 256)
        for ds in datasets {
            writer.writeUInt8(0x1C)
            writer.writeUInt8(ds.tag.record)
            writer.writeUInt8(ds.tag.dataSet)
            writer.writeUInt16BigEndian(UInt16(ds.rawValue.count))
            writer.writeBytes(ds.rawValue)
        }
        return writer.data
    }
}

final class DateShiftingTests: XCTestCase {

    func testShiftExifDateString() {
        // Shift forward by 2 hours
        let result = ImageMetadata.shiftExifDateString("2024:01:15 14:30:00", by: 7200)
        XCTAssertEqual(result, "2024:01:15 16:30:00")
    }

    func testShiftExifDateStringBackward() {
        // Shift backward by 3 hours
        let result = ImageMetadata.shiftExifDateString("2024:01:15 02:00:00", by: -10800)
        XCTAssertEqual(result, "2024:01:14 23:00:00")
    }

    func testShiftExifDateStringCrossDay() {
        // Shift that crosses midnight
        let result = ImageMetadata.shiftExifDateString("2024:01:31 23:00:00", by: 7200)
        XCTAssertEqual(result, "2024:02:01 01:00:00")
    }

    func testShiftDateStringISO8601() {
        let result = ImageMetadata.shiftDateString("2024-01-15", by: 86400)
        XCTAssertEqual(result, "2024-01-16")
    }

    func testShiftDatesUpdatesIPTC() throws {
        var metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        metadata.iptc.dateCreated = "20240115"
        try metadata.iptc.setValue("143000", for: .timeCreated)

        metadata.shiftDates(by: 7200) // +2 hours

        XCTAssertEqual(metadata.iptc.dateCreated, "20240115")
        XCTAssertEqual(metadata.iptc.value(for: .timeCreated), "163000")
    }

    func testShiftDatesUpdatesXMP() throws {
        var metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        metadata.xmp = XMPData()
        metadata.xmp?.setValue(.simple("2024:01:15 14:30:00"), namespace: XMPNamespace.photoshop, property: "DateCreated")

        metadata.shiftDates(by: 7200)

        let dateCreated = metadata.xmp?.simpleValue(namespace: XMPNamespace.photoshop, property: "DateCreated")
        XCTAssertEqual(dateCreated, "2024:01:15 16:30:00")
    }

    func testShiftDatesNegativeInterval() throws {
        var metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        metadata.iptc.dateCreated = "20240115"
        try metadata.iptc.setValue("020000", for: .timeCreated)

        metadata.shiftDates(by: -10800) // -3 hours

        XCTAssertEqual(metadata.iptc.dateCreated, "20240114")
        XCTAssertEqual(metadata.iptc.value(for: .timeCreated), "230000")
    }

    func testShiftInvalidDateIsNoOp() {
        let result = ImageMetadata.shiftExifDateString("not-a-date", by: 3600)
        XCTAssertNil(result)
    }
}
