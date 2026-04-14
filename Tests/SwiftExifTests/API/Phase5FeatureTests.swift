import XCTest
@testable import SwiftExif

// MARK: - MetadataCondition Tests

final class MetadataConditionTests: XCTestCase {

    // MARK: - Helpers

    private func makeMetadata(make: String = "Canon", model: String = "EOS R5", iso: UInt16 = 400, city: String? = nil) -> ImageMetadata {
        let byteOrder = ByteOrder.bigEndian

        // Build IFD0 with Make and Model
        let makeData = Data(make.utf8) + Data([0x00])
        let modelData = Data(model.utf8) + Data([0x00])
        let makeEntry = IFDEntry(tag: ExifTag.make, type: .ascii, count: UInt32(makeData.count), valueData: makeData)
        let modelEntry = IFDEntry(tag: ExifTag.model, type: .ascii, count: UInt32(modelData.count), valueData: modelData)
        let ifd0 = IFD(entries: [makeEntry, modelEntry], nextIFDOffset: 0)

        // Build Exif IFD with ISO
        var isoData = Data(count: 2)
        isoData[0] = UInt8(iso >> 8)
        isoData[1] = UInt8(iso & 0xFF)
        // Pad to 4 bytes
        while isoData.count < 4 { isoData.append(0x00) }
        let isoEntry = IFDEntry(tag: ExifTag.isoSpeedRatings, type: .short, count: 1, valueData: isoData)
        let exifIFD = IFD(entries: [isoEntry], nextIFDOffset: 0)

        var exifData = ExifData(byteOrder: byteOrder)
        exifData.ifd0 = ifd0
        exifData.exifIFD = exifIFD

        var iptc = IPTCData()
        if let city = city {
            try? iptc.setValue(city, for: .city)
        }

        return ImageMetadata(format: .jpeg, iptc: iptc, exif: exifData)
    }

    // MARK: - Equals

    func testEqualsMatchesExactValue() {
        let metadata = makeMetadata(make: "Canon")
        let condition = MetadataCondition.equals(field: "Make", value: "Canon")
        XCTAssertTrue(condition.matches(metadata))
    }

    func testEqualsRejectsWrongValue() {
        let metadata = makeMetadata(make: "Canon")
        let condition = MetadataCondition.equals(field: "Make", value: "Nikon")
        XCTAssertFalse(condition.matches(metadata))
    }

    func testEqualsMissingField() {
        let metadata = makeMetadata()
        let condition = MetadataCondition.equals(field: "NonExistentField", value: "anything")
        XCTAssertFalse(condition.matches(metadata))
    }

    // MARK: - Not Equals

    func testNotEqualsRejectsMatch() {
        let metadata = makeMetadata(make: "Canon")
        let condition = MetadataCondition.notEquals(field: "Make", value: "Canon")
        XCTAssertFalse(condition.matches(metadata))
    }

    func testNotEqualsAcceptsDifferent() {
        let metadata = makeMetadata(make: "Canon")
        let condition = MetadataCondition.notEquals(field: "Make", value: "Nikon")
        XCTAssertTrue(condition.matches(metadata))
    }

    // MARK: - Contains

    func testContainsSubstring() {
        let metadata = makeMetadata(make: "Canon", model: "EOS R5")
        let condition = MetadataCondition.contains(field: "Model", substring: "eos")
        XCTAssertTrue(condition.matches(metadata)) // case-insensitive
    }

    func testContainsRejectsNonMatch() {
        let metadata = makeMetadata(model: "EOS R5")
        let condition = MetadataCondition.contains(field: "Model", substring: "D850")
        XCTAssertFalse(condition.matches(metadata))
    }

    // MARK: - Regex

    func testMatchesRegexPattern() {
        let metadata = makeMetadata(model: "EOS R5")
        let condition = MetadataCondition.matches(field: "Model", pattern: "^EOS R\\d$")
        XCTAssertTrue(condition.matches(metadata))
    }

