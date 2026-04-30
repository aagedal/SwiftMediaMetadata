import XCTest
@testable import SwiftExif

/// Synthetic-fixture coverage for the RIFF WAVE / Broadcast WAVE parser.
/// Constructs valid RIFF chunk lists in-memory and verifies that the
/// `fmt `, `bext` (BWF), `LIST INFO`, and `iXML` chunks decode correctly.
final class WAVParserTests: XCTestCase {

    // MARK: - fmt chunk

    func testParseFmtChunkPCM48k24bitStereo() throws {
        let fmt = makeFmtChunk(
            formatTag: 0x0001, channels: 2, sampleRate: 48_000, bitsPerSample: 24
        )
        let wav = makeWAV(chunks: [fmt])
        let meta = try WAVParser.parse(wav)
        XCTAssertEqual(meta.format, .wav)
        XCTAssertEqual(meta.sampleRate, 48_000)
        XCTAssertEqual(meta.channels, 2)
        XCTAssertEqual(meta.bitDepth, 24)
        XCTAssertEqual(meta.codec, "PCM")
        XCTAssertEqual(meta.codecName, "WAVE / PCM")
        XCTAssertEqual(meta.channelLayout, "stereo")
    }

    func testParseFmtChunkFloat32Mono() throws {
        let fmt = makeFmtChunk(formatTag: 0x0003, channels: 1, sampleRate: 96_000, bitsPerSample: 32)
        let meta = try WAVParser.parse(makeWAV(chunks: [fmt]))
        XCTAssertEqual(meta.codec, "PCM (float)")
        XCTAssertEqual(meta.channels, 1)
        XCTAssertEqual(meta.channelLayout, "mono")
    }

    // MARK: - bext (BWF)

    func testParseBextV0() throws {
        let fmt = makeFmtChunk(formatTag: 0x0001, channels: 2, sampleRate: 48_000, bitsPerSample: 24)
        let bext = makeBextChunk(
            description: "SCN_001 / Drone B-roll",
            originator: "Sound Devices MixPre-10 II",
            originatorReference: "AAGE_001",
            originationDate: "2026-04-15",
            originationTime: "10:23:42",
            timeReference: 48_000 * 60 * 60,  // 1 hour at 48 kHz
            version: 0,
            codingHistory: "A=PCM,F=48000,W=24,M=stereo,T=Sound Devices MixPre"
        )
        let meta = try WAVParser.parse(makeWAV(chunks: [fmt, bext]))
        let bwf = try XCTUnwrap(meta.bwf)
        XCTAssertEqual(bwf.description, "SCN_001 / Drone B-roll")
        XCTAssertEqual(bwf.originator, "Sound Devices MixPre-10 II")
        XCTAssertEqual(bwf.originatorReference, "AAGE_001")
        XCTAssertEqual(bwf.originationDate, "2026-04-15")
        XCTAssertEqual(bwf.originationTime, "10:23:42")
        XCTAssertEqual(bwf.timeReference, UInt64(48_000) * 60 * 60)
        XCTAssertEqual(bwf.version, 0)
        XCTAssertEqual(bwf.codingHistory, "A=PCM,F=48000,W=24,M=stereo,T=Sound Devices MixPre")
        // Loudness fields not present in v0.
        XCTAssertNil(bwf.loudnessValue)
    }

    func testBextStartTimecodeFromSampleReference() throws {
        let fmt = makeFmtChunk(formatTag: 0x0001, channels: 2, sampleRate: 48_000, bitsPerSample: 24)
        // 10:23:42:00 at 48 kHz = (10·3600 + 23·60 + 42) · 48000 = 1,796,256,000 samples.
        let samples: UInt64 = (10 * 3600 + 23 * 60 + 42) * 48_000
        let bext = makeBextChunk(timeReference: samples, version: 0)
        let meta = try WAVParser.parse(makeWAV(chunks: [fmt, bext]))
        let bwf = try XCTUnwrap(meta.bwf)
        let tc = bwf.startTimecode(sampleRate: 48_000, frameRate: 24.0)
        XCTAssertEqual(tc, "10:23:42:00")
    }

