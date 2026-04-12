import XCTest
@testable import SwiftExif

final class FullRoundTripTests: XCTestCase {

    func testFullIPTCRoundTripWithNordicChars() throws {
        // Create metadata with Nordic content
        var metadata = ImageMetadata()
        metadata.jpegFile = try JPEGParser.parse(TestFixtures.minimalJPEG())

        metadata.iptc.headline = "Sterk nordavind i Tromsø"
        metadata.iptc.byline = "Bjørn Ødegård"
        metadata.iptc.city = "Tromsø"
        metadata.iptc.provinceState = "Troms og Finnmark"
        metadata.iptc.countryName = "Norge"
        metadata.iptc.countryCode = "NOR"
        metadata.iptc.keywords = ["vær", "storm", "Tromsø"]
        metadata.iptc.caption = "Kraftig nordavind i Tromsø førte til store bølger."
        metadata.iptc.copyright = "© NTB / Bjørn Ødegård"
        metadata.iptc.credit = "NTB Scanpix"
        metadata.iptc.source = "NTB"
        metadata.iptc.dateCreated = "20260412"
        metadata.iptc.timeCreated = "143000+0200"
        metadata.iptc.specialInstructions = "Kreditering påkrevet"
        metadata.iptc.writerEditor = "Skrivebord Øst"
        metadata.iptc.originatingProgram = "SwiftExif"
        metadata.iptc.programVersion = "1.0"

        // Write to data
        let jpeg = try metadata.writeToData()

        // Read back
        let reparsed = try ImageMetadata.read(from: jpeg)

        XCTAssertEqual(reparsed.iptc.headline, "Sterk nordavind i Tromsø")
        XCTAssertEqual(reparsed.iptc.byline, "Bjørn Ødegård")
        XCTAssertEqual(reparsed.iptc.city, "Tromsø")
        XCTAssertEqual(reparsed.iptc.provinceState, "Troms og Finnmark")
        XCTAssertEqual(reparsed.iptc.countryName, "Norge")
        XCTAssertEqual(reparsed.iptc.countryCode, "NOR")
        XCTAssertEqual(reparsed.iptc.keywords, ["vær", "storm", "Tromsø"])
        XCTAssertEqual(reparsed.iptc.caption, "Kraftig nordavind i Tromsø førte til store bølger.")
        XCTAssertEqual(reparsed.iptc.copyright, "© NTB / Bjørn Ødegård")
        XCTAssertEqual(reparsed.iptc.credit, "NTB Scanpix")
        XCTAssertEqual(reparsed.iptc.source, "NTB")
        XCTAssertEqual(reparsed.iptc.dateCreated, "20260412")
        XCTAssertEqual(reparsed.iptc.timeCreated, "143000+0200")
        XCTAssertEqual(reparsed.iptc.specialInstructions, "Kreditering påkrevet")
        XCTAssertEqual(reparsed.iptc.writerEditor, "Skrivebord Øst")
    }

    func testScanDataIdenticalAfterMetadataWrite() throws {
        let original = TestFixtures.minimalJPEG()
        let originalFile = try JPEGParser.parse(original)

        // Add extensive metadata
        var metadata = try ImageMetadata.read(from: original)
        metadata.iptc.headline = "Test"
        metadata.iptc.keywords = Array(repeating: "keyword", count: 50)
        metadata.iptc.caption = String(repeating: "This is a test caption. ", count: 20)

        let modified = try metadata.writeToData()
        let modifiedFile = try JPEGParser.parse(modified)

        // Image data must be byte-identical
        XCTAssertEqual(originalFile.scanData, modifiedFile.scanData,
                       "Scan data changed after metadata modification!")
    }

    func testIPTCXMPSyncRoundTrip() throws {
        var metadata = ImageMetadata()
        metadata.jpegFile = try JPEGParser.parse(TestFixtures.minimalJPEG())

        // Set IPTC data with Nordic chars
        metadata.iptc.headline = "Tromsø havn"
        metadata.iptc.city = "Tromsø"
        metadata.iptc.keywords = ["sjø", "båt"]
        metadata.iptc.byline = "Fotografen"
        metadata.iptc.copyright = "© Fotografen"
        metadata.iptc.caption = "En vakker dag ved sjøen"
        metadata.iptc.countryName = "Norge"

        // Sync to XMP
        metadata.syncIPTCToXMP()

        // Write JPEG with both IPTC and XMP
        let jpeg = try metadata.writeToData()

        // Read back
        let reparsed = try ImageMetadata.read(from: jpeg)

        // Verify IPTC
        XCTAssertEqual(reparsed.iptc.headline, "Tromsø havn")
        XCTAssertEqual(reparsed.iptc.city, "Tromsø")
        XCTAssertEqual(reparsed.iptc.keywords, ["sjø", "båt"])

        // Verify XMP
        XCTAssertNotNil(reparsed.xmp)
        XCTAssertEqual(reparsed.xmp?.headline, "Tromsø havn")
        XCTAssertEqual(reparsed.xmp?.city, "Tromsø")
        XCTAssertEqual(reparsed.xmp?.subject, ["sjø", "båt"])
        XCTAssertEqual(reparsed.xmp?.country, "Norge")
    }

    func testWriteToTemporaryFile() throws {
        var metadata = ImageMetadata()
        metadata.jpegFile = try JPEGParser.parse(TestFixtures.minimalJPEG())
        metadata.iptc.headline = "File Test"
        metadata.iptc.city = "Tromsø"

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try metadata.write(to: tempURL)

        let readBack = try ImageMetadata.read(from: tempURL)
        XCTAssertEqual(readBack.iptc.headline, "File Test")
        XCTAssertEqual(readBack.iptc.city, "Tromsø")
    }

    func testMultipleModifications() throws {
        let jpeg = TestFixtures.minimalJPEG()

        // First modification
        var metadata1 = try ImageMetadata.read(from: jpeg)
        metadata1.iptc.headline = "First Version"
        let jpeg2 = try metadata1.writeToData()

        // Second modification
        var metadata2 = try ImageMetadata.read(from: jpeg2)
        XCTAssertEqual(metadata2.iptc.headline, "First Version")
        metadata2.iptc.headline = "Second Version"
        metadata2.iptc.keywords = ["updated"]
        let jpeg3 = try metadata2.writeToData()

        // Third modification
        var metadata3 = try ImageMetadata.read(from: jpeg3)
        XCTAssertEqual(metadata3.iptc.headline, "Second Version")
        XCTAssertEqual(metadata3.iptc.keywords, ["updated"])
        metadata3.iptc.headline = "Final Version"
        let jpeg4 = try metadata3.writeToData()

        let final = try ImageMetadata.read(from: jpeg4)
        XCTAssertEqual(final.iptc.headline, "Final Version")
        XCTAssertEqual(final.iptc.keywords, ["updated"])
    }
}
