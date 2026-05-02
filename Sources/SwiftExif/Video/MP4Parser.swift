import Foundation

/// Parses MP4/MOV/M4V video files to extract metadata.
/// Reuses ISOBMFFBoxReader for box-level parsing.
public struct MP4Parser: Sendable {

    // Seconds between 1904-01-01 and 1970-01-01 (QuickTime epoch to Unix epoch)
    private static let epochOffset: TimeInterval = 2082844800

    // XMP UUID prefix: BE7ACFCB-97A9-42E8-9C71-999491E3AFAC
    static let xmpUUID = Data([
        0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8,
        0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC,
    ])

    /// Parse video metadata from data.
    public static func parse(_ data: Data) throws -> VideoMetadata {
        // Parse top-level boxes, but skip mdat payload to save memory
        let boxes = try parseTopLevelBoxes(data)

        // Determine format from ftyp. Legacy QuickTime / Blackmagic RAW files
        // omit ftyp entirely (the file starts with `wide` + `mdat`, with the
        // moov tail-placed); fall back to .mov so the rest of the parse can
        // proceed. Callers that know the extension override metadata.format
        // to a more specific value (e.g. .braw) afterwards.
        let format: VideoFormat
        if let ftyp = boxes.first(where: { $0.type == "ftyp" }) {
            format = detectFormat(from: ftyp)
        } else {
            format = .mov
        }

        var metadata = VideoMetadata(format: format)

        // Find moov box
        guard let moov = boxes.first(where: { $0.type == "moov" }) else {
            throw MetadataError.invalidVideo("Missing moov box")
        }
        let moovChildren = try ISOBMFFBoxReader.parseBoxes(from: moov.data)

        // Parse mvhd (movie header). Returns the movie timescale, which is
        // needed later by `edts > elst` entries (their segment_duration field
        // is expressed in movie timescale, not media timescale).
        var movieTimescale: UInt32 = 0
        if let mvhd = moovChildren.first(where: { $0.type == "mvhd" }) {
            movieTimescale = parseMVHD(mvhd.data, into: &metadata)
        }

        // Pre-compute the set of track IDs that serve as QuickTime chapter
        // text tracks — they're the target of any `tref > chap` reference
        // anywhere in the movie. Must be excluded from `subtitleStreams`
        // (ffprobe filters them the same way: `-select_streams s` returns
        // zero even though the handler is "text"/"subt").
        //
        // The reference can live on any trak — DaVinci Resolve writes it on
        // video + audio + every subtitle track; ffmpeg's mov muxer writes it
        // on audio + subtitles but NOT on the video track. Scan them all.
        var chapterReferencedTrackIDs = Set<UInt32>()
        for trak in moovChildren where trak.type == "trak" {
            for tid in parseTrefChap(trak.data) {
                chapterReferencedTrackIDs.insert(tid)
            }
        }

        // Parse tracks
        for trak in moovChildren.filter({ $0.type == "trak" }) {
            parseTrak(
                trak.data,
                movieTimescale: movieTimescale,
                chapterTrackIDs: chapterReferencedTrackIDs,
                into: &metadata
            )
        }

        // QuickTime timecode track (`tmcd`): the sample entry in stsd gives
        // the frame rate + drop-frame flag and the first media sample in mdat
        // is a 32-bit frame counter. Needs the original data blob for the
        // mdat read, so we walk the trak list here rather than in parseTrak.
        //
        // ffprobe surfaces the decoded timecode in two places: the clip-level
        // `format.tags.timecode` (via the first tmcd track) and, per stream,
        // the video track that cross-references a tmcd track via `tref.tmcd`.
        // Mirror that behaviour here.
        var tmcdTimecodes: [UInt32: String] = [:]
        for trak in moovChildren.filter({ $0.type == "trak" }) {
            guard trakHandlerType(trak.data) == "tmcd",
                  let tid = parseTKHDTrackID(trak.data),
                  let tc = parseTmcdTrackTimecode(trak.data, fullData: data) else { continue }
            tmcdTimecodes[tid] = tc
        }
        if !tmcdTimecodes.isEmpty {
            // Record the first tmcd-track value as the clip-level primary.
            // Using `recordTimecode` keeps the `timecodes` provenance array
            // and the legacy scalar `timecode` field in sync.
            if let first = tmcdTimecodes.first?.value {
                metadata.recordTimecode(first, source: .tmcdTrack)
            }
            // ffprobe only sets the per-stream `timecode` tag on a video track
            // when that track has an explicit `tref > tmcd` reference to a
            // timecode track. Recordings without the cross-reference (e.g.
            // Atomos Ninja ProRes RAW) surface timecode only at
            // `format.tags.timecode`. Mirror that exactly — no fallback.
            var videoIdx = 0
            for trak in moovChildren.filter({ $0.type == "trak" }) {
                guard trakHandlerType(trak.data) == "vide" else { continue }
                defer { videoIdx += 1 }
                guard videoIdx < metadata.videoStreams.count,
                      metadata.videoStreams[videoIdx].timecode == nil else { continue }
                let refs = parseTrefTmcd(trak.data)
                if let tid = refs.first(where: { tmcdTimecodes[$0] != nil }),
                   let tc = tmcdTimecodes[tid] {
                    metadata.videoStreams[videoIdx].timecode = tc
                    // Flag disagreement between this video track's
                    // tref-linked tmcd and the clip-level primary. ffprobe
                    // reports both values in its streams/format blocks;
                    // we mirror that plus a warning so callers can act on
                    // the divergence rather than silently picking one.
                    if let clip = metadata.timecode, clip != tc {
                        metadata.warnings.append(
                            "timecode mismatch: clip=\(clip) vs videoStream[\(videoIdx)]=\(tc)"
                        )
                    }
                }
            }
        }

        // Blackmagic RAW: the per-frame interpretation header at the start
        // of every video chunk in mdat carries clip-level defaults that
        // aren't in moov.meta — ISO equivalent (`isoe`), white-balance
        // Kelvin (`wkel`), and white-balance tint (`wtin`). The values are
        // identical for every frame in the clips we've inspected (camera
        // bakes them once at record-start), so reading frame 0 is enough.
        for trak in moovChildren.filter({ $0.type == "trak" }) {
            guard trakHandlerType(trak.data) == "vide" else { continue }
            parseBRAWFirstFrameAttributes(
                trak.data, fullData: data, into: &metadata
            )
        }

        // Chapter markers. Two paths, both standard:
        //   1. QuickTime text-track chapters — the video track carries
        //      `tref > chap` pointing at one or more text/subt tracks whose
        //      samples are the chapter titles. Apple's QuickTime, Compressor,
        //      and iTunes all write this form.
        //   2. Nero-style `udta > chpl` — a flat list of (start, title) pairs
        //      written by x264/ffmpeg/MP4Box pipelines.
        // ffprobe reports whichever is present; when both exist the chap
        // track wins (per-sample granularity beats a flat list). Mirror that.
        let chapterTracks = parseChapterTracks(moovChildren, fullData: data)
        if !chapterTracks.isEmpty {
            metadata.chapters = chapterTracks
        } else if let udta = moovChildren.first(where: { $0.type == "udta" }),
                  let chpl = (try? ISOBMFFBoxReader.parseBoxes(from: udta.data))?
                      .first(where: { $0.type == "chpl" }) {
            metadata.chapters = parseCHPL(chpl.data)
        }

        // Parse udta -> meta -> ilst (QuickTime metadata)
        if let udta = moovChildren.first(where: { $0.type == "udta" }) {
            parseUDTA(udta.data, into: &metadata)
        }

        // Some writers place mdta-style metadata directly under `moov` rather
        // than wrapped in `udta` — Blackmagic RAW does this with its full
        // camera/clip slate (camera_type, viewing_gamma, offspeed_frame_time …).
        // ffmpeg's mov demuxer reads this same shape.
        if let meta = moovChildren.first(where: { $0.type == "meta" }) {
            parseMetaBox(meta.data, into: &metadata)
        }

        // Check for top-level meta box (some files put XMP here)
        if let meta = boxes.first(where: { $0.type == "meta" }) {
            parseMetaBox(meta.data, into: &metadata)
        }

        // Check for XMP in uuid boxes
        for uuid in boxes.filter({ $0.type == "uuid" }) {
            parseUUIDBox(uuid.data, into: &metadata)
        }

        // Once XMP has been attached (via ilst, top-level meta, or the XMP
        // uuid), pull xmpDM:startTimeCode / altTimeCode out and record them
        // as provenance-tagged timecodes. A mismatch with an already-recorded
        // tmcd/udta value surfaces as a `warnings` entry.
        metadata.ingestXMPTimecodes()
        // Sony NRT blobs arrive via the NRT uuid box above; fold any start
        // timecode into the provenance array the same way.
        metadata.ingestNRTTimecode()

        // Parse C2PA manifest store if present (top-level jumb or uuid-wrapped JUMBF).
        if let jumbfData = C2PAReader.extractJUMBFFromISOBMFF(boxes) {
            do {
                if let c2pa = try C2PAReader.parseManifestStore(from: jumbfData) {
                    metadata.c2pa = c2pa
                }
            } catch {
                metadata.warnings.append("C2PA parse error: \(error)")
            }
        }

        // Derive ffprobe-compatible fields the parser can't read directly:
        // color range / chroma siting defaults, pixelFormat, avg/rFrameRate.
        for i in 0..<metadata.videoStreams.count {
            // ISOBMFF color: when no `colr` box is present, ffprobe assumes
            // limited-range YUV ("tv") for the H.264/H.265/AV1/VP9 codecs that
            // dominate Apple/Adobe pipelines, and tv for ProRes too. Mirror
            // that behaviour so JSON output isn't blank on every other clip.
            if isLimitedRangeDefaultCodec(metadata.videoStreams[i].codec) {
                if metadata.videoStreams[i].colorInfo == nil {
                    metadata.videoStreams[i].colorInfo = VideoColorInfo(fullRange: false)
                } else if metadata.videoStreams[i].colorInfo?.fullRange == nil {
                    metadata.videoStreams[i].colorInfo?.fullRange = false
                }
            }
            // Chroma siting: ffprobe surfaces a default for the H.264/HEVC
            // family when the bitstream omits chroma_sample_loc_type — "left"
            // for 4:2:0 (matches MPEG-2/AVC), "topleft" for APV. AV1/VP9
            // routinely report nothing here, so we leave them alone rather
            // than fabricating a value.
            if metadata.videoStreams[i].chromaLocation == nil,
               let codec = metadata.videoStreams[i].codec {
                switch codec {
                case "avc1", "avc3",
                     "hvc1", "hev1", "hev2", "dvh1", "dvhe":
                    if metadata.videoStreams[i].chromaSubsampling == "4:2:0" {
                        metadata.videoStreams[i].chromaLocation = "left"
                    }
                case "apv1":
                    metadata.videoStreams[i].chromaLocation = "topleft"
                default:
                    break
                }
            }
            if metadata.videoStreams[i].pixelFormat == nil {
                metadata.videoStreams[i].pixelFormat = PixelFormatDerivation.derive(
                    chromaSubsampling: metadata.videoStreams[i].chromaSubsampling,
                    bitDepth: metadata.videoStreams[i].bitDepth,
                    fullRange: metadata.videoStreams[i].colorInfo?.fullRange,
                    codec: metadata.videoStreams[i].codec
                )
            }
            if metadata.videoStreams[i].avgFrameRate == nil,
               let fps = metadata.videoStreams[i].frameRate {
                metadata.videoStreams[i].avgFrameRate = fps
                if metadata.videoStreams[i].rFrameRate == nil {
                    metadata.videoStreams[i].rFrameRate = fps
                }
            }
            // Pixel/display aspect ratio: default to square pixels when no
            // pasp box was present and tkhd didn't override. ffprobe always
            // emits SAR/DAR for video tracks.
            if let w = metadata.videoStreams[i].width,
               let h = metadata.videoStreams[i].height, w > 0, h > 0 {
                if metadata.videoStreams[i].displayWidth == nil {
                    metadata.videoStreams[i].displayWidth = w
                }
                if metadata.videoStreams[i].displayHeight == nil {
                    metadata.videoStreams[i].displayHeight = h
                }
                if metadata.videoStreams[i].pixelAspectRatio == nil,
                   let dw = metadata.videoStreams[i].displayWidth,
                   let dh = metadata.videoStreams[i].displayHeight, dw > 0, dh > 0 {
                    let parNum = dw * h
                    let parDen = dh * w
                    let g = gcdMP4(parNum, parDen)
                    metadata.videoStreams[i].pixelAspectRatio = (parNum / g, parDen / g)
                }
            }
            // Default-track flag: ISOBMFF doesn't have a per-track "default"
            // bit the way Matroska does, so ffprobe marks only the first track
            // of each kind as default. Match that.
            if metadata.videoStreams[i].isDefault == nil {
                metadata.videoStreams[i].isDefault = (i == 0)
            }
            if metadata.videoStreams[i].isAttachedPic == nil {
                metadata.videoStreams[i].isAttachedPic = false
            }
        }
        // Mirror per-stream PAR/DAR up to top-level metadata.
        if let v = metadata.videoStreams.first {
            if metadata.pixelAspectRatio == nil { metadata.pixelAspectRatio = v.pixelAspectRatio }
            if metadata.displayWidth == nil { metadata.displayWidth = v.displayWidth }
            if metadata.displayHeight == nil { metadata.displayHeight = v.displayHeight }
        }
        for i in 0..<metadata.audioStreams.count {
            if metadata.audioStreams[i].isDefault == nil {
                metadata.audioStreams[i].isDefault = (i == 0)
            }
        }

        // Format-level duration: keep mvhd, but cap it at max(audio, video
        // stream durations) if mvhd is larger. Real-world files routinely
        // declare mvhd as the longest mdhd of *any* track, including subtitle
        // / chapter tracks whose declared length exceeds the playable a/v
        // essence — ChapterMarkerDualSubtitle.mp4 has subtitle2 mdhd=98.691s
        // but audio/video both end at ~71.16s, and ffprobe reports 71.146s.
        // We don't blindly use max(av) instead, because for healthy files
        // mvhd is *smaller* than the longest av stream (mvhd respects the
        // edit-list-trimmed window while audio mdhd reports the raw essence)
        // and ffprobe still prefers the mvhd value in that case.
        let avDurations = metadata.videoStreams.compactMap(\.duration)
                        + metadata.audioStreams.compactMap(\.duration)
        if let avMax = avDurations.max(), avMax > 0,
           let mvhd = metadata.duration, mvhd > avMax {
            metadata.duration = avMax
        }

        // Container bit_rate fallback (matches ffprobe `format.bit_rate`).
        let containerBytes = metadata.fileSize ?? Int64(data.count)
        if metadata.bitRate == nil,
           let dur = metadata.duration, dur > 0, containerBytes > 0 {
            metadata.bitRate = Int(Double(containerBytes) * 8.0 / dur)
        }

        // Sony RTMD summary — populated when an `rtmd` timed-metadata track
        // is present (Alpha A1 / A7S III / FX3 / FX30 etc). Reads only the
        // first rtmd sample, so it stays cheap. Per-frame harvest lives
        // behind the `rtmd-frames` CLI subcommand.
        if RTMDReader.hasRTMDTrack(in: data) {
            metadata.rtmd = RTMDSummary(
                imuSampleRateHz: RTMDReader.estimateIMUSampleRate(in: data),
                firstFrame: RTMDReader.firstFrameSnapshot(from: data)
            )
        }

        return metadata
    }

