import Foundation

/// Reader for MPEG Program Streams (.mpg/.mpeg/.vob) and MPEG Transport
/// Streams (.ts/.m2ts). Pulls coarse video facts from the first video
/// Sequence Header.
///
/// Program Streams (PS): payload is a sequence of pack headers
/// (0x00 0x00 0x01 0xBA) followed by PES packets; video elementary stream
/// data is embedded in PES packets 0x000001E0..0x000001EF.
///
/// Transport Streams (TS): 188-byte packets, each starting with 0x47. Video
/// packets carry ES data in their payload; packets marked `payload_unit_start`
/// begin with a PES header that precedes the ES data.
///
/// Both forms lift the first MPEG-1/2 video sequence header (start code
/// 0x000001B3), which gives us width, height, frame rate, aspect ratio and
/// bit rate. For H.264/H.265 TS streams we currently only report the codec
/// identity — parsing the SPS is beyond scope here.
public struct MPEGReader: Sendable {

    /// Quick sniff: MPEG-PS starts with a pack header (0x00 0x00 0x01 0xBA);
    /// plain MPEG-TS has 188-byte packets with 0x47 sync at 0 / 188 / 376 /
    /// 564; Blu-ray M2TS prepends a 4-byte TP_extra_header to each packet,
    /// producing 192-byte packets with 0x47 at 4 / 196 / 388 / 580.
    public static func isMPEG(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let s = data.startIndex

        // Program stream
        if data[s] == 0x00 && data[s + 1] == 0x00 && data[s + 2] == 0x01 && data[s + 3] == 0xBA {
            return true
        }

        // Transport stream (plain MPEG-TS, 188-byte packets).
        if data[s] == 0x47 && data.count >= 188 * 4 {
            if data[s + 188] == 0x47
                && data[s + 376] == 0x47
                && data[s + 564] == 0x47 {
                return true
            }
        }

        // M2TS / Blu-ray BDAV: 192-byte packets with a 4-byte timestamp prefix.
        if data.count >= 192 * 4 {
            if data[s + 4] == 0x47
                && data[s + 196] == 0x47
                && data[s + 388] == 0x47
                && data[s + 580] == 0x47 {
                return true
            }
        }

        return false
    }

    public static func parse(_ data: Data) throws -> VideoMetadata {
        guard isMPEG(data) else {
            throw MetadataError.invalidVideo("Not an MPEG-PS/TS file")
        }

        var metadata = VideoMetadata(format: .mpg)

        if data.count >= 4 {
            let s = data.startIndex
            if data[s] == 0x47 {
                parseTransportStream(data, into: &metadata, packetOffset: 0, packetStride: 188)
            } else if data.count >= 192 * 4,
                      data[s + 4] == 0x47,
                      data[s + 196] == 0x47 {
                // M2TS: 4-byte TP_extra_header + 188-byte TS packet = 192-byte stride.
                parseTransportStream(data, into: &metadata, packetOffset: 4, packetStride: 192)
            } else {
                parseProgramStream(data, into: &metadata)
            }
        }

        // Surface the first video/audio stream to the top-level fields.
        if let v = metadata.videoStreams.first {
            if metadata.videoWidth == nil { metadata.videoWidth = v.width }
            if metadata.videoHeight == nil { metadata.videoHeight = v.height }
            if metadata.videoCodec == nil { metadata.videoCodec = v.codec }
            if metadata.frameRate == nil { metadata.frameRate = v.frameRate }
        }

        return metadata
    }

    // MARK: - Program Stream

    /// Scan a bounded window for the first MPEG-1/2 video sequence header start
    /// code (00 00 01 B3) and decode it.
    ///
    /// We don't try to reconstruct PES structure — finding the start code is
    /// sufficient to pull stream-level facts and the scan window is cheap.
    private static let psScanWindow = 16 * 1024 * 1024

