import XCTest
@testable import SwiftExif

final class ExifRoundTripTests: XCTestCase {

    func testRoundTripBigEndian() throws {
        var exif = ExifData(byteOrder: .bigEndian)
        let makeData = Data("Nikon\0".utf8)
        let modelData = Data("D850\0".utf8)

        exif.ifd0 = IFD(entries: [
            IFDEntry(tag: ExifTag.make, type: .ascii, count: UInt32(makeData.count), valueData: makeData),
            IFDEntry(tag: ExifTag.model, type: .ascii, count: UInt32(modelData.count), valueData: modelData),
        ])

        let written = ExifWriter.write(exif)
        let parsed = try ExifReader.read(from: written)

        XCTAssertEqual(parsed.byteOrder, .bigEndian)
        XCTAssertEqual(parsed.make, "Nikon")
        XCTAssertEqual(parsed.model, "D850")
    }

    func testRoundTripLittleEndian() throws {
        var exif = ExifData(byteOrder: .littleEndian)
        let makeData = Data("Canon\0".utf8)

        exif.ifd0 = IFD(entries: [
            IFDEntry(tag: ExifTag.make, type: .ascii, count: UInt32(makeData.count), valueData: makeData),
        ])

        let written = ExifWriter.write(exif)
        let parsed = try ExifReader.read(from: written)

        XCTAssertEqual(parsed.byteOrder, .littleEndian)
        XCTAssertEqual(parsed.make, "Canon")
    }

    func testRoundTripShortValue() throws {
        var exif = ExifData(byteOrder: .bigEndian)

        var orientationData = BinaryWriter(capacity: 2)
        orientationData.writeUInt16BigEndian(6) // Orientation: rotated 90° CW

        exif.ifd0 = IFD(entries: [
            IFDEntry(tag: ExifTag.orientation, type: .short, count: 1, valueData: orientationData.data),
        ])

        let written = ExifWriter.write(exif)
        let parsed = try ExifReader.read(from: written)

        XCTAssertEqual(parsed.orientation, 6)
    }
}
