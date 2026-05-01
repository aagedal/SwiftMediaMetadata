import XCTest
@testable import SwiftExif

/// Round-trip tests for AIFFWriter. Builds a synthetic AIFF FORM, parses it,
/// mutates a few metadata fields, writes it back out, then re-parses and
/// asserts the changes survived plus that the COMM chunk is preserved.
final class AIFFWriterTests: XCTestCase {

    func testRoundTripUpdatesNameAuthCopyright() throws {
        let aiff = makeAIFFWithComm(channels: 2, sampleFrames: 48_000,
                                    sampleSize: 16, sampleRate: 48_000)
        var meta = try parsedAIFF(aiff)
        meta.title = "New Track"
        meta.artist = "New Artist"
        meta.comment = "© 2026 Aagedal"  // (c) chunk path

        let written = try AIFFWriter.write(meta, to: aiff)
        let reparsed = try AIFFParser.parse(written)

        XCTAssertEqual(reparsed.title, "New Track")
        XCTAssertEqual(reparsed.artist, "New Artist")
        XCTAssertEqual(reparsed.comment, "© 2026 Aagedal")
        // COMM survives.
        XCTAssertEqual(reparsed.sampleRate, 48_000)
        XCTAssertEqual(reparsed.channels, 2)
        XCTAssertEqual(reparsed.bitDepth, 16)
    }

    func testCommentWithoutCopyrightPrefixGoesToANNO() throws {
        let aiff = makeAIFFWithComm(channels: 1, sampleFrames: 100,
                                    sampleSize: 16, sampleRate: 44_100)
        var meta = try parsedAIFF(aiff)
        meta.comment = "Plain annotation"

        let written = try AIFFWriter.write(meta, to: aiff)
        let reparsed = try AIFFParser.parse(written)
        XCTAssertEqual(reparsed.comment, "Plain annotation")
    }

    func testWriteOutputIsValidFORMContainer() throws {
        let aiff = makeAIFFWithComm(channels: 2, sampleFrames: 0,
                                    sampleSize: 16, sampleRate: 48_000)
        var meta = try parsedAIFF(aiff)
        meta.title = "Hi"  // odd-length value forces a pad byte

        let written = try AIFFWriter.write(meta, to: aiff)
        XCTAssertEqual(written.prefix(4), Data("FORM".utf8))
        XCTAssertEqual(Data(written[8..<12]), Data("AIFF".utf8))
        let declared = (UInt32(written[4]) << 24) |
            (UInt32(written[5]) << 16) |
            (UInt32(written[6]) << 8) |
            UInt32(written[7])
        XCTAssertEqual(Int(declared), written.count - 8)
    }

    func testNilMetadataOmitsTextChunks() throws {
        let aiff = makeAIFFWithComm(channels: 2, sampleFrames: 100,
                                    sampleSize: 16, sampleRate: 48_000)
        let meta = try parsedAIFF(aiff)
        let written = try AIFFWriter.write(meta, to: aiff)
        let reparsed = try AIFFParser.parse(written)
        XCTAssertNil(reparsed.title)
        XCTAssertNil(reparsed.artist)
        XCTAssertNil(reparsed.comment)
    }

    // MARK: - Fixture builders

    private func makeAIFFWithComm(channels: UInt16, sampleFrames: UInt32,
                                  sampleSize: UInt16, sampleRate: UInt32) -> Data {
        let comm = makeCommChunk(channels: channels, sampleFrames: sampleFrames,
                                 sampleSize: sampleSize, sampleRate: sampleRate)
        return makeAIFF(form: "AIFF", chunks: [comm])
    }

    private func makeAIFF(form: String, chunks: [Data]) -> Data {
        var body = Data(form.utf8)
        for c in chunks { body.append(c) }
        var out = Data("FORM".utf8)
        out.append(uint32BE(UInt32(body.count)))
        out.append(body)
        return out
    }

    private func makeChunk(id: String, payload: Data) -> Data {
        var idBytes = Data(id.utf8)
        while idBytes.count < 4 { idBytes.append(0x20) }
        var out = idBytes.prefix(4)
        out.append(uint32BE(UInt32(payload.count)))
        out.append(payload)
        if payload.count & 1 == 1 { out.append(0x00) }
        return Data(out)
    }

    private func makeCommChunk(channels: UInt16, sampleFrames: UInt32,
                               sampleSize: UInt16, sampleRate: UInt32) -> Data {
        var p = Data()
        p.append(uint16BE(channels))
        p.append(uint32BE(sampleFrames))
        p.append(uint16BE(sampleSize))
        p.append(extendedFloat80BE(Double(sampleRate)))
        return makeChunk(id: "COMM", payload: p)
    }

    /// Encode a Double as 80-bit IEEE 754 extended-precision (AIFF sample rate).
    private func extendedFloat80BE(_ v: Double) -> Data {
        if v == 0 { return Data(repeating: 0, count: 10) }
        let absV = abs(v)
        let signBit: UInt16 = v < 0 ? 0x8000 : 0
        let unbiasedExp = Int(floor(log2(absV)))
        let exponent = UInt16(unbiasedExp + 16383)
        let mantissa = UInt64((absV / pow(2.0, Double(unbiasedExp))) * Double(UInt64(1) << 63))
        var d = Data()
        let expSign = signBit | exponent
        d.append(UInt8(expSign >> 8))
        d.append(UInt8(expSign & 0xFF))
        for shift in stride(from: 56, through: 0, by: -8) {
            d.append(UInt8((mantissa >> shift) & 0xFF))
        }
        return d
    }

    private func uint16BE(_ v: UInt16) -> Data {
        Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private func uint32BE(_ v: UInt32) -> Data {
        Data([
            UInt8((v >> 24) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8(v & 0xFF),
        ])
    }
}

/// Parse an AIFF in memory and stash the original bytes onto `originalData`,
/// which the writer needs in order to walk the existing chunk list.
private func parsedAIFF(_ data: Data) throws -> AudioMetadata {
    var meta = try AIFFParser.parse(data)
    meta.originalData = data
    return meta
}