    private static func parseProgramStream(_ data: Data, into metadata: inout VideoMetadata) {
        let scanEnd = min(data.count, psScanWindow)
        let header = findSequenceHeader(data, from: 0, end: scanEnd)
        if let (w, h, fps, bitRate, aspect) = header {
            var stream = VideoStream(index: 0)
            stream.codec = "mpeg2video"
            stream.codecName = "MPEG-2 Video"
            stream.width = w
            stream.height = h
            stream.frameRate = fps
            if w > 0, h > 0, let aspect, aspect.0 > 0, aspect.1 > 0,
               aspect != (w, h) {
                stream.displayWidth = aspect.0
                stream.displayHeight = aspect.1
            }
            metadata.videoStreams.append(stream)
            if bitRate > 0 {
                metadata.bitRate = bitRate
            }
        }
    }

    // MARK: - Transport Stream

    /// Walk TS packets, decoding PAT/PMT and scanning video PES payloads for
    /// the first MPEG-1/2 sequence header.
    ///
    /// - `packetOffset`: byte offset to the first packet in the stream (0 for
    ///   plain TS, 4 for M2TS with a TP_extra_header prefix).
    /// - `packetStride`: distance between packet starts (188 for plain TS,
    ///   192 for M2TS).
    private static func parseTransportStream(
        _ data: Data,
        into metadata: inout VideoMetadata,
        packetOffset: Int,
        packetStride: Int
    ) {
        // Walk up to ~9 MB of packet payload, enough to cover PAT/PMT and the
        // first video sequence header in any typical stream.
        let available = max(0, data.count - packetOffset)
        let maxPackets = min(available / packetStride, 48_000)
        let packetPayloadSize = 188
        var videoPIDs: [Int: TSStreamInfo] = [:]
        var audioPIDs: [Int: TSStreamInfo] = [:]
        var subtitlePIDs: [Int: TSStreamInfo] = [:]

        // Pass 1: find PAT → PMT → elementary stream types.
        var patPMTPids: Set<Int> = []
        for i in 0..<maxPackets {
            let packetStart = packetOffset + i * packetStride
            let (pid, unitStart, payloadStart) = parseTSHeader(data, at: packetStart)
            guard pid >= 0, let payloadStart else { continue }
            if pid == 0, unitStart {
                let pmtPids = parsePAT(data, from: payloadStart, end: packetStart + packetPayloadSize)
                patPMTPids.formUnion(pmtPids)
                continue
            }
            if patPMTPids.contains(pid), unitStart {
                parsePMT(data, from: payloadStart, end: packetStart + packetPayloadSize,
                         videoPIDs: &videoPIDs, audioPIDs: &audioPIDs,
                         subtitlePIDs: &subtitlePIDs)
            }
        }

        // Pass 2: find the first video sequence header in any video PID's PES.
        for i in 0..<maxPackets {
            let packetStart = packetOffset + i * packetStride
            let (pid, unitStart, payloadStart) = parseTSHeader(data, at: packetStart)
            guard pid >= 0, var info = videoPIDs[pid], let payloadStart else { continue }
            if info.sequenceHeaderParsed { continue }

            // Skip the PES header when this is a unit-start packet.
            var esStart = payloadStart
            if unitStart {
                esStart = skipPESHeader(data, at: payloadStart, end: packetStart + packetPayloadSize) ?? payloadStart
            }
            if esStart >= packetStart + packetPayloadSize { continue }

            // Scan this packet's ES payload for a sequence header.
            if let (w, h, fps, br, aspect) = findSequenceHeader(data, from: esStart, end: packetStart + packetPayloadSize) {
                info.width = w
                info.height = h
                info.frameRate = fps
                info.bitRate = br
                info.displayWidth = aspect?.0
                info.displayHeight = aspect?.1
                info.sequenceHeaderParsed = true
                videoPIDs[pid] = info
            }
        }

        // Publish streams. Preserve PAT/PMT discovery order.
        var nextIndex = 0
        for (_, info) in videoPIDs.sorted(by: { $0.key < $1.key }) {
            var stream = VideoStream(index: nextIndex); nextIndex += 1
            stream.codec = info.codec
            stream.codecName = info.codecName
            stream.width = info.width
            stream.height = info.height
            stream.frameRate = info.frameRate
            if let dw = info.displayWidth, let dh = info.displayHeight,
               dw != info.width || dh != info.height {
                stream.displayWidth = dw
                stream.displayHeight = dh
            }
            metadata.videoStreams.append(stream)
            if metadata.bitRate == nil, let br = info.bitRate, br > 0 {
                metadata.bitRate = br
            }
        }

        var audioIdx = 0
        for (_, info) in audioPIDs.sorted(by: { $0.key < $1.key }) {
            var stream = AudioStream(index: audioIdx); audioIdx += 1
            stream.codec = info.codec
            stream.codecName = info.codecName
            stream.language = info.language
            metadata.audioStreams.append(stream)
            if metadata.audioCodec == nil { metadata.audioCodec = info.codec }
        }

        var subIdx = 0
        for (_, info) in subtitlePIDs.sorted(by: { $0.key < $1.key }) {
            var stream = SubtitleStream(index: subIdx); subIdx += 1
            stream.codec = info.codec
            stream.codecName = info.codecName
            stream.language = info.language
            stream.isHearingImpaired = info.isHearingImpaired
            metadata.subtitleStreams.append(stream)
        }
    }

