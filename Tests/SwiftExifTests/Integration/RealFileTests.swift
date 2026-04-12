import XCTest
@testable import SwiftExif

/// Integration tests using real image files from TestImages/.
/// These tests verify reading, writing, and round-tripping metadata
/// with actual camera-produced files rather than synthetic test data.
final class RealFileTests: XCTestCase {

    static let testImagesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Integration/
        .deletingLastPathComponent() // SwiftExifTests/
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // project root
        .appendingPathComponent("TestImages")

    private func testImageURL(_ name: String) -> URL {
        Self.testImagesDir.appendingPathComponent(name)
    }

    private func skipIfMissing(_ url: URL) throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "Test image not found: \(url.lastPathComponent)")
    }

    // MARK: - JPEG Reading

    func testReadJPEGWithIPTC() throws {
        let url = testImageURL("Nepobaby sesong 2 01.jpg")
        try skipIfMissing(url)

        let metadata = try ImageMetadata.read(from: url)
        XCTAssertEqual(metadata.format, .jpeg)

        // Should have Exif from camera
        XCTAssertNotNil(metadata.exif)
        XCTAssertNotNil(metadata.exif?.make)
    }

    func testReadJPEGWithRichMetadata() throws {
        let url = testImageURL("TRA03167_edit.jpg")
        try skipIfMissing(url)

        let metadata = try ImageMetadata.read(from: url)
        XCTAssertEqual(metadata.format, .jpeg)
        XCTAssertNotNil(metadata.exif)

        // Sony camera
        let make = metadata.exif?.make
        XCTAssertNotNil(make)
    }

    // MARK: - JPEG Round Trip

    func testJPEGRoundTripPreservesImageData() throws {
        let url = testImageURL("S01E13 The Parting of Ways-0003.jpg")
        try skipIfMissing(url)

        let original = try Data(contentsOf: url)
        let originalFile = try JPEGParser.parse(original)

        var metadata = try ImageMetadata.read(from: original)
        metadata.iptc.headline = "Test round trip"
        metadata.iptc.keywords = ["test", "round-trip"]

        let written = try metadata.writeToData()
        let writtenFile = try JPEGParser.parse(written)

        // Image scan data must be identical
        XCTAssertEqual(originalFile.scanData, writtenFile.scanData,
                       "Image scan data was corrupted during metadata write")
    }

    func testJPEGWriteReadIPTC() throws {
        let url = testImageURL("S01E13 The Parting of Ways-0006.jpg")
        try skipIfMissing(url)

        var metadata = try ImageMetadata.read(from: url)

        // Write new IPTC metadata
        metadata.iptc.headline = "The Parting of Ways"
        metadata.iptc.byline = "BBC Studios"
        metadata.iptc.keywords = ["Doctor Who", "sci-fi", "Daleks"]
        metadata.iptc.city = "London"
        metadata.iptc.copyright = "© BBC 2005"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.iptc.headline, "The Parting of Ways")
        XCTAssertEqual(reparsed.iptc.byline, "BBC Studios")
        XCTAssertEqual(reparsed.iptc.keywords, ["Doctor Who", "sci-fi", "Daleks"])
        XCTAssertEqual(reparsed.iptc.city, "London")
        XCTAssertEqual(reparsed.iptc.copyright, "© BBC 2005")

        // Exif should be preserved
        XCTAssertNotNil(reparsed.exif)
    }

    func testJPEGIPTCXMPSyncRoundTrip() throws {
        let url = testImageURL("Vixen 2026 05.jpg")
        try skipIfMissing(url)

        var metadata = try ImageMetadata.read(from: url)

        metadata.iptc.headline = "Vixen 2026"
        metadata.iptc.byline = "Fotograf"
        metadata.iptc.keywords = ["mote", "Tromsø"]
        metadata.iptc.city = "Tromsø"
        metadata.iptc.copyright = "© Fotograf 2026"
        metadata.syncIPTCToXMP()

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        // Verify IPTC
        XCTAssertEqual(reparsed.iptc.headline, "Vixen 2026")
        XCTAssertEqual(reparsed.iptc.keywords, ["mote", "Tromsø"])

        // Verify XMP was synced
        XCTAssertNotNil(reparsed.xmp)
        XCTAssertEqual(reparsed.xmp?.headline, "Vixen 2026")
        XCTAssertEqual(reparsed.xmp?.subject, ["mote", "Tromsø"])
        XCTAssertEqual(reparsed.xmp?.city, "Tromsø")
    }

    // MARK: - ARW (Sony RAW) Reading and Writing

    func testReadARW() throws {
        let url = testImageURL("TRA03164.ARW")
        try skipIfMissing(url)

        let metadata = try ImageMetadata.read(from: url)

        // ARW is TIFF-based; magic-byte detection returns .tiff since ARW
        // can't be distinguished from TIFF without MakerNotes analysis.
        // Both .tiff and .raw(.arw) are valid — the important thing is it reads.
        XCTAssertTrue(metadata.format == .tiff || {
            if case .raw(.arw) = metadata.format { return true }
            return false
        }())

        // Sony ILCE-1
        XCTAssertEqual(metadata.exif?.make, "SONY")
        XCTAssertEqual(metadata.exif?.model, "ILCE-1")
    }

    func testARWWriteIPTCAndXMP() throws {
        let url = testImageURL("TRA03164.ARW")
        try skipIfMissing(url)

        var metadata = try ImageMetadata.read(from: url)

        metadata.iptc.headline = "ARW Test"
        metadata.iptc.keywords = ["sony", "raw", "test"]
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "ARW XMP Test"

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.iptc.headline, "ARW Test")
        XCTAssertEqual(reparsed.iptc.keywords, ["sony", "raw", "test"])
        XCTAssertEqual(reparsed.xmp?.headline, "ARW XMP Test")
    }

    // MARK: - JPEG XL Reading and Writing

    func testReadJXLBareCodestream() throws {
        let url = testImageURL("ShortPlantHDR_seq_000001.jxl")
        try skipIfMissing(url)

        let metadata = try ImageMetadata.read(from: url)
        XCTAssertEqual(metadata.format, .jpegXL)

        // Bare codestream — writing should fail gracefully
        XCTAssertThrowsError(try metadata.writeToData()) { error in
            guard let metaError = error as? MetadataError,
                  case .writeNotSupported = metaError else {
                XCTFail("Expected writeNotSupported for bare codestream")
                return
            }
        }
    }

    func testReadJXLContainer() throws {
        let url = testImageURL("TRA03168_edit_002.jxl")
        try skipIfMissing(url)

        let metadata = try ImageMetadata.read(from: url)
        XCTAssertEqual(metadata.format, .jpegXL)
    }

    func testJXLContainerWriteXMP() throws {
        let url = testImageURL("TRA03168_edit_002.jxl")
        try skipIfMissing(url)

        var metadata = try ImageMetadata.read(from: url)

        metadata.xmp = XMPData()
        metadata.xmp?.headline = "JXL Real File Test"
        metadata.xmp?.city = "Bergen"
        metadata.xmp?.subject = ["jxl", "hdr", "plant"]

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertEqual(reparsed.format, .jpegXL)
        XCTAssertEqual(reparsed.xmp?.headline, "JXL Real File Test")
        XCTAssertEqual(reparsed.xmp?.city, "Bergen")
        XCTAssertEqual(reparsed.xmp?.subject, ["jxl", "hdr", "plant"])
    }

    func testJXLRoundTripPreservesCodestream() throws {
        let url = testImageURL("TRA03168_edit_002.jxl")
        try skipIfMissing(url)

        let originalData = try Data(contentsOf: url)
        let originalFile = try JXLParser.parse(originalData)
        let originalJxlc = originalFile.findBox("jxlc")?.data

        var metadata = try ImageMetadata.read(from: originalData)
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Codestream check"

        let written = try metadata.writeToData()
        let writtenFile = try JXLParser.parse(written)
        let writtenJxlc = writtenFile.findBox("jxlc")?.data

        XCTAssertEqual(originalJxlc, writtenJxlc,
                       "JXL codestream was corrupted during metadata write")
    }

    func testJXLWithExistingMetadata() throws {
        let url = testImageURL("TRA03168_edit_002.jxl")
        try skipIfMissing(url)

        let metadata = try ImageMetadata.read(from: url)
        XCTAssertEqual(metadata.format, .jpegXL)

        // Write additional metadata
        var modified = metadata
        modified.xmp = modified.xmp ?? XMPData()
        modified.xmp?.headline = "Updated JXL"

        let written = try modified.writeToData()
        let reparsed = try ImageMetadata.read(from: written)
        XCTAssertEqual(reparsed.xmp?.headline, "Updated JXL")
    }

    // MARK: - XMP Sidecar Reading

    func testReadExistingSidecar() throws {
        let sidecarURL = testImageURL("TRA03164.xmp")
        try skipIfMissing(sidecarURL)

        let xmp = try XMPSidecar.read(from: sidecarURL)

        XCTAssertEqual(xmp.headline, "Hello world'")
        XCTAssertEqual(xmp.credit, "TV 2")
        XCTAssertEqual(xmp.subject, ["I am the king", "star wars", "Strawberry"])
        XCTAssertEqual(xmp.creator, ["Truls Aagedal"])
        XCTAssertEqual(xmp.rights, "Truls Aagedal / TV 2")
        XCTAssertEqual(xmp.title, "Hello world'")
        XCTAssertEqual(xmp.description, "2026-03-18 , :")
        XCTAssertEqual(xmp.personInImage, ["Jonas", "Silje"])
    }

    func testSidecarURLDerivation() throws {
        let arwURL = testImageURL("TRA03164.ARW")
        let sidecarURL = XMPSidecar.sidecarURL(for: arwURL)

        XCTAssertEqual(sidecarURL.lastPathComponent, "TRA03164.xmp")
    }

    func testReadSidecarMatchesManualRead() throws {
        let arwURL = testImageURL("TRA03164.ARW")
        let sidecarURL = testImageURL("TRA03164.xmp")
        try skipIfMissing(sidecarURL)

        // Read via convenience
        let xmp1 = try ImageMetadata.readSidecar(for: arwURL)
        // Read directly
        let xmp2 = try XMPSidecar.read(from: sidecarURL)

        XCTAssertEqual(xmp1.headline, xmp2.headline)
        XCTAssertEqual(xmp1.subject, xmp2.subject)
        XCTAssertEqual(xmp1.creator, xmp2.creator)
    }

    // MARK: - XMP Sidecar Writing

    func testWriteSidecarForARW() throws {
        let arwURL = testImageURL("TRA03164.ARW")
        try skipIfMissing(arwURL)

        var metadata = try ImageMetadata.read(from: arwURL)
        metadata.iptc.headline = "Sidecar from ARW"
        metadata.iptc.keywords = ["sony", "sidecar"]
        metadata.iptc.byline = "Test Photographer"
        metadata.syncIPTCToXMP()

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("TRA03164_test_\(UUID()).xmp")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try metadata.writeSidecar(to: tempURL)

        let readBack = try XMPSidecar.read(from: tempURL)
        XCTAssertEqual(readBack.headline, "Sidecar from ARW")
        XCTAssertEqual(readBack.subject, ["sony", "sidecar"])
        XCTAssertEqual(readBack.creator, ["Test Photographer"])
    }

    func testReadExistingNepobabySidecar() throws {
        let url = testImageURL("Nepobaby sesong 2 06.xmp")
        try skipIfMissing(url)

        let xmp = try XMPSidecar.read(from: url)
        // Should at least parse without error
        XCTAssertNotNil(xmp)
    }

    // MARK: - Multiple Modifications

    func testMultipleJPEGModifications() throws {
        let url = testImageURL("S01E13 The Parting of Ways-0003.jpg")
        try skipIfMissing(url)

        // First pass
        var meta1 = try ImageMetadata.read(from: url)
        meta1.iptc.headline = "Pass 1"
        meta1.iptc.keywords = ["first"]
        let data1 = try meta1.writeToData()

        // Second pass
        var meta2 = try ImageMetadata.read(from: data1)
        XCTAssertEqual(meta2.iptc.headline, "Pass 1")
        meta2.iptc.headline = "Pass 2"
        meta2.iptc.keywords = ["first", "second"]
        let data2 = try meta2.writeToData()

        // Third pass
        var meta3 = try ImageMetadata.read(from: data2)
        XCTAssertEqual(meta3.iptc.headline, "Pass 2")
        meta3.iptc.headline = "Pass 3"
        meta3.iptc.city = "Tromsø"
        meta3.syncIPTCToXMP()
        let data3 = try meta3.writeToData()

        let final = try ImageMetadata.read(from: data3)
        XCTAssertEqual(final.iptc.headline, "Pass 3")
        XCTAssertEqual(final.iptc.keywords, ["first", "second"])
        XCTAssertEqual(final.iptc.city, "Tromsø")
        XCTAssertEqual(final.xmp?.headline, "Pass 3")
        XCTAssertEqual(final.xmp?.city, "Tromsø")
    }

    // MARK: - Write to Temp File and Read Back

    func testWriteJPEGToTempFile() throws {
        let url = testImageURL("DEI_8158_edit.jpg")
        try skipIfMissing(url)

        var metadata = try ImageMetadata.read(from: url)
        metadata.iptc.headline = "Temp file test"
        metadata.iptc.city = "Tromsø"
        metadata.iptc.copyright = "© Fotograf"

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DEI_test_\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try metadata.write(to: tempURL)

        let readBack = try ImageMetadata.read(from: tempURL)
        XCTAssertEqual(readBack.iptc.headline, "Temp file test")
        XCTAssertEqual(readBack.iptc.city, "Tromsø")
        XCTAssertEqual(readBack.iptc.copyright, "© Fotograf")

        // Exif should still be there
        XCTAssertNotNil(readBack.exif)
    }
}