    func testParseBextV2WithLoudness() throws {
        let fmt = makeFmtChunk(formatTag: 0x0001, channels: 2, sampleRate: 48_000, bitsPerSample: 24)
        let bext = makeBextChunk(
            description: "Loud master",
            version: 2,
            loudnessValue:        Int16(-2350), // -23.50 LUFS (EBU R128 target)
            loudnessRange:        Int16(  500), //   5.00 LU
            maxTruePeakLevel:     Int16( -100), //  -1.00 dBTP
            maxMomentaryLoudness: Int16(-1500), // -15.00 LUFS
            maxShortTermLoudness: Int16(-1800)  // -18.00 LUFS
        )
        let meta = try WAVParser.parse(makeWAV(chunks: [fmt, bext]))
        let bwf = try XCTUnwrap(meta.bwf)
        XCTAssertEqual(bwf.version, 2)
        XCTAssertEqual(bwf.loudnessValue ?? 0, -23.5, accuracy: 0.001)
        XCTAssertEqual(bwf.loudnessRange  ?? 0,   5.0, accuracy: 0.001)
        XCTAssertEqual(bwf.maxTruePeakLevel ?? 0, -1.0, accuracy: 0.001)
        XCTAssertEqual(bwf.maxMomentaryLoudness ?? 0, -15.0, accuracy: 0.001)
        XCTAssertEqual(bwf.maxShortTermLoudness ?? 0, -18.0, accuracy: 0.001)
    }

    // MARK: - LIST INFO

    func testParseListInfoChunk() throws {
        let fmt = makeFmtChunk(formatTag: 0x0001, channels: 2, sampleRate: 44_100, bitsPerSample: 16)
        let info = makeListInfoChunk(items: [
            ("INAM", "My Recording"),
            ("IART", "Truls A."),
            ("ICRD", "2026-04-15"),
            ("ICMT", "Mastered for HDR"),
            ("IPRD", "Album Title"),
            ("IGNR", "Ambient"),
        ])
        let meta = try WAVParser.parse(makeWAV(chunks: [fmt, info]))
        XCTAssertEqual(meta.title,   "My Recording")
        XCTAssertEqual(meta.artist,  "Truls A.")
        XCTAssertEqual(meta.year,    "2026-04-15")
        XCTAssertEqual(meta.comment, "Mastered for HDR")
        XCTAssertEqual(meta.album,   "Album Title")
        XCTAssertEqual(meta.genre,   "Ambient")
    }

    // MARK: - iXML preservation

    func testIXMLChunkPreserved() throws {
        let fmt = makeFmtChunk(formatTag: 0x0001, channels: 2, sampleRate: 48_000, bitsPerSample: 24)
        let xml = "<BWFXML><PROJECT>Test Doc</PROJECT><SCENE>SCN_001</SCENE></BWFXML>"
        let ixml = makeChunk(id: "iXML", payload: Data(xml.utf8))
        let meta = try WAVParser.parse(makeWAV(chunks: [fmt, ixml]))
        XCTAssertEqual(meta.bwf?.iXML, xml)
    }

    // MARK: - Format detection

    func testDetectWAVFromMagic() {
        let fmt = makeFmtChunk(formatTag: 0x0001, channels: 2, sampleRate: 48_000, bitsPerSample: 24)
        let wav = makeWAV(chunks: [fmt])
        XCTAssertEqual(FormatDetector.detectAudio(wav), .wav)
    }

    func testDetectWAVFromExtension() {
        XCTAssertEqual(FormatDetector.detectAudioFromExtension("wav"), .wav)
        XCTAssertEqual(FormatDetector.detectAudioFromExtension("BWF"), .wav)
        XCTAssertEqual(FormatDetector.detectAudioFromExtension("wave"), .wav)
    }

    // MARK: - Helpers

    /// Wrap chunks in a RIFF / WAVE form header.
    private func makeWAV(chunks: [Data]) -> Data {
        var body = Data("WAVE".utf8)
        for c in chunks { body.append(c) }
        var out = Data("RIFF".utf8)
        out.append(uint32LE(UInt32(body.count)))
        out.append(body)
        return out
    }

