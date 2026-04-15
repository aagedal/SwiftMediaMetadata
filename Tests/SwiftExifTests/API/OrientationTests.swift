import XCTest
@testable import SwiftExif

final class OrientationTests: XCTestCase {

    // MARK: - Transform Compose Tests

    func testRotateClockwiseAll() {
        let expected: [UInt16] = [6, 7, 8, 5, 2, 3, 4, 1]
        for i in 1...8 {
            XCTAssertEqual(
                OrientationTransform.compose(current: UInt16(i), operation: .rotateClockwise),
                expected[i - 1],
                "RotateCW from \(i)"
            )
        }
    }

    func testRotateCounterClockwiseAll() {
        let expected: [UInt16] = [8, 5, 6, 7, 4, 1, 2, 3]
        for i in 1...8 {
            XCTAssertEqual(
                OrientationTransform.compose(current: UInt16(i), operation: .rotateCounterClockwise),
                expected[i - 1],
                "RotateCCW from \(i)"
            )
        }
    }

    func testFlipHorizontalAll() {
        let expected: [UInt16] = [2, 1, 4, 3, 6, 5, 8, 7]
        for i in 1...8 {
            XCTAssertEqual(
                OrientationTransform.compose(current: UInt16(i), operation: .flipHorizontal),
                expected[i - 1],
                "FlipH from \(i)"
            )
        }
    }

    func testFlipVerticalAll() {
        let expected: [UInt16] = [4, 3, 2, 1, 8, 7, 6, 5]
        for i in 1...8 {
            XCTAssertEqual(
                OrientationTransform.compose(current: UInt16(i), operation: .flipVertical),
                expected[i - 1],
                "FlipV from \(i)"
            )
        }
    }

    func testFourRotationsReturnToOriginal() {
        for start: UInt16 in 1...8 {
            var current = start
            for _ in 0..<4 {
                current = OrientationTransform.compose(current: current, operation: .rotateClockwise)
            }
            XCTAssertEqual(current, start, "4x CW from \(start) should return to \(start)")
        }
    }

    func testCWThenCCWIsIdentity() {
        for start: UInt16 in 1...8 {
            let rotated = OrientationTransform.compose(current: start, operation: .rotateClockwise)
            let back = OrientationTransform.compose(current: rotated, operation: .rotateCounterClockwise)
            XCTAssertEqual(back, start, "CW then CCW from \(start)")
        }
    }

    func testDoubleFlipHIsIdentity() {
        for start: UInt16 in 1...8 {
            let flipped = OrientationTransform.compose(current: start, operation: .flipHorizontal)
            let back = OrientationTransform.compose(current: flipped, operation: .flipHorizontal)
            XCTAssertEqual(back, start, "Double FlipH from \(start)")
        }
    }

    func testDoubleFlipVIsIdentity() {
        for start: UInt16 in 1...8 {
            let flipped = OrientationTransform.compose(current: start, operation: .flipVertical)
            let back = OrientationTransform.compose(current: flipped, operation: .flipVertical)
            XCTAssertEqual(back, start, "Double FlipV from \(start)")
        }
    }

    func testInvalidOrientationDefaultsToOne() {
        XCTAssertEqual(OrientationTransform.compose(current: 0, operation: .rotateClockwise), 6)
        XCTAssertEqual(OrientationTransform.compose(current: 9, operation: .rotateClockwise), 6)
        XCTAssertEqual(OrientationTransform.compose(current: 255, operation: .flipHorizontal), 2)
    }

    // MARK: - ImageMetadata Orientation Methods

    func testSetOrientation() {
        var metadata = makeMetadata()
        metadata.setOrientation(6)
        XCTAssertEqual(metadata.exif?.orientation, 6)
    }

    func testResetOrientation() {
        var metadata = makeMetadata()
        metadata.setOrientation(6)
        metadata.resetOrientation()
        XCTAssertEqual(metadata.exif?.orientation, 1)
    }

    func testRotateClockwiseFromNormal() {
        var metadata = makeMetadata()
        metadata.rotateClockwise()
        XCTAssertEqual(metadata.exif?.orientation, 6)
    }

    func testRotateCounterClockwiseFromNormal() {
        var metadata = makeMetadata()
        metadata.rotateCounterClockwise()
        XCTAssertEqual(metadata.exif?.orientation, 8)
    }

    func testFlipHorizontalFromNormal() {
        var metadata = makeMetadata()
        metadata.flipHorizontal()
        XCTAssertEqual(metadata.exif?.orientation, 2)
    }

    func testFlipVerticalFromNormal() {
        var metadata = makeMetadata()
        metadata.flipVertical()
        XCTAssertEqual(metadata.exif?.orientation, 4)
    }

    func testOrientationWithNoExif() {
        // Start with no exif at all — should create it
        var metadata = makeMetadata(includeExif: false)
        XCTAssertNil(metadata.exif)
        metadata.rotateClockwise()
        XCTAssertNotNil(metadata.exif)
        XCTAssertEqual(metadata.exif?.orientation, 6)
    }

    func testOrientationInvalidValueIgnored() {
        var metadata = makeMetadata()
        metadata.setOrientation(1)
        metadata.setOrientation(0) // invalid, should be ignored
        XCTAssertEqual(metadata.exif?.orientation, 1)
        metadata.setOrientation(9) // invalid
        XCTAssertEqual(metadata.exif?.orientation, 1)
    }

    func testThumbnailOrientationUpdated() {
        var metadata = makeMetadata(includeThumbnail: true)
        metadata.setOrientation(6)

        // Both IFD0 and IFD1 should have orientation 6
        XCTAssertEqual(metadata.exif?.orientation, 6)
        let thumbOrientation = metadata.exif?.ifd1?.entry(for: ExifTag.orientation)?
            .uint16Value(endian: metadata.exif!.byteOrder)
        XCTAssertEqual(thumbOrientation, 6)
    }

    func testOrientationRoundTrip() throws {
        // Build a minimal JPEG, read it, add exif via setOrientation, write, re-read
        let jpeg = TestFixtures.minimalJPEG()
        var metadata = try ImageMetadata.read(from: jpeg)

        metadata.rotateClockwise()
        XCTAssertEqual(metadata.exif?.orientation, 6)

        let written = try metadata.writeToData()
        let reread = try ImageMetadata.read(from: written)
        XCTAssertEqual(reread.exif?.orientation, 6)
    }

    // MARK: - Helpers

    private func makeMetadata(includeExif: Bool = true, includeThumbnail: Bool = false) -> ImageMetadata {
        let jpeg = JPEGFile(segments: [], scanData: Data())

        if includeExif {
            var exif = ExifData(byteOrder: .bigEndian)
            var orientationWriter = BinaryWriter(capacity: 2)
            orientationWriter.writeUInt16BigEndian(1)
            let entry = IFDEntry(tag: ExifTag.orientation, type: .short, count: 1, valueData: orientationWriter.data)
            exif.ifd0 = IFD(entries: [entry])
            if includeThumbnail {
                exif.ifd1 = IFD(entries: [entry])
            }
            return ImageMetadata(container: .jpeg(jpeg), format: .jpeg, iptc: IPTCData(), exif: exif)
        } else {
            return ImageMetadata(container: .jpeg(jpeg), format: .jpeg, iptc: IPTCData())
        }
    }
}
