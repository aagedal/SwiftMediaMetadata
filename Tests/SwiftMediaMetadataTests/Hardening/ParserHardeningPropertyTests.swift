import Foundation
import XCTest
@testable import SwiftMediaMetadata

/// Deterministic parser properties that complement the focused regression tests.
///
/// The default iteration count is intentionally small enough for every `swift test`
/// run. `Scripts/run-parser-fuzzing.sh` raises it for a longer local fuzz pass and
/// prints the seed so every failure can be reproduced exactly.
final class ParserHardeningPropertyTests: XCTestCase {
    private static let defaultSeed: UInt64 = 0x5357_4946_544D_4554 // "SWIFTMET"
    private static let defaultIterations = 256
    private static let maximumInputLength = 512

    func testEveryTruncationOfValidInputsReturnsWithoutTrapping() {
        let inputs: [(ParserTarget, Data)] = [
            (.tiffExif, TestFixtures.tiffWithExif(make: "Truncation", model: "Seed")),
            (.isobmff, ISOBMFFBoxWriter.serialize(boxes: [
                ISOBMFFBox(type: "free", data: Data([0x01, 0x02, 0x03])),
                ISOBMFFBox(type: "uuid", data: Data(repeating: 0xA5, count: 24), usesLargeSize: true),
            ])),
            (.xmp, makeXMPSeed()),
            (.c2pa, makeJUMBFSeed()),
            (.videoBitstream, Data([0x64, 0x00, 0x28, 0xAC, 0x2B, 0x40, 0x78, 0x02, 0x27, 0xE5, 0xC0])),
        ]

        for (target, input) in inputs {
            for length in 0...input.count {
                exercise(target, with: Data(input.prefix(length)))
            }
        }
    }

    func testMalformedLengthFieldsReturnWithoutTrapping() {
        let oversized32 = Data([0xFF, 0xFF, 0xFF, 0xFF])
        let oversized64 = Data(repeating: 0xFF, count: 8)

        let cases: [(ParserTarget, Data)] = [
            // Big-endian TIFF: one LONG entry declaring UInt32.max values at
            // UInt32.max. It must throw/bail rather than allocate or trap.
            (.tiffExif, Data([
                0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,
                0x00, 0x01, 0x01, 0x00, 0x00, 0x04,
            ]) + oversized32 + oversized32 + Data(repeating: 0, count: 4)),
            // Extended-size ISOBMFF box whose declared size cannot fit Int.
            (.isobmff, Data([0x00, 0x00, 0x00, 0x01]) + Data("free".utf8) + oversized64),
            // A content box nested under a valid JUMBF description but claiming
            // a payload far beyond the enclosing superbox.
            (.c2pa, makeJUMBFSeed() + oversized32 + Data("cbor".utf8)),
            // SEI payload type/length continuation bytes with no terminator.
            (.videoBitstream, Data(repeating: 0xFF, count: 64)),
        ]

        for (target, input) in cases {
            exercise(target, with: input)
        }
    }

    func testDeterministicByteSoupReturnsWithoutTrapping() {
        let environment = ProcessInfo.processInfo.environment
        let iterations = environment["SWIFT_METADATA_FUZZ_ITERATIONS"].flatMap(Int.init)
            ?? Self.defaultIterations
        let seed = environment["SWIFT_METADATA_FUZZ_SEED"].flatMap(parseSeed)
            ?? Self.defaultSeed

        XCTAssertGreaterThan(iterations, 0)
        var generator = SplitMix64(state: seed)
        let targets = ParserTarget.allCases

        for iteration in 0..<iterations {
            let length = Int(generator.next() % UInt64(Self.maximumInputLength + 1))
            var bytes = [UInt8]()
            bytes.reserveCapacity(length)
            for _ in 0..<length {
                bytes.append(UInt8(truncatingIfNeeded: generator.next()))
            }

            let target = targets[iteration % targets.count]
            exercise(target, with: Data(bytes))
        }
    }

