import XCTest
@testable import SwiftExif

/// Integration tests for the rich video-stream metadata added in phase 16:
/// frame rate, field order, resolution, color space, chroma subsampling,
/// bit depth, channel layout, bit rate. Tests only run when the developer
/// fixture folder is present; in CI they silently no-op.
final class VideoStreamMetadataTests: XCTestCase {

    private let fixtureDir = URL(fileURLWithPath: "/Users/traag222/Movies/TestVideo")

    /// Skip when the developer test fixture is missing so CI stays green.
    private func fixtureURL(_ name: String) throws -> URL {
        let url = fixtureDir.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "Fixture \(name) not present on this machine")
        return url
    }

    // MARK: - iPhone HEVC HLG (HDR)

    func testIPhoneHDRMOV() throws {
        let url = try fixtureURL("IMG_0151.MOV")
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.format, .mov)
        XCTAssertEqual(m.videoCodec, "hvc1")
        XCTAssertEqual(m.videoWidth, 3840)
        XCTAssertEqual(m.videoHeight, 2160)
        XCTAssertEqual(m.bitDepth, 10)
        XCTAssertEqual(m.chromaSubsampling, "4:2:0")
        XCTAssertEqual(m.colorInfo?.label, "bt2020-hlg")
        XCTAssertEqual(m.audioCodec, "mp4a")
        XCTAssertEqual(m.audioSampleRate, 48000)
        XCTAssertEqual(m.audioChannels, 2)
        XCTAssertEqual(m.audioStreams.first?.channelLayout, "stereo")
        XCTAssertNotNil(m.frameRate)
        XCTAssertGreaterThan(m.frameRate ?? 0, 59)
    }

    // MARK: - ProRes LPCM V2 audio

    func testProResV2LPCM() throws {
        let url = try fixtureURL("TimeCode_APV.mov")
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.format, .mov)
        XCTAssertEqual(m.videoCodec, "apv1")
        XCTAssertEqual(m.videoWidth, 1920)
        XCTAssertEqual(m.videoHeight, 1080)
        XCTAssertEqual(m.frameRate, 25.0)
        XCTAssertEqual(m.fieldOrder, .progressive)
        XCTAssertEqual(m.colorInfo?.label, "bt709")
        XCTAssertEqual(m.audioCodec, "lpcm")
        XCTAssertEqual(m.audioSampleRate, 48000)
        XCTAssertEqual(m.audioChannels, 1)
    }

    // MARK: - AV1 HDR

    func testAV1HDR() throws {
        let url = try fixtureURL("ShortPlantHDR_av1.mp4")
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.videoCodec, "av01")
        XCTAssertEqual(m.bitDepth, 10)
        XCTAssertEqual(m.chromaSubsampling, "4:2:0")
        XCTAssertEqual(m.colorInfo?.label, "bt2020-pq")
    }

    // MARK: - Matroska / WebM

    func testWebMVP8() throws {
        let url = try fixtureURL("big-buck-bunny_trailer-.webm")
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.format, .webm)
        XCTAssertEqual(m.videoCodec, "V_VP8")
        XCTAssertEqual(m.videoWidth, 640)
        XCTAssertEqual(m.videoHeight, 360)
        XCTAssertEqual(m.frameRate, 25.0)
        XCTAssertEqual(m.audioCodec, "A_VORBIS")
    }

    func testMKVHEVCPQ() throws {
        let url = try fixtureURL("Interstellar_2014_copy.mkv")
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.format, .mkv)
        XCTAssertEqual(m.videoWidth, 3840)
        XCTAssertEqual(m.videoHeight, 2160)
        XCTAssertEqual(m.colorInfo?.primaries, 9)
        XCTAssertEqual(m.colorInfo?.transfer, 16)
        XCTAssertEqual(m.colorInfo?.matrix, 9)
    }

    // MARK: - MXF

    func testMXFBroadcastDescriptor() throws {
        let url = try fixtureURL("n-intervju_249165_multitrack.mxf")
        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.format, .mxf)
        XCTAssertEqual(m.videoWidth, 1440)
        XCTAssertEqual(m.videoHeight, 540)
        XCTAssertEqual(m.frameRate, 25.0)
        XCTAssertEqual(m.audioSampleRate, 48000)
        XCTAssertEqual(m.audioChannels, 1)
    }
}

/// Audio-only stream metadata (MP3, FLAC, M4A).
final class StandaloneAudioMetadataTests: XCTestCase {

    private let fixtureDir = URL(fileURLWithPath: "/Users/traag222/Movies/TestVideo")

    private func fixtureURL(_ name: String) throws -> URL {
        let url = fixtureDir.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "Fixture \(name) not present")
        return url
    }

    func testMP3ID3v2FilePopulatesAudioFacts() throws {
        let url = try fixtureURL("TV 2 Nyhetsbed 1.mp3")
        let m = try AudioMetadata.read(from: url)
        XCTAssertEqual(m.format, .mp3)
        XCTAssertEqual(m.codec, "mp3")
        XCTAssertEqual(m.codecName, "MP3")
        XCTAssertEqual(m.sampleRate, 48000)
        XCTAssertEqual(m.channels, 2)
        XCTAssertEqual(m.bitrate, 320_000)
        XCTAssertNotNil(m.duration)
    }

    func testM4APopulatesCodecFacts() throws {
        let url = try fixtureURL("MusicTestWaveform.m4a")
        let m = try AudioMetadata.read(from: url)
        XCTAssertEqual(m.format, .m4a)
        XCTAssertEqual(m.codec, "mp4a")
        XCTAssertEqual(m.codecName, "AAC")
        XCTAssertEqual(m.sampleRate, 44100)
        XCTAssertEqual(m.channels, 2)
        XCTAssertEqual(m.bitDepth, 16)
        XCTAssertNotNil(m.duration)
    }
}
