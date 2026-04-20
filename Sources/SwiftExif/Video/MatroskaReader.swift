import Foundation

/// Reader for Matroska / WebM containers.
///
/// Matroska uses EBML (Extensible Binary Meta Language) framing. Each element
/// is `<vint id><vint length><payload>`, where VINTs are unsigned integers whose
/// length is encoded in a leading marker bit.
///
/// Scope: we pull top-level container facts (duration, timescale), Tracks
/// (video codec, dimensions, frame rate, colour, audio codec/samplerate) and
/// a handful of Segment/Info fields. We do not parse Cluster/BlockGroup data.
public struct MatroskaReader: Sendable {

    private static let ebmlHeaderID: UInt64 = 0x1A45DFA3

    /// Maximum number of bytes to walk when searching an element payload for a
    /// sub-element. Matroska header metadata (Segment/Info + Tracks) is tiny
    /// compared to media data, so a 32 MB window is ample while still bounding
    /// the cost of a malformed file.
    private static let maxHeaderScan = 32 * 1024 * 1024

    /// True when the data begins with the EBML header magic.
    public static func isMatroska(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let s = data.startIndex
        return data[s] == 0x1A && data[s + 1] == 0x45
            && data[s + 2] == 0xDF && data[s + 3] == 0xA3
    }

    public static func parse(_ data: Data) throws -> VideoMetadata {
        guard isMatroska(data) else {
            throw MetadataError.invalidVideo("Not a Matroska file — missing EBML header")
        }

        var format: VideoFormat = .mkv
        var metadata = VideoMetadata(format: format)

        var reader = BinaryReader(data: data)
        while reader.remainingCount >= 2 {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  size <= UInt64(reader.remainingCount) else { break }

            let payloadStart = reader.offset
            switch id {
            case Self.ebmlHeaderID:
                let end = payloadStart + Int(size)
                let docType = readEBMLDocType(data, from: payloadStart, end: end)
                if docType == "webm" { format = .webm }
                if (try? reader.seek(to: end)) == nil { return metadata }

            case 0x18538067: // Segment
                let scanEnd = min(payloadStart + Int(size), payloadStart + maxHeaderScan)
                parseSegment(data, from: payloadStart, end: scanEnd, into: &metadata)
                // Segment is usually the last top-level element — stop after it.
                metadata.format = format
                return metadata

            default:
                if (try? reader.seek(to: payloadStart + Int(size))) == nil { return metadata }
            }
        }

        metadata.format = format
        return metadata
    }

    // MARK: - Segment walker

    private static func parseSegment(
        _ data: Data,
        from start: Int,
        end: Int,
        into metadata: inout VideoMetadata
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        var timestampScale: UInt64 = 1_000_000 // nanoseconds per tick (Matroska default)

        while reader.offset < end, reader.remainingCount >= 2 {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }

            let childStart = reader.offset
            let childEnd = childStart + Int(size)

            switch id {
            case 0x1549A966: // Info
                parseInfo(data, from: childStart, end: childEnd,
                          timestampScale: &timestampScale, into: &metadata)
            case 0x1654AE6B: // Tracks
                parseTracks(data, from: childStart, end: childEnd, into: &metadata)
            case 0x1C53BB6B, 0x1F43B675, 0x1941A469: // Cues, Cluster, Attachments
                break
            default:
                break
            }

            if (try? reader.seek(to: childEnd)) == nil { return }
        }

        // Fold Duration (ticks) × TimestampScale (ns/tick) into seconds.
        if let ticks = metadata.duration {
            metadata.duration = ticks * Double(timestampScale) / 1_000_000_000
        }