    func testWriterReadWriterIsStable() throws {
        var exif = ExifData(byteOrder: .littleEndian)
        exif.ifd0 = IFD(entries: [
            IFDEntry(
                tag: ExifTag.make,
                type: .ascii,
                count: 9,
                valueData: Data("Property\0".utf8)
            ),
            IFDEntry(
                tag: ExifTag.orientation,
                type: .short,
                count: 1,
                valueData: Data([0x06, 0x00])
            ),
        ])
        let firstTIFF = ExifWriter.writeTIFF(exif)
        let parsedExif = try ExifReader.readFromTIFF(data: firstTIFF)
        XCTAssertEqual(ExifWriter.writeTIFF(parsedExif), firstTIFF)

        let boxes = [
            ISOBMFFBox(type: "free", data: Data([0x10, 0x20, 0x30])),
            ISOBMFFBox(type: "uuid", data: Data(repeating: 0x5A, count: 17), usesLargeSize: true),
        ]
        let firstBoxes = ISOBMFFBoxWriter.serialize(boxes: boxes)
        let parsedBoxes = try ISOBMFFBoxReader.parseBoxes(from: firstBoxes)
        XCTAssertEqual(ISOBMFFBoxWriter.serialize(boxes: parsedBoxes), firstBoxes)

        var xmp = XMPData()
        xmp.headline = "Escaped <headline> & Nordic ÆØÅ"
        xmp.subject = ["property", "round-trip"]
        let firstXML = Data(XMPWriter.generateXML(xmp).utf8)
        let parsedXMP = try XMPReader.readFromXML(firstXML)
        let secondXML = Data(XMPWriter.generateXML(parsedXMP).utf8)
        let reparsedXMP = try XMPReader.readFromXML(secondXML)
        XCTAssertEqual(reparsedXMP, parsedXMP)
        XCTAssertEqual(Data(XMPWriter.generateXML(reparsedXMP).utf8), secondXML)
    }

    // MARK: - Shared fuzz entry points

    private enum ParserTarget: CaseIterable {
        case tiffExif
        case isobmff
        case xmp
        case c2pa
        case videoBitstream
    }

    /// Exercise every public/internal leaf that accepts arbitrary bytes. Parser
    /// errors are expected outcomes; a crash, trap, timeout, or runaway allocation
    /// is the failure signal for these property cases.
    private func exercise(_ target: ParserTarget, with data: Data) {
        switch target {
        case .tiffExif:
            _ = try? ExifReader.readFromTIFF(data: data)
            _ = try? TIFFFileParser.parse(data)
        case .isobmff:
            _ = try? ISOBMFFBoxReader.parseBoxes(from: data)
            _ = try? ISOBMFFBoxReader.parseTopLevelBoxesSkippingMdat(data)
        case .xmp:
            _ = try? XMPReader.readFromXML(data)
        case .c2pa:
            _ = try? JUMBFParser.parseDescription(from: data)
            _ = try? JUMBFParser.parseSuperbox(from: data)
        case .videoBitstream:
            _ = MPEGBitstream.annexBNALRanges(data)
            _ = MPEGBitstream.stripEmulationPrevention(data)
            _ = MPEGBitstream.extractHEVCConfigurationBitstreams(data)
            _ = MPEGBitstream.parseH264SPS(data)
            _ = MPEGBitstream.parseHEVCSPS(data)
            _ = MPEGBitstream.parseAACADTS(data)
            _ = MPEGBitstream.parseAudioSpecificConfig(data)
            _ = MPEGBitstream.parseAACLATM(data)
            _ = MPEGBitstream.parseAC3(data)
            _ = MPEGBitstream.parseEAC3(data)
            _ = MPEGBitstream.parseSEIMessages([data], forHEVC: false)
            _ = MPEGBitstream.parseSEIMessages([data], forHEVC: true)
        }
    }

    private func parseSeed(_ value: String) -> UInt64? {
        let normalized = value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value
        return UInt64(normalized, radix: 16) ?? UInt64(value)
    }

    private func makeXMPSeed() -> Data {
        var xmp = XMPData()
        xmp.headline = "Truncation seed"
        xmp.subject = ["one", "two"]
        return Data(XMPWriter.generateXML(xmp).utf8)
    }

    private func makeJUMBFSeed() -> Data {
        var description = Data("c2pa".utf8)
        description.append(contentsOf: JUMBFParser.c2paUUIDSuffix)
        description.append(0x03)
        description.append(contentsOf: Data("c2pa\0".utf8))

        let descriptionBox = ISOBMFFBoxWriter.serialize(boxes: [
            ISOBMFFBox(type: "jumd", data: description),
        ])
        return descriptionBox
    }
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