    /// ISOBMFF audio FourCCs that carry uncompressed PCM samples. Their bit
    /// rate is deterministic (sample_rate × channels × bit_depth), so we
    /// prefer that formula over stsz-sum-over-duration which introduces tiny
    /// rounding noise from the final partial sample.
    static func isUncompressedPCMCodec(_ codec: String) -> Bool {
        switch codec {
        case "sowt", "twos", "lpcm", "ipcm", "in24", "in32",
             "fl32", "fl64", "raw ", "NONE":
            return true
        default:
            return false
        }
    }

    private static func gcdMP4(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }

    /// Codecs that ffprobe treats as limited-range YUV ("tv") when no explicit
    /// color_range box is present. Used to fill in `color_range` and the
    /// "left" `chroma_location` default for plain H.264/H.265 clips.
    private static func isLimitedRangeDefaultCodec(_ codec: String?) -> Bool {
        guard let codec else { return false }
        switch codec {
        case "avc1", "avc3",
             "hvc1", "hev1", "hev2", "dvh1", "dvhe",
             "vvc1", "vvi1",
             "av01",
             "vp08", "vp09",
             "apch", "apcn", "apcs", "apco", "ap4h", "ap4x", "apv1",
             "mp4v":
            return true
        default:
            return false
        }
    }

