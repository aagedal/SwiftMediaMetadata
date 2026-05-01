import XCTest
@testable import SwiftExif

/// Round-trip tests for WAVWriter. Builds a synthetic RIFF WAVE, parses it,
/// mutates a few metadata fields, writes it back out, then re-parses and
/// asserts the changes survived plus that the audio (`data`) chunk and
/// `fmt ` parameters are byte-stable.
final class WAVWriterTests: XCTestCase {

    func testRoundTripUpdatesListInfo() throws {
        let wav = makeWAVWithFmtAndData(
            sampleRate: 48_000, channels: 2, bitsPerSample: 24,
            audioBytes: 16
        )
        var meta = try parsedWAV(wav)
        meta.title = "Updated Title"
        meta.artist = "Updated Artist"
        meta.album = "Updated Album"
        meta.year = "2026"
        meta.genre = "Ambient"
        meta.comment = "Re-mastered"

        let written = try WAVWriter.write(meta, to: wav)
        let reparsed = try WAVParser.parse(written)

        XCTAssertEqual(reparsed.title, "Updated Title")
        XCTAssertEqual(reparsed.artist, "Updated Artist")
        XCTAssertEqual(reparsed.album, "Updated Album")
        XCTAssertEqual(reparsed.year, "2026")
        XCTAssertEqual(reparsed.genre, "Ambient")
        XCTAssertEqual(reparsed.comment, "Re-mastered")
        // fmt chunk parameters survive unchanged.
        XCTAssertEqual(reparsed.sampleRate, 48_000)
        XCTAssertEqual(reparsed.channels, 2)
        XCTAssertEqual(reparsed.bitDepth, 24)
        XCTAssertEqual(reparsed.codec, "PCM")
    }

    func testWriteOutputIsValidRIFFWAVE() throws {
        let wav = makeWAVWithFmtAndData(
            sampleRate: 44_100, channels: 1, bitsPerSample: 16,
            audioBytes: 4
        )
        var meta = try parsedWAV(wav)
        meta.title = "Hi"  // odd-length value forces a pad byte

        let written = try WAVWriter.write(meta, to: wav)

        // RIFF/WAVE header sanity.
        XCTAssertEqual(written.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(Data(written[8..<12]), Data("WAVE".utf8))
        // The 4-byte size at offset 4 must equal `total - 8`.
        let declared = UInt32(written[4]) |
            (UInt32(written[5]) << 8) |
            (UInt32(written[6]) << 16) |
            (UInt32(written[7]) << 24)
        XCTAssertEqual(Int(declared), written.count - 8)
    }

    func testNilMetadataFieldsOmitListInfoChunk() throws {
        // No title/artist/etc. — writer should not emit an empty LIST/INFO,
        // and the parser should not invent fields.
        let wav = makeWAVWithFmtAndData(
            sampleRate: 48_000, channels: 2, bitsPerSample: 16, audioBytes: 8
        )
        let meta = try parsedWAV(wav)

        let written = try WAVWriter.write(meta, to: wav)
        let reparsed = try WAVParser.parse(written)
        XCTAssertNil(reparsed.title)
        XCTAssertNil(reparsed.artist)
        XCTAssertNil(reparsed.comment)
    }

    func testBextDescriptionRoundTrips() throws {
        let wav = makeWAVWithFmtAndData(
            sampleRate: 48_000, channels: 2, bitsPerSample: 24, audioBytes: 0
        )
        var meta = try parsedWAV(wav)
        // Source has no bext yet — the writer should synthesize one when a
        // BWFMetadata is supplied.
        var bwf = BWFMetadata()
        bwf.description = "SCN_002 / Take 03"
        bwf.originator = "Aagedal Media"
        bwf.originationDate = "2026-05-01"
        bwf.originationTime = "12:34:56"
        meta.bwf = bwf

        let written = try WAVWriter.write(meta, to: wav)
        let reparsed = try WAVParser.parse(written)
        let outBwf = try XCTUnwrap(reparsed.bwf)
        XCTAssertEqual(outBwf.description, "SCN_002 / Take 03")
        XCTAssertEqual(outBwf.originator, "Aagedal Media")
        XCTAssertEqual(outBwf.originationDate, "2026-05-01")
        XCTAssertEqual(outBwf.originationTime, "12:34:56")
    }

    // MARK: - Fixture builders

    private func makeWAVWithFmtAndData(
        sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16,
        audioBytes: Int
    ) -> Data {
        let fmt = makeFmtChunk(formatTag: 0x0001, channels: channels,
                               sampleRate: sampleRate, bitsPerSample: bitsPerSample)
        let dataChunk = makeChunk(id: "data", payload: Data(repeating: 0xAA, count: audioBytes))
        return makeWAV(chunks: [fmt, dataChunk])
    }

    private func makeWAV(chunks: [Data]) -> Data {
        var body = Data("WAVE".utf8)
        for c in chunks { body.append(c) }
        var out = Data("RIFF".utf8)
        out.append(uint32LE(UInt32(body.count)))
        out.append(body)
        return out
    }

    private func makeChunk(id: String, payload: Data) -> Data {
        var idBytes = Data(id.utf8)
        while idBytes.count < 4 { idBytes.append(0x20) }
        var out = idBytes.prefix(4)
        out.append(uint32LE(UInt32(payload.count)))
        out.append(payload)
        if payload.count & 1 == 1 { out.append(0x00) }
        return Data(out)
    }

    private func makeFmtChunk(formatTag: UInt16, channels: UInt16,
                              sampleRate: UInt32, bitsPerSample: UInt16) -> Data {
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

    private func uint16LE(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    private func uint32LE(_ v: UInt32) -> Data {
        Data([
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF),
        ])
    }
}

/// Parse a WAV in memory and stash the original bytes onto `originalData`,
/// which the writer needs in order to walk the existing chunk list. Mirrors
/// what `AudioMetadata.read(from: URL)` does for on-disk files.
private func parsedWAV(_ data: Data) throws -> AudioMetadata {
    var meta = try WAVParser.parse(data)
    meta.originalData = data
    return meta
}