    private struct TSStreamInfo {
        var codec: String?
        var codecName: String?
        var width: Int?
        var height: Int?
        var frameRate: Double?
        var bitRate: Int?
        var displayWidth: Int?
        var displayHeight: Int?
        var language: String?
        var isHearingImpaired: Bool?
        var sequenceHeaderParsed: Bool = false
    }

    /// Parse a single 188-byte TS packet header. Returns (pid, payloadUnitStart, payloadOffset-or-nil).
    /// `payloadOffset` is nil when there is no payload (adaptation-field-only packet).
    private static func parseTSHeader(_ data: Data, at packetStart: Int) -> (Int, Bool, Int?) {
        guard packetStart + 4 <= data.count, data[data.startIndex + packetStart] == 0x47 else {
            return (-1, false, nil)
        }
        let s = data.startIndex + packetStart
        let flags1 = data[s + 1]
        let flags2 = data[s + 2]
        let adaptationByte = data[s + 3]

        let payloadUnitStart = (flags1 & 0x40) != 0
        let pid = (Int(flags1 & 0x1F) << 8) | Int(flags2)
        let hasAdaptation = (adaptationByte & 0x20) != 0
        let hasPayload = (adaptationByte & 0x10) != 0

        guard hasPayload else { return (pid, payloadUnitStart, nil) }
        var payloadOffset = 4
        if hasAdaptation {
            guard packetStart + 4 + 1 <= data.count else { return (pid, payloadUnitStart, nil) }
            let adLen = Int(data[s + 4])
            payloadOffset = 4 + 1 + adLen
        }
        if payloadOffset >= 188 { return (pid, payloadUnitStart, nil) }
        return (pid, payloadUnitStart, packetStart + payloadOffset)
    }

    /// PAT body layout (after the pointer field, once we've skipped it):
    ///   table_id(1) + section_syntax(1) + section_length(2) + transport_stream_id(2) +
    ///   version(1) + section_number(1) + last_section(1) +
    ///   [program_number(2) + reserved+PMT_PID(2)]*
    private static func parsePAT(_ data: Data, from start: Int, end: Int) -> [Int] {
        guard start < end else { return [] }
        var s = start
        // Pointer field
        let pointer = Int(data[data.startIndex + s])
        s += 1 + pointer
        guard s + 8 <= end else { return [] }
        let sectionLength = (Int(data[data.startIndex + s + 1] & 0x0F) << 8) | Int(data[data.startIndex + s + 2])
        let sectionEnd = min(s + 3 + sectionLength - 4, end) // exclude 4-byte CRC

        var pids: [Int] = []
        var off = s + 8
        while off + 4 <= sectionEnd {
            let programNumber = (Int(data[data.startIndex + off]) << 8) | Int(data[data.startIndex + off + 1])
            let pmtPid = (Int(data[data.startIndex + off + 2] & 0x1F) << 8) | Int(data[data.startIndex + off + 3])
            if programNumber != 0 { pids.append(pmtPid) }
            off += 4
        }
        return pids
    }

