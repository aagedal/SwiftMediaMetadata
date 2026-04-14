import XCTest
@testable import SwiftExif

final class CompositeTagTests: XCTestCase {

    // MARK: - Aperture from APEX

    func testApertureFromAPEX() {
        // APEX ApertureValue = 4.0 → f-number = 2^(4/2) = 4.0
        let exif = makeExif(apertureValue: (4, 1))
        let result = CompositeTagCalculator.apertureFromAPEX(exif)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 4.0, accuracy: 0.01)
    }

    func testApertureFromAPEXFractional() {
        // APEX ApertureValue = 2.97 → f-number = 2^(2.97/2) ≈ 2.8
        let exif = makeExif(apertureValue: (297, 100))
        let result = CompositeTagCalculator.apertureFromAPEX(exif)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 2.8, accuracy: 0.05)
    }

    func testApertureMissingReturnsNil() {
        let exif = ExifData(byteOrder: .bigEndian)
        XCTAssertNil(CompositeTagCalculator.apertureFromAPEX(exif))
    }

    // MARK: - Shutter Speed from APEX

    func testShutterSpeedFromAPEX() {
        // APEX ShutterSpeedValue = 8 → time = 1/2^8 = 1/256 ≈ 0.00390625
        let exif = makeExif(shutterSpeedValue: (8, 1))
        let result = CompositeTagCalculator.shutterSpeedFromAPEX(exif)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 1.0 / 256.0, accuracy: 0.0001)
    }

    func testShutterSpeedNegativeAPEX() {
        // APEX ShutterSpeedValue = -1 → time = 1/2^(-1) = 2 seconds
        let exif = makeExif(shutterSpeedValue: (-1, 1))
        let result = CompositeTagCalculator.shutterSpeedFromAPEX(exif)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 2.0, accuracy: 0.01)
    }

    // MARK: - Megapixels

    func testMegapixels() {
        let exif = makeExif(pixelX: 6000, pixelY: 4000)
        let result = CompositeTagCalculator.megapixels(exif)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 24.0, accuracy: 0.01)
    }

    func testMegapixelsMissingReturnsNil() {
        let exif = ExifData(byteOrder: .bigEndian)
        XCTAssertNil(CompositeTagCalculator.megapixels(exif))
    }

    // MARK: - LensID

    func testLensIDCombined() {
        let exif = makeExif(lensMake: "Canon", lensModel: "EF 24-70mm f/2.8L II")
        let result = CompositeTagCalculator.lensID(exif)
        XCTAssertEqual(result, "Canon EF 24-70mm f/2.8L II")
    }

    func testLensIDModelOnly() {
        let exif = makeExif(lensModel: "RF 50mm F1.2 L USM")
        let result = CompositeTagCalculator.lensID(exif)
        XCTAssertEqual(result, "RF 50mm F1.2 L USM")
    }

    func testLensIDAvoidsDuplication() {
        // If model already starts with make, don't duplicate
        let exif = makeExif(lensMake: "Canon", lensModel: "Canon EF 50mm f/1.4")
        let result = CompositeTagCalculator.lensID(exif)
        XCTAssertEqual(result, "Canon EF 50mm f/1.4")
    }

    func testLensIDNilWhenMissing() {
        let exif = ExifData(byteOrder: .bigEndian)
        XCTAssertNil(CompositeTagCalculator.lensID(exif))
    }

    // MARK: - ScaleFactor35efl

    func testScaleFactor35efl() {
        // 50mm lens, 75mm equiv → 1.5x crop factor
        let exif = makeExif(focalLength: (50, 1), fl35mm: 75)
        let result = CompositeTagCalculator.scaleFactor35efl(exif)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 1.5, accuracy: 0.01)
    }

    func testScaleFactorMissingReturnsNil() {
        let exif = makeExif(focalLength: (50, 1))
        XCTAssertNil(CompositeTagCalculator.scaleFactor35efl(exif))
    }

    // MARK: - Light Value

    func testLightValue() {
        // f/4, 1/250s, ISO 100 → EV = log2(16/0.004) ≈ 11.97
        let exif = makeExif(fNumber: (4, 1), exposureTime: (1, 250), iso: 100)
        let result = CompositeTagCalculator.lightValue(exif)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 11.97, accuracy: 0.1)
    }

    func testLightValueWithISO() {
        // f/2.8, 1/60s, ISO 400 → LV = log2(7.84/0.0167) - log2(4) ≈ 6.9
        let exif = makeExif(fNumber: (28, 10), exposureTime: (1, 60), iso: 400)
        let result = CompositeTagCalculator.lightValue(exif)
        XCTAssertNotNil(result)
        XCTAssertTrue(result! > 5.0 && result! < 10.0)
    }

    // MARK: - GPS Position

    func testGPSPosition() {
        let exif = makeExifWithGPS(lat: 59.9139, lon: 10.7522)
        let result = CompositeTagCalculator.gpsPosition(exif)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("59.913"))
        XCTAssertTrue(result!.contains("10.752"))
    }

    func testGPSPositionMissing() {
        let exif = ExifData(byteOrder: .bigEndian)
        XCTAssertNil(CompositeTagCalculator.gpsPosition(exif))
    }

    // MARK: - Calculate All

    func testCalculateReturnsCompositePrefix() {
        let exif = makeExif(pixelX: 4000, pixelY: 3000)
        let result = CompositeTagCalculator.calculate(from: exif)
        XCTAssertTrue(result.keys.allSatisfy { $0.hasPrefix("Composite:") })
    }

    // MARK: - MetadataExporter Integration

    func testCompositeTagsInExporterOutput() {
        let exif = makeExif(pixelX: 6000, pixelY: 4000)
        let metadata = ImageMetadata(format: .jpeg, exif: exif)
        let dict = MetadataExporter.buildDictionary(metadata)
        XCTAssertEqual(dict["Composite:Megapixels"] as? Double, 24.0)
    }

    // MARK: - Helpers

    private func makeExif(
        apertureValue: (UInt32, UInt32)? = nil,
        shutterSpeedValue: (Int32, Int32)? = nil,
        pixelX: UInt32? = nil,
        pixelY: UInt32? = nil,
        lensMake: String? = nil,
        lensModel: String? = nil,
        focalLength: (UInt32, UInt32)? = nil,
        fl35mm: UInt16? = nil,
        fNumber: (UInt32, UInt32)? = nil,
        exposureTime: (UInt32, UInt32)? = nil,
        iso: UInt16? = nil
    ) -> ExifData {
        let endian = ByteOrder.bigEndian
        var exifEntries: [IFDEntry] = []

        if let av = apertureValue {
            var w = BinaryWriter(capacity: 8)
            w.writeUInt32(av.0, endian: endian)
            w.writeUInt32(av.1, endian: endian)
            exifEntries.append(IFDEntry(tag: ExifTag.apertureValue, type: .rational, count: 1, valueData: w.data))
        }

        if let sv = shutterSpeedValue {
            var w = BinaryWriter(capacity: 8)
            w.writeUInt32(UInt32(bitPattern: sv.0), endian: endian)
            w.writeUInt32(UInt32(bitPattern: sv.1), endian: endian)
            exifEntries.append(IFDEntry(tag: ExifTag.shutterSpeedValue, type: .srational, count: 1, valueData: w.data))
        }

        if let px = pixelX {
            var w = BinaryWriter(capacity: 4)
            w.writeUInt32(px, endian: endian)
            exifEntries.append(IFDEntry(tag: ExifTag.pixelXDimension, type: .long, count: 1, valueData: w.data))
        }

        if let py = pixelY {
            var w = BinaryWriter(capacity: 4)
            w.writeUInt32(py, endian: endian)
            exifEntries.append(IFDEntry(tag: ExifTag.pixelYDimension, type: .long, count: 1, valueData: w.data))
        }

        if let lm = lensMake {
            let bytes = Data(lm.utf8) + Data([0x00])
            exifEntries.append(IFDEntry(tag: ExifTag.lensMake, type: .ascii, count: UInt32(bytes.count), valueData: bytes))
        }

        if let model = lensModel {
            let bytes = Data(model.utf8) + Data([0x00])
            exifEntries.append(IFDEntry(tag: ExifTag.lensModel, type: .ascii, count: UInt32(bytes.count), valueData: bytes))
        }

        if let fl = focalLength {
            var w = BinaryWriter(capacity: 8)
            w.writeUInt32(fl.0, endian: endian)
            w.writeUInt32(fl.1, endian: endian)
            exifEntries.append(IFDEntry(tag: ExifTag.focalLength, type: .rational, count: 1, valueData: w.data))
        }

        if let fl35 = fl35mm {
            var w = BinaryWriter(capacity: 2)
            w.writeUInt16(fl35, endian: endian)
            exifEntries.append(IFDEntry(tag: ExifTag.focalLengthIn35mmFilm, type: .short, count: 1, valueData: w.data))
        }

        if let fn = fNumber {
            var w = BinaryWriter(capacity: 8)
            w.writeUInt32(fn.0, endian: endian)
            w.writeUInt32(fn.1, endian: endian)
            exifEntries.append(IFDEntry(tag: ExifTag.fNumber, type: .rational, count: 1, valueData: w.data))
        }

        if let et = exposureTime {
            var w = BinaryWriter(capacity: 8)
            w.writeUInt32(et.0, endian: endian)
            w.writeUInt32(et.1, endian: endian)
            exifEntries.append(IFDEntry(tag: ExifTag.exposureTime, type: .rational, count: 1, valueData: w.data))
        }

        if let iso = iso {
            var w = BinaryWriter(capacity: 2)
            w.writeUInt16(iso, endian: endian)
            exifEntries.append(IFDEntry(tag: ExifTag.isoSpeedRatings, type: .short, count: 1, valueData: w.data))
        }

        var exifData = ExifData(byteOrder: endian)
        exifData.exifIFD = IFD(entries: exifEntries)
        return exifData
    }

    private func makeExifWithGPS(lat: Double, lon: Double) -> ExifData {
        let endian = ByteOrder.bigEndian
        var exifData = ExifData(byteOrder: endian)

        let latTriplet = GPXGeotagger.degreesToRationalTriplet(abs(lat))
        let lonTriplet = GPXGeotagger.degreesToRationalTriplet(abs(lon))

        var latWriter = BinaryWriter(capacity: 24)
        for (n, d) in latTriplet {
            latWriter.writeUInt32(n, endian: endian)
            latWriter.writeUInt32(d, endian: endian)
        }

        var lonWriter = BinaryWriter(capacity: 24)
        for (n, d) in lonTriplet {
            lonWriter.writeUInt32(n, endian: endian)
            lonWriter.writeUInt32(d, endian: endian)
        }

        let latRef = (lat >= 0 ? "N" : "S") + "\0"
        let lonRef = (lon >= 0 ? "E" : "W") + "\0"

        var latRefData = Data(latRef.utf8)
        while latRefData.count < 4 { latRefData.append(0x00) }
        var lonRefData = Data(lonRef.utf8)
        while lonRefData.count < 4 { lonRefData.append(0x00) }

        exifData.gpsIFD = IFD(entries: [
            IFDEntry(tag: ExifTag.gpsLatitudeRef, type: .ascii, count: 2, valueData: latRefData),
            IFDEntry(tag: ExifTag.gpsLatitude, type: .rational, count: 3, valueData: latWriter.data),
            IFDEntry(tag: ExifTag.gpsLongitudeRef, type: .ascii, count: 2, valueData: lonRefData),
            IFDEntry(tag: ExifTag.gpsLongitude, type: .rational, count: 3, valueData: lonWriter.data),
        ])

        return exifData
    }
}