    func testMatchesRegexRejectsNonMatch() {
        let metadata = makeMetadata(model: "EOS R5")
        let condition = MetadataCondition.matches(field: "Model", pattern: "^D\\d+$")
        XCTAssertFalse(condition.matches(metadata))
    }

    // MARK: - Exists

    func testExistsForPresentField() {
        let metadata = makeMetadata()
        let condition = MetadataCondition.exists(field: "Make")
        XCTAssertTrue(condition.matches(metadata))
    }

    func testExistsForMissingField() {
        let metadata = makeMetadata()
        let condition = MetadataCondition.exists(field: "LensModel")
        XCTAssertFalse(condition.matches(metadata))
    }

    // MARK: - Numeric Comparisons

    func testGreaterThan() {
        let metadata = makeMetadata(iso: 1600)
        XCTAssertTrue(MetadataCondition.greaterThan(field: "ISO", value: 800).matches(metadata))
        XCTAssertFalse(MetadataCondition.greaterThan(field: "ISO", value: 1600).matches(metadata))
    }

    func testLessThan() {
        let metadata = makeMetadata(iso: 200)
        XCTAssertTrue(MetadataCondition.lessThan(field: "ISO", value: 400).matches(metadata))
        XCTAssertFalse(MetadataCondition.lessThan(field: "ISO", value: 100).matches(metadata))
    }

    func testGreaterThanOrEqual() {
        let metadata = makeMetadata(iso: 800)
        XCTAssertTrue(MetadataCondition.greaterThanOrEqual(field: "ISO", value: 800).matches(metadata))
        XCTAssertTrue(MetadataCondition.greaterThanOrEqual(field: "ISO", value: 400).matches(metadata))
        XCTAssertFalse(MetadataCondition.greaterThanOrEqual(field: "ISO", value: 1600).matches(metadata))
    }

    func testLessThanOrEqual() {
        let metadata = makeMetadata(iso: 400)
        XCTAssertTrue(MetadataCondition.lessThanOrEqual(field: "ISO", value: 400).matches(metadata))
        XCTAssertFalse(MetadataCondition.lessThanOrEqual(field: "ISO", value: 200).matches(metadata))
    }

    // MARK: - Logical Combinators

    func testAndAllTrue() {
        let metadata = makeMetadata(make: "Canon", iso: 1600)
        let condition = MetadataCondition.and([
            .equals(field: "Make", value: "Canon"),
            .greaterThan(field: "ISO", value: 800),
        ])
        XCTAssertTrue(condition.matches(metadata))
    }

    func testAndOneFalse() {
        let metadata = makeMetadata(make: "Canon", iso: 400)
        let condition = MetadataCondition.and([
            .equals(field: "Make", value: "Canon"),
            .greaterThan(field: "ISO", value: 800),
        ])
        XCTAssertFalse(condition.matches(metadata))
    }

    func testOrOneTrue() {
        let metadata = makeMetadata(make: "Canon")
        let condition = MetadataCondition.or([
            .equals(field: "Make", value: "Nikon"),
            .equals(field: "Make", value: "Canon"),
        ])
        XCTAssertTrue(condition.matches(metadata))
    }

    func testOrAllFalse() {
        let metadata = makeMetadata(make: "Canon")
        let condition = MetadataCondition.or([
            .equals(field: "Make", value: "Nikon"),
            .equals(field: "Make", value: "Sony"),
        ])
        XCTAssertFalse(condition.matches(metadata))
    }

    func testNot() {
        let metadata = makeMetadata(make: "Canon")
        XCTAssertTrue(MetadataCondition.not(.equals(field: "Make", value: "Nikon")).matches(metadata))
        XCTAssertFalse(MetadataCondition.not(.equals(field: "Make", value: "Canon")).matches(metadata))
    }

    func testNestedLogic() {
        // (Make == Canon AND ISO > 800) OR IPTC:City == Oslo
        let metadata = makeMetadata(make: "Canon", iso: 400, city: "Oslo")
        let condition = MetadataCondition.or([
            .and([
                .equals(field: "Make", value: "Canon"),
                .greaterThan(field: "ISO", value: 800),
            ]),
            .equals(field: "IPTC:City", value: "Oslo"),
        ])
        XCTAssertTrue(condition.matches(metadata)) // First branch false, second true
    }

