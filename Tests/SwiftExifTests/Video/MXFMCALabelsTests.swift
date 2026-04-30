import XCTest
@testable import SwiftExif

/// Tests for SMPTE ST 377-4 / ST 2020-1 Multi-Channel Audio (MCA) labelling
/// — the bmxtools `--audio-labels` round-trip path.
///
/// Three layers:
///   1. `MCALabelsRenderer` — pure in-memory model → labels.txt rendering.
///   2. Synthetic MXF fixture — Primer Pack + Sound Essence Descriptor +
///      MCA subdescriptors, assert end-to-end parsing.
///   3. Real fixture — gated on the user's local bmxtools-produced MXF being
///      present, so CI stays hermetic.
final class MXFMCALabelsTests: XCTestCase {

    // MARK: - Renderer

    /// Rendering a 4-track stereo + mono-pair labelling matches the canonical
    /// bmxtools labels.txt block (modulo descriptive `# Track …` comments,
    /// which bmx accepts as freeform input).
    func testRenderRoundTripsBmxStereoPlusMonoLayout() {
        let sgStereoUID = UUID()
        let sgMonoDcmUID = UUID()
        let sgMonoMEUID = UUID()
        let ggMPgUID = UUID()
        let ggDcmUID = UUID()
        let ggMEUID = UUID()

        var labeling = MCAAudioLabeling()
        labeling.channels = [
            channel(track: 0, symbol: "chL", name: "Left", sgUID: sgStereoUID),
            channel(track: 1, symbol: "chR", name: "Right", sgUID: sgStereoUID),
            channel(track: 2, symbol: "chM1", name: "Mono One", sgUID: sgMonoDcmUID),
            channel(track: 3, symbol: "chM1", name: "Mono One", sgUID: sgMonoMEUID),
        ]
        labeling.soundfieldGroups = [
            soundfieldGroup(symbol: "sgST", name: "Standard Stereo",
                            uid: sgStereoUID, ggRefs: [ggMPgUID]),
            soundfieldGroup(symbol: "sgM", name: "Monoaural",
                            uid: sgMonoDcmUID, ggRefs: [ggDcmUID]),
            soundfieldGroup(symbol: "sgM", name: "Monoaural",
                            uid: sgMonoMEUID, ggRefs: [ggMEUID]),
        ]
        labeling.groupsOfSoundfieldGroups = [
            groupOfGroups(symbol: "ggMPg", name: "Main Program", uid: ggMPgUID, lang: "en"),
            groupOfGroups(symbol: "ggDcm", name: "Dialog Centric Mix", uid: ggDcmUID, lang: "en"),
            groupOfGroups(symbol: "ggME", name: "Music and Effects", uid: ggMEUID),
        ]

        let expected = """
        0
        chL
        sgST, id=sg1
        ggMPg, id=gosg1, lang=en

        1
        chR
        sgST, id=sg1, repeat=false
        ggMPg, id=gosg1, repeat=false

        2
        chM1
        sgM, id=sg2
        ggDcm, id=gosg2, lang=en

        3
        chM1
        sgM, id=sg3
        ggME, id=gosg3

        """

        XCTAssertEqual(MCALabelsRenderer.render(labeling), expected)
    }

    /// Channels with no resolved track index are skipped — they wouldn't
    /// have a valid bmx track number to write next to.
    func testRenderSkipsOrphanChannels() {
        var labeling = MCAAudioLabeling()
        labeling.channels = [
            { var ch = MCAChannelLabel(); ch.symbol = "chC"; return ch }(),
        ]
        XCTAssertEqual(MCALabelsRenderer.render(labeling), "")
    }

    // MARK: - Synthetic MXF fixture

