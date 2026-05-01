import XCTest
@testable import SwiftExif

// MARK: - ID3v2 frame detail (Phase 23.1)

final class ID3FrameDetailTests: XCTestCase {

    func testTXXXFrameRoundTrip() throws {
        // TXXX: encoding (1) + description + 0x00 + value
        var frame = Data([0x03])  // UTF-8
        frame.append(contentsOf: "MusicBrainz Album Id".utf8)
        frame.append(0x00)
        frame.append(contentsOf: "abc-123-def".utf8)

        let mp3 = makeMP3(with: [(id: "TXXX", body: frame)])
        let m = try ID3Parser.parse(mp3)
        XCTAssertEqual(m.userTextFrames["MusicBrainz Album Id"], "abc-123-def")
    }

    func testWXXXFrameRoundTrip() throws {
        // WXXX: encoding(1) + desc + 0x00 + url(Latin-1)
        var frame = Data([0x03])
        frame.append(contentsOf: "Source".utf8)
        frame.append(0x00)
        frame.append(contentsOf: "https://example.com/foo".utf8)

        let mp3 = makeMP3(with: [(id: "WXXX", body: frame)])
        let m = try ID3Parser.parse(mp3)
        XCTAssertEqual(m.userURLFrames["Source"], "https://example.com/foo")
    }

    func testWOAFFrame() throws {
        // WOAF: ASCII URL only.
        let frame = Data("https://example.com".utf8)
        let mp3 = makeMP3(with: [(id: "WOAF", body: frame)])
        let m = try ID3Parser.parse(mp3)
        XCTAssertEqual(m.urlFrames["WOAF"], "https://example.com")
    }