    // MARK: - Top-Level Parsing (skips mdat)

    private static func parseTopLevelBoxes(_ data: Data) throws -> [ISOBMFFBox] {
        var reader = BinaryReader(data: data)
        var boxes: [ISOBMFFBox] = []

        while !reader.isAtEnd && reader.remainingCount >= 8 {
            let boxStart = reader.offset
            let size32 = try reader.readUInt32BigEndian()
            let typeBytes = try reader.readBytes(4)
            guard let type = String(data: typeBytes, encoding: .isoLatin1) else { break }

            let boxSize: Int
            if size32 == 1 {
                guard reader.remainingCount >= 8 else { break }
                let size64 = try reader.readUInt64BigEndian()
                boxSize = Int(size64)
            } else if size32 == 0 {
                boxSize = data.count - boxStart
            } else {
                boxSize = Int(size32)
            }

            let headerSize = (size32 == 1) ? 16 : 8
            let payloadSize = boxSize - headerSize
            guard payloadSize >= 0 else { break }

            if type == "mdat" {
                // Skip mdat payload — can be gigabytes of media data
                let endPos = boxStart + boxSize
                if endPos <= data.count {
                    try reader.seek(to: endPos)
                } else {
                    break // mdat extends to EOF
                }
                boxes.append(ISOBMFFBox(type: "mdat", data: Data()))
            } else {
                guard reader.offset + payloadSize <= data.count else { break }
                let payload = try reader.readBytes(payloadSize)
                boxes.append(ISOBMFFBox(type: type, data: payload))
            }
        }

        return boxes
    }

