import XCTest
@testable import SwiftExif

/// Subtitle-track extraction tests. Fixtures are built with ffmpeg on-demand;
/// tests `XCTSkipUnless` when ffmpeg isn't installed so machines without
/// media tooling stay green.
final class SubtitleTrackTests: XCTestCase {

    // MARK: - MP4 (3GPP Timed Text)

    func testMP4TimedTextSubtitleTrack() throws {
        let url = try generateMP4WithTimedText(language: "nor")
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.subtitleStreams.count, 1)
        let sub = m.subtitleStreams[0]
        XCTAssertEqual(sub.codec, "tx3g")
        XCTAssertEqual(sub.codecName, "3GPP Timed Text")
        XCTAssertEqual(sub.language, "nor")
        // Plain track: neither the `kind` disposition box nor the tx3g
        // forced bit is present, so the flag stays nil.
        XCTAssertNil(sub.isForced)
    }

    /// Forced disposition surfaces as `isForced = true` via the tx3g
    /// displayFlags bit 0x40000000 that ffmpeg writes for
    /// `-disposition:s:0 forced`.
    func testMP4ForcedSubtitleTrackFlag() throws {
        let url = try generateMP4WithTimedText(language: "eng", forced: true)
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.subtitleStreams.count, 1)
        XCTAssertEqual(m.subtitleStreams[0].isForced, true)
    }

    // MARK: - Matroska (SubRip)

    func testMKVSubRipSubtitleTrack() throws {
        let url = try generateMKVWithSRT(language: "swe")
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.subtitleStreams.count, 1)
        let sub = m.subtitleStreams[0]
        XCTAssertEqual(sub.codec, "S_TEXT/UTF8")
        XCTAssertEqual(sub.codecName, "SubRip (SRT)")
        XCTAssertEqual(sub.language, "swe")
    }

    // MARK: - MPEG-TS (DVB subtitling descriptor, SDH)

    /// Per ETSI EN 300 468 §6.2.41, the DVB subtitling descriptor's
    /// `subtitling_type` byte distinguishes normal subtitles (0x01-0x06)
    /// from hard-of-hearing variants (0x20-0x24). The reader should surface
    /// the SDH variant as `isHearingImpaired = true` so MPEG-TS matches the
    /// parity MP4 and Matroska already provide.
    func testMPEGTSDVBSubtitleHearingImpairedFlag() throws {
        let url = try writeTSFixture(subtitlingType: 0x20, language: "eng")
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.subtitleStreams.count, 1)
        let sub = m.subtitleStreams[0]
        XCTAssertEqual(sub.codec, "dvb_subtitle")
        XCTAssertEqual(sub.language, "eng")
        XCTAssertEqual(sub.isHearingImpaired, true)
    }

    /// Regression guard: a plain DVB subtitle (subtitling_type 0x10, reserved
    /// range but below the SDH threshold) must leave `isHearingImpaired` nil
    /// rather than defaulting to `true`.
    func testMPEGTSDVBSubtitleNonSDHLeavesFlagNil() throws {
        let url = try writeTSFixture(subtitlingType: 0x10, language: "nor")
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.subtitleStreams.count, 1)
        XCTAssertNil(m.subtitleStreams[0].isHearingImpaired)
    }

    // MARK: - Fixture generation

    /// Build an MP4 with an embedded `tx3g` subtitle track and a chosen
    /// ISO 639-2 language code.
    private func generateMP4WithTimedText(language: String, forced: Bool = false) throws -> URL {
        let subURL = try writeSRT()
        var args = [
            "-y", "-v", "error",
            "-f", "lavfi",
            "-i", "testsrc=size=640x360:rate=25:duration=2",
            "-i", subURL.path,
            "-c:v", "libx264", "-preset", "ultrafast",
            "-c:s", "mov_text",
            "-metadata:s:s:0", "language=\(language)",
        ]
        if forced {
            args.append(contentsOf: ["-disposition:s:0", "forced"])
        }
        return try runFFmpeg(arguments: args, suffix: ".mp4")
    }

    private func generateMKVWithSRT(language: String) throws -> URL {
        let subURL = try writeSRT()
        return try runFFmpeg(
            arguments: [
                "-y", "-v", "error",
                "-f", "lavfi",
                "-i", "testsrc=size=640x360:rate=25:duration=2",
                "-i", subURL.path,
                "-c:v", "libx264", "-preset", "ultrafast",
                "-c:s", "srt",
                "-metadata:s:s:0", "language=\(language)",
            ],
            suffix: ".mkv"
        )
    }

    private func writeSRT() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftexif-sub-\(UUID().uuidString).srt")
        let srt = "1\n00:00:00,000 --> 00:00:02,000\nHello\n"
        try srt.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func runFFmpeg(arguments: [String], suffix: String) throws -> URL {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")
                          || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg"),
                          "ffmpeg not installed; skipping subtitle fixture test")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftexif-sub-\(UUID().uuidString)\(suffix)")
        let process = Process()
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") {
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        }
        process.arguments = arguments + [url.path]
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("ffmpeg failed to mux subtitle fixture")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Build a minimal 4-packet MPEG-TS fixture: PAT, PMT carrying a single
    /// elementary stream of type 0x06 (private data) with a DVB subtitling
    /// descriptor, plus two null packets so `isMPEG` sees sync bytes at
    /// packets 0/1/2/3. No CRC — the parser skips the last 4 section bytes
    /// without verifying them.
    private func writeTSFixture(subtitlingType: UInt8, language: String) throws -> URL {
        var data = Data()
        data.append(makePATPacket(pmtPID: 0x100))
        data.append(makePMTPacket(pmtPID: 0x100,
                                  elementaryPID: 0x101,
                                  language: language,
                                  subtitlingType: subtitlingType))
        data.append(makeNullPacket())
        data.append(makeNullPacket())

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftexif-sub-\(UUID().uuidString).ts")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makePATPacket(pmtPID: UInt16) -> Data {
        var section = Data()
        section.append(0x00)                                  // pointer_field
        section.append(0x00)                                  // table_id (PAT)
        section.append(0xB0)                                  // section_syntax=1, reserved=11, length high=0
        section.append(0x0D)                                  // section_length = 13
        section.append(contentsOf: [0x00, 0x01])              // transport_stream_id
        section.append(0xC1)                                  // reserved=11, version=0, current_next=1
        section.append(0x00)                                  // section_number
        section.append(0x00)                                  // last_section_number
        section.append(contentsOf: [0x00, 0x01])              // program_number
        section.append(UInt8(0xE0 | ((pmtPID >> 8) & 0x1F)))  // reserved + pmt_pid high
        section.append(UInt8(pmtPID & 0xFF))                  // pmt_pid low
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // CRC32 (ignored)
        return wrapInTSPacket(pid: 0x0000, payloadUnitStart: true, payload: section)
    }

    private func makePMTPacket(pmtPID: UInt16,
                               elementaryPID: UInt16,
                               language: String,
                               subtitlingType: UInt8) -> Data {
        // DVB subtitling descriptor: one 8-byte entry.
        var descriptor = Data()
        descriptor.append(0x59)                               // descriptor_tag
        descriptor.append(0x08)                               // descriptor_length
        descriptor.append(contentsOf: Array(language.utf8.prefix(3)))
        descriptor.append(subtitlingType)
        descriptor.append(contentsOf: [0x00, 0x01])           // composition_page_id
        descriptor.append(contentsOf: [0x00, 0x01])           // ancillary_page_id

        // ES loop entry wrapping the descriptor.
        var esLoop = Data()
        esLoop.append(0x06)                                   // stream_type (private data)
        esLoop.append(UInt8(0xE0 | ((elementaryPID >> 8) & 0x1F)))
        esLoop.append(UInt8(elementaryPID & 0xFF))
        let esInfoLen = UInt16(descriptor.count)
        esLoop.append(UInt8(0xF0 | ((esInfoLen >> 8) & 0x0F)))
        esLoop.append(UInt8(esInfoLen & 0xFF))
        esLoop.append(descriptor)

        // Section length covers everything after section_length up to and including CRC.
        let sectionLength = UInt16(2 + 1 + 1 + 1 + 2 + 2 + esLoop.count + 4)

        var section = Data()
        section.append(0x00)                                  // pointer_field
        section.append(0x02)                                  // table_id (PMT)
        section.append(UInt8(0xB0 | ((sectionLength >> 8) & 0x0F)))
        section.append(UInt8(sectionLength & 0xFF))
        section.append(contentsOf: [0x00, 0x01])              // program_number
        section.append(0xC1)                                  // version/current_next
        section.append(0x00)                                  // section_number
        section.append(0x00)                                  // last_section_number
        section.append(contentsOf: [0xE1, 0x00])              // reserved + PCR_PID = 0x100
        section.append(contentsOf: [0xF0, 0x00])              // reserved + program_info_length = 0
        section.append(esLoop)
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // CRC32 (ignored)

        return wrapInTSPacket(pid: pmtPID, payloadUnitStart: true, payload: section)
    }

    private func makeNullPacket() -> Data {
        wrapInTSPacket(pid: 0x1FFF, payloadUnitStart: false, payload: Data())
    }

    /// Build a 188-byte TS packet: sync byte + 3-byte header + payload,
    /// padded to 184 bytes with 0xFF stuffing. No adaptation field.
    private func wrapInTSPacket(pid: UInt16, payloadUnitStart: Bool, payload: Data) -> Data {
        precondition(payload.count <= 184, "TS payload exceeds 184 bytes")
        var packet = Data(capacity: 188)
        packet.append(0x47)
        let pus: UInt8 = payloadUnitStart ? 0x40 : 0x00
        packet.append(pus | UInt8((pid >> 8) & 0x1F))
        packet.append(UInt8(pid & 0xFF))
        packet.append(0x10)                                   // adaptation=01 (payload only)
        packet.append(payload)
        if packet.count < 188 {
            packet.append(Data(repeating: 0xFF, count: 188 - packet.count))
        }
        return packet
    }
}
