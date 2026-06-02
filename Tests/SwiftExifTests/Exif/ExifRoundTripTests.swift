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

    /// The embedded-Exif writer (JPEG/PNG/AVIF/JXL) must also fix up a relocated
    /// absolute MakerNote's internal offsets.
    func testExifWriterRelocatesAbsoluteMakerNote() throws {
        func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func le32(_ v: UInt32) -> Data {
            Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
        }
        func ifd(_ entries: [(UInt16, UInt16, UInt32, Data)], next: UInt32 = 0) -> Data {
            var out = le16(UInt16(entries.count))
            for (t, ty, c, v) in entries {
                var p = v.prefix(4); while p.count < 4 { p.append(0) }
                out += le16(t) + le16(ty) + le32(c) + Data(p)
            }
            return out + le32(next)
        }

        // Standalone Canon TIFF with an Exif IFD carrying an absolute MakerNote.
        let make = Data("Canon\u{0}".utf8)
        let ifd0Size = 2 + 4 * 12 + 4
        let makeOffset = 8 + ifd0Size
        let exifOffset = makeOffset + make.count
        let exifSize = 2 + 1 * 12 + 4
        let mnOffset = exifOffset + exifSize
        let mnValueAbs = mnOffset + 18           // value bytes after the 18-byte IFD

        var tiff = Data([0x49, 0x49]) + le16(42) + le32(8)
        tiff += ifd([
            (0x0100, 3, 1, le16(1)),
            (0x0101, 3, 1, le16(1)),
            (0x010F, 2, UInt32(make.count), le32(UInt32(makeOffset))),
            (0x8769, 4, 1, le32(UInt32(exifOffset))),
        ])
        tiff += make
        tiff += ifd([(0x927C, 7, 26, le32(UInt32(mnOffset)))])
        tiff += ifd([(0x0006, 2, 8, le32(UInt32(mnValueAbs)))])
        tiff += Data("CANONSER".utf8)

        let metadata = try ImageMetadata.read(from: tiff)
        let exif = try XCTUnwrap(metadata.exif)
        XCTAssertEqual(exif.make, "Canon")

        var warnings: [String] = []
        // write() prepends "Exif\0\0", so the TIFF header sits at offset 6 and
        // internal offsets are relative to it.
        let written = ExifWriter.write(exif, warnings: &warnings)
        XCTAssertFalse(warnings.contains { $0.contains("MakerNote") },
                       "absolute MakerNote should be fixed up by ExifWriter, not warned")

        // The relocated MakerNote's internal offset must resolve in the output.
        let reread = try ExifReader.read(from: written)
        let mn = try XCTUnwrap(reread.exifIFD?.entry(for: ExifTag.makerNote))
        let s = mn.valueData.startIndex + 10
        let ptr = Int(UInt32(mn.valueData[s]) | (UInt32(mn.valueData[s + 1]) << 8)
                      | (UInt32(mn.valueData[s + 2]) << 16) | (UInt32(mn.valueData[s + 3]) << 24))
        let tiffStart = 6 // "Exif\0\0"
        XCTAssertLessThanOrEqual(tiffStart + ptr + 8, written.count)
        let resolved = written.subdata(in: (written.startIndex + tiffStart + ptr) ..< (written.startIndex + tiffStart + ptr + 8))
        XCTAssertEqual(resolved, Data("CANONSER".utf8))
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