    private static func parsePMT(
        _ data: Data,
        from start: Int,
        end: Int,
        videoPIDs: inout [Int: TSStreamInfo],
        audioPIDs: inout [Int: TSStreamInfo],
        subtitlePIDs: inout [Int: TSStreamInfo]
    ) {
        guard start < end else { return }
        var s = start
        let pointer = Int(data[data.startIndex + s])
        s += 1 + pointer
        guard s + 12 <= end else { return }

        let sectionLength = (Int(data[data.startIndex + s + 1] & 0x0F) << 8) | Int(data[data.startIndex + s + 2])
        let sectionEnd = min(s + 3 + sectionLength - 4, end)

        // Program_info_length at offset s+10..11
        let programInfoLength = (Int(data[data.startIndex + s + 10] & 0x0F) << 8) | Int(data[data.startIndex + s + 11])
        var off = s + 12 + programInfoLength
        while off + 5 <= sectionEnd {
            let streamType = data[data.startIndex + off]
            let pid = (Int(data[data.startIndex + off + 1] & 0x1F) << 8) | Int(data[data.startIndex + off + 2])
            let esInfoLen = (Int(data[data.startIndex + off + 3] & 0x0F) << 8) | Int(data[data.startIndex + off + 4])

            let descriptorStart = off + 5
            let descriptorEnd = min(descriptorStart + esInfoLen, sectionEnd)
            let esDescriptors = parseESDescriptors(data, from: descriptorStart, end: descriptorEnd)

            switch streamType {
            case 0x01, 0x02:
                var info = videoPIDs[pid] ?? TSStreamInfo()
                info.codec = "mpeg2video"
                info.codecName = "MPEG-2 Video"
                videoPIDs[pid] = info
            case 0x1B:
                var info = videoPIDs[pid] ?? TSStreamInfo()
                info.codec = "avc1"
                info.codecName = "H.264 / AVC"
                info.sequenceHeaderParsed = true // SPS parsing is out of scope
                videoPIDs[pid] = info
            case 0x24:
                var info = videoPIDs[pid] ?? TSStreamInfo()
                info.codec = "hvc1"
                info.codecName = "H.265 / HEVC"
                info.sequenceHeaderParsed = true
                videoPIDs[pid] = info
            case 0x10:
                var info = videoPIDs[pid] ?? TSStreamInfo()
                info.codec = "mp4v"
                info.codecName = "MPEG-4 Visual"
                info.sequenceHeaderParsed = true
                videoPIDs[pid] = info
            case 0x03, 0x04:
                var info = audioPIDs[pid] ?? TSStreamInfo()
                info.codec = "mp3"
                info.codecName = "MPEG-1/2 Layer III"
                info.language = esDescriptors.language
                audioPIDs[pid] = info
            case 0x0F, 0x11:
                var info = audioPIDs[pid] ?? TSStreamInfo()
                info.codec = "aac"
                info.codecName = "AAC"
                info.language = esDescriptors.language
                audioPIDs[pid] = info
            case 0x81:
                var info = audioPIDs[pid] ?? TSStreamInfo()
                info.codec = "ac3"
                info.codecName = "Dolby Digital (AC-3)"
                info.language = esDescriptors.language
                audioPIDs[pid] = info
            case 0x87:
                var info = audioPIDs[pid] ?? TSStreamInfo()
                info.codec = "eac3"
                info.codecName = "Dolby Digital Plus (E-AC-3)"
                info.language = esDescriptors.language
                audioPIDs[pid] = info
            case 0x82:
                // HDMV PGS (Blu-ray graphic subtitles).
                var info = subtitlePIDs[pid] ?? TSStreamInfo()
                info.codec = "hdmv_pgs"
                info.codecName = "PGS (Blu-ray)"
                info.language = esDescriptors.language
                subtitlePIDs[pid] = info
            case 0x92:
                // HDMV IGS (Blu-ray interactive graphics) — not subtitles, skip.
                break
            case 0x06:
                // Private data — resolve to DVB subtitles / teletext via
                // descriptors when present.
                if let kind = esDescriptors.privateKind {
                    var info = subtitlePIDs[pid] ?? TSStreamInfo()
                    switch kind {
                    case .dvbSubtitle:
                        info.codec = "dvb_subtitle"
                        info.codecName = "DVB Subtitles"
                    case .teletext:
                        info.codec = "dvb_teletext"
                        info.codecName = "DVB Teletext"
                    case .ac3:
                        // Some muxers carry AC-3 on private stream type 0x06
                        // with an AC-3 descriptor. Route it to audio.
                        var a = audioPIDs[pid] ?? TSStreamInfo()
                        a.codec = "ac3"
                        a.codecName = "Dolby Digital (AC-3)"
                        a.language = esDescriptors.language
                        audioPIDs[pid] = a
                        off += 5 + esInfoLen
                        continue
                    }
                    info.language = esDescriptors.language
                    if esDescriptors.isHearingImpaired == true {
                        info.isHearingImpaired = true
                    }
                    subtitlePIDs[pid] = info
                }
            default:
                break
            }

            off += 5 + esInfoLen
        }
    }