    func testPRIVFrame() throws {
        // PRIV: owner (Latin-1, null-terminated) + binary payload.
        var frame = Data()
        frame.append(contentsOf: "iTunesU".utf8)
        frame.append(0x00)
        frame.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])

        let mp3 = makeMP3(with: [(id: "PRIV", body: frame)])
        let m = try ID3Parser.parse(mp3)
        XCTAssertEqual(m.privateFrames.count, 1)
        XCTAssertEqual(m.privateFrames.first?.owner, "iTunesU")
        XCTAssertEqual(m.privateFrames.first?.data, Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testGEOBFrame() throws {
        // GEOB: encoding (1) + MIME (Latin-1 null-term) + filename (encoding null-term)
        // + description (encoding null-term) + binary data
        var frame = Data([0x03])  // UTF-8
        frame.append(contentsOf: "application/pdf".utf8)
        frame.append(0x00)
        frame.append(contentsOf: "manual.pdf".utf8)
        frame.append(0x00)
        frame.append(contentsOf: "Owner's manual".utf8)
        frame.append(0x00)
        frame.append(contentsOf: [0x25, 0x50, 0x44, 0x46])  // %PDF (fake binary)

        let mp3 = makeMP3(with: [(id: "GEOB", body: frame)])
        let m = try ID3Parser.parse(mp3)
        XCTAssertEqual(m.attachedObjects.count, 1)
        XCTAssertEqual(m.attachedObjects.first?.mimeType, "application/pdf")
        XCTAssertEqual(m.attachedObjects.first?.filename, "manual.pdf")
        XCTAssertEqual(m.attachedObjects.first?.description, "Owner's manual")
        XCTAssertEqual(m.attachedObjects.first?.data, Data([0x25, 0x50, 0x44, 0x46]))
    }

    func testCHAPFrameWithTitle() throws {
        // CHAP: element ID (Latin-1 null-term) + start (4) + end (4) + startOff (4) + endOff (4)
        // + sub-frames. Add an embedded TIT2 sub-frame.
        var frame = Data()
        frame.append(contentsOf: "ch1".utf8)
        frame.append(0x00)
        // start = 0 ms, end = 30000 ms, offsets 0xFFFFFFFF (unused)
        appendU32BE(&frame, 0)
        appendU32BE(&frame, 30000)
        appendU32BE(&frame, 0xFFFFFFFF)
        appendU32BE(&frame, 0xFFFFFFFF)

        // Embedded TIT2 sub-frame: header (10) + body
        var titleBody = Data([0x03])  // UTF-8
        titleBody.append(contentsOf: "Intro".utf8)
        frame.append(contentsOf: "TIT2".utf8)
        // 32-bit big-endian size (we use BE form, parser also accepts syncsafe)
        let sz = titleBody.count
        frame.append(UInt8((sz >> 24) & 0xFF))
        frame.append(UInt8((sz >> 16) & 0xFF))
        frame.append(UInt8((sz >> 8) & 0xFF))
        frame.append(UInt8(sz & 0xFF))
        frame.append(0); frame.append(0)  // flags
        frame.append(titleBody)

        let mp3 = makeMP3(with: [(id: "CHAP", body: frame)])
        let m = try ID3Parser.parse(mp3)
        XCTAssertEqual(m.chapters.count, 1)
        let chapter = m.chapters[0]
        XCTAssertEqual(chapter.elementID, "ch1")
        XCTAssertEqual(chapter.startTimeMs, 0)
        XCTAssertEqual(chapter.endTimeMs, 30000)
        XCTAssertEqual(chapter.title, "Intro")
    }

    func testCTOCFrame() throws {
        // CTOC: element (null-term) + flags (1) + entry_count (1) + child IDs (null-term each)
        var frame = Data()
        frame.append(contentsOf: "toc1".utf8)
        frame.append(0x00)
        frame.append(0x03)  // top-level + ordered
        frame.append(0x02)  // 2 children
        frame.append(contentsOf: "ch1".utf8); frame.append(0x00)
        frame.append(contentsOf: "ch2".utf8); frame.append(0x00)

        let mp3 = makeMP3(with: [(id: "CTOC", body: frame)])
        let m = try ID3Parser.parse(mp3)
        XCTAssertEqual(m.chapterTOCs.count, 1)
        let toc = m.chapterTOCs[0]
        XCTAssertEqual(toc.elementID, "toc1")
        XCTAssertTrue(toc.isTopLevel)
        XCTAssertTrue(toc.isOrdered)
        XCTAssertEqual(toc.childElementIDs, ["ch1", "ch2"])
    }

    func testStripClearsExtendedFrames() {
        var m = AudioMetadata(format: .mp3)
        m.userTextFrames["foo"] = "bar"
        m.privateFrames = [ID3PrivateFrame(owner: "x", data: Data([0xFF]))]
        m.chapters = [ID3Chapter(elementID: "c1", startTimeMs: 0, endTimeMs: 1000,
                                 startOffset: 0xFFFFFFFF, endOffset: 0xFFFFFFFF)]
        m.stripMetadata()
        XCTAssertTrue(m.userTextFrames.isEmpty)
        XCTAssertTrue(m.privateFrames.isEmpty)
        XCTAssertTrue(m.chapters.isEmpty)
    }

    // MARK: - Helpers

    /// Build a minimal ID3v2.4 file containing the given frames. No audio
    /// frames — parser will skip the audio-frame scan when no sync word is found.
    private func makeMP3(with frames: [(id: String, body: Data)]) -> Data {
        var body = Data()
        for frame in frames {
            body.append(contentsOf: frame.id.utf8)
            // Use syncsafe size (v2.4)
            body.append(contentsOf: ID3Parser.encodeSyncsafe(frame.body.count))
            body.append(0); body.append(0)  // flags
            body.append(frame.body)
        }
        var out = Data()
        out.append(contentsOf: "ID3".utf8)
        out.append(0x04); out.append(0x00)  // version 2.4.0
        out.append(0x00)  // flags
        out.append(contentsOf: ID3Parser.encodeSyncsafe(body.count))
        out.append(body)
        return out
    }

    private func appendU32BE(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }
}

// MARK: - FLAC SeekTable / CueSheet (Phase 23.2)

final class FLACBlockDetailTests: XCTestCase {