    /// Build a generic RIFF chunk: 4-byte ID + 4-byte LE size + payload (+ pad byte if odd).
    private func makeChunk(id: String, payload: Data) -> Data {
        var idBytes = Data(id.utf8)
        while idBytes.count < 4 { idBytes.append(0x20) } // pad with space
        var out = idBytes.prefix(4)
        out.append(uint32LE(UInt32(payload.count)))
        out.append(payload)
        if payload.count & 1 == 1 { out.append(0x00) }
        return Data(out)
    }

    private func makeFmtChunk(formatTag: UInt16, channels: UInt16, sampleRate: UInt32, bitsPerSample: UInt16) -> Data {
        var p = Data()
        p.append(uint16LE(formatTag))
        p.append(uint16LE(channels))
        p.append(uint32LE(sampleRate))
        let blockAlign = UInt16(channels) * (bitsPerSample / 8)
        let avgBytesPerSec = sampleRate * UInt32(blockAlign)
        p.append(uint32LE(avgBytesPerSec))
        p.append(uint16LE(blockAlign))
        p.append(uint16LE(bitsPerSample))
        return makeChunk(id: "fmt ", payload: p)
    }

    private func makeBextChunk(
        description: String = "",
        originator: String = "",
        originatorReference: String = "",
        originationDate: String = "",
        originationTime: String = "",
        timeReference: UInt64 = 0,
        version: UInt16 = 0,
        loudnessValue: Int16? = nil,
        loudnessRange: Int16? = nil,
        maxTruePeakLevel: Int16? = nil,
        maxMomentaryLoudness: Int16? = nil,
        maxShortTermLoudness: Int16? = nil,
        codingHistory: String = ""
    ) -> Data {
        var p = Data()
        p.append(asciiPadded(description, length: 256))
        p.append(asciiPadded(originator, length: 32))
        p.append(asciiPadded(originatorReference, length: 32))
        p.append(asciiPadded(originationDate, length: 10))
        p.append(asciiPadded(originationTime, length: 8))
        p.append(uint32LE(UInt32(timeReference & 0xFFFFFFFF)))
        p.append(uint32LE(UInt32(timeReference >> 32)))
        p.append(uint16LE(version))
        // UMID — 64 bytes (zeros for v0).
        p.append(Data(repeating: 0, count: 64))
        // Loudness fields — 5 × Int16 (10 bytes), zeroed if missing.
        p.append(uint16LE(UInt16(bitPattern: loudnessValue ?? 0)))
        p.append(uint16LE(UInt16(bitPattern: loudnessRange ?? 0)))
        p.append(uint16LE(UInt16(bitPattern: maxTruePeakLevel ?? 0)))
        p.append(uint16LE(UInt16(bitPattern: maxMomentaryLoudness ?? 0)))
        p.append(uint16LE(UInt16(bitPattern: maxShortTermLoudness ?? 0)))
        // Reserved — 180 bytes.
        p.append(Data(repeating: 0, count: 180))
        // Coding history — variable-length null-terminated ASCII.
        p.append(Data(codingHistory.utf8))
        p.append(0x00)
        return makeChunk(id: "bext", payload: p)
    }

    private func makeListInfoChunk(items: [(String, String)]) -> Data {
        var p = Data("INFO".utf8)
        for (id, value) in items {
            var idBytes = Data(id.utf8)
            while idBytes.count < 4 { idBytes.append(0x20) }
            // INFO sub-chunks store a null-terminated ASCII string.
            var payload = Data(value.utf8)
            payload.append(0x00)
            p.append(idBytes.prefix(4))
            p.append(uint32LE(UInt32(payload.count)))
            p.append(payload)
            if payload.count & 1 == 1 { p.append(0x00) }
        }
        return makeChunk(id: "LIST", payload: p)
    }

    private func asciiPadded(_ s: String, length: Int) -> Data {
        var d = Data(s.utf8.prefix(length))
        while d.count < length { d.append(0x00) }
        return d
    }

    private func uint16LE(_ v: UInt16) -> Data {
        return Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    private func uint32LE(_ v: UInt32) -> Data {
        return Data([
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF),
        ])
    }
}
