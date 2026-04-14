import XCTest
@testable import SwiftExif

// MARK: - ICC Profile Tests

final class ICCProfileTests: XCTestCase {

    func testParseICCProfileHeader() {
        let profile = makeMinimalSRGBProfile()
        XCTAssertNotNil(profile)
        XCTAssertEqual(profile!.colorSpace, "RGB ")
        XCTAssertEqual(profile!.profileConnectionSpace, "XYZ ")
        XCTAssertEqual(profile!.profileSize, UInt32(profile!.data.count))
    }

    func testICCProfileTooSmallReturnsNil() {
        let tooSmall = Data(repeating: 0, count: 50)
        XCTAssertNil(ICCProfile(data: tooSmall))
    }

    func testJPEGICCProfileRoundTrip() throws {
        guard let profile = makeMinimalSRGBProfile() else {
            XCTFail("Failed to create test profile"); return
        }

        // Build JPEG with ICC profile
        let jpegData = makeJPEGWithICCProfile(profile.data)
        var metadata = try ImageMetadata.read(from: jpegData)

        XCTAssertNotNil(metadata.iccProfile)
        XCTAssertEqual(metadata.iccProfile?.colorSpace, "RGB ")

        // Write and re-read
        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertNotNil(reparsed.iccProfile)
        XCTAssertEqual(reparsed.iccProfile?.colorSpace, "RGB ")
        XCTAssertEqual(reparsed.iccProfile?.data.count, profile.data.count)
    }

    func testTIFFICCProfileRoundTrip() throws {
        guard let profile = makeMinimalSRGBProfile() else {
            XCTFail("Failed to create test profile"); return
        }

        // Build TIFF with ICC profile tag
        let tiffData = makeTIFFWithICCProfile(profile.data)
        var metadata = try ImageMetadata.read(from: tiffData)

        XCTAssertNotNil(metadata.iccProfile)
        XCTAssertEqual(metadata.iccProfile?.colorSpace, "RGB ")

        // Write and re-read
        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)

        XCTAssertNotNil(reparsed.iccProfile)
        XCTAssertEqual(reparsed.iccProfile?.data.count, profile.data.count)
    }

    func testStripICCProfile() throws {
        guard let profile = makeMinimalSRGBProfile() else {
            XCTFail("Failed to create test profile"); return
        }

        let jpegData = makeJPEGWithICCProfile(profile.data)
        var metadata = try ImageMetadata.read(from: jpegData)
        XCTAssertNotNil(metadata.iccProfile)

        metadata.stripICCProfile()
        XCTAssertNil(metadata.iccProfile)

        let written = try metadata.writeToData()
        let reparsed = try ImageMetadata.read(from: written)
        XCTAssertNil(reparsed.iccProfile)
    }

    func testStripAllIncludesICC() throws {
        guard let profile = makeMinimalSRGBProfile() else {
            XCTFail("Failed to create test profile"); return
        }

        let jpegData = makeJPEGWithICCProfile(profile.data)
        var metadata = try ImageMetadata.read(from: jpegData)
        XCTAssertNotNil(metadata.iccProfile)

        metadata.stripAllMetadata()
        XCTAssertNil(metadata.iccProfile)
    }

    func testCopyICCProfile() throws {
        guard let profile = makeMinimalSRGBProfile() else {
            XCTFail("Failed to create test profile"); return
        }

        var source = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        source.iccProfile = profile
        var target = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)

        target.copyMetadata(from: source, groups: [.iccProfile])

        XCTAssertNotNil(target.iccProfile)
        XCTAssertEqual(target.iccProfile?.colorSpace, "RGB ")
        XCTAssertNil(target.exif) // Not copied
    }

    func testDiffDetectsICCProfileChange() throws {
        guard let profile = makeMinimalSRGBProfile() else {
            XCTFail("Failed to create test profile"); return
        }

        var m1 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m1.iccProfile = profile
        let m2 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)

        let diff = m1.diff(against: m2)
        XCTAssertTrue(diff.removals.contains { $0.key == "ICCProfile:ColorSpace" })
    }

    func testICCProfileInExport() throws {
        guard let profile = makeMinimalSRGBProfile() else {
            XCTFail("Failed to create test profile"); return
        }

        var metadata = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        metadata.iccProfile = profile

        let dict = MetadataExporter.buildDictionary(metadata)
        XCTAssertEqual(dict["ICCProfile:ColorSpace"] as? String, "RGB")
        XCTAssertNotNil(dict["ICCProfile:Size"])
    }

    func testNoICCProfileReturnsNil() throws {
        let jpeg = TestFixtures.minimalJPEG()
        let metadata = try ImageMetadata.read(from: jpeg)
        XCTAssertNil(metadata.iccProfile)
    }

    func testICCProfileGroupInCaseIterable() {
        let allGroups = ImageMetadata.MetadataGroup.allCases
        XCTAssertTrue(allGroups.contains(.iccProfile))
    }

    // MARK: - Helpers

    /// Create a minimal valid ICC profile with sRGB-like header.
    private func makeMinimalSRGBProfile() -> ICCProfile? {
        var data = Data(repeating: 0, count: 220)

        // Profile size (bytes 0-3)
        let size = UInt32(data.count)
        data[0] = UInt8((size >> 24) & 0xFF)
        data[1] = UInt8((size >> 16) & 0xFF)
        data[2] = UInt8((size >> 8) & 0xFF)
        data[3] = UInt8(size & 0xFF)

        // Preferred CMM (bytes 4-7): "appl"
        data[4] = 0x61; data[5] = 0x70; data[6] = 0x70; data[7] = 0x6C

        // Version (bytes 8-11): 2.1.0
        data[8] = 0x02; data[9] = 0x10

        // Device class (bytes 12-15): "mntr" (monitor)
        data[12] = 0x6D; data[13] = 0x6E; data[14] = 0x74; data[15] = 0x72

        // Color space (bytes 16-19): "RGB "
        data[16] = 0x52; data[17] = 0x47; data[18] = 0x42; data[19] = 0x20

        // PCS (bytes 20-23): "XYZ "
        data[20] = 0x58; data[21] = 0x59; data[22] = 0x5A; data[23] = 0x20

        // Signature (bytes 36-39): "acsp"
        data[36] = 0x61; data[37] = 0x63; data[38] = 0x73; data[39] = 0x70

        // Tag count (bytes 128-131): 1
        data[131] = 1

        // Tag entry: 'desc' at offset 144, size 76
        // Tag signature "desc"
        data[132] = 0x64; data[133] = 0x65; data[134] = 0x73; data[135] = 0x63
        // Offset: 144
        data[139] = 144
        // Size: 76
        data[143] = 76

        // desc tag data at offset 144:
        // Type signature "desc"
        data[144] = 0x64; data[145] = 0x65; data[146] = 0x73; data[147] = 0x63
        // Reserved (4 bytes)
        // ASCII count: 5 ("sRGB\0")
        data[155] = 5
        // ASCII string
        let descStr = "sRGB"
        for (i, byte) in descStr.utf8.enumerated() {
            data[156 + i] = byte
        }
        data[160] = 0 // null terminator

        return ICCProfile(data: data)
    }

    /// Build a JPEG with an ICC profile in APP2 segments.
    private func makeJPEGWithICCProfile(_ profileData: Data) -> Data {
        let base = TestFixtures.minimalJPEG()
        guard var file = try? JPEGParser.parse(base) else {
            fatalError("Failed to parse minimal JPEG")
        }
        file.replaceOrAddICCProfileSegments(profileData)
        return try! JPEGWriter.write(file)
    }

    /// Build a TIFF with an ICC profile in tag 0x8773.
    private func makeTIFFWithICCProfile(_ profileData: Data) -> Data {
        return TestFixtures.minimalTIFF(byteOrder: .littleEndian, entries: [
            (tag: ExifTag.iccProfile, type: .undefined, count: UInt32(profileData.count), valueData: profileData),
        ])
    }
}