    /// Fields we extract from an elementary stream's descriptor loop.
    private struct ESDescriptorInfo {
        var language: String?
        var privateKind: PrivateStreamKind?
        var isHearingImpaired: Bool?
    }

    private enum PrivateStreamKind {
        case dvbSubtitle
        case teletext
        case ac3
    }

    /// Walk the descriptor loop that follows every ES entry in the PMT.
    /// Recognises:
    ///   - ISO 639 language descriptor (tag 0x0A) — 3-byte ISO code per entry.
    ///   - DVB subtitle descriptor (tag 0x59) — marks subtitle streams; the
    ///     per-language `subtitling_type` byte distinguishes SDH variants
    ///     (0x20-0x24 hard-of-hearing, 0x30-0x31 sign-language) from the
    ///     plain subtitle types (0x01-0x06).
    ///   - Teletext descriptor (tag 0x56) — marks teletext streams; each
    ///     entry's `teletext_type` nibble flags value 0x05 as the
    ///     hearing-impaired subtitle page.
    ///   - AC-3 descriptor (tag 0x6A) — present on DVB private-stream AC-3.
    private static func parseESDescriptors(_ data: Data, from start: Int, end: Int) -> ESDescriptorInfo {
        var info = ESDescriptorInfo()
        guard start < end, end <= data.count else { return info }
        var off = start
        while off + 2 <= end {
            let tag = data[data.startIndex + off]
            let length = Int(data[data.startIndex + off + 1])
            let valueStart = off + 2
            let valueEnd = valueStart + length
            guard valueEnd <= end else { break }

            switch tag {
            case 0x0A: // ISO 639 language descriptor — first 3 bytes are the language code.
                if length >= 3 {
                    let bytes = data[data.startIndex + valueStart ..< data.startIndex + valueStart + 3]
                    if let lang = String(data: bytes, encoding: .ascii)?
                        .lowercased()
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       lang.count == 3 {
                        info.language = lang
                    }
                }
            case 0x56: // Teletext descriptor — 5-byte entries.
                info.privateKind = .teletext
                if length >= 3, info.language == nil {
                    let bytes = data[data.startIndex + valueStart ..< data.startIndex + valueStart + 3]
                    info.language = String(data: bytes, encoding: .ascii)?.lowercased()
                }
                var entryOff = valueStart
                while entryOff + 5 <= valueEnd {
                    // Top 5 bits of byte 3 are the teletext_type. 0x05 = subtitle
                    // page for the hearing impaired (ETSI EN 300 468 §6.2.42).
                    let teletextType = data[data.startIndex + entryOff + 3] >> 3
                    if teletextType == 0x05 {
                        info.isHearingImpaired = true
                    }
                    entryOff += 5
                }
            case 0x59: // DVB subtitling descriptor — 8-byte entries.
                info.privateKind = .dvbSubtitle
                if length >= 3, info.language == nil {
                    let bytes = data[data.startIndex + valueStart ..< data.startIndex + valueStart + 3]
                    info.language = String(data: bytes, encoding: .ascii)?.lowercased()
                }
                var entryOff = valueStart
                while entryOff + 8 <= valueEnd {
                    // Byte 3 is subtitling_type. 0x20-0x24 mark hard-of-hearing
                    // subtitles; 0x30/0x31 mark sign-language interpretation
                    // (ETSI EN 300 468 §6.2.41, table 26).
                    let subType = data[data.startIndex + entryOff + 3]
                    if (0x20...0x24).contains(subType) || subType == 0x30 || subType == 0x31 {
                        info.isHearingImpaired = true
                    }
                    entryOff += 8
                }
            case 0x6A: // DVB AC-3 descriptor
                info.privateKind = .ac3
            default:
                break
            }

            off = valueEnd
        }
        return info
    }

