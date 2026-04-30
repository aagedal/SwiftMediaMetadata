import XCTest
@testable import SwiftExif

/// Coverage for ExifData accessors added in the EXIF 2.32 completeness pass:
/// body/lens serial numbers, image unique ID, camera owner, subject distance,
/// and the expanded GPS surface (altitude, image direction, destination bearing,
/// DOP, horizontal positioning error).
final class ExifDataAccessorTests: XCTestCase {

    // MARK: - Exif IFD strings

    func testBodySerialNumber() {
        let exif = makeExifIFD(asciiTags: [(ExifTag.bodySerialNumber, "Z9-12345")])
        XCTAssertEqual(exif.bodySerialNumber, "Z9-12345")
    }

    func testLensSerialNumber() {
        let exif = makeExifIFD(asciiTags: [(ExifTag.lensSerialNumber, "L-9876")])
        XCTAssertEqual(exif.lensSerialNumber, "L-9876")
    }

    func testCameraOwnerName() {
        let exif = makeExifIFD(asciiTags: [(ExifTag.cameraOwnerName, "Truls A.")])
        XCTAssertEqual(exif.cameraOwnerName, "Truls A.")
    }

    func testImageUniqueID() {
        // Spec: 33-character ASCII hex string.
        let id = String(repeating: "A", count: 32)
        let exif = makeExifIFD(asciiTags: [(ExifTag.imageUniqueID, id)])
        XCTAssertEqual(exif.imageUniqueID, id)
    }

    func testSubjectDistanceMeters() {
        let exif = makeExifIFD(rationalTags: [(ExifTag.subjectDistance, (250, 100))])
        XCTAssertEqual(exif.subjectDistance ?? 0, 2.5, accuracy: 0.001)
    }

    func testSubjectDistanceNilWhenAbsent() {
        let exif = ExifData(byteOrder: .bigEndian)
        XCTAssertNil(exif.subjectDistance)
    }

    // MARK: - GPS expansion

    func testGPSAltitudeAboveSeaLevel() {
        let exif = makeGPSIFD(rationalTags: [(ExifTag.gpsAltitude, (12345, 100))],
                              byteTags: [(ExifTag.gpsAltitudeRef, 0)])
        XCTAssertEqual(exif.gpsAltitude ?? 0, 123.45, accuracy: 0.01)
    }

    func testGPSAltitudeBelowSeaLevel() {
        let exif = makeGPSIFD(rationalTags: [(ExifTag.gpsAltitude, (500, 100))],
                              byteTags: [(ExifTag.gpsAltitudeRef, 1)])
        XCTAssertEqual(exif.gpsAltitude ?? 0, -5.0, accuracy: 0.01)
    }

    func testGPSImgDirection() {
        let exif = makeGPSIFD(rationalTags: [(ExifTag.gpsImgDirection, (27050, 100))],
                              asciiTags: [(ExifTag.gpsImgDirectionRef, "T")])
        XCTAssertEqual(exif.gpsImgDirection ?? 0, 270.5, accuracy: 0.01)
        XCTAssertEqual(exif.gpsImgDirectionRef, "T")
    }

    func testGPSDestBearing() {
        let exif = makeGPSIFD(rationalTags: [(ExifTag.gpsDestBearing, (4500, 100))],
                              asciiTags: [(ExifTag.gpsDestBearingRef, "M")])
        XCTAssertEqual(exif.gpsDestBearing ?? 0, 45.0, accuracy: 0.01)
        XCTAssertEqual(exif.gpsDestBearingRef, "M")
    }

    func testGPSDOP() {
        let exif = makeGPSIFD(rationalTags: [(ExifTag.gpsDOP, (320, 100))])
        XCTAssertEqual(exif.gpsDOP ?? 0, 3.2, accuracy: 0.01)
    }

    func testGPSHPositioningError() {
        let exif = makeGPSIFD(rationalTags: [(ExifTag.gpsHPositioningError, (450, 100))])
        XCTAssertEqual(exif.gpsHPositioningError ?? 0, 4.5, accuracy: 0.01)
    }

    // MARK: - Tag name lookup

    func testNewExifTagNamesResolve() {
        XCTAssertEqual(ExifTag.name(for: ExifTag.bodySerialNumber, ifd: .exifIFD), "BodySerialNumber")
        XCTAssertEqual(ExifTag.name(for: ExifTag.lensSerialNumber, ifd: .exifIFD), "LensSerialNumber")
        XCTAssertEqual(ExifTag.name(for: ExifTag.imageUniqueID, ifd: .exifIFD), "ImageUniqueID")
        XCTAssertEqual(ExifTag.name(for: ExifTag.compositeImage, ifd: .exifIFD), "CompositeImage")
        XCTAssertEqual(ExifTag.name(for: ExifTag.subjectDistance, ifd: .exifIFD), "SubjectDistance")
    }

    func testNewGPSTagNamesResolve() {
        XCTAssertEqual(ExifTag.name(for: ExifTag.gpsImgDirection, ifd: .gpsIFD), "GPSImgDirection")
        XCTAssertEqual(ExifTag.name(for: ExifTag.gpsDestBearing, ifd: .gpsIFD), "GPSDestBearing")
        XCTAssertEqual(ExifTag.name(for: ExifTag.gpsDOP, ifd: .gpsIFD), "GPSDOP")
        XCTAssertEqual(ExifTag.name(for: ExifTag.gpsHPositioningError, ifd: .gpsIFD), "GPSHPositioningError")
    }

    // MARK: - Helpers

    private func makeExifIFD(
        asciiTags: [(UInt16, String)] = [],
        rationalTags: [(UInt16, (UInt32, UInt32))] = []
    ) -> ExifData {
        let endian = ByteOrder.bigEndian
        var entries: [IFDEntry] = []
        for (tag, str) in asciiTags {
            let bytes = Data(str.utf8) + Data([0x00])
            entries.append(IFDEntry(tag: tag, type: .ascii, count: UInt32(bytes.count), valueData: bytes))
        }
        for (tag, r) in rationalTags {
            var w = BinaryWriter(capacity: 8)
            w.writeUInt32(r.0, endian: endian)
            w.writeUInt32(r.1, endian: endian)
            entries.append(IFDEntry(tag: tag, type: .rational, count: 1, valueData: w.data))
        }
        var exif = ExifData(byteOrder: endian)
        exif.exifIFD = IFD(entries: entries)
        return exif
    }

    private func makeGPSIFD(
        rationalTags: [(UInt16, (UInt32, UInt32))] = [],
        byteTags: [(UInt16, UInt8)] = [],
        asciiTags: [(UInt16, String)] = []
    ) -> ExifData {
        let endian = ByteOrder.bigEndian
        var entries: [IFDEntry] = []
        for (tag, r) in rationalTags {
            var w = BinaryWriter(capacity: 8)
            w.writeUInt32(r.0, endian: endian)
            w.writeUInt32(r.1, endian: endian)
            entries.append(IFDEntry(tag: tag, type: .rational, count: 1, valueData: w.data))
        }
        for (tag, b) in byteTags {
            entries.append(IFDEntry(tag: tag, type: .byte, count: 1, valueData: Data([b])))
        }
        for (tag, str) in asciiTags {
            let bytes = Data(str.utf8) + Data([0x00])
            entries.append(IFDEntry(tag: tag, type: .ascii, count: UInt32(bytes.count), valueData: bytes))
        }
        var exif = ExifData(byteOrder: endian)
        exif.gpsIFD = IFD(entries: entries)
        return exif
    }
}