// MARK: - CSV Export Tests

final class CSVExporterTests: XCTestCase {

    func testBasicCSVExport() {
        var m1 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m1.iptc.headline = "First"
        var m2 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m2.iptc.headline = "Second"

        let csv = CSVExporter.toCSV([m1, m2])

        XCTAssertTrue(csv.contains("IPTC:Headline"))
        XCTAssertTrue(csv.contains("First"))
        XCTAssertTrue(csv.contains("Second"))
    }

    func testCSVWithSpecificFields() {
        var m = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m.iptc.headline = "Test"
        m.iptc.city = "Oslo"

        let csv = CSVExporter.toCSV([m], fields: ["IPTC:Headline"])

        XCTAssertTrue(csv.contains("IPTC:Headline"))
        XCTAssertTrue(csv.contains("Test"))
        XCTAssertFalse(csv.contains("Oslo")) // city not in fields
    }

    func testCSVEscapesCommas() {
        var m = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m.iptc.headline = "Hello, World"

        let csv = CSVExporter.toCSV([m], fields: ["IPTC:Headline"])

        // Should be quoted
        XCTAssertTrue(csv.contains("\"Hello, World\""))
    }

    func testCSVEscapesQuotes() {
        var m = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m.iptc.headline = "She said \"hi\""

        let csv = CSVExporter.toCSV([m], fields: ["IPTC:Headline"])

        // Double quotes should be escaped
        XCTAssertTrue(csv.contains("\"\"hi\"\""))
    }

    func testCSVMissingFieldsAreEmpty() {
        var m1 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m1.iptc.headline = "Has Headline"
        let m2 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)

        let csv = CSVExporter.toCSV([m1, m2], fields: ["IPTC:Headline", "IPTC:City"])

        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3) // header + 2 data rows
        // Second data row should have empty values
        XCTAssertEqual(lines[2], ",") // both fields empty
    }

    func testCSVKeywordsJoinedWithSemicolon() {
        var m = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m.iptc.keywords = ["arctic", "norway", "photo"]

        let csv = CSVExporter.toCSV([m], fields: ["IPTC:Keywords"])

        XCTAssertTrue(csv.contains("arctic;norway;photo"))
    }

    func testCSVEmptyInputReturnsEmpty() {
        let csv = CSVExporter.toCSV([])
        XCTAssertEqual(csv, "")
    }

    func testCSVAutoDiscoverKeys() {
        var m1 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m1.iptc.headline = "A"
        var m2 = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m2.iptc.city = "B"

        let csv = CSVExporter.toCSV([m1, m2])

        // Both keys should be present in header
        let header = csv.components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(header.contains("IPTC:Headline"))
        XCTAssertTrue(header.contains("IPTC:City"))
    }

    func testCSVHeaderIsSorted() {
        var m = ImageMetadata(container: .jpeg(JPEGFile()), format: .jpeg)
        m.iptc.headline = "Z"
        m.iptc.city = "A"

        let csv = CSVExporter.toCSV([m])
        let header = csv.components(separatedBy: "\n").first ?? ""
        let columns = header.components(separatedBy: ",")

        // Should be sorted alphabetically
        XCTAssertEqual(columns, columns.sorted())
    }
}