    // MARK: - Format Detection

    private static func detectFormat(from ftyp: ISOBMFFBox) -> VideoFormat {
        guard ftyp.data.count >= 4 else { return .mp4 }
        let brand = String(data: ftyp.data.prefix(4), encoding: .ascii) ?? ""
        switch brand {
        case "qt  ": return .mov
        case "M4V ", "M4VH", "M4VP": return .m4v
        default: return .mp4
        }
    }

    // MARK: - mvhd (Movie Header)

    @discardableResult
    private static func parseMVHD(_ data: Data, into metadata: inout VideoMetadata) -> UInt32 {
        guard data.count >= 4 else { return 0 }
        var reader = BinaryReader(data: data)

        // FullBox: version (1 byte) + flags (3 bytes)
        guard let version = try? reader.readUInt8() else { return 0 }
        _ = try? reader.readBytes(3) // flags

        if version == 0 {
            // Version 0: 32-bit fields
            guard data.count >= 20 else { return 0 }
            guard let creationTime = try? reader.readUInt32BigEndian(),
                  let modTime = try? reader.readUInt32BigEndian(),
                  let timescale = try? reader.readUInt32BigEndian(),
                  let duration = try? reader.readUInt32BigEndian() else { return 0 }

            if creationTime > 0 {
                metadata.creationDate = Date(timeIntervalSince1970: Double(creationTime) - epochOffset)
            }
            if modTime > 0 {
                metadata.modificationDate = Date(timeIntervalSince1970: Double(modTime) - epochOffset)
            }
            if timescale > 0 {
                metadata.duration = Double(duration) / Double(timescale)
            }
            return timescale
        } else {
            // Version 1: 64-bit fields
            guard data.count >= 32 else { return 0 }
            guard let creationTime = try? reader.readUInt64BigEndian(),
                  let modTime = try? reader.readUInt64BigEndian(),
                  let timescale = try? reader.readUInt32BigEndian(),
                  let duration = try? reader.readUInt64BigEndian() else { return 0 }

            if creationTime > 0 {
                metadata.creationDate = Date(timeIntervalSince1970: Double(creationTime) - epochOffset)
            }
            if modTime > 0 {
                metadata.modificationDate = Date(timeIntervalSince1970: Double(modTime) - epochOffset)
            }
            if timescale > 0 {
                metadata.duration = Double(duration) / Double(timescale)
            }
            return timescale
        }
    }


