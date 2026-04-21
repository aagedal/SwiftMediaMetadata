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
        var trackRefs: [TrackRef] = []
        var tagsBlocks: [(start: Int, end: Int)] = []

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
                parseTracks(data, from: childStart, end: childEnd,
                            into: &metadata, refs: &trackRefs)
            case 0x1254C367: // Tags — deferred: the Tag targets reference TrackUIDs
                             // which we only know after Tracks has been walked.
                tagsBlocks.append((childStart, childEnd))
            case 0x1C53BB6B, 0x1F43B675, 0x1941A469: // Cues, Cluster, Attachments
                break
            default:
                break
            }

            if (try? reader.seek(to: childEnd)) == nil { return }
        }

        for (s, e) in tagsBlocks {
            parseTags(data, from: s, end: e, refs: trackRefs, into: &metadata)
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
            if metadata.videoStreams[i].pixelFormat == nil {
                metadata.videoStreams[i].pixelFormat = PixelFormatDerivation.derive(
                    chromaSubsampling: metadata.videoStreams[i].chromaSubsampling,
                    bitDepth: metadata.videoStreams[i].bitDepth,
                    fullRange: metadata.videoStreams[i].colorInfo?.fullRange,
                    codec: codec
                )
            }
            if metadata.videoStreams[i].avgFrameRate == nil,
               let fps = metadata.videoStreams[i].frameRate {
                metadata.videoStreams[i].avgFrameRate = fps
                if metadata.videoStreams[i].rFrameRate == nil {
                    metadata.videoStreams[i].rFrameRate = fps
                }
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

    private enum TrackKind { case video, audio, subtitle }
    private struct TrackRef {
        let uid: UInt64
        let kind: TrackKind
        let index: Int
    }

    private static func parseTracks(
        _ data: Data,
        from start: Int,
        end: Int,
        into metadata: inout VideoMetadata,
        refs: inout [TrackRef]
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
                parseTrackEntry(data, from: entryStart, end: entryEnd,
                                into: &metadata, refs: &refs)
            }

            if (try? reader.seek(to: entryEnd)) == nil { return }
        }
    }

    private static func parseTrackEntry(
        _ data: Data,
        from start: Int,
        end: Int,
        into metadata: inout VideoMetadata,
        refs: inout [TrackRef]
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        var trackType: UInt64 = 0
        var trackUID: UInt64 = 0
        var codecID: String?
        var codecPrivate: Data?
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
            case 0x73C5: // TrackUID
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    trackUID = v
                }
            case 0x86: // CodecID
                codecID = readStringPayload(data, offset: vStart, size: vSize)
            case 0x63A2: // CodecPrivate — codec-specific decoder config
                if vSize > 0, vStart + vSize <= data.count {
                    codecPrivate = Data(
                        data[data.startIndex + vStart ..< data.startIndex + vStart + vSize]
                    )
                }
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
            stream.title = trackName
            if let s = videoBlockStart, let e = videoBlockEnd {
                parseVideoBlock(data, from: s, end: e, into: &stream)
            }
            if let priv = codecPrivate, let id = codecID {
                applyMatroskaCodecPrivate(id: id, data: priv, into: &stream)
            }
            // Store DefaultDuration as ns for now; parseSegment converts to fps
            // after this finishes so we know the Segment's TimestampScale.
            if defaultDurationNs > 0 {
                stream.frameRate = Double(defaultDurationNs)
            }
            if trackUID != 0 {
                refs.append(TrackRef(uid: trackUID, kind: .video, index: stream.index))
            }
            metadata.videoStreams.append(stream)

        case 2: // Audio
            var stream = AudioStream(index: metadata.audioStreams.count)
            stream.codec = codecID
            stream.codecName = codecLongNameMatroska(codecID)
            stream.language = language
            stream.title = trackName
            if let s = audioBlockStart, let e = audioBlockEnd {
                parseAudioBlock(data, from: s, end: e, into: &stream)
            }
            if trackUID != 0 {
                refs.append(TrackRef(uid: trackUID, kind: .audio, index: stream.index))
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
            if trackUID != 0 {
                refs.append(TrackRef(uid: trackUID, kind: .subtitle, index: stream.index))
            }
            metadata.subtitleStreams.append(stream)

        default:
            break
        }
    }

    // MARK: - Tags (per-track SimpleTag values)

    /// Walk `Tags` master: a sequence of `Tag` entries. Each Tag carries a
    /// Targets master (listing one or more TagTrackUIDs) plus any number of
    /// SimpleTag name/value pairs. FFmpeg and mkvtoolnix encode per-track
    /// `BPS`, `DURATION`, `NUMBER_OF_FRAMES`, `NUMBER_OF_BYTES` here — it's
    /// the only place a declared bitrate appears in most MKV/WebM files.
    private static func parseTags(
        _ data: Data,
        from start: Int,
        end: Int,
        refs: [TrackRef],
        into metadata: inout VideoMetadata
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            if id == 0x7373 { // Tag
                parseTag(data, from: vStart, end: vStart + vSize,
                         refs: refs, into: &metadata)
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }
    }

    private static func parseTag(
        _ data: Data,
        from start: Int,
        end: Int,
        refs: [TrackRef],
        into metadata: inout VideoMetadata
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        var targetUIDs: [UInt64] = []
        var simpleTags: [(name: String, value: String)] = []

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            switch id {
            case 0x63C0: // Targets
                targetUIDs = readTagTargetUIDs(data, from: vStart, end: vStart + vSize)
            case 0x67C8: // SimpleTag
                if let pair = readSimpleTag(data, from: vStart, end: vStart + vSize) {
                    simpleTags.append(pair)
                }
            default:
                break
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }

        // A Tag without a TagTrackUID targets the Segment itself — apply its
        // COMMENT/DESCRIPTION/TITLE pairs to the top-level metadata.
        if targetUIDs.isEmpty {
            for (name, value) in simpleTags {
                applySegmentTag(name: name, value: value, in: &metadata)
            }
            return
        }

        for uid in targetUIDs {
            guard let ref = refs.first(where: { $0.uid == uid }) else { continue }
            for (name, value) in simpleTags {
                applyTrackTag(name: name, value: value, to: ref, in: &metadata)
            }
        }
    }

    /// Segment-level SimpleTag → top-level `VideoMetadata` field mapping.
    /// `COMMENT`/`COMMENTS`/`DESCRIPTION` all carry long-form free text;
    /// Matroska muxers use whichever one they feel like, so accept all three.
    private static func applySegmentTag(
        name: String,
        value: String,
        in metadata: inout VideoMetadata
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch name.uppercased() {
        case "COMMENT", "COMMENTS", "DESCRIPTION":
            if metadata.comment == nil { metadata.comment = trimmed }
        case "TITLE":
            if metadata.title == nil { metadata.title = trimmed }
        case "ARTIST", "AUTHOR":
            if metadata.artist == nil { metadata.artist = trimmed }
        default:
            break
        }
    }

    private static func readTagTargetUIDs(_ data: Data, from start: Int, end: Int) -> [UInt64] {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()
        var out: [UInt64] = []
        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            if id == 0x63C5 { // TagTrackUID
                if let v = readUIntPayload(data, offset: vStart, size: vSize), v != 0 {
                    out.append(v)
                }
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { return out }
        }
        return out
    }

    /// Read a SimpleTag's `TagName` + `TagString`. Nested SimpleTags are
    /// ignored — Matroska allows them but no mainstream muxer writes nested
    /// BPS/DURATION.
    private static func readSimpleTag(
        _ data: Data,
        from start: Int,
        end: Int
    ) -> (name: String, value: String)? {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()
        var name: String?
        var value: String?
        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            switch id {
            case 0x45A3: // TagName
                name = readStringPayload(data, offset: vStart, size: vSize)
            case 0x4487: // TagString
                value = readStringPayload(data, offset: vStart, size: vSize)
            default:
                break
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { break }
        }
        guard let n = name, let v = value else { return nil }
        return (n, v)
    }

    private static func applyTrackTag(
        name: String,
        value: String,
        to ref: TrackRef,
        in metadata: inout VideoMetadata
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name.uppercased() {
        case "BPS":
            guard let bps = Int(trimmed), bps > 0 else { return }
            switch ref.kind {
            case .video:
                guard ref.index < metadata.videoStreams.count else { return }
                if metadata.videoStreams[ref.index].bitRate == nil {
                    metadata.videoStreams[ref.index].bitRate = bps
                }
            case .audio:
                guard ref.index < metadata.audioStreams.count else { return }
                if metadata.audioStreams[ref.index].bitRate == nil {
                    metadata.audioStreams[ref.index].bitRate = bps
                }
            case .subtitle:
                break // SubtitleStream has no bitRate.
            }
        case "NUMBER_OF_FRAMES":
            guard let n = Int(trimmed), n > 0 else { return }
            if ref.kind == .video, ref.index < metadata.videoStreams.count,
               metadata.videoStreams[ref.index].frameCount == nil {
                metadata.videoStreams[ref.index].frameCount = n
            }
        default:
            break
        }
    }

    /// Apply Matroska `CodecPrivate` bytes to a video stream when the codec
    /// carries a known decoder-configuration record. The bytes are identical
    /// to the corresponding ISOBMFF boxes (hvcC / avcC / av1C), so we read the
    /// same offsets here — profile/bit-depth/chroma surface without pulling
    /// in the full MP4 parser.
    private static func applyMatroskaCodecPrivate(
        id: String,
        data: Data,
        into stream: inout VideoStream
    ) {
        switch id {
        case "V_MPEGH/ISO/HEVC":
            // Same bytes as MP4 hvcC.
            guard data.count >= 23 else { return }
            let s = data.startIndex
            let profileIDC = Int(data[s + 1] & 0x1F)
            let chromaFormatIDC = Int(data[s + 16] & 0x03)
            let bitDepth = Int(data[s + 17] & 0x07) + 8
            if stream.profile == nil {
                stream.profile = hevcProfileLabel(
                    profileIDC: profileIDC,
                    chromaFormatIDC: chromaFormatIDC,
                    bitDepth: bitDepth
                )
            }
            if stream.bitDepth == nil {
                stream.bitDepth = bitDepth
            }
            if stream.chromaSubsampling == nil {
                switch chromaFormatIDC {
                case 0: stream.chromaSubsampling = "4:0:0"
                case 1: stream.chromaSubsampling = "4:2:0"
                case 2: stream.chromaSubsampling = "4:2:2"
                case 3: stream.chromaSubsampling = "4:4:4"
                default: break
                }
            }

        case "V_MPEG4/ISO/AVC":
            // Same bytes as MP4 avcC — profile lives at byte 1.
            guard data.count >= 4 else { return }
            let profileIDC = data[data.startIndex + 1]
            if stream.profile == nil {
                stream.profile = avcProfileLabel(profileIDC)
            }
            if stream.bitDepth == nil { stream.bitDepth = 8 }
            if stream.chromaSubsampling == nil { stream.chromaSubsampling = "4:2:0" }

        case "V_AV1":
            // Same bytes as MP4 av1C.
            guard data.count >= 3 else { return }
            let byte1 = data[data.startIndex + 1]
            let byte2 = data[data.startIndex + 2]
            let seqProfile = Int((byte1 & 0xE0) >> 5)
            let highBitDepth = (byte2 >> 6) & 0x01
            let twelveBit = (byte2 >> 5) & 0x01
            let monochrome = (byte2 >> 4) & 0x01
            let ssx = (byte2 >> 3) & 0x01
            let ssy = (byte2 >> 2) & 0x01

            if stream.bitDepth == nil {
                stream.bitDepth = twelveBit == 1 ? 12 : (highBitDepth == 1 ? 10 : 8)
            }
            if stream.chromaSubsampling == nil {
                if monochrome == 1 {
                    stream.chromaSubsampling = "4:0:0"
                } else if ssx == 1 && ssy == 1 {
                    stream.chromaSubsampling = "4:2:0"
                } else if ssx == 1 && ssy == 0 {
                    stream.chromaSubsampling = "4:2:2"
                } else if ssx == 0 && ssy == 0 {
                    stream.chromaSubsampling = "4:4:4"
                }
            }
            if stream.profile == nil {
                switch seqProfile {
                case 0: stream.profile = "Main"
                case 1: stream.profile = "High"
                case 2: stream.profile = "Professional"
                default: break
                }
            }

        default:
            break
        }
    }

    /// HEVC profile_idc → label. Mirrors MP4Parser.hevcProfileName — duplicated
    /// here to keep MatroskaReader self-contained rather than depending on
    /// ISOBMFF internals.
    private static func hevcProfileLabel(profileIDC: Int, chromaFormatIDC: Int, bitDepth: Int) -> String? {
        switch profileIDC {
        case 1: return "Main"
        case 2: return "Main 10"
        case 3: return "Main Still Picture"
        case 4:
            let chroma: String
            switch chromaFormatIDC {
            case 0: return "Monochrome \(bitDepth)"
            case 1: chroma = "4:2:0"
            case 2: chroma = "4:2:2"
            case 3: chroma = "4:4:4"
            default: return "Range Extensions"
            }
            return "Main \(chroma) \(bitDepth)"
        default: return nil
        }
    }

    /// AVC profile_idc → label. Mirrors MP4Parser.avcProfileName.
    private static func avcProfileLabel(_ profileIDC: UInt8) -> String? {
        switch profileIDC {
        case 66: return "Constrained Baseline"
        case 77: return "Main"
        case 88: return "Extended"
        case 100: return "High"
        case 110: return "High 10"
        case 122: return "High 4:2:2"
        case 244: return "High 4:4:4 Predictive"
        default: return nil
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
            case 0x55B2: // BitsPerChannel (per-component bit depth, matches ffprobe bits_per_raw_sample)
                if let v = readUIntPayload(data, offset: vStart, size: vSize), v > 0 {
                    stream.bitDepth = Int(v)
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
                var siting: (h: UInt64?, v: UInt64?) = (nil, nil)
                parseMatroskaColour(data, from: vStart, end: vStart + vSize,
                                    info: &info, chroma: &chroma, siting: &siting)
                stream.colorInfo = info
                if let ch = chroma {
                    stream.chromaSubsampling = chromaLabelFor(x: ch.x, y: ch.y)
                }
                if let loc = chromaLocationLabel(horz: siting.h, vert: siting.v) {
                    stream.chromaLocation = loc
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
        chroma: inout (x: UInt64, y: UInt64)?,
        siting: inout (h: UInt64?, v: UInt64?)
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
            case 0x55B7: // ChromaSitingHorz
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    siting.h = v
                }
            case 0x55B8: // ChromaSitingVert
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    siting.v = v
                }
            default:
                break
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }
    }

    /// Matroska ChromaSitingHorz/Vert values map to ffprobe chroma_location:
    ///   Horz 1 + Vert 1  → left
    ///   Horz 1 + Vert 2  → topleft
    ///   Horz 1 + Vert 3  → bottomleft (rare)
    ///   Horz 2 + Vert 1  → center
    ///   Horz 2 + Vert 2  → top
    ///   Horz 2 + Vert 3  → bottom
    /// Values of 0 are "unspecified" and we treat them as unknown.
    private static func chromaLocationLabel(horz: UInt64?, vert: UInt64?) -> String? {
        guard let h = horz, let v = vert, h != 0, v != 0 else { return nil }
        switch (h, v) {
        case (1, 1): return "left"
        case (1, 2): return "topleft"
        case (1, 3): return "bottomleft"
        case (2, 1): return "center"
        case (2, 2): return "top"
        case (2, 3): return "bottom"
        default: return nil
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