    /// End-to-end: build a minimal MXF carrying a Primer Pack + WaveAudio
    /// Descriptor + 3 MCA subdescriptors (channel/soundfield/group) and verify
    /// the parser surfaces the right symbols and links.
    func testParseSyntheticMCAFixture() throws {
        let channelUID = UUID()
        let sgUID      = UUID()
        let ggUID      = UUID()
        let chLinkID   = UUID()
        let sgLinkID   = UUID()
        let ggLinkID   = UUID()

        let primerBody = buildPrimerPack(entries: [
            (0x6101, MCAULs.tagSymbol),
            (0x6102, MCAULs.tagName),
            (0x6103, MCAULs.linkID),
            (0x6104, MCAULs.soundfieldGroupLinkID),
            (0x6105, MCAULs.groupOfGroupsLinkID),
            (0x6106, MCAULs.rfc5646Language),
            (0x3F01, MCAULs.subDescriptors),
        ])

        let soundDescriptorBody = buildSoundDescriptor(
            instanceUID: UUID(),
            subDescriptors: [channelUID, sgUID, ggUID]
        )

        let channelSubDescriptorBody = buildMCAChannelSubDescriptor(
            instanceUID: channelUID,
            symbol: "chL", name: "Left",
            linkID: chLinkID, soundfieldGroupLinkID: sgLinkID
        )

        let soundfieldSubDescriptorBody = buildMCASoundfieldSubDescriptor(
            instanceUID: sgUID,
            symbol: "sgST", name: "Standard Stereo",
            linkID: sgLinkID, groupOfGroupsLinkIDs: [ggLinkID]
        )

        let groupOfGroupsSubDescriptorBody = buildMCAGroupOfGroupsSubDescriptor(
            instanceUID: ggUID,
            symbol: "ggMPg", name: "Main Program",
            linkID: ggLinkID, language: "en"
        )

        let data = buildMinimalMXFFixture(klvs: [
            (key: ULBytes.primerPackKey, value: primerBody),
            (key: ULBytes.waveAudioDescriptorKey, value: soundDescriptorBody),
            (key: ULBytes.audioChannelLabelSubDescriptorKey, value: channelSubDescriptorBody),
            (key: ULBytes.soundfieldGroupSubDescriptorKey, value: soundfieldSubDescriptorBody),
            (key: ULBytes.groupOfGroupsSubDescriptorKey, value: groupOfGroupsSubDescriptorBody),
        ])

        let metadata = try MXFReader.parse(data)

        let labeling = try XCTUnwrap(metadata.mcaAudioLabeling)
        XCTAssertEqual(labeling.channels.count, 1)
        XCTAssertEqual(labeling.channels.first?.symbol, "chL")
        XCTAssertEqual(labeling.channels.first?.name, "Left")
        XCTAssertEqual(labeling.channels.first?.trackIndex, 0)
        XCTAssertEqual(labeling.channels.first?.linkID, chLinkID)
        XCTAssertEqual(labeling.channels.first?.soundfieldGroupLinkID, sgLinkID)

        XCTAssertEqual(labeling.soundfieldGroups.count, 1)
        XCTAssertEqual(labeling.soundfieldGroups.first?.symbol, "sgST")
        XCTAssertEqual(labeling.soundfieldGroups.first?.linkID, sgLinkID)
        XCTAssertEqual(labeling.soundfieldGroups.first?.groupOfGroupsLinkIDs, [ggLinkID])

        XCTAssertEqual(labeling.groupsOfSoundfieldGroups.count, 1)
        XCTAssertEqual(labeling.groupsOfSoundfieldGroups.first?.symbol, "ggMPg")
        XCTAssertEqual(labeling.groupsOfSoundfieldGroups.first?.name, "Main Program")
        XCTAssertEqual(labeling.groupsOfSoundfieldGroups.first?.language, "en")
        XCTAssertEqual(labeling.groupsOfSoundfieldGroups.first?.linkID, ggLinkID)

        // AudioStream back-fill.
        XCTAssertEqual(metadata.audioStreams.first?.mcaChannelLabel, "chL")
        XCTAssertEqual(metadata.audioStreams.first?.mcaChannelName, "Left")
        XCTAssertEqual(metadata.audioStreams.first?.mcaSoundfieldGroup, "sgST")
        XCTAssertEqual(metadata.audioStreams.first?.mcaGroupOfSoundfieldGroups, "ggMPg")
    }

    // MARK: - Real-fixture (skip if missing)

