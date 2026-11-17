import XCTest
@testable import SwiftMediaMetadata

/// Fragmented MP4/MOV: samples in top-level `moof` boxes count toward the
/// movie, track and bitrate figures, as they do in ffprobe and AVFoundation.
final class MP4FragmentTests: XCTestCase {

    /// ffmpeg `frag_keyframe` without `empty_moov` (yt-dlp-rs growing-file
    /// recordings): one second in moov, the rest in fragments, no mehd.
    func testFragmentsWithoutMEHDExtendDurationFrameCountAndBitrate() throws {
        let moofs = (0..<9).map { _ in
            moof(trackID: 1, trun: trun(durations: Array(repeating: 3000, count: 30),
                                        sizes: Array(repeating: 1000, count: 30)))
        }
        let data = movie(
            moovSamples: 30, sampleDelta: 3000, sampleSize: 1000,
            mehd: nil, trex: (duration: 0, size: 0), moofs: moofs
        )
        let metadata = try VideoMetadata.read(from: data)
        let stream = try XCTUnwrap(metadata.videoStreams.first)

        XCTAssertEqual(metadata.duration ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(stream.duration ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(stream.frameCount, 300)
        XCTAssertEqual(stream.avgFrameRate ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(stream.bitRate, 300 * 1000 * 8 / 10)
    }

    /// `empty_moov`: nothing in moov; sizes and durations come from the
    /// tfhd default for the first fragment and the trex default for the second.
    func testEmptyMoovUsesTFHDAndTREXDefaults() throws {
        let data = movie(
            moovSamples: 0, sampleDelta: 0, sampleSize: 0,
            mehd: nil, trex: (duration: 3000, size: 500),
            moofs: [
                moof(trackID: 1, defaultDuration: 1500, defaultSize: 2000, trun: trun(sampleCount: 60)),
                moof(trackID: 1, trun: trun(sampleCount: 30)),
            ]
        )
        let metadata = try VideoMetadata.read(from: data)
        let stream = try XCTUnwrap(metadata.videoStreams.first)

        // 60 × 1500 + 30 × 3000 ticks at 90 kHz = 2 s; 60 × 2000 + 30 × 500 bytes.
        XCTAssertEqual(metadata.duration ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(stream.duration ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(stream.frameCount, 90)
        XCTAssertEqual(stream.bitRate, (60 * 2000 + 30 * 500) * 8 / 2)
    }

    /// A declared `mehd` length is the movie duration.
    func testMEHDSetsMovieDuration() throws {
        let data = movie(
            moovSamples: 0, sampleDelta: 0, sampleSize: 0,
            mehd: 45_000, trex: (duration: 3000, size: 100),
            moofs: [moof(trackID: 1, trun: trun(sampleCount: 15))]
        )
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.duration ?? 0, 0.5, accuracy: 0.001)
    }

    /// Fragments of a track that isn't in moov are ignored, and a trun whose
    /// sample_count exceeds its table is skipped rather than trusted.
    func testUnknownTracksAndOversizedTRUNAreIgnored() throws {
        var oversized = trun(durations: [3000], sizes: [100])
        // Overwrite sample_count (after version+flags) with a huge value.
        oversized.replaceSubrange(oversized.startIndex + 4 ..< oversized.startIndex + 8,
                                  with: be32(0xFFFF_FFFF))
        let data = movie(
            moovSamples: 30, sampleDelta: 3000, sampleSize: 1000,
            mehd: nil, trex: (duration: 0, size: 0),
            moofs: [
                moof(trackID: 7, trun: trun(durations: Array(repeating: 3000, count: 30),
                                            sizes: Array(repeating: 1000, count: 30))),
                moof(trackID: 1, trun: oversized),
            ]
        )
        let metadata = try VideoMetadata.read(from: data)
        let stream = try XCTUnwrap(metadata.videoStreams.first)

        XCTAssertEqual(metadata.duration ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(stream.frameCount, 30)
    }

    /// A plain movie is untouched: no mvex, no fragments.
    func testUnfragmentedMovieKeepsMVHDDuration() throws {
        let data = movie(
            moovSamples: 30, sampleDelta: 3000, sampleSize: 1000,
            mehd: nil, trex: nil, moofs: []
        )
        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.duration ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(metadata.videoStreams.first?.frameCount, 30)
    }

    // MARK: - Builders

    private let timescale: UInt32 = 90_000

    private func be32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private func be16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private func zeros(_ count: Int) -> Data {
        Data(repeating: 0, count: count)
    }

    private func ascii(_ text: String) -> Data {
        Data(text.utf8)
    }

    /// A box whose payload is `parts` joined. Variadic rather than chained
    /// `+`, which CI's compiler cannot type-check in reasonable time.
    private func box(_ type: String, _ parts: Data...) -> Data {
        let payload = parts.reduce(Data(), +)
        var data = be32(UInt32(8 + payload.count))
        data.append(ascii(type))
        data.append(payload)
        return data
    }

    /// ftyp + moov (mvhd, one 90 kHz video trak holding `moovSamples`
    /// uniform samples, optional mvex) + the given moof boxes, each followed
    /// by an empty mdat.
    private func movie(
        moovSamples: UInt32,
        sampleDelta: UInt32,
        sampleSize: UInt32,
        mehd: UInt32?,
        trex: (duration: UInt32, size: UInt32)?,
        moofs: [Data]
    ) -> Data {
        let moovTicks = moovSamples * sampleDelta
        let mvhd = box("mvhd", be32(0), be32(0), be32(0), be32(timescale), be32(moovTicks), zeros(80))
        // tkhd v0: version+flags, creation, modification, track_ID, reserved,
        // duration, 52 bytes of reserved/layer/volume/matrix, width, height.
        let width: UInt32 = 640 << 16
        let height: UInt32 = 360 << 16
        let tkhd = box("tkhd", be32(3), be32(0), be32(0), be32(1), be32(0), be32(moovTicks),
                       zeros(52), be32(width), be32(height))
        let mdhd = box("mdhd", be32(0), be32(0), be32(0), be32(timescale), be32(moovTicks),
                       be16(0x55C4), be16(0))
        let hdlr = box("hdlr", be32(0), be32(0), ascii("vide"), zeros(12))
        let stsd = box("stsd", be32(0), be32(1), be32(16), ascii("avc1"), zeros(8))
        let stts = moovSamples > 0
            ? box("stts", be32(0), be32(1), be32(moovSamples), be32(sampleDelta))
            : box("stts", be32(0), be32(0))
        let stsz = box("stsz", be32(0), be32(sampleSize), be32(moovSamples))
        let stbl = box("stbl", stsd, stts, stsz)
        let mdia = box("mdia", mdhd, hdlr, box("minf", stbl))
        let trak = box("trak", tkhd, mdia)

        var mvex = Data()
        if let trex {
            var children = Data()
            if let mehd { children.append(box("mehd", be32(0), be32(mehd))) }
            children.append(box("trex", be32(0), be32(1), be32(1), be32(trex.duration), be32(trex.size), be32(0)))
            mvex = box("mvex", children)
        }

        var data = box("ftyp", ascii("qt  "), be32(0x200), ascii("qt  "))
        data.append(box("moov", mvhd, trak, mvex))
        for moofBox in moofs {
            data.append(moofBox)
            data.append(box("mdat"))
        }
        return data
    }

    private func moof(trackID: UInt32, defaultDuration: UInt32? = nil, defaultSize: UInt32? = nil, trun: Data) -> Data {
        var flags: UInt32 = 0
        var fields = Data()
        if let defaultDuration { flags |= 0x08; fields.append(be32(defaultDuration)) }
        if let defaultSize { flags |= 0x10; fields.append(be32(defaultSize)) }
        let tfhd = box("tfhd", be32(flags), be32(trackID), fields)
        let mfhd = box("mfhd", be32(0), be32(1))
        return box("moof", mfhd, box("traf", tfhd, box("trun", trun)))
    }

    /// trun payload with per-sample durations and sizes (flags 0x301).
    private func trun(durations: [UInt32], sizes: [UInt32]) -> Data {
        var payload = be32(0x301)
        payload.append(be32(UInt32(durations.count)))
        payload.append(be32(0))
        for (duration, size) in zip(durations, sizes) {
            payload.append(be32(duration))
            payload.append(be32(size))
        }
        return payload
    }

    /// trun payload with no per-sample fields: every sample takes the defaults.
    private func trun(sampleCount: UInt32) -> Data {
        var payload = be32(0x001)
        payload.append(be32(sampleCount))
        payload.append(be32(0))
        return payload
    }
}