    // MARK: - IPTC field conditions

    func testIPTCFieldCondition() {
        let metadata = makeMetadata(city: "Tromsø")
        let condition = MetadataCondition.equals(field: "IPTC:City", value: "Tromsø")
        XCTAssertTrue(condition.matches(metadata))
    }
}

// MARK: - MetadataRenamer Tests

final class MetadataRenamerTests: XCTestCase {

    private func makeMetadata(make: String = "Canon", model: String = "EOS R5", dateTime: String = "2024:01:15 14:30:00") -> ImageMetadata {
        let byteOrder = ByteOrder.bigEndian

        let makeData = Data(make.utf8) + Data([0x00])
        let modelData = Data(model.utf8) + Data([0x00])
        let dateData = Data(dateTime.utf8) + Data([0x00])

        let makeEntry = IFDEntry(tag: ExifTag.make, type: .ascii, count: UInt32(makeData.count), valueData: makeData)
        let modelEntry = IFDEntry(tag: ExifTag.model, type: .ascii, count: UInt32(modelData.count), valueData: modelData)
        let dateEntry = IFDEntry(tag: ExifTag.dateTimeOriginal, type: .ascii, count: UInt32(dateData.count), valueData: dateData)

        let ifd0 = IFD(entries: [makeEntry, modelEntry], nextIFDOffset: 0)
        let exifIFD = IFD(entries: [dateEntry], nextIFDOffset: 0)

        var exifData = ExifData(byteOrder: byteOrder)
        exifData.ifd0 = ifd0
        exifData.exifIFD = exifIFD

        return ImageMetadata(format: .jpeg, exif: exifData)
    }

    func testSimpleFieldToken() {
        let renamer = MetadataRenamer(template: "%{Make}")
        let metadata = makeMetadata(make: "Canon")
        XCTAssertEqual(renamer.newName(for: metadata), "Canon")
    }

    func testMultipleTokens() {
        let renamer = MetadataRenamer(template: "%{Make}_%{Model}")
        let metadata = makeMetadata(make: "Canon", model: "EOS R5")
        XCTAssertEqual(renamer.newName(for: metadata), "Canon_EOS R5")
    }

    func testDateFormatToken() {
        let renamer = MetadataRenamer(template: "%{DateTimeOriginal:yyyy-MM-dd}")
        let metadata = makeMetadata(dateTime: "2024:01:15 14:30:00")
        XCTAssertEqual(renamer.newName(for: metadata), "2024-01-15")
    }

    func testDateTimeFormatToken() {
        let renamer = MetadataRenamer(template: "%{DateTimeOriginal:yyyyMMdd_HHmmss}")
        let metadata = makeMetadata(dateTime: "2024:01:15 14:30:00")
        XCTAssertEqual(renamer.newName(for: metadata), "20240115_143000")
    }

    func testCounterToken() {
        let renamer = MetadataRenamer(template: "photo_%c")
        let metadata = makeMetadata()
        XCTAssertEqual(renamer.newName(for: metadata, counter: 1), "photo_001")
        XCTAssertEqual(renamer.newName(for: metadata, counter: 42), "photo_042")
    }

    func testCounterDigitsCustom() {
        let renamer = MetadataRenamer(template: "img_%c", counterDigits: 5)
        let metadata = makeMetadata()
        XCTAssertEqual(renamer.newName(for: metadata, counter: 7), "img_00007")
    }

    func testCombinedTemplate() {
        let renamer = MetadataRenamer(template: "%{DateTimeOriginal:yyyy-MM-dd}_%{Make}_%c")
        let metadata = makeMetadata(make: "Canon", dateTime: "2024:01:15 14:30:00")
        XCTAssertEqual(renamer.newName(for: metadata, counter: 1), "2024-01-15_Canon_001")
    }

    func testMissingFieldReturnsEmpty() {
        let renamer = MetadataRenamer(template: "%{LensModel}")
        let metadata = makeMetadata()
        XCTAssertEqual(renamer.newName(for: metadata), "")
    }

