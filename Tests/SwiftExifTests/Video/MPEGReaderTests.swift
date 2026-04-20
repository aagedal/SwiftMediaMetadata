import XCTest
@testable import SwiftExif

/// MPEG-TS container parse tests driven by synthetic PAT/PMT byte fixtures —
/// no ffmpeg dependency so CI stays green on bare runners.
final class MPEGReaderTests: XCTestCase {

    /// ISO/IEC 13818-1 maximum_bitrate_descriptor (tag 0x0E) carries the only
    /// bit-rate most DVB streams advertise for AAC and H.264/H.265 elementary
    /// streams. The parser should surface it as AudioStream.bitRate /
    /// VideoStream.bitRate in bits per second (the raw value is in 50 byte/s
    /// units, i.e. multiplied by 400).
    func testMaximumBitRateDescriptorPopulatesStreamBitRate() throws {
        // 1500 units × 400 = 600 000 bits/s = 600 kbps for the AAC stream.
        // 5000 units × 400 = 2 000 000 bits/s = 2 Mbps for the H.264 stream.
        let data = buildTSWithBitRateDescriptor(audioRate: 1500, videoRate: 5000)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftexif-mpegts-\(UUID().uuidString).ts")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let m = try VideoMetadata.read(from: url)
        XCTAssertEqual(m.audioStreams.count, 1)
        XCTAssertEqual(m.audioStreams[0].codec, "aac")
        XCTAssertEqual(m.audioStreams[0].bitRate, 600_000)

        XCTAssertEqual(m.videoStreams.count, 1)
        XCTAssertEqual(m.videoStreams[0].codec, "avc1")
        XCTAssertEqual(m.videoStreams[0].bitRate, 2_000_000)
    }

    // MARK: - Synthetic TS builder

    /// Build a 4-packet TS: PAT, PMT with one H.264 video ES and one AAC audio
    /// ES (each carrying a maximum_bitrate_descriptor), plus two null packets
    /// so `isMPEG` sees sync bytes at 0/188/376/564.
    private func buildTSWithBitRateDescriptor(audioRate: UInt32, videoRate: UInt32) -> Data {
        var data = Data()
        data.append(makePATPacket(pmtPID: 0x100))
        data.append(makePMTWithTwoStreams(pmtPID: 0x100,
                                          videoPID: 0x101, videoRate: videoRate,
                                          audioPID: 0x102, audioRate: audioRate))
        data.append(makeNullPacket())
        data.append(makeNullPacket())
        return data
    }

    private func makePATPacket(pmtPID: UInt16) -> Data {
        var section = Data()
        section.append(0x00)                                  // pointer_field
        section.append(0x00)                                  // table_id (PAT)
        section.append(0xB0)                                  // section_syntax=1, length high=0
        section.append(0x0D)                                  // section_length = 13
        section.append(contentsOf: [0x00, 0x01])              // transport_stream_id
        section.append(0xC1)                                  // version + current_next
        section.append(0x00)                                  // section_number
        section.append(0x00)                                  // last_section_number
        section.append(contentsOf: [0x00, 0x01])              // program_number
        section.append(UInt8(0xE0 | ((pmtPID >> 8) & 0x1F)))
        section.append(UInt8(pmtPID & 0xFF))
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // CRC32 (ignored)
        return wrapInTSPacket(pid: 0x0000, payloadUnitStart: true, payload: section)
    }

    private func makePMTWithTwoStreams(pmtPID: UInt16,
                                       videoPID: UInt16, videoRate: UInt32,
                                       audioPID: UInt16, audioRate: UInt32) -> Data {
        let videoDescriptor = makeMaxBitRateDescriptor(units: videoRate)
        let audioDescriptor = makeMaxBitRateDescriptor(units: audioRate)

        var esLoop = Data()
        esLoop.append(esEntry(streamType: 0x1B, pid: videoPID, descriptors: videoDescriptor)) // H.264
        esLoop.append(esEntry(streamType: 0x0F, pid: audioPID, descriptors: audioDescriptor)) // AAC

        let sectionLength = UInt16(2 + 1 + 1 + 1 + 2 + 2 + esLoop.count + 4)

        var section = Data()
        section.append(0x00)                                  // pointer_field
        section.append(0x02)                                  // table_id (PMT)
        section.append(UInt8(0xB0 | ((sectionLength >> 8) & 0x0F)))
        section.append(UInt8(sectionLength & 0xFF))
        section.append(contentsOf: [0x00, 0x01])              // program_number
        section.append(0xC1)                                  // version / current_next
        section.append(0x00)                                  // section_number
        section.append(0x00)                                  // last_section_number
        section.append(contentsOf: [0xE1, 0x00])              // PCR_PID
        section.append(contentsOf: [0xF0, 0x00])              // program_info_length = 0
        section.append(esLoop)
        section.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // CRC32 (ignored)

        return wrapInTSPacket(pid: pmtPID, payloadUnitStart: true, payload: section)
    }

    private func esEntry(streamType: UInt8, pid: UInt16, descriptors: Data) -> Data {
        var entry = Data()
        entry.append(streamType)
        entry.append(UInt8(0xE0 | ((pid >> 8) & 0x1F)))
        entry.append(UInt8(pid & 0xFF))
        let len = UInt16(descriptors.count)
        entry.append(UInt8(0xF0 | ((len >> 8) & 0x0F)))
        entry.append(UInt8(len & 0xFF))
        entry.append(descriptors)
        return entry
    }

    private func makeMaxBitRateDescriptor(units: UInt32) -> Data {
        // Tag 0x0E, length 3, payload = 2 reserved bits set to 11 + 22-bit value.
        var d = Data()
        d.append(0x0E)
        d.append(0x03)
        d.append(UInt8(0xC0 | UInt8((units >> 16) & 0x3F)))
        d.append(UInt8((units >> 8) & 0xFF))
        d.append(UInt8(units & 0xFF))
        return d
    }

    private func makeNullPacket() -> Data {
        wrapInTSPacket(pid: 0x1FFF, payloadUnitStart: false, payload: Data())
    }

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
