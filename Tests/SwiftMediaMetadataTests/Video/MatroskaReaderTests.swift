import XCTest
@testable import SwiftMediaMetadata

/// Matroska container parse tests. Fixtures are built with ffmpeg on-demand;
/// tests `XCTSkipUnless` when ffmpeg isn't installed.
final class MatroskaReaderTests: XCTestCase {

    /// EBML `Name` (0x536E) is valid on every TrackEntry, not only subtitle
    /// tracks. MatroskaReader used to populate it only on subtitle streams
    /// and silently drop it for video / audio tracks.
    func testMKVTrackTitlesPopulatedForVideoAndAudio() throws {
        let url = try generateMKVWithTitles(
            videoTitle: "Main Camera",
            audioTitle: "Dialog Track"
        )
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.videoStreams.count, 1)
        XCTAssertEqual(m.audioStreams.count, 1)
        XCTAssertEqual(m.videoStreams[0].title, "Main Camera")
        XCTAssertEqual(m.audioStreams[0].title, "Dialog Track")
    }

    /// Matroska's per-track bitrate doesn't live on the TrackEntry — it's
    /// emitted as a `BPS` SimpleTag inside the Segment's `Tags` block, keyed
    /// by `TagTrackUID`. This verifies parseTags routes BPS back to the owning
    /// stream's `bitRate`. We set BPS via `-metadata:s:*` because FFmpeg's
    /// default matroska muxer only writes DURATION per-track, not BPS.
    func testMKVPerTrackBitRateFromTagsBlock() throws {
        let url = try generateMKVWithBPSTags(videoBPS: 500_000, audioBPS: 96_000)
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.videoStreams.count, 1)
        XCTAssertEqual(m.audioStreams.count, 1)
        XCTAssertEqual(m.videoStreams[0].bitRate, 500_000)
        XCTAssertEqual(m.audioStreams[0].bitRate, 96_000)
    }

    /// MakeMKV → ffmpeg-trim pipelines leave the original `BPS` SimpleTag on
    /// every track (statistics weren't refreshed after the lossless cut). A
    /// 50 Mbps video bitrate copied verbatim onto a DTS audio track is
    /// nonsense, so the reader must drop the duplicated values rather than
    /// surface them as audio bitrates.
    func testMKVStaleSharedBPSIsDropped() throws {
        // Same value on both tracks — the stale-stats guard should clear the
        // audio bitrate (and the stream-count > 1 invariant means we keep the
        // video's, since dropping it loses real information).
        let url = try generateMKVWithBPSTags(videoBPS: 51_669_696, audioBPS: 51_669_696)
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.videoStreams.count, 1)
        XCTAssertEqual(m.audioStreams.count, 1)
        XCTAssertNil(m.audioStreams[0].bitRate,
                     "shared BPS across video+audio must be treated as stale")
    }

    /// MKV containers without explicit DisplayWidth/Height should still report
    /// a DAR/PAR — square pixels are the implicit default.
    func testMKVDerivedSquarePixelAspectRatio() throws {
        let url = try generateMKVWithTitles(videoTitle: "v", audioTitle: "a")
        let m = try VideoMetadata.read(from: url)
        let v = try XCTUnwrap(m.videoStreams.first)
        XCTAssertEqual(v.displayWidth, v.width)
        XCTAssertEqual(v.displayHeight, v.height)
        XCTAssertEqual(v.pixelAspectRatio?.0, 1)
        XCTAssertEqual(v.pixelAspectRatio?.1, 1)
    }

    /// Container `bit_rate` should fall back to file-size × 8 / duration when
    /// the EBML stream doesn't expose one explicitly — matches ffprobe's
    /// `format.bit_rate` column.
    func testMKVContainerBitRateFallback() throws {
        let url = try generateMKVWithTitles(videoTitle: "v", audioTitle: "a")
        let m = try VideoMetadata.read(from: url)
        XCTAssertNotNil(m.bitRate)
        XCTAssertGreaterThan(m.bitRate ?? 0, 0)
    }

    /// Matroska `Chapters` master element — parsed directly from a synthesised
    /// EBML blob to avoid needing ffmpeg + a separate chapter-metadata input.
    /// Exercises the two time units (1-byte ChapterFlagHidden vs 8-byte
    /// ChapterTimeStart), ChapterDisplay > ChapString, and ChapLanguage.
    func testMKVChaptersBlockDecodes() throws {
        let blob = buildMatroskaWithChapters([
            (uid: 0xA1A2A3A4, startNs: 0,             endNs: 60_000_000_000, title: "Opening",   language: "eng"),
            (uid: 0xB1B2B3B4, startNs: 60_000_000_000, endNs: 180_000_000_000, title: "Act Two",  language: "eng"),
            (uid: 0xC1C2C3C4, startNs: 180_000_000_000, endNs: nil,          title: "Epilogue", language: "nor"),
        ])
        let m = try VideoMetadata.read(from: blob)
        XCTAssertEqual(m.chapters.count, 3)
        XCTAssertEqual(m.chapters[0].id, 0xA1A2A3A4)
        XCTAssertEqual(m.chapters[0].title, "Opening")
        XCTAssertEqual(m.chapters[0].language, "eng")
        XCTAssertEqual(m.chapters[0].startTime, 0.0, accuracy: 0.0001)
        XCTAssertEqual(m.chapters[0].endTime ?? -1, 60.0, accuracy: 0.0001)
        XCTAssertEqual(m.chapters[1].startTime, 60.0, accuracy: 0.0001)
        XCTAssertEqual(m.chapters[2].title, "Epilogue")
        XCTAssertEqual(m.chapters[2].language, "nor")
        XCTAssertNil(m.chapters[2].endTime)
    }

    /// A hidden chapter atom (ChapterFlagHidden=1) is dropped on the floor —
    /// matches ffprobe's behaviour. The remaining chapters are re-indexed so
    /// their `index` field is contiguous.
    func testMKVHiddenChaptersSuppressed() throws {
        let specs: [ChapterSpec] = [
            ChapterSpec(uid: 1, startNs: 0,              endNs: nil, title: "Visible A", language: nil),
            ChapterSpec(uid: 2, startNs: 10_000_000_000, endNs: nil, title: "Hidden",    language: nil, hidden: true),
            ChapterSpec(uid: 3, startNs: 20_000_000_000, endNs: nil, title: "Visible B", language: nil),
        ]
        let blob = buildMatroskaWithChapters(specs)
        let m = try VideoMetadata.read(from: blob)
        XCTAssertEqual(m.chapters.count, 2)
        XCTAssertEqual(m.chapters.map { $0.index }, [0, 1])
        XCTAssertEqual(m.chapters[0].title, "Visible A")
        XCTAssertEqual(m.chapters[1].title, "Visible B")
    }

    /// Matroska HDR static metadata — `MaxCLL` (0x55BC), `MaxFALL` (0x55BD), and
    /// the `MasteringMetadata` (0x55D0) group inside a video track's `Colour`
    /// element. Synthesised inline so we don't need an HDR mux pipeline. Values
    /// correspond to BT.2020 / SMPTE ST 2086: BT.2020 primaries, D65 white
    /// point, 1000 cd/m² peak, 0.005 cd/m² floor, MaxCLL 1000, MaxFALL 400.
    func testMKVColourHDRMasteringAndCLL() throws {
        let blob = buildMatroskaWithHDRTrack(
            primaries: 9, transfer: 16, matrix: 9,
            maxCLL: 1000, maxFALL: 400,
            redX: 0.708, redY: 0.292,
            greenX: 0.170, greenY: 0.797,
            blueX: 0.131, blueY: 0.046,
            whiteX: 0.3127, whiteY: 0.3290,
            maxLuminance: 1000.0, minLuminance: 0.005
        )
        let m = try VideoMetadata.read(from: blob)
        let v = try XCTUnwrap(m.videoStreams.first)
        XCTAssertEqual(v.colorInfo?.primaries, 9)
        XCTAssertEqual(v.colorInfo?.transfer, 16)
        XCTAssertEqual(v.colorInfo?.matrix, 9)

        let cll = try XCTUnwrap(v.hdr?.contentLightLevel)
        XCTAssertEqual(cll.maxCLL, 1000)
        XCTAssertEqual(cll.maxFALL, 400)

        let md = try XCTUnwrap(v.hdr?.masteringDisplay)
        XCTAssertEqual(md.redX, 0.708, accuracy: 1e-5)
        XCTAssertEqual(md.redY, 0.292, accuracy: 1e-5)
        XCTAssertEqual(md.greenX, 0.170, accuracy: 1e-5)
        XCTAssertEqual(md.greenY, 0.797, accuracy: 1e-5)
        XCTAssertEqual(md.blueX, 0.131, accuracy: 1e-5)
        XCTAssertEqual(md.blueY, 0.046, accuracy: 1e-5)
        XCTAssertEqual(md.whitePointX, 0.3127, accuracy: 1e-5)
        XCTAssertEqual(md.whitePointY, 0.3290, accuracy: 1e-5)
        XCTAssertEqual(md.maxLuminance, 1000.0, accuracy: 1e-3)
        XCTAssertEqual(md.minLuminance, 0.005, accuracy: 1e-5)
    }

    /// SDR sanity: a video track whose `Colour` element advertises only
    /// BT.709 primaries / transfer / matrix and no HDR siblings must not
    /// fabricate an `HDRMetadata` record — `stream.hdr` stays nil. Mirrors the
    /// equivalent guard in MP4 (`testStreamWithoutHDRBoxesHasNilHDR`).
    func testMKVColourSDRLeavesHDRNil() throws {
        let blob = buildMatroskaWithHDRTrack(
            primaries: 1, transfer: 1, matrix: 1,
            maxCLL: nil, maxFALL: nil,
            redX: nil, redY: nil,
            greenX: nil, greenY: nil,
            blueX: nil, blueY: nil,
            whiteX: nil, whiteY: nil,
            maxLuminance: nil, minLuminance: nil
        )
        let m = try VideoMetadata.read(from: blob)
        let v = try XCTUnwrap(m.videoStreams.first)
        XCTAssertEqual(v.colorInfo?.primaries, 1)
        XCTAssertEqual(v.colorInfo?.transfer, 1)
        XCTAssertEqual(v.colorInfo?.matrix, 1)
        XCTAssertNil(v.hdr, "SDR streams must not synthesise an empty HDRMetadata record")
    }

    // MARK: - Fixtures

    private func generateMKVWithTitles(videoTitle: String, audioTitle: String) throws -> URL {
        try runFFmpeg(
            arguments: [
                "-y", "-v", "error",
                "-f", "lavfi",
                "-i", "testsrc=size=160x120:rate=10:duration=1",
                "-f", "lavfi",
                "-i", "sine=frequency=440:duration=1",
                "-c:v", "libx264", "-preset", "ultrafast",
                "-c:a", "aac",
                "-metadata:s:v:0", "title=\(videoTitle)",
                "-metadata:s:a:0", "title=\(audioTitle)",
            ],
            suffix: ".mkv"
        )
    }

    private func generateMKVWithBPSTags(videoBPS: Int, audioBPS: Int) throws -> URL {
        try runFFmpeg(
            arguments: [
                "-y", "-v", "error",
                "-f", "lavfi",
                "-i", "testsrc=size=320x240:rate=25:duration=1",
                "-f", "lavfi",
                "-i", "sine=frequency=440:duration=1",
                "-c:v", "libx264", "-preset", "ultrafast",
                "-c:a", "aac",
                "-metadata:s:v:0", "BPS=\(videoBPS)",
                "-metadata:s:a:0", "BPS=\(audioBPS)",
            ],
            suffix: ".mkv"
        )
    }

    // MARK: - Synthesised Matroska fixtures

    /// Minimal Matroska blob: EBML header (DocType "matroska") + Segment
    /// containing a Chapters block with one EditionEntry and a list of
    /// ChapterAtoms. No Info / Tracks / Clusters — the reader tolerates those
    /// being missing.
    private struct ChapterSpec {
        let uid: UInt64
        let startNs: UInt64
        let endNs: UInt64?
        let title: String?
        let language: String?
        let hidden: Bool
        init(uid: UInt64, startNs: UInt64, endNs: UInt64?,
             title: String?, language: String?, hidden: Bool = false) {
            self.uid = uid; self.startNs = startNs; self.endNs = endNs
            self.title = title; self.language = language; self.hidden = hidden
        }
    }

    private func buildMatroskaWithChapters(
        _ entries: [(uid: UInt64, startNs: UInt64, endNs: UInt64?, title: String?, language: String?)]
    ) -> Data {
        buildMatroskaWithChapters(entries.map {
            ChapterSpec(uid: $0.uid, startNs: $0.startNs, endNs: $0.endNs,
                        title: $0.title, language: $0.language)
        })
    }

    private func buildMatroskaWithChapters(_ specs: [ChapterSpec]) -> Data {
        // EBML header: DocType "matroska".
        var ebmlPayload = Data()
        ebmlPayload.append(ebmlElement(id: [0x42, 0x86], payload: encodeUInt(1)))          // EBMLVersion
        ebmlPayload.append(ebmlElement(id: [0x42, 0xF7], payload: encodeUInt(1)))          // EBMLReadVersion
        ebmlPayload.append(ebmlElement(id: [0x42, 0x82], payload: Data("matroska".utf8))) // DocType
        ebmlPayload.append(ebmlElement(id: [0x42, 0x87], payload: encodeUInt(4)))          // DocTypeVersion
        ebmlPayload.append(ebmlElement(id: [0x42, 0x85], payload: encodeUInt(2)))          // DocTypeReadVersion
        let ebmlHeader = ebmlElement(id: [0x1A, 0x45, 0xDF, 0xA3], payload: ebmlPayload)

        // Chapters > EditionEntry > ChapterAtom*
        var atoms = Data()
        for s in specs {
            var atom = Data()
            atom.append(ebmlElement(id: [0x73, 0xC4], payload: encodeUInt(s.uid)))         // ChapterUID
            atom.append(ebmlElement(id: [0x91], payload: encodeUInt(s.startNs)))            // ChapterTimeStart
            if let e = s.endNs {
                atom.append(ebmlElement(id: [0x92], payload: encodeUInt(e)))                // ChapterTimeEnd
            }
            if s.hidden {
                atom.append(ebmlElement(id: [0x98], payload: encodeUInt(1)))                // ChapterFlagHidden
            }
            // ChapterDisplay(0x80) > ChapString(0x85) + ChapLanguage(0x437C)
            if s.title != nil || s.language != nil {
                var display = Data()
                if let t = s.title {
                    display.append(ebmlElement(id: [0x85], payload: Data(t.utf8)))
                }
                if let l = s.language {
                    display.append(ebmlElement(id: [0x43, 0x7C], payload: Data(l.utf8)))
                }
                atom.append(ebmlElement(id: [0x80], payload: display))
            }
            atoms.append(ebmlElement(id: [0xB6], payload: atom))                            // ChapterAtom
        }
        let edition = ebmlElement(id: [0x45, 0xB9], payload: atoms)                         // EditionEntry
        let chapters = ebmlElement(id: [0x10, 0x43, 0xA7, 0x70], payload: edition)          // Chapters

        let segment = ebmlElement(id: [0x18, 0x53, 0x80, 0x67], payload: chapters)          // Segment
        return ebmlHeader + segment
    }

    /// Build a minimal Matroska blob with a single video TrackEntry whose
    /// `Colour` master carries the supplied color signalling and HDR static
    /// metadata. Any field passed as nil is omitted from the EBML tree — used
    /// by the SDR-vs-HDR tests above to exercise both populated and absent
    /// `MasteringMetadata` / `MaxCLL` / `MaxFALL`.
    private func buildMatroskaWithHDRTrack(
        primaries: UInt64, transfer: UInt64, matrix: UInt64,
        maxCLL: UInt64?, maxFALL: UInt64?,
        redX: Double?, redY: Double?,
        greenX: Double?, greenY: Double?,
        blueX: Double?, blueY: Double?,
        whiteX: Double?, whiteY: Double?,
        maxLuminance: Double?, minLuminance: Double?
    ) -> Data {
        // EBML header
        var ebmlPayload = Data()
        ebmlPayload.append(ebmlElement(id: [0x42, 0x86], payload: encodeUInt(1)))          // EBMLVersion
        ebmlPayload.append(ebmlElement(id: [0x42, 0xF7], payload: encodeUInt(1)))          // EBMLReadVersion
        ebmlPayload.append(ebmlElement(id: [0x42, 0x82], payload: Data("matroska".utf8))) // DocType
        ebmlPayload.append(ebmlElement(id: [0x42, 0x87], payload: encodeUInt(4)))          // DocTypeVersion
        ebmlPayload.append(ebmlElement(id: [0x42, 0x85], payload: encodeUInt(2)))          // DocTypeReadVersion
        let ebmlHeader = ebmlElement(id: [0x1A, 0x45, 0xDF, 0xA3], payload: ebmlPayload)

        // Colour master
        var colour = Data()
        colour.append(ebmlElement(id: [0x55, 0xBB], payload: encodeUInt(primaries))) // Primaries
        colour.append(ebmlElement(id: [0x55, 0xBA], payload: encodeUInt(transfer)))  // TransferCharacteristics
        colour.append(ebmlElement(id: [0x55, 0xB1], payload: encodeUInt(matrix)))    // MatrixCoefficients
        if let v = maxCLL  { colour.append(ebmlElement(id: [0x55, 0xBC], payload: encodeUInt(v))) }
        if let v = maxFALL { colour.append(ebmlElement(id: [0x55, 0xBD], payload: encodeUInt(v))) }

        // MasteringMetadata only if at least one chromaticity/luminance field
        // is set — matches how real muxers emit it.
        let mdFields: [(id: [UInt8], value: Double?)] = [
            ([0x55, 0xD1], redX), ([0x55, 0xD2], redY),
            ([0x55, 0xD3], greenX), ([0x55, 0xD4], greenY),
            ([0x55, 0xD5], blueX), ([0x55, 0xD6], blueY),
            ([0x55, 0xD7], whiteX), ([0x55, 0xD8], whiteY),
            ([0x55, 0xD9], maxLuminance), ([0x55, 0xDA], minLuminance),
        ]
        if mdFields.contains(where: { $0.value != nil }) {
            var md = Data()
            for f in mdFields {
                if let v = f.value {
                    md.append(ebmlElement(id: f.id, payload: encodeFloat32BE(v)))
                }
            }
            colour.append(ebmlElement(id: [0x55, 0xD0], payload: md)) // MasteringMetadata
        }

        // Video > Colour
        let videoBlock = ebmlElement(id: [0xE0], payload:
            ebmlElement(id: [0xB0], payload: encodeUInt(1920)) +    // PixelWidth (any sensible value)
            ebmlElement(id: [0xBA], payload: encodeUInt(1080)) +    // PixelHeight
            ebmlElement(id: [0x55, 0xB0], payload: colour)          // Colour master
        )

        // TrackEntry > {TrackNumber, TrackUID, TrackType=1(video), CodecID, Video}
        var trackEntry = Data()
        trackEntry.append(ebmlElement(id: [0xD7], payload: encodeUInt(1)))                        // TrackNumber
        trackEntry.append(ebmlElement(id: [0x73, 0xC5], payload: encodeUInt(0xCAFEBABE)))         // TrackUID
        trackEntry.append(ebmlElement(id: [0x83], payload: encodeUInt(1)))                        // TrackType = video
        trackEntry.append(ebmlElement(id: [0x86], payload: Data("V_MPEGH/ISO/HEVC".utf8)))        // CodecID
        trackEntry.append(videoBlock)

        let tracks = ebmlElement(id: [0x16, 0x54, 0xAE, 0x6B], payload:
            ebmlElement(id: [0xAE], payload: trackEntry)            // TrackEntry
        )
        let segment = ebmlElement(id: [0x18, 0x53, 0x80, 0x67], payload: tracks)
        return ebmlHeader + segment
    }

    /// IEEE 754 single-precision, big-endian — matches the 4-byte branch in
    /// `MatroskaReader.readFloatPayload`.
    private func encodeFloat32BE(_ value: Double) -> Data {
        let bits = Float(value).bitPattern
        return Data([
            UInt8((bits >> 24) & 0xFF),
            UInt8((bits >> 16) & 0xFF),
            UInt8((bits >> 8) & 0xFF),
            UInt8(bits & 0xFF),
        ])
    }

    /// Encode an unsigned integer as the shortest big-endian byte sequence
    /// that still round-trips (minimum 1 byte for value 0).
    private func encodeUInt(_ value: UInt64) -> Data {
        if value == 0 { return Data([0]) }
        var bytes: [UInt8] = []
        var v = value
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        return Data(bytes)
    }

    /// Build one EBML element: raw ID bytes (already marker-preserved) + VINT
    /// size + payload. We always emit a 4-byte size VINT for simplicity, which
    /// gives us a payload range up to 2²⁸ − 2 bytes — plenty for fixtures.
    private func ebmlElement(id: [UInt8], payload: Data) -> Data {
        var out = Data(id)
        // 4-byte VINT: marker bit 0x10 in the first byte, remaining 28 bits = size.
        let size = UInt32(payload.count)
        precondition(size < (1 << 28) - 1, "ebml element payload too large for 4-byte VINT")
        out.append(UInt8(0x10 | (size >> 24) & 0x0F))
        out.append(UInt8((size >> 16) & 0xFF))
        out.append(UInt8((size >> 8) & 0xFF))
        out.append(UInt8(size & 0xFF))
        out.append(payload)
        return out
    }

    private func runFFmpeg(arguments: [String], suffix: String) throws -> URL {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")
                          || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg"),
                          "ffmpeg not installed; skipping MKV fixture test")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftexif-mkv-\(UUID().uuidString)\(suffix)")
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
            throw XCTSkip("ffmpeg failed to mux MKV fixture")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