    func testSeekTableParses() throws {
        // 2 seek points: (sample 0, offset 0, 4096 samples) and
        // (sample 4096, offset 1024, 4096 samples).
        var seekData = Data()
        appendU64BE(&seekData, 0); appendU64BE(&seekData, 0)
        appendU16BE(&seekData, 4096)
        appendU64BE(&seekData, 4096); appendU64BE(&seekData, 1024)
        appendU16BE(&seekData, 4096)

        let flac = makeFLAC(with: [(type: 0, data: minimalStreamInfo()),
                                   (type: 3, data: seekData)])
        let m = try FLACParser.parse(flac)
        XCTAssertEqual(m.flacSeekTable.count, 2)
        XCTAssertEqual(m.flacSeekTable.first?.sampleNumber, 0)
        XCTAssertEqual(m.flacSeekTable.last?.byteOffset, 1024)
        XCTAssertEqual(m.flacSeekTable.last?.frameSamples, 4096)
    }

    func testCueSheetParses() throws {
        var cue = Data(repeating: 0, count: 396)
        // Catalog number (bytes 0..127) — leave as NUL.
        // Lead-in samples (bytes 128..135).
        appendU64BE(into: &cue, at: 128, value: 88200)
        // isCD flag (byte 136 bit 7).
        cue[136] = 0x80
        // Track count (byte 396) — set after appending track.
        cue.append(0x01)  // track count = 1

        // Track header (36 bytes): offset(8) + num(1) + ISRC(12) + flags(1) + reserved(13) + indexCount(1)
        var track = Data(repeating: 0, count: 36)
        appendU64BE(into: &track, at: 0, value: 0)
        track[8] = 0x01  // track number
        // ISRC bytes 9..20 — leave as NUL
        track[21] = 0x00  // audio + no pre-emphasis
        track[35] = 0x01  // 1 index
        cue.append(track)

        // Index point: offset(8) + num(1) + reserved(3)
        var index = Data(repeating: 0, count: 12)
        appendU64BE(into: &index, at: 0, value: 0)
        index[8] = 0x01
        cue.append(index)

        let flac = makeFLAC(with: [(type: 0, data: minimalStreamInfo()),
                                   (type: 5, data: cue)])
        let m = try FLACParser.parse(flac)
        guard let cs = m.flacCueSheet else { XCTFail("no cue sheet"); return }
        XCTAssertEqual(cs.leadInSamples, 88200)
        XCTAssertTrue(cs.isCD)
        XCTAssertEqual(cs.tracks.count, 1)
        XCTAssertEqual(cs.tracks.first?.trackNumber, 1)
        XCTAssertTrue(cs.tracks.first?.isAudio ?? false)
        XCTAssertEqual(cs.tracks.first?.indices.count, 1)
        XCTAssertEqual(cs.tracks.first?.indices.first?.indexNumber, 1)
    }

    // MARK: - Helpers

    private func minimalStreamInfo() -> Data {
        // STREAMINFO is 34 bytes; we only care that it parses cleanly.
        var s = Data(repeating: 0, count: 34)
        // bytes 10..12 carry a 20-bit sample rate; encode 44100 = 0x0AC44.
        s[10] = 0x0A; s[11] = 0xC4; s[12] = 0x40  // SR(20) | channels(3) | bps(5 high)
        // bps: 16 bits → bps-1 = 15 = 0x0F. Spans bits in byte 12 low + byte 13 high.
        s[12] |= 0x00  // already correct
        s[13] = 0xF0   // 4 high bps bits + 0 in low 4 (samples count)
        return s
    }

    private func makeFLAC(with blocks: [(type: UInt8, data: Data)]) -> Data {
        var out = Data()
        out.append(contentsOf: [0x66, 0x4C, 0x61, 0x43])  // "fLaC"
        for (i, block) in blocks.enumerated() {
            let isLast: UInt8 = (i == blocks.count - 1) ? 0x80 : 0x00
            out.append(isLast | block.type)
            let len = block.data.count
            out.append(UInt8((len >> 16) & 0xFF))
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
            out.append(block.data)
        }
        return out
    }

    private func appendU16BE(_ data: inout Data, _ v: UInt16) {
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    private func appendU64BE(_ data: inout Data, _ v: UInt64) {
        for i in (0..<8).reversed() {
            data.append(UInt8((v >> (i * 8)) & 0xFF))
        }
    }

    private func appendU64BE(into data: inout Data, at offset: Int, value: UInt64) {
        for i in (0..<8).reversed() {
            data[offset + (7 - i)] = UInt8((value >> (i * 8)) & 0xFF)
        }
    }
}