        // parseTrackEntry parks DefaultDuration (ns/frame) as a positive value
        // in stream.frameRate; the deprecated Video>FrameRate element is parked
        // as a negative float. Fold both back into positive fps here.
        for i in 0..<metadata.videoStreams.count {
            guard let v = metadata.videoStreams[i].frameRate else { continue }
            if v < 0 {
                metadata.videoStreams[i].frameRate = -v
            } else if v > 0 {
                metadata.videoStreams[i].frameRate = 1_000_000_000.0 / v
            }
        }
        if let fps = metadata.videoStreams.first?.frameRate {
            metadata.frameRate = fps
        }

        // Fill top-level summary fields from the first video/audio stream.
        if let v = metadata.videoStreams.first {
            if metadata.videoWidth == nil { metadata.videoWidth = v.width }
            if metadata.videoHeight == nil { metadata.videoHeight = v.height }
            if metadata.videoCodec == nil { metadata.videoCodec = v.codec }
            if metadata.fieldOrder == nil { metadata.fieldOrder = v.fieldOrder }
            if metadata.colorInfo == nil { metadata.colorInfo = v.colorInfo }
            if metadata.bitDepth == nil { metadata.bitDepth = v.bitDepth }
            if metadata.chromaSubsampling == nil { metadata.chromaSubsampling = v.chromaSubsampling }
            if metadata.displayWidth == nil { metadata.displayWidth = v.displayWidth }
            if metadata.displayHeight == nil { metadata.displayHeight = v.displayHeight }
        }

        // Now that all video streams know their bit depth, fill in conservative
        // defaults for codecs where the bitstream carries the real info.
        for i in 0..<metadata.videoStreams.count {
            let codec = metadata.videoStreams[i].codec ?? ""
            if metadata.videoStreams[i].chromaSubsampling == nil {
                metadata.videoStreams[i].chromaSubsampling = defaultChromaSubsampling(forCodec: codec)
            }
            if metadata.videoStreams[i].bitDepth == nil,
               let depth = defaultBitDepth(forCodec: codec) {
                metadata.videoStreams[i].bitDepth = depth
            }
        }
        if metadata.chromaSubsampling == nil {
            metadata.chromaSubsampling = metadata.videoStreams.first?.chromaSubsampling
        }
        if metadata.bitDepth == nil {
            metadata.bitDepth = metadata.videoStreams.first?.bitDepth
        }

        if let a = metadata.audioStreams.first {
            if metadata.audioCodec == nil { metadata.audioCodec = a.codec }
            if metadata.audioSampleRate == nil { metadata.audioSampleRate = a.sampleRate }
            if metadata.audioChannels == nil { metadata.audioChannels = a.channels }
        }