    /// Skip the PES header when a packet's payload begins with 0x000001 start code.
    /// Returns the offset of ES data after the PES header, or nil if the input
    /// doesn't look like a PES start.
    private static func skipPESHeader(_ data: Data, at offset: Int, end: Int) -> Int? {
        guard offset + 9 <= end else { return nil }
        let s = data.startIndex + offset
        guard data[s] == 0x00, data[s + 1] == 0x00, data[s + 2] == 0x01 else { return nil }
        let headerDataLen = Int(data[s + 8])
        let esOffset = offset + 9 + headerDataLen
        return esOffset < end ? esOffset : nil
    }

    // MARK: - Sequence Header

    /// Scan `data[start..<end]` for an MPEG-1/2 video sequence header
    /// (start code 0x000001B3) and return (width, height, fps, bit-rate bps,
    /// display-aspect (width, height)?).
    ///
    /// Sequence header layout after the start code:
    ///   12 bits horizontal_size
    ///   12 bits vertical_size
    ///    4 bits aspect_ratio_information
    ///    4 bits frame_rate_code
    ///   18 bits bit_rate (in 400 bps units)
    ///    1 bit marker
    ///   10 bits vbv_buffer_size
    ///    1 bit constrained_parameters_flag
    private static func findSequenceHeader(_ data: Data, from start: Int, end: Int)
        -> (Int, Int, Double, Int, (Int, Int)?)?
    {
        let bound = min(end, data.count)
        guard start >= 0, start + 4 <= bound else { return nil }

        var i = start
        let raw = data
        while i + 4 <= bound {
            if raw[raw.startIndex + i] == 0x00
                && raw[raw.startIndex + i + 1] == 0x00
                && raw[raw.startIndex + i + 2] == 0x01
                && raw[raw.startIndex + i + 3] == 0xB3 {
                let headerStart = i + 4
                guard headerStart + 8 <= bound else { return nil }
                let b0 = raw[raw.startIndex + headerStart]
                let b1 = raw[raw.startIndex + headerStart + 1]
                let b2 = raw[raw.startIndex + headerStart + 2]
                let b3 = raw[raw.startIndex + headerStart + 3]
                let b4 = raw[raw.startIndex + headerStart + 4]
                let b5 = raw[raw.startIndex + headerStart + 5]
                let b6 = raw[raw.startIndex + headerStart + 6]

                let width = (Int(b0) << 4) | Int(b1 >> 4)
                let height = (Int(b1 & 0x0F) << 8) | Int(b2)
                let aspectCode = Int(b3 >> 4)
                let frameRateCode = Int(b3 & 0x0F)
                let bitRate400 = (Int(b4) << 10) | (Int(b5) << 2) | Int(b6 >> 6)

                let fps = frameRate(fromCode: frameRateCode)
                let aspect = displayAspect(
                    width: width,
                    height: height,
                    code: aspectCode
                )
                return (width, height, fps, bitRate400 * 400, aspect)
            }
            i += 1
        }
        return nil
    }

    private static func frameRate(fromCode code: Int) -> Double {
        switch code {
        case 1: return 24000.0 / 1001.0 // 23.976
        case 2: return 24.0
        case 3: return 25.0
        case 4: return 30000.0 / 1001.0 // 29.97
        case 5: return 30.0
        case 6: return 50.0
        case 7: return 60000.0 / 1001.0
        case 8: return 60.0
        default: return 0
        }
    }

    /// MPEG-2 aspect_ratio_information (Table 6-3):
    ///   1 = square pixels (SAR 1:1) → display aspect = width:height
    ///   2 = 4:3 display aspect
    ///   3 = 16:9 display aspect
    ///   4 = 2.21:1 display aspect
    private static func displayAspect(width: Int, height: Int, code: Int) -> (Int, Int)? {
        switch code {
        case 2: return (4, 3)
        case 3: return (16, 9)
        case 4: return (221, 100)
        default: return nil
        }
    }
}