    func testNewFileName() {
        let renamer = MetadataRenamer(template: "%{Make}")
        let metadata = makeMetadata(make: "Canon")
        let url = URL(fileURLWithPath: "/photos/IMG_0001.jpg")
        XCTAssertEqual(renamer.newFileName(for: metadata, originalURL: url), "Canon.jpg")
    }

    func testNewURL() {
        let renamer = MetadataRenamer(template: "%{Make}")
        let metadata = makeMetadata(make: "Canon")
        let url = URL(fileURLWithPath: "/photos/IMG_0001.jpg")
        let newURL = renamer.newURL(for: metadata, originalURL: url)
        XCTAssertEqual(newURL.lastPathComponent, "Canon.jpg")
        XCTAssertEqual(newURL.deletingLastPathComponent().path, "/photos")
    }

    func testSanitizesIllegalCharacters() {
        let renamer = MetadataRenamer(template: "%{Make}/%{Model}")
        let metadata = makeMetadata(make: "Canon", model: "EOS:R5")
        // Both / and : should be removed
        let name = renamer.newName(for: metadata)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    func testDryRunMultipleFiles() throws {
        // Create temp directory with two test files
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let jpeg1 = tmpDir.appendingPathComponent("a.jpg")
        let jpeg2 = tmpDir.appendingPathComponent("b.jpg")

        // Build JPEG files with different metadata
        let data1 = makeJPEGWithMake("Canon")
        let data2 = makeJPEGWithMake("Nikon")
        try data1.write(to: jpeg1)
        try data2.write(to: jpeg2)

        let renamer = MetadataRenamer(template: "%{Make}_%c")
        let preview = renamer.dryRun(files: [jpeg1, jpeg2])

        XCTAssertEqual(preview.count, 2)
        XCTAssertTrue(preview[0].to.lastPathComponent.hasPrefix("Canon"))
        XCTAssertTrue(preview[1].to.lastPathComponent.hasPrefix("Nikon"))
    }

    func testRenameCreatesCorrectFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let original = tmpDir.appendingPathComponent("IMG_0001.jpg")
        let data = makeJPEGWithMake("Canon")
        try data.write(to: original)

        let renamer = MetadataRenamer(template: "%{Make}")
        let result = try renamer.rename(file: original)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.lastPathComponent, "Canon.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    // Helper: create a minimal JPEG with Make in Exif
    private func makeJPEGWithMake(_ make: String) -> Data {
        let exifData = TestFixtures.exifAPP1Data(byteOrder: .bigEndian, ifd0Entries: [
            (tag: ExifTag.make, stringValue: make),
        ])
        return TestFixtures.jpegWithSegment(marker: .app1, data: exifData)
    }
}

// MARK: - PrintConverter Tests

final class PrintConverterTests: XCTestCase {

    // MARK: - Orientation

    func testOrientationValues() {
        XCTAssertEqual(PrintConverter.orientation(1), "Horizontal (normal)")
        XCTAssertEqual(PrintConverter.orientation(3), "Rotate 180")
        XCTAssertEqual(PrintConverter.orientation(6), "Rotate 90 CW")
        XCTAssertEqual(PrintConverter.orientation(8), "Rotate 270 CW")
        XCTAssertEqual(PrintConverter.orientation(99), "Unknown (99)")
    }

    // MARK: - Exposure Time

    func testExposureTimeFractional() {
        XCTAssertEqual(PrintConverter.exposureTime("1/250"), "1/250s")
        XCTAssertEqual(PrintConverter.exposureTime("1/60"), "1/60s")
        XCTAssertEqual(PrintConverter.exposureTime("1/8000"), "1/8000s")
    }

    func testExposureTimeWholeSeconds() {
        XCTAssertEqual(PrintConverter.exposureTime("30/1"), "30s")
        XCTAssertEqual(PrintConverter.exposureTime("1/1"), "1s")
    }

    // MARK: - F-Number