    /// Drive the parser against the bmxtools-produced MXF the user
    /// committed locally. Skipped on machines that don't have the file —
    /// keeps CI hermetic, but verifies on the developer's machine that the
    /// implementation handles a real-world AS-11 / MCA bitstream.
    func testRealBmxToolsFixture() throws {
        let path = "/Users/traag222/Movies/TestVideo/MCA_Test/n-intervju_with-MCA-labels.mxf"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real MCA fixture not present: \(path)")
        }
        let metadata = try VideoMetadata.read(from: URL(fileURLWithPath: path))
        let labeling = try XCTUnwrap(metadata.mcaAudioLabeling)

        // Four tracks: chL / chR / chM1 / chM1 in declaration order.
        XCTAssertEqual(labeling.channels.count, 4)
        XCTAssertEqual(labeling.channels.map(\.symbol),
                       ["chL", "chR", "chM1", "chM1"])
        XCTAssertEqual(labeling.channels.map(\.name),
                       ["Left", "Right", "Mono One", "Mono One"])
        XCTAssertEqual(labeling.channels.map(\.trackIndex),
                       [0, 1, 2, 3])

        // Three soundfield groups: sgST shared by tracks 0+1, sgM split
        // across the two mono tracks (different UUIDs per declaration).
        XCTAssertEqual(labeling.soundfieldGroups.count, 3)
        XCTAssertEqual(Set(labeling.soundfieldGroups.compactMap(\.symbol)),
                       Set(["sgST", "sgM"]))

        // Three groups-of-groups: ggMPg, ggDcm, ggME.
        XCTAssertEqual(labeling.groupsOfSoundfieldGroups.count, 3)
        XCTAssertEqual(Set(labeling.groupsOfSoundfieldGroups.compactMap(\.symbol)),
                       Set(["ggMPg", "ggDcm", "ggME"]))

        // ggMPg + ggDcm carry RFC5646 lang=en; ggME does not.
        let ggBySymbol = Dictionary(grouping: labeling.groupsOfSoundfieldGroups, by: { $0.symbol ?? "" })
            .compactMapValues(\.first)
        XCTAssertEqual(ggBySymbol["ggMPg"]?.language, "en")
        XCTAssertEqual(ggBySymbol["ggDcm"]?.language, "en")
        XCTAssertNil(ggBySymbol["ggME"]?.language)

        // Per-stream summary back-fill matches.
        XCTAssertEqual(metadata.audioStreams.map(\.mcaChannelLabel),
                       ["chL", "chR", "chM1", "chM1"])
        XCTAssertEqual(metadata.audioStreams.map(\.mcaSoundfieldGroup),
                       ["sgST", "sgST", "sgM", "sgM"])
        XCTAssertEqual(metadata.audioStreams.map(\.mcaGroupOfSoundfieldGroups),
                       ["ggMPg", "ggMPg", "ggDcm", "ggME"])

