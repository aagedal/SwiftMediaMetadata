import XCTest
@testable import SwiftExif

/// Synthetic-fixture coverage for the AIFF / AIFF-C parser.
/// Builds valid FORM containers in-memory and verifies that COMM (with the
/// 80-bit IEEE 754 sample rate), NAME, AUTH, (c), ANNO, and AIFC compression
/// fields decode correctly.
final class AIFFParserTests: XCTestCase {

    // MARK: - COMM

    func testParseCommChunkPCM48k24bitStereo() throws {
        let comm = makeCommChunk(channels: 2, sampleFrames: 48_000 * 5, sampleSize: 24, sampleRate: 48_000)
        let aiff = makeAIFF(form: "AIFF", chunks: [comm])
        let meta = try AIFFParser.parse(aiff)

        XCTAssertEqual(meta.format, .aiff)
        XCTAssertEqual(meta.channels, 2)
        XCTAssertEqual(meta.sampleRate, 48_000)
        XCTAssertEqual(meta.bitDepth, 24)
        XCTAssertEqual(meta.duration ?? 0, 5.0, accuracy: 0.001)
        XCTAssertEqual(meta.bitrate, 48_000 * 2 * 24)
        XCTAssertEqual(meta.codec, "PCM")
        XCTAssertEqual(meta.codecName, "AIFF / PCM")
        XCTAssertEqual(meta.channelLayout, "stereo")
    }

    func testParseAIFCWithCompressionTag() throws {
        let comm = makeCommChunk(
            channels: 2, sampleFrames: 96_000, sampleSize: 32, sampleRate: 96_000,
            isAIFC: true, compressionType: "fl32", compressionName: "Float 32"
        )
        let aiff = makeAIFF(form: "AIFC", chunks: [comm])
        let meta = try AIFFParser.parse(aiff)
        XCTAssertEqual(meta.codec, "PCM (float 32-bit)")
        XCTAssertEqual(meta.codecName, "AIFF-C / PCM (float 32-bit)")
    }

    // MARK: - Metadata chunks

    func testParseNameAuthCopyrightChunks() throws {
        let comm = makeCommChunk(channels: 2, sampleFrames: 48_000, sampleSize: 16, sampleRate: 48_000)
        let name  = makeChunk(id: "NAME", payload: Data("My Track".utf8))
        let auth  = makeChunk(id: "AUTH", payload: Data("Truls A.".utf8))
        let copy  = makeChunk(id: "(c) ", payload: Data("2026 Aagedal Media".utf8))

        let meta = try AIFFParser.parse(makeAIFF(form: "AIFF", chunks: [comm, name, auth, copy]))
        XCTAssertEqual(meta.title, "My Track")
        XCTAssertEqual(meta.artist, "Truls A.")
        XCTAssertEqual(meta.comment, "© 2026 Aagedal Media")
    }

    func testMultipleANNOChunksJoinIntoComment() throws {
        let comm = makeCommChunk(channels: 1, sampleFrames: 100, sampleSize: 16, sampleRate: 44_100)
        let anno1 = makeChunk(id: "ANNO", payload: Data("First note".utf8))
        let anno2 = makeChunk(id: "ANNO", payload: Data("Second note".utf8))
        let meta = try AIFFParser.parse(makeAIFF(form: "AIFF", chunks: [comm, anno1, anno2]))
        XCTAssertEqual(meta.comment, "First note\nSecond note")
    }

    // MARK: - Format detection

    func testDetectAIFFFromMagic() {
        let comm = makeCommChunk(channels: 2, sampleFrames: 0, sampleSize: 16, sampleRate: 48_000)
        XCTAssertEqual(FormatDetector.detectAudio(makeAIFF(form: "AIFF", chunks: [comm])), .aiff)
        XCTAssertEqual(FormatDetector.detectAudio(makeAIFF(form: "AIFC", chunks: [comm])), .aiff)
    }

    func testDetectAIFFFromExtension() {
        XCTAssertEqual(FormatDetector.detectAudioFromExtension("aiff"), .aiff)
        XCTAssertEqual(FormatDetector.detectAudioFromExtension("aif"), .aiff)
        XCTAssertEqual(FormatDetector.detectAudioFromExtension("AIFC"), .aiff)
    }

    // MARK: - Helpers

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

    private func makeCommChunk(
        channels: UInt16, sampleFrames: UInt32, sampleSize: UInt16, sampleRate: UInt32,
        isAIFC: Bool = false, compressionType: String = "", compressionName: String = ""
    ) -> Data {
        var p = Data()
        p.append(uint16BE(channels))
        p.append(uint32BE(sampleFrames))
        p.append(uint16BE(sampleSize))
        p.append(extendedFloat80BE(Double(sampleRate)))
        if isAIFC {
            // Pad / truncate the compression type to exactly 4 bytes.
            var tag = Data(compressionType.utf8)
            while tag.count < 4 { tag.append(0x00) }
            p.append(tag.prefix(4))
            // Pascal string for compression name.
            let nameBytes = Data(compressionName.utf8)
            p.append(UInt8(min(nameBytes.count, 255)))
            p.append(nameBytes.prefix(255))
            if (1 + nameBytes.count) & 1 == 1 { p.append(0x00) }
        }
        return makeChunk(id: "COMM", payload: p)
    }

    /// Encode a Double as the 80-bit IEEE 754 extended-precision format
    /// AIFF uses for sample rate.
    private func extendedFloat80BE(_ v: Double) -> Data {
        if v == 0 { return Data(repeating: 0, count: 10) }
        let absV = abs(v)
        let signBit: UInt16 = v < 0 ? 0x8000 : 0
        let log2v = log2(absV)
        let unbiasedExp = Int(floor(log2v))
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
        return Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private func uint32BE(_ v: UInt32) -> Data {
        return Data([
            UInt8((v >> 24) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8(v & 0xFF),
        ])
    }
}