    func testFNumberFormatting() {
        XCTAssertEqual(PrintConverter.fNumber(2.8), "f/2.8")
        XCTAssertEqual(PrintConverter.fNumber(4.0), "f/4")
        XCTAssertEqual(PrintConverter.fNumber(1.4), "f/1.4")
        XCTAssertEqual(PrintConverter.fNumber(22.0), "f/22")
    }

    // MARK: - Focal Length

    func testFocalLengthFormatting() {
        XCTAssertEqual(PrintConverter.focalLength(50.0), "50.0 mm")
        XCTAssertEqual(PrintConverter.focalLength(24.5), "24.5 mm")
        XCTAssertEqual(PrintConverter.focalLength(200.0), "200.0 mm")
    }

    // MARK: - Exposure Program

    func testExposureProgram() {
        XCTAssertEqual(PrintConverter.exposureProgram(0), "Not Defined")
        XCTAssertEqual(PrintConverter.exposureProgram(1), "Manual")
        XCTAssertEqual(PrintConverter.exposureProgram(2), "Normal Program")
        XCTAssertEqual(PrintConverter.exposureProgram(3), "Aperture Priority")
        XCTAssertEqual(PrintConverter.exposureProgram(4), "Shutter Priority")
    }

    // MARK: - Metering Mode

    func testMeteringMode() {
        XCTAssertEqual(PrintConverter.meteringMode(1), "Average")
        XCTAssertEqual(PrintConverter.meteringMode(2), "Center-weighted average")
        XCTAssertEqual(PrintConverter.meteringMode(3), "Spot")
        XCTAssertEqual(PrintConverter.meteringMode(5), "Multi-segment")
        XCTAssertEqual(PrintConverter.meteringMode(255), "Other")
    }

    // MARK: - Flash

    func testFlashNotFired() {
        XCTAssertEqual(PrintConverter.flash(0), "Did not fire")
    }

    func testFlashFired() {
        XCTAssertTrue(PrintConverter.flash(1).hasPrefix("Fired"))
    }

    func testFlashAutoMode() {
        // Flash fired, auto mode = 0x19 (binary: 0001 1001)
        let value = 0x19 // fired=1, return=0, mode=3(auto), function=0, redeye=0
        let result = PrintConverter.flash(value)
        XCTAssertTrue(result.contains("Fired"))
        XCTAssertTrue(result.contains("auto mode"))
    }

    func testFlashRedEyeReduction() {
        // value = 0x41 (binary: 0100 0001) = fired + red-eye reduction
        let result = PrintConverter.flash(0x41)
        XCTAssertTrue(result.contains("Fired"))
        XCTAssertTrue(result.contains("red-eye reduction"))
    }

    // MARK: - Color Space

    func testColorSpace() {
        XCTAssertEqual(PrintConverter.colorSpace(1), "sRGB")
        XCTAssertEqual(PrintConverter.colorSpace(65535), "Uncalibrated")
    }

    // MARK: - White Balance

    func testWhiteBalance() {
        XCTAssertEqual(PrintConverter.whiteBalance(0), "Auto")
        XCTAssertEqual(PrintConverter.whiteBalance(1), "Manual")
    }

    // MARK: - Scene Capture Type

    func testSceneCaptureType() {
        XCTAssertEqual(PrintConverter.sceneCaptureType(0), "Standard")
        XCTAssertEqual(PrintConverter.sceneCaptureType(1), "Landscape")
        XCTAssertEqual(PrintConverter.sceneCaptureType(2), "Portrait")
        XCTAssertEqual(PrintConverter.sceneCaptureType(3), "Night Scene")
    }

    // MARK: - Exposure Mode

    func testExposureMode() {
        XCTAssertEqual(PrintConverter.exposureMode(0), "Auto")
        XCTAssertEqual(PrintConverter.exposureMode(1), "Manual")
        XCTAssertEqual(PrintConverter.exposureMode(2), "Auto Bracket")
    }

    // MARK: - Custom Rendered

    func testCustomRendered() {
        XCTAssertEqual(PrintConverter.customRendered(0), "Normal")
        XCTAssertEqual(PrintConverter.customRendered(1), "Custom")
    }