        // Round-trip back to labels.txt content matches the user's input
        // (modulo `# Track …` comment lines).
        let rendered = MCALabelsRenderer.render(labeling)
        let expected = """
        0
        chL
        sgST, id=sg1
        ggMPg, id=gosg1, lang=en

        1
        chR
        sgST, id=sg1, repeat=false
        ggMPg, id=gosg1, repeat=false

        2
        chM1
        sgM, id=sg2
        ggDcm, id=gosg2, lang=en

        3
        chM1
        sgM, id=sg3
        ggME, id=gosg3

        """
        XCTAssertEqual(rendered, expected)
    }

    // MARK: - Render helpers

    private func channel(
        track: Int, symbol: String, name: String, sgUID: UUID
    ) -> MCAChannelLabel {
        var ch = MCAChannelLabel()
        ch.trackIndex = track
        ch.symbol = symbol
        ch.name = name
        ch.soundfieldGroupLinkID = sgUID
        return ch
    }

    private func soundfieldGroup(
        symbol: String, name: String, uid: UUID, ggRefs: [UUID]
    ) -> MCASoundfieldGroup {
        var sg = MCASoundfieldGroup()
        sg.symbol = symbol
        sg.name = name
        sg.linkID = uid
        sg.groupOfGroupsLinkIDs = ggRefs
        return sg
    }

    private func groupOfGroups(
        symbol: String, name: String, uid: UUID, lang: String? = nil
    ) -> MCAGroupOfSoundfieldGroups {
        var gg = MCAGroupOfSoundfieldGroups()
        gg.symbol = symbol
        gg.name = name
        gg.linkID = uid
        gg.language = lang
        return gg
    }

    // MARK: - Synthetic-fixture helpers

    /// Property-UL constants used in the Primer Pack of the synthetic test
    /// fixture. Borrowed from SMPTE ST 377-4 dictionary version 0x0D so the
    /// parser exercises the legacy half of `mcaProperty(forUL:)`.
    private enum MCAULs {
        static let tagSymbol: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x0D,
            0x03, 0x02, 0x01, 0x02, 0x03, 0x00, 0x00, 0x00,
        ]
        static let tagName: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x0D,
            0x03, 0x02, 0x01, 0x02, 0x04, 0x00, 0x00, 0x00,
        ]
        static let linkID: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x0D,
            0x01, 0x01, 0x15, 0x10, 0x00, 0x00, 0x00, 0x00,
        ]
        static let soundfieldGroupLinkID: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x0D,
            0x01, 0x01, 0x15, 0x11, 0x00, 0x00, 0x00, 0x00,
        ]
        static let groupOfGroupsLinkID: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x0D,
            0x01, 0x04, 0x15, 0x12, 0x00, 0x00, 0x00, 0x00,
        ]
        static let rfc5646Language: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x0D,
            0x03, 0x01, 0x01, 0x02, 0x03, 0x15, 0x00, 0x00,
        ]
        static let subDescriptors: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x02,
            0x06, 0x01, 0x01, 0x04, 0x06, 0x10, 0x00, 0x00,
        ]
    }

    /// KLV keys for the synthetic-fixture top-level objects.
    private enum ULBytes {
        static let primerPackKey: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
            0x0D, 0x01, 0x02, 0x01, 0x01, 0x05, 0x01, 0x00,
        ]
        // WaveAudioDescriptor (kind 0x48) — exercises the existing sound-
        // descriptor branch of MXFReader.parse.
        static let waveAudioDescriptorKey: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01,
            0x0D, 0x01, 0x01, 0x01, 0x01, 0x01, 0x48, 0x00,
        ]
        // AudioChannelLabel SubDescriptor (kind 0x6B).
        static let audioChannelLabelSubDescriptorKey: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01,
            0x0D, 0x01, 0x01, 0x01, 0x01, 0x01, 0x6B, 0x00,
        ]
        // SoundfieldGroupLabel SubDescriptor (kind 0x6C).
        static let soundfieldGroupSubDescriptorKey: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01,
            0x0D, 0x01, 0x01, 0x01, 0x01, 0x01, 0x6C, 0x00,
        ]
        // GroupOfSoundfieldGroupsLabel SubDescriptor (kind 0x6D).
        static let groupOfGroupsSubDescriptorKey: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01,
            0x0D, 0x01, 0x01, 0x01, 0x01, 0x01, 0x6D, 0x00,
        ]
    }

    private func buildPrimerPack(entries: [(UInt16, [UInt8])]) -> Data {
        var out = Data()
        out.append(uint32BE(UInt32(entries.count)))
        out.append(uint32BE(18))
        for (tag, ul) in entries {
            out.append(uint16BE(tag))
            out.append(contentsOf: ul)
        }
        return out
    }

    private func buildSoundDescriptor(
        instanceUID: UUID,
        subDescriptors: [UUID]
    ) -> Data {
        var body = Data()
        body.append(localTagLV(0x3C0A, value: uuidData(instanceUID)))
        // Minimal audio fields so the existing parseSoundDescriptor populates
        // the AudioStream and `parse()` accepts the descriptor.
        body.append(localTagLV(0x3D03, value:
            uint32BE(48000) + uint32BE(1)
        ))
        body.append(localTagLV(0x3D07, value: uint32BE(1)))
        body.append(localTagLV(0x3D01, value: uint32BE(16)))
        // SubDescriptors strong-reference array.
        var sub = Data()
        sub.append(uint32BE(UInt32(subDescriptors.count)))
        sub.append(uint32BE(16))
        for uid in subDescriptors {
            sub.append(uuidData(uid))
        }
        body.append(localTagLV(0x3F01, value: sub))
        return body
    }

    private func buildMCAChannelSubDescriptor(
        instanceUID: UUID,
        symbol: String, name: String,
        linkID: UUID, soundfieldGroupLinkID: UUID
    ) -> Data {
        var body = Data()
        body.append(localTagLV(0x3C0A, value: uuidData(instanceUID)))
        body.append(localTagLV(0x6101, value: utf16BEData(symbol)))
        body.append(localTagLV(0x6102, value: utf16BEData(name)))
        body.append(localTagLV(0x6103, value: uuidData(linkID)))
        body.append(localTagLV(0x6104, value: uuidData(soundfieldGroupLinkID)))
        return body
    }

    private func buildMCASoundfieldSubDescriptor(
        instanceUID: UUID,
        symbol: String, name: String,
        linkID: UUID, groupOfGroupsLinkIDs: [UUID]
    ) -> Data {
        var body = Data()
        body.append(localTagLV(0x3C0A, value: uuidData(instanceUID)))
        body.append(localTagLV(0x6101, value: utf16BEData(symbol)))
        body.append(localTagLV(0x6102, value: utf16BEData(name)))
        body.append(localTagLV(0x6103, value: uuidData(linkID)))
        var arr = Data()
        arr.append(uint32BE(UInt32(groupOfGroupsLinkIDs.count)))
        arr.append(uint32BE(16))
        for uid in groupOfGroupsLinkIDs { arr.append(uuidData(uid)) }
        body.append(localTagLV(0x6105, value: arr))
        return body
    }

    private func buildMCAGroupOfGroupsSubDescriptor(
        instanceUID: UUID,
        symbol: String, name: String,
        linkID: UUID, language: String?
    ) -> Data {
        var body = Data()
        body.append(localTagLV(0x3C0A, value: uuidData(instanceUID)))
        body.append(localTagLV(0x6101, value: utf16BEData(symbol)))
        body.append(localTagLV(0x6102, value: utf16BEData(name)))
        body.append(localTagLV(0x6103, value: uuidData(linkID)))
        if let language {
            body.append(localTagLV(0x6106, value: Data(language.utf8) + Data([0])))
        }
        return body
    }

    /// Wrap a list of (key, value) KLVs in a minimal partition pack so the
    /// MXFReader's magic check passes.
    private func buildMinimalMXFFixture(klvs: [(key: [UInt8], value: Data)]) -> Data {
        let partitionPackKey: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
            0x0D, 0x01, 0x02, 0x01, 0x01, 0x02, 0x04, 0x00,
        ]
        let partitionBody = Data(repeating: 0x00, count: 16)

        var out = Data()
        out.append(contentsOf: partitionPackKey)
        out.append(berLength(partitionBody.count))
        out.append(partitionBody)

        for klv in klvs {
            out.append(contentsOf: klv.key)
            out.append(berLength(klv.value.count))
            out.append(klv.value)
        }
        return out
    }

    // MARK: - Byte-emission utilities

    private func localTagLV(_ tag: UInt16, value: Data) -> Data {
        precondition(value.count <= 0xFFFF)
        var out = Data()
        out.append(uint16BE(tag))
        out.append(uint16BE(UInt16(value.count)))
        out.append(value)
        return out
    }

    private func uint16BE(_ v: UInt16) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 2)
    }

    private func uint32BE(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 4)
    }

    private func uuidData(_ uuid: UUID) -> Data {
        let t = uuid.uuid
        return Data([
            t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7,
            t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15,
        ])
    }

    /// UTF-16BE with trailing null terminator — matches what bmxtools writes
    /// for MCA Tag Symbol / Tag Name strings.
    private func utf16BEData(_ s: String) -> Data {
        var out = Data()
        for unit in s.utf16 {
            out.append(uint16BE(unit))
        }
        out.append(contentsOf: [0x00, 0x00])
        return out
    }

    private func berLength(_ length: Int) -> Data {
        if length <= 0x7F { return Data([UInt8(length)]) }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