    // MARK: - Chapter markers

    /// Nero-style `chpl` box (written by x264 / ffmpeg / MP4Box). Only the
    /// version-1 shape is recognised — it's what every modern muxer emits and
    /// the only form documented by Nero.
    ///
    /// Layout:
    ///   FullBox header(4)            version(1) + flags(0)
    ///   reserved(1)                  0x00
    ///   count(4)                     big-endian UInt32 entry count
    ///   entries[count]:
    ///     start(8)                   big-endian UInt64, 100-nanosecond units
    ///     title_length(1)            UInt8
    ///     title(title_length)        UTF-8 bytes
    static func parseCHPL(_ data: Data) -> [VideoChapter] {
        // version(1) + flags(3) + reserved(1) + count(4) = 9 bytes minimum
        guard data.count >= 9 else { return [] }
        let s = data.startIndex
        guard data[s] == 1 else { return [] } // only version 1 is supported
        var offset = 4      // past FullBox header
        offset += 1         // reserved
        let count = Int(
            (UInt32(data[s + offset]) << 24)
            | (UInt32(data[s + offset + 1]) << 16)
            | (UInt32(data[s + offset + 2]) << 8)
            | UInt32(data[s + offset + 3])
        )
        offset += 4
        // Clamp to something defensive — real-world chapter lists are <10 000.
        guard count > 0, count <= 100_000 else { return [] }

        var out: [VideoChapter] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            guard offset + 9 <= data.count else { break }
            var raw: UInt64 = 0
            for j in 0..<8 {
                raw = (raw << 8) | UInt64(data[s + offset + j])
            }
            offset += 8
            let titleLen = Int(data[s + offset])
            offset += 1
            guard offset + titleLen <= data.count else { break }
            let titleBytes = data[s + offset ..< s + offset + titleLen]
            offset += titleLen
            // Nero encodes start as 100-ns ticks: 10 000 000 ticks / second.
            let start = Double(raw) / 10_000_000.0
            let title = String(data: Data(titleBytes), encoding: .utf8)
            out.append(VideoChapter(
                index: i,
                startTime: start,
                title: title?.isEmpty == true ? nil : title
            ))
        }
        return out
    }

    /// Walk the moov children for QuickTime chapter tracks. A chapter track is
    /// a trak whose handler is `text` / `subt` / `sbtl`, referenced by another
    /// trak's `tref > chap`. Each sample is a chapter title; the sample's
    /// decoding timestamp (from stts) is the chapter's start time.
    ///
    /// Apple's QuickTime File Format § "Chapter Lists" — see
    /// https://developer.apple.com/documentation/quicktime-file-format/chapter_lists
    private static func parseChapterTracks(
        _ moovChildren: [ISOBMFFBox],
        fullData: Data
    ) -> [VideoChapter] {
        // Build trackID → trak index for tref lookup.
        var traksByID: [UInt32: Data] = [:]
        for trak in moovChildren where trak.type == "trak" {
            if let tid = parseTKHDTrackID(trak.data) {
                traksByID[tid] = trak.data
            }
        }

        // Collect chapter track IDs referenced from any trak. DaVinci writes
        // the `tref chap` on the video track; ffmpeg's mov muxer writes it on
        // audio + subtitle tracks instead. Scan every trak so either layout
        // surfaces the chapter list.
        var chapterTrackIDs: [UInt32] = []
        for trak in moovChildren where trak.type == "trak" {
            for tid in parseTrefChap(trak.data) where traksByID[tid] != nil {
                if !chapterTrackIDs.contains(tid) { chapterTrackIDs.append(tid) }
            }
        }

        // Decode the first chapter track only — ffprobe behaves the same way.
        // A movie with multiple chap-referenced tracks (rare) typically
        // duplicates them per language; we pick the first and surface the
        // rest through per-track `VideoStream.title` already.
        for tid in chapterTrackIDs {
            guard let trakData = traksByID[tid] else { continue }
            let handler = trakHandlerType(trakData) ?? ""
            guard handler == "text" || handler == "subt" || handler == "sbtl" else { continue }
            let chapters = decodeChapterTrack(trakData, fullData: fullData)
            if !chapters.isEmpty { return chapters }
        }
        return []
    }

    /// `trak > tref > chap` — list of track IDs whose samples provide chapter
    /// text for the referencing track.
    private static func parseTrefChap(_ trakData: Data) -> [UInt32] {
        guard let trakChildren = try? ISOBMFFBoxReader.parseBoxes(from: trakData),
              let tref = trakChildren.first(where: { $0.type == "tref" }),
              let trefChildren = try? ISOBMFFBoxReader.parseBoxes(from: tref.data),
              let chap = trefChildren.first(where: { $0.type == "chap" }) else { return [] }
        let payload = chap.data
        let count = payload.count / 4
        var out: [UInt32] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let s = payload.startIndex + i * 4
            let v = (UInt32(payload[s]) << 24)
                | (UInt32(payload[s + 1]) << 16)
                | (UInt32(payload[s + 2]) << 8)
                | UInt32(payload[s + 3])
            out.append(v)
        }
        return out
    }

    /// Pull timed chapter samples out of a text-track trak. Each sample starts
    /// with a 2-byte big-endian length followed by UTF-8 bytes (QuickTime text
    /// sample format); any trailing metadata atoms are ignored.
    private static func decodeChapterTrack(
        _ trakData: Data,
        fullData: Data
    ) -> [VideoChapter] {
        guard let trakChildren = try? ISOBMFFBoxReader.parseBoxes(from: trakData),
              let mdia = trakChildren.first(where: { $0.type == "mdia" }),
              let mdiaChildren = try? ISOBMFFBoxReader.parseBoxes(from: mdia.data),
              let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }),
              let mdhdInfo = parseMDHD(mdhd.data), mdhdInfo.timescale > 0,
              let minf = mdiaChildren.first(where: { $0.type == "minf" }),
              let minfChildren = try? ISOBMFFBoxReader.parseBoxes(from: minf.data),
              let stbl = minfChildren.first(where: { $0.type == "stbl" }),
              let stblChildren = try? ISOBMFFBoxReader.parseBoxes(from: stbl.data)
        else { return [] }

        let timescale = Double(mdhdInfo.timescale)
        let sttsBox = stblChildren.first(where: { $0.type == "stts" })
        let stszBox = stblChildren.first(where: { $0.type == "stsz" })
        let stscBox = stblChildren.first(where: { $0.type == "stsc" })
        let stcoBox = stblChildren.first(where: { $0.type == "stco" })
        let co64Box = stblChildren.first(where: { $0.type == "co64" })

        guard let starts = sttsBox.flatMap({ sttsSampleStartTicks($0.data) }),
              !starts.isEmpty else { return [] }

        let sizes = stszBox.flatMap({ stszSampleSizes($0.data) }) ?? []
        let samplesPerChunk = stscBox.flatMap({ stscSamplesPerChunk($0.data) }) ?? []
        let chunkOffsets: [UInt64] = {
            if let b = co64Box { return co64Offsets(b.data) }
            if let b = stcoBox { return stcoOffsets(b.data).map(UInt64.init) }
            return []
        }()

        let sampleCount = min(starts.count, sizes.count)
        guard sampleCount > 0, !chunkOffsets.isEmpty else { return [] }

        // Build a list of sample file offsets.
        let sampleOffsets = sampleFileOffsets(
            sampleCount: sampleCount,
            sizes: sizes,
            samplesPerChunk: samplesPerChunk,
            chunkOffsets: chunkOffsets
        )
        guard sampleOffsets.count == sampleCount else { return [] }

        var out: [VideoChapter] = []
        for i in 0..<sampleCount {
            let fileOff = sampleOffsets[i]
            let size = sizes[i]
            guard size >= 2,
                  fileOff + UInt64(size) <= UInt64(fullData.count) else { continue }
            let base = fullData.startIndex + Int(fileOff)
            let titleLen = (Int(fullData[base]) << 8) | Int(fullData[base + 1])
            guard titleLen >= 0, 2 + titleLen <= size else { continue }
            let titleBytes = fullData[base + 2 ..< base + 2 + titleLen]
            let title = stripBOM(String(data: Data(titleBytes), encoding: .utf8))
            let start = Double(starts[i]) / timescale
            let end: TimeInterval?
            if i + 1 < starts.count {
                end = Double(starts[i + 1]) / timescale
            } else {
                end = nil
            }
            out.append(VideoChapter(
                index: i,
                startTime: start,
                endTime: end,
                title: title?.isEmpty == true ? nil : title
            ))
        }
        return out
    }

    /// Strip a UTF-16 BOM from a decoded title (QuickTime sometimes encodes
    /// chapter titles as UTF-16 with a BOM inside the UTF-8 sample bytes when
    /// the TextSampleEntry's encoding hint calls for it — the BOM shows up as
    /// a leading "\u{FEFF}"). Removing it keeps test assertions clean.
    private static func stripBOM(_ s: String?) -> String? {
        guard let s else { return nil }
        return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
    }

    /// Running-sum sample start ticks (cumulative sample_delta in stts).
    internal static func sttsSampleStartTicks(_ data: Data) -> [UInt64]? {
        guard data.count >= 8 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let entryCount = try? reader.readUInt32BigEndian() else { return nil }
        var out: [UInt64] = []
        var running: UInt64 = 0
        // Total-sample cap — stts expands sample_count per entry, so the two
        // per-loop caps below still let a crafted file produce 2^32 samples.
        // Real chapter tracks have hundreds of samples, not millions.
        let totalCap = 1 << 20
        outer: for _ in 0..<min(entryCount, 1 << 16) {
            guard let sc = try? reader.readUInt32BigEndian(),
                  let sd = try? reader.readUInt32BigEndian() else { break }
            for _ in 0..<min(sc, 1 << 16) {
                if out.count >= totalCap { break outer }
                out.append(running)
                running &+= UInt64(sd)
            }
        }
        return out
    }

    /// Per-sample sizes from stsz. Handles both uniform size and per-sample
    /// size modes.
    internal static func stszSampleSizes(_ data: Data) -> [Int]? {
        guard data.count >= 12 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let uniform = try? reader.readUInt32BigEndian(),
              let count = try? reader.readUInt32BigEndian() else { return nil }
        let capped = Int(min(count, 1 << 20))
        if uniform > 0 {
            return Array(repeating: Int(uniform), count: capped)
        }
        var out: [Int] = []
        out.reserveCapacity(capped)
        for _ in 0..<capped {
            guard let sz = try? reader.readUInt32BigEndian() else { break }
            out.append(Int(sz))
        }
        return out
    }

    /// stsc entries: [first_chunk, samples_per_chunk, sample_description_index].
    /// Return just the first_chunk / samples_per_chunk pairs — the description
    /// index is irrelevant for chapter text, which always uses entry 1.
    internal static func stscSamplesPerChunk(_ data: Data) -> [(firstChunk: Int, samplesPerChunk: Int)] {
        guard data.count >= 8 else { return [] }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let entryCount = try? reader.readUInt32BigEndian() else { return [] }
        var out: [(Int, Int)] = []
        for _ in 0..<min(entryCount, 1 << 16) {
            guard let fc = try? reader.readUInt32BigEndian(),
                  let spc = try? reader.readUInt32BigEndian(),
                  (try? reader.skip(4)) != nil else { break }
            out.append((Int(fc), Int(spc)))
        }
        return out
    }

    /// All stco chunk offsets.
    internal static func stcoOffsets(_ data: Data) -> [UInt32] {
        guard data.count >= 8 else { return [] }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let count = try? reader.readUInt32BigEndian() else { return [] }
        var out: [UInt32] = []
        out.reserveCapacity(Int(min(count, 1 << 20)))
        for _ in 0..<min(count, 1 << 20) {
            guard let off = try? reader.readUInt32BigEndian() else { break }
            out.append(off)
        }
        return out
    }

    /// All co64 chunk offsets.
    internal static func co64Offsets(_ data: Data) -> [UInt64] {
        guard data.count >= 8 else { return [] }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let count = try? reader.readUInt32BigEndian() else { return [] }
        var out: [UInt64] = []
        out.reserveCapacity(Int(min(count, 1 << 20)))
        for _ in 0..<min(count, 1 << 20) {
            guard let off = try? reader.readUInt64BigEndian() else { break }
            out.append(off)
        }
        return out
    }

    /// Walk stsc to resolve each sample's containing chunk + index-in-chunk,
    /// then add the chunk's file offset plus the summed sizes of preceding
    /// samples in the same chunk.
    ///
    /// When stsc is empty (single-chunk case typical of chapter tracks), every
    /// sample lives in chunk 0.
    internal static func sampleFileOffsets(
        sampleCount: Int,
        sizes: [Int],
        samplesPerChunk: [(firstChunk: Int, samplesPerChunk: Int)],
        chunkOffsets: [UInt64]
    ) -> [UInt64] {
        guard !chunkOffsets.isEmpty else { return [] }

        // Expand stsc's run-length-encoded (first_chunk, spc) pairs into a flat
        // samples-per-chunk array covering every chunk up to chunkOffsets.count.
        // stsc uses 1-based chunk indices.
        var spc = [Int](repeating: 1, count: chunkOffsets.count)
        if !samplesPerChunk.isEmpty {
            for i in 0..<samplesPerChunk.count {
                let firstChunk = max(samplesPerChunk[i].firstChunk - 1, 0)
                let nextFirst = (i + 1 < samplesPerChunk.count)
                    ? max(samplesPerChunk[i + 1].firstChunk - 1, 0)
                    : chunkOffsets.count
                let value = samplesPerChunk[i].samplesPerChunk
                for c in firstChunk..<min(nextFirst, chunkOffsets.count) {
                    spc[c] = value
                }
            }
        }

        var out: [UInt64] = []
        out.reserveCapacity(sampleCount)
        var sampleIdx = 0
        for (chunkIdx, chunkOff) in chunkOffsets.enumerated() {
            let inChunk = spc[chunkIdx]
            var runningInChunk: UInt64 = 0
            for _ in 0..<inChunk {
                guard sampleIdx < sampleCount, sampleIdx < sizes.count else { return out }
                out.append(chunkOff &+ runningInChunk)
                runningInChunk &+= UInt64(sizes[sampleIdx])
                sampleIdx += 1
            }
            if sampleIdx >= sampleCount { break }
        }
        return out
    }
}