    // MARK: - Resolution Unit

    func testResolutionUnit() {
        XCTAssertEqual(PrintConverter.resolutionUnit(1), "No Unit")
        XCTAssertEqual(PrintConverter.resolutionUnit(2), "inches")
        XCTAssertEqual(PrintConverter.resolutionUnit(3), "centimeters")
    }

    // MARK: - Sensing Method

    func testSensingMethod() {
        XCTAssertEqual(PrintConverter.sensingMethod(2), "One-chip color area")
    }

    // MARK: - Light Source

    func testLightSource() {
        XCTAssertEqual(PrintConverter.lightSource(0), "Unknown")
        XCTAssertEqual(PrintConverter.lightSource(1), "Daylight")
        XCTAssertEqual(PrintConverter.lightSource(2), "Fluorescent")
        XCTAssertEqual(PrintConverter.lightSource(4), "Flash")
    }

    // MARK: - Compression

    func testCompression() {
        XCTAssertEqual(PrintConverter.compression(1), "Uncompressed")
        XCTAssertEqual(PrintConverter.compression(6), "JPEG")
    }

    // MARK: - GPS Coordinates

    func testGPSLatitude() {
        let result = PrintConverter.formatGPSCoordinate(59.9139, isLatitude: true)
        XCTAssertTrue(result.contains("59°"))
        XCTAssertTrue(result.contains("N"))
    }

    func testGPSLatitudeSouth() {
        let result = PrintConverter.formatGPSCoordinate(-33.8688, isLatitude: true)
        XCTAssertTrue(result.contains("33°"))
        XCTAssertTrue(result.contains("S"))
    }

    func testGPSLongitude() {
        let result = PrintConverter.formatGPSCoordinate(10.7522, isLongitude: true)
        XCTAssertTrue(result.contains("10°"))
        XCTAssertTrue(result.contains("E"))
    }

    func testGPSLongitudeWest() {
        let result = PrintConverter.formatGPSCoordinate(-73.9857, isLongitude: true)
        XCTAssertTrue(result.contains("73°"))
        XCTAssertTrue(result.contains("W"))
    }

    // MARK: - Full Dictionary Conversion

    func testBuildReadableDictionary() {
        let byteOrder = ByteOrder.bigEndian

        // Build metadata with orientation=6 and ISO=1600
        let orientData = Data([0x00, 0x06, 0x00, 0x00])
        let orientEntry = IFDEntry(tag: ExifTag.orientation, type: .short, count: 1, valueData: orientData)

        var isoData = Data([0x06, 0x40, 0x00, 0x00]) // 1600 big-endian
        let isoEntry = IFDEntry(tag: ExifTag.isoSpeedRatings, type: .short, count: 1, valueData: isoData)

        let ifd0 = IFD(entries: [orientEntry], nextIFDOffset: 0)
        let exifIFD = IFD(entries: [isoEntry], nextIFDOffset: 0)

        var exifData = ExifData(byteOrder: byteOrder)
        exifData.ifd0 = ifd0
        exifData.exifIFD = exifIFD

        let metadata = ImageMetadata(format: .jpeg, exif: exifData)
        let readable = PrintConverter.buildReadableDictionary(metadata)

        XCTAssertEqual(readable["Orientation"], "Rotate 90 CW")
        XCTAssertEqual(readable["ISO"], "1600")
    }

    // MARK: - Readable JSON Export

    func testToReadableJSON() {
        let byteOrder = ByteOrder.bigEndian

        let orientData = Data([0x00, 0x01, 0x00, 0x00])
        let orientEntry = IFDEntry(tag: ExifTag.orientation, type: .short, count: 1, valueData: orientData)
        let ifd0 = IFD(entries: [orientEntry], nextIFDOffset: 0)

        var exifData = ExifData(byteOrder: byteOrder)
        exifData.ifd0 = ifd0

        let metadata = ImageMetadata(format: .jpeg, exif: exifData)
        let json = MetadataExporter.toReadableJSON(metadata)

        XCTAssertTrue(json.contains("Horizontal (normal)"))
    }
}