        // Synthesize channel layouts from counts where the container doesn't
        // provide one explicitly (Matroska rarely does).
        for i in 0..<metadata.audioStreams.count {
            if metadata.audioStreams[i].channelLayout == nil,
               let c = metadata.audioStreams[i].channels {
                metadata.audioStreams[i].channelLayout = defaultLayout(forChannels: c)
            }
        }
    }

    private static func defaultChromaSubsampling(forCodec codec: String) -> String? {
        switch codec {
        case "V_VP8", "V_VP9", "V_AV1", "V_MPEG4/ISO/AVC", "V_MPEGH/ISO/HEVC",
             "V_MPEG4/ISO/ASP", "V_MPEG2", "V_MPEG1":
            return "4:2:0"
        default:
            return nil
        }
    }

    private static func defaultBitDepth(forCodec codec: String) -> Int? {
        switch codec {
        case "V_VP8", "V_MPEG4/ISO/ASP", "V_MPEG2", "V_MPEG1":
            return 8
        default:
            return nil
        }
    }

    private static func chromaLabelFor(x: UInt64, y: UInt64) -> String? {
        switch (x, y) {
        case (2, 2): return "4:2:0"
        case (2, 1): return "4:2:2"
        case (1, 1): return "4:4:4"
        case (0, 0): return nil
        default: return nil
        }
    }

    private static func defaultLayout(forChannels n: Int) -> String? {
        switch n {
        case 1: return "mono"
        case 2: return "stereo"
        case 3: return "2.1"
        case 4: return "4.0"
        case 5: return "5.0"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return n > 0 ? "\(n) channels" : nil
        }
    }

    private static func parseInfo(
        _ data: Data,
        from start: Int,
        end: Int,
        timestampScale: inout UInt64,
        into metadata: inout VideoMetadata
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }

            let valueStart = reader.offset
            switch id {
            case 0x2AD7B1: // TimestampScale (uint)
                if let v = readUIntPayload(data, offset: valueStart, size: Int(size)) {
                    timestampScale = v
                }
            case 0x4489: // Duration (float)
                if let v = readFloatPayload(data, offset: valueStart, size: Int(size)) {
                    metadata.duration = v
                }
            case 0x7BA9: // Title (utf8)
                if let v = readStringPayload(data, offset: valueStart, size: Int(size)) {
                    metadata.title = v
                }
            case 0x4D80: // MuxingApp (utf8)
                break
            case 0x5741: // WritingApp (utf8)
                break
            case 0x4461: // DateUTC (int, ns since 2001-01-01)
                if let ns = readSIntPayload(data, offset: valueStart, size: Int(size)) {
                    // Matroska epoch is 2001-01-01 00:00:00 UTC.
                    let mkvEpoch = Date(timeIntervalSince1970: 978_307_200)
                    metadata.creationDate = Date(timeInterval: TimeInterval(ns) / 1_000_000_000,
                                                  since: mkvEpoch)
                }
            default:
                break
            }

            if (try? reader.seek(to: valueStart + Int(size))) == nil { return }
        }
    }

    private static func parseTracks(
        _ data: Data,
        from start: Int,
        end: Int,
        into metadata: inout VideoMetadata
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }

            let entryStart = reader.offset
            let entryEnd = entryStart + Int(size)

            if id == 0xAE {
                parseTrackEntry(data, from: entryStart, end: entryEnd, into: &metadata)
            }

            if (try? reader.seek(to: entryEnd)) == nil { return }
        }
    }

    private static func parseTrackEntry(
        _ data: Data,
        from start: Int,
        end: Int,
        into metadata: inout VideoMetadata
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        var trackType: UInt64 = 0
        var codecID: String?
        var defaultDurationNs: UInt64 = 0
        var language: String?
        var trackName: String?
        var flagDefault: Bool?
        var flagForced: Bool?
        var flagHearingImpaired: Bool?
        var videoBlockStart: Int?
        var videoBlockEnd: Int?
        var audioBlockStart: Int?
        var audioBlockEnd: Int?

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)

            switch id {
            case 0x83: // TrackType
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    trackType = v
                }
            case 0x86: // CodecID
                codecID = readStringPayload(data, offset: vStart, size: vSize)
            case 0x23E383: // DefaultDuration (uint, ns)
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    defaultDurationNs = v
                }
            case 0x22B59C: // Language (ASCII)
                language = readStringPayload(data, offset: vStart, size: vSize)
            case 0x536E: // Name (UTF-8)
                trackName = readStringPayload(data, offset: vStart, size: vSize)
            case 0x88: // FlagDefault
                if let v = readUIntPayload(data, offset: vStart, size: vSize) { flagDefault = v != 0 }
            case 0x55AA: // FlagForced
                if let v = readUIntPayload(data, offset: vStart, size: vSize) { flagForced = v != 0 }
            case 0x55AB: // FlagHearingImpaired (Matroska v4)
                if let v = readUIntPayload(data, offset: vStart, size: vSize) { flagHearingImpaired = v != 0 }
            case 0xE0: // Video (master)
                videoBlockStart = vStart
                videoBlockEnd = vStart + vSize
            case 0xE1: // Audio (master)
                audioBlockStart = vStart
                audioBlockEnd = vStart + vSize
            default:
                break
            }

            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }

        switch trackType {
        case 1: // Video
            var stream = VideoStream(index: metadata.videoStreams.count)
            stream.codec = codecID
            stream.codecName = codecLongNameMatroska(codecID)
            if let s = videoBlockStart, let e = videoBlockEnd {
                parseVideoBlock(data, from: s, end: e, into: &stream)
            }
            // Store DefaultDuration as ns for now; parseSegment converts to fps
            // after this finishes so we know the Segment's TimestampScale.
            if defaultDurationNs > 0 {
                stream.frameRate = Double(defaultDurationNs)
            }
            metadata.videoStreams.append(stream)

        case 2: // Audio
            var stream = AudioStream(index: metadata.audioStreams.count)
            stream.codec = codecID
            stream.codecName = codecLongNameMatroska(codecID)
            stream.language = language
            if let s = audioBlockStart, let e = audioBlockEnd {
                parseAudioBlock(data, from: s, end: e, into: &stream)
            }
            metadata.audioStreams.append(stream)

        case 0x11: // Subtitle (Matroska TrackType value 17)
            var stream = SubtitleStream(index: metadata.subtitleStreams.count)
            stream.codec = codecID
            stream.codecName = subtitleLongNameMatroska(codecID)
            stream.language = language
            stream.title = trackName
            stream.isDefault = flagDefault
            stream.isForced = flagForced
            stream.isHearingImpaired = flagHearingImpaired
            metadata.subtitleStreams.append(stream)

        default:
            break
        }
    }

    private static func subtitleLongNameMatroska(_ id: String?) -> String? {
        guard let id else { return nil }
        switch id {
        case "S_TEXT/UTF8": return "SubRip (SRT)"
        case "S_TEXT/ASCII": return "Plain text"
        case "S_TEXT/SSA": return "SSA"
        case "S_TEXT/ASS": return "ASS"
        case "S_TEXT/USF": return "Universal Subtitle Format"
        case "S_TEXT/WEBVTT": return "WebVTT"
        case "S_VOBSUB": return "VobSub"
        case "S_HDMV/PGS": return "PGS (Blu-ray)"
        case "S_HDMV/TEXTST": return "HDMV Text Subtitles"
        case "S_KATE": return "Kate"
        case "S_IMAGE/BMP": return "Image Subtitles (BMP)"
        default: return id
        }
    }

    /// Parse the `Video` master element.
    private static func parseVideoBlock(
        _ data: Data,
        from start: Int,
        end: Int,
        into stream: inout VideoStream
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)

            switch id {
            case 0xB0: // PixelWidth
                if let v = readUIntPayload(data, offset: vStart, size: vSize) { stream.width = Int(v) }
            case 0xBA: // PixelHeight
                if let v = readUIntPayload(data, offset: vStart, size: vSize) { stream.height = Int(v) }
            case 0x54B0: // DisplayWidth
                if let v = readUIntPayload(data, offset: vStart, size: vSize) { stream.displayWidth = Int(v) }
            case 0x54BA: // DisplayHeight
                if let v = readUIntPayload(data, offset: vStart, size: vSize) { stream.displayHeight = Int(v) }
            case 0x9A: // FlagInterlaced (0=undetermined,1=interlaced,2=progressive)
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    if stream.fieldOrder == nil {
                        stream.fieldOrder = (v == 2) ? .progressive : (v == 1) ? .unknown : nil
                    }
                }
            case 0x9D: // FieldOrder (0=progressive,1=tff,6=bff,9=tff(swapped),14=bff(swapped))
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    switch v {
                    case 0: stream.fieldOrder = .progressive
                    case 1, 9: stream.fieldOrder = .topFieldFirst
                    case 6, 14: stream.fieldOrder = .bottomFieldFirst
                    default: stream.fieldOrder = .unknown
                    }
                }
            case 0x55B0: // Colour (master)
                var info = stream.colorInfo ?? VideoColorInfo()
                var chroma: (x: UInt64, y: UInt64)?
                parseMatroskaColour(data, from: vStart, end: vStart + vSize,
                                    info: &info, chroma: &chroma)
                stream.colorInfo = info
                if let ch = chroma {
                    stream.chromaSubsampling = chromaLabelFor(x: ch.x, y: ch.y)
                }
            case 0x2383E3: // FrameRate (deprecated float fps; keep only if nothing better)
                if stream.frameRate == nil,
                   let v = readFloatPayload(data, offset: vStart, size: vSize) {
                    // Encoded directly as fps (not ns) — flag by using negative marker.
                    // parseSegment converts positive values (ns) → fps; negative we negate.
                    stream.frameRate = -v
                }
            default:
                break
            }

            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }
    }

    private static func parseMatroskaColour(
        _ data: Data,
        from start: Int,
        end: Int,
        info: inout VideoColorInfo,
        chroma: inout (x: UInt64, y: UInt64)?
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            switch id {
            case 0x55B1: // MatrixCoefficients
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    info.matrix = Int(v)
                }
            case 0x55B9: // Range (0=unspec,1=broadcast,2=full,3=derived)
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    if v == 2 { info.fullRange = true }
                    else if v == 1 { info.fullRange = false }
                }
            case 0x55BA: // TransferCharacteristics
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    info.transfer = Int(v)
                }
            case 0x55BB: // Primaries
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    info.primaries = Int(v)
                }
            case 0x55B4: // ChromaSubsamplingHorz (# of samples to combine horizontally)
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    var c = chroma ?? (x: 0, y: 0)
                    c.x = v
                    chroma = c
                }
            case 0x55B5: // ChromaSubsamplingVert
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    var c = chroma ?? (x: 0, y: 0)
                    c.y = v
                    chroma = c
                }
            default:
                break
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }
    }

    private static func parseAudioBlock(
        _ data: Data,
        from start: Int,
        end: Int,
        into stream: inout AudioStream
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            switch id {
            case 0xB5: // SamplingFrequency (float)
                if let v = readFloatPayload(data, offset: vStart, size: vSize) {
                    stream.sampleRate = Int(v)
                }
            case 0x9F: // Channels
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    stream.channels = Int(v)
                }
            case 0x6264: // BitDepth
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    stream.bitDepth = Int(v)
                }
            default:
                break
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }
    }

    // MARK: - EBML primitives

    /// Read an EBML element ID (VINT with the marker bits preserved).
    static func readEBMLID(_ reader: inout BinaryReader) throws -> UInt64 {
        guard reader.remainingCount >= 1 else { throw MetadataError.unexpectedEndOfData }
        let first = try reader.readUInt8()
        guard first != 0 else { throw MetadataError.invalidVideo("EBML ID byte 0") }
        var width = 0
        for i in 0..<8 {
            if first & (0x80 >> i) != 0 {
                width = i + 1
                break
            }
        }
        guard width > 0 else { throw MetadataError.invalidVideo("EBML ID invalid length") }
        var id: UInt64 = UInt64(first)
        for _ in 1..<width {
            let b = try reader.readUInt8()
            id = (id << 8) | UInt64(b)
        }
        return id
    }

    /// Read an EBML VINT (unknown-size sentinel returns nil).
    static func readVINT(_ reader: inout BinaryReader) throws -> UInt64? {
        guard reader.remainingCount >= 1 else { throw MetadataError.unexpectedEndOfData }
        let first = try reader.readUInt8()
        guard first != 0 else { throw MetadataError.invalidVideo("EBML VINT byte 0") }
        var width = 0
        for i in 0..<8 {
            if first & (0x80 >> i) != 0 {
                width = i + 1
                break
            }
        }
        guard width > 0 else { throw MetadataError.invalidVideo("EBML VINT invalid length") }

        let marker = UInt8(0x80) >> (width - 1)
        var value: UInt64 = UInt64(first & ~marker)
        // All-ones payload = unknown size.
        var isUnknown = (value == (1 << (7 - (width - 1))) - 1)
        for _ in 1..<width {
            let b = try reader.readUInt8()
            value = (value << 8) | UInt64(b)
            if b != 0xFF { isUnknown = false }
        }
        return isUnknown ? nil : value
    }

    // MARK: - Payload readers

    private static func readUIntPayload(_ data: Data, offset: Int, size: Int) -> UInt64? {
        guard size > 0, size <= 8, offset + size <= data.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<size {
            value = (value << 8) | UInt64(data[data.startIndex + offset + i])
        }
        return value
    }

    private static func readSIntPayload(_ data: Data, offset: Int, size: Int) -> Int64? {
        guard let u = readUIntPayload(data, offset: offset, size: size), size > 0 else { return nil }
        let shift = 64 - size * 8
        let signed = Int64(bitPattern: u << shift) >> shift
        return signed
    }

    private static func readFloatPayload(_ data: Data, offset: Int, size: Int) -> Double? {
        guard offset + size <= data.count else { return nil }
        if size == 4 {
            let bits = (UInt32(data[data.startIndex + offset]) << 24)
                | (UInt32(data[data.startIndex + offset + 1]) << 16)
                | (UInt32(data[data.startIndex + offset + 2]) << 8)
                | UInt32(data[data.startIndex + offset + 3])
            return Double(Float(bitPattern: bits))
        }
        if size == 8 {
            var bits: UInt64 = 0
            for i in 0..<8 {
                bits = (bits << 8) | UInt64(data[data.startIndex + offset + i])
            }
            return Double(bitPattern: bits)
        }
        return nil
    }

    private static func readStringPayload(_ data: Data, offset: Int, size: Int) -> String? {
        guard offset + size <= data.count else { return nil }
        let slice = data[data.startIndex + offset ..< data.startIndex + offset + size]
        // Strip trailing NULs (common in CodecID/Language).
        let trimmed = slice.prefix(while: { $0 != 0 })
        return String(data: Data(trimmed), encoding: .utf8)
    }

    private static func readEBMLDocType(_ data: Data, from start: Int, end: Int) -> String? {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()
        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let s = reader.offset
            let sz = Int(size)
            if id == 0x4282 { // DocType
                return readStringPayload(data, offset: s, size: sz)
            }
            if (try? reader.seek(to: s + sz)) == nil { return nil }
        }
        return nil
    }

    // MARK: - Codec naming

    private static func codecLongNameMatroska(_ id: String?) -> String? {
        guard let id else { return nil }
        switch id {
        case "V_MPEG4/ISO/AVC": return "H.264 / AVC"
        case "V_MPEGH/ISO/HEVC": return "H.265 / HEVC"
        case "V_AV1": return "AV1"
        case "V_VP8": return "VP8"
        case "V_VP9": return "VP9"
        case "V_MPEG4/ISO/ASP": return "MPEG-4 ASP"
        case "V_MPEG2": return "MPEG-2 Video"
        case "V_MPEG1": return "MPEG-1 Video"
        case "V_PRORES": return "Apple ProRes"
        case "V_THEORA": return "Theora"
        case "V_MS/VFW/FOURCC": return "VfW (FourCC)"
        case "A_AAC", "A_AAC/MPEG4/LC", "A_AAC/MPEG4/LC/SBR": return "AAC"
        case "A_AC3": return "Dolby Digital (AC-3)"
        case "A_EAC3": return "Dolby Digital Plus (E-AC-3)"
        case "A_DTS", "A_DTS/EXPRESS", "A_DTS/LOSSLESS": return "DTS"
        case "A_FLAC": return "FLAC"
        case "A_OPUS": return "Opus"
        case "A_VORBIS": return "Vorbis"
        case "A_MPEG/L3": return "MP3"
        case "A_MPEG/L2": return "MP2"
        case "A_PCM/INT/LIT", "A_PCM/INT/BIG", "A_PCM/FLOAT/IEEE": return "PCM"
        case "A_TRUEHD": return "TrueHD"
        default: return id
        }
    }
}
