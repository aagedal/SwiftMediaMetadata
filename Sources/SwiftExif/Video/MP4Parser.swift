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
    private static func isUncompressedPCMCodec(_ codec: String) -> Bool {
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

    // MARK: - Track Parsing

    private static func parseTrak(
        _ data: Data,
        movieTimescale: UInt32,
        chapterTrackIDs: Set<UInt32> = [],
        into metadata: inout VideoMetadata
    ) {
        guard let children = try? ISOBMFFBoxReader.parseBoxes(from: data) else { return }

        // tkhd provides track-level display dimensions, flags, and the track
        // ID we compare against the chapter-track exclusion set below.
        var trackWidth: Int?
        var trackHeight: Int?
        var tkhdIsDefault: Bool?
        var tkhdRotation: Int?
        if let tkhd = children.first(where: { $0.type == "tkhd" }) {
            if let dims = parseTKHDDimensions(tkhd.data) {
                trackWidth = dims.width
                trackHeight = dims.height
            }
            tkhdIsDefault = parseTKHDIsDefault(tkhd.data)
            tkhdRotation = parseTKHDRotation(tkhd.data)
        }
        // parseTKHDTrackID walks the trak looking for tkhd itself — cheap
        // enough; we already parsed the children but the function is shared
        // with the timecode + chapter-track paths in `parse()`.
        let trackID: UInt32? = parseTKHDTrackID(data)

        // A text track referenced from a video track's `tref > chap` list is
        // a chapter-title track, not a user-facing subtitle. Bail out before
        // the handler dispatch so it never lands in `subtitleStreams`. (The
        // chapter titles themselves are harvested separately in `parse()`.)
        let isChapterTextTrack: Bool = trackID.map(chapterTrackIDs.contains(_:)) ?? false

        // `edts > elst` trims the visible essence window inside the mdhd
        // duration — ffmpeg uses it to hide B-frame decoder pre-roll and to
        // support seamless concatenation. When present, the sum of each entry's
        // segment_duration (in *movie* timescale) is the effective track
        // duration; ignoring it over-reports the media duration and deflates
        // per-stream bitrate accordingly. We recover it here and plumb it as
        // `editedDuration` below.
        var editedDuration: TimeInterval?
        if movieTimescale > 0,
           let edts = children.first(where: { $0.type == "edts" }),
           let edtsChildren = try? ISOBMFFBoxReader.parseBoxes(from: edts.data),
           let elst = edtsChildren.first(where: { $0.type == "elst" }) {
            if let total = parseELSTSegmentDuration(elst.data), total > 0 {
                editedDuration = Double(total) / Double(movieTimescale)
            }
        }

        // Disposition flags from trak.udta.kind (ISO/IEC 14496-12 + DASH Role
        // scheme, "urn:mpeg:dash:role:2011"). This is how ffmpeg records
        // -disposition:s:N forced / caption / main on an MP4 subtitle track;
        // tx3g displayFlags (3GPP TS 26.245 §5.16) is the alternative path.
        let dispositions = parseTrackKindDispositions(children)

        guard let mdia = children.first(where: { $0.type == "mdia" }),
              let mdiaChildren = try? ISOBMFFBoxReader.parseBoxes(from: mdia.data) else {
            return
        }

        // mdhd: per-track timescale + duration + language.
        var trackDuration: TimeInterval?
        var language: String?
        var trackTimescale: UInt32 = 0
        if let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }) {
            if let info = parseMDHD(mdhd.data) {
                trackDuration = info.duration
                language = info.language
                trackTimescale = info.timescale
            }
        }

        // `trackDuration` stays on the raw mdhd value — ffprobe reports that
        // for a stream's `duration` field and computes `avg_frame_rate` as
        // `samples / mdhd_duration`. Only the bitrate calc prefers
        // `editedDuration` (mirroring ffprobe, which sums the packet bytes
        // that land inside the edit-list window).

        // hdlr → track handler type ("vide", "soun").
        var handlerType = ""
        if let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }),
           hdlr.data.count >= 12 {
            handlerType = String(
                data: hdlr.data[hdlr.data.startIndex + 8 ..< hdlr.data.startIndex + 12],
                encoding: .ascii
            ) ?? ""
        }

        guard let minf = mdiaChildren.first(where: { $0.type == "minf" }),
              let minfChildren = try? ISOBMFFBoxReader.parseBoxes(from: minf.data),
              let stbl = minfChildren.first(where: { $0.type == "stbl" }),
              let stblChildren = try? ISOBMFFBoxReader.parseBoxes(from: stbl.data)
        else { return }

        let sttsBox = stblChildren.first(where: { $0.type == "stts" })
        let stszBox = stblChildren.first(where: { $0.type == "stsz" })
        let stsdBox = stblChildren.first(where: { $0.type == "stsd" })

        let frameCount = stszBox.flatMap(parseSTSZSampleCount)
        let sttsFrames = sttsBox.flatMap(parseSTTSSampleCount)
        let trackBytes = stszBox.flatMap(parseSTSZTotalBytes)
        let dominantSampleDelta = sttsBox.flatMap(parseSTTSDominantDelta)

        // Prefer stsz; stts is a sum of per-run counts but some muxers only populate one.
        let samples = frameCount ?? sttsFrames

        let fps: Double? = {
            guard let samples, samples > 0, let trackDuration, trackDuration > 0 else {
                return nil
            }
            return Double(samples) / trackDuration
        }()

        // Real (decoder cadence) frame rate: timescale / dominant sample delta.
        // ffprobe surfaces this as `r_frame_rate` and it's stable across files
        // with a partial trailing sample (where samples/duration would slip).
        let rFrameRate: Double? = {
            guard trackTimescale > 0, let delta = dominantSampleDelta, delta > 0 else { return nil }
            return Double(trackTimescale) / Double(delta)
        }()

        // Per-stream bitrate fallback: total essence bytes × 8 / duration.
        // Priority order matches ffprobe:
        //   1. edit-list-corrected duration (strips B-frame pre-roll, seamless
        //      concatenation joins, and any other explicit trim)
        //   2. stts-derived essence duration (samples × dominant_delta /
        //      timescale) — stable when mdhd has a partial trailing sample
        //   3. raw mdhd duration
        let derivedTrackBitRate: Int? = {
            guard let bytes = trackBytes else { return nil }
            if let edited = editedDuration, edited > 0 {
                return Int(Double(bytes) * 8.0 / edited)
            }
            if let samples, samples > 0,
               let delta = dominantSampleDelta, delta > 0,
               trackTimescale > 0 {
                let essenceDur = Double(samples) * Double(delta) / Double(trackTimescale)
                if essenceDur > 0 { return Int(Double(bytes) * 8.0 / essenceDur) }
            }
            if let dur = trackDuration, dur > 0 {
                return Int(Double(bytes) * 8.0 / dur)
            }
            return nil
        }()

        if handlerType == "vide", let stsdBox {
            metadata.streamOrder.append(.video(metadata.videoStreams.count))
            var stream = VideoStream(index: metadata.videoStreams.count)
            stream.duration = trackDuration
            stream.frameCount = samples
            // Legacy `frameRate` and `avgFrameRate` both report the essence
            // average (samples / duration). `rFrameRate` is the decoder
            // cadence (timescale / dominant sample delta) — equal to avg when
            // stts has a single, uniform entry.
            stream.frameRate = fps
            stream.avgFrameRate = fps
            stream.rFrameRate = rFrameRate ?? fps
            stream.isDefault = tkhdIsDefault
            stream.rotation = tkhdRotation
            parseVisualSampleEntry(stsdBox.data, into: &stream)
            // Blackmagic RAW: pull the three uint32 codec-config atoms
            // (bfdn / ctrn / bver) out of the BRAW sample entry's child
            // boxes and surface them next to the moov.meta clip slate.
            // BRAW uses one FourCC per quality preset — `brhq` (High
            // Quality), `brst` (Standard), `brlt` (Light), plus likely
            // others for Q0/Q1/Q3/Q5 and constant-bitrate ratios — all
            // sharing the "br" prefix.
            if stream.codec?.hasPrefix("br") == true {
                parseBRAWCodecExtensions(stsdBox.data, into: &metadata)
            }
            // ffprobe always computes per-stream bit_rate from actual packet
            // sizes in the edit-list window (not from the encoder-declared
            // `btrt` value, which goes stale after lossless trim). Mirror that
            // priority: stsz-derived over btrt whenever stsz has data. Fall
            // back to btrt/esds only when stsz is missing (e.g. fragmented
            // movies with no sample count we can sum).
            if let derived = derivedTrackBitRate, derived > 0 {
                stream.bitRate = derived
            }

            if stream.width == nil, let trackWidth, trackWidth > 0 {
                stream.width = trackWidth
            }
            if stream.height == nil, let trackHeight, trackHeight > 0 {
                stream.height = trackHeight
            }
            // tkhd carries display-aspect-corrected dimensions. Only fall back
            // to them when the sample entry (pasp) hasn't already set display
            // dimensions, and only when they actually differ from the pixel grid.
            if stream.displayWidth == nil, let trackWidth, trackWidth > 0,
               stream.width.map({ $0 != trackWidth }) ?? false {
                stream.displayWidth = trackWidth
            }
            if stream.displayHeight == nil, let trackHeight, trackHeight > 0,
               stream.height.map({ $0 != trackHeight }) ?? false {
                stream.displayHeight = trackHeight
            }

            // MP4/MOV convention: absence of a `fiel` atom means progressive.
            // Cameras and modern encoders (HEVC, AV1, VVC) routinely omit it.
            // ffmpeg's mov demuxer treats untagged streams the same way.
            if stream.fieldOrder == nil { stream.fieldOrder = .progressive }

            metadata.videoStreams.append(stream)

            if metadata.videoWidth == nil, let w = stream.width, w > 0 {
                metadata.videoWidth = w
            }
            if metadata.videoHeight == nil, let h = stream.height, h > 0 {
                metadata.videoHeight = h
            }
            if metadata.videoCodec == nil { metadata.videoCodec = stream.codec }
            if metadata.frameRate == nil { metadata.frameRate = stream.frameRate }
            if metadata.fieldOrder == nil { metadata.fieldOrder = stream.fieldOrder }
            if metadata.colorInfo == nil { metadata.colorInfo = stream.colorInfo }
            if metadata.bitDepth == nil { metadata.bitDepth = stream.bitDepth }
            if metadata.chromaSubsampling == nil { metadata.chromaSubsampling = stream.chromaSubsampling }
            if metadata.pixelAspectRatio == nil { metadata.pixelAspectRatio = stream.pixelAspectRatio }
            if metadata.displayWidth == nil { metadata.displayWidth = stream.displayWidth }
            if metadata.displayHeight == nil { metadata.displayHeight = stream.displayHeight }
        } else if handlerType == "soun", let stsdBox {
            metadata.streamOrder.append(.audio(metadata.audioStreams.count))
            var stream = AudioStream(index: metadata.audioStreams.count)
            stream.duration = trackDuration
            stream.language = language
            stream.isDefault = tkhdIsDefault
            parseAudioSampleEntry(stsdBox.data, into: &stream)
            // Uncompressed PCM has a deterministic bit rate
            // (sample_rate × channels × bit_depth) — use that verbatim
            // regardless of what `esds` / `btrt` / stsz happen to compute,
            // because stsz-over-duration introduces rounding noise and
            // ffprobe reports the exact mathematical value.
            if let codec = stream.codec, isUncompressedPCMCodec(codec),
               let sr = stream.sampleRate, sr > 0,
               let ch = stream.channels, ch > 0,
               let bd = stream.bitDepth, bd > 0 {
                stream.bitRate = sr * ch * bd
            } else if let derived = derivedTrackBitRate, derived > 0 {
                // Compressed audio: match ffprobe priority — packet-sum over
                // edited duration, falling back to esds/btrt only when stsz
                // is unusable (typical of fragmented MP4).
                stream.bitRate = derived
            }
            if stream.bitRate == nil,
               let sr = stream.sampleRate, sr > 0,
               let ch = stream.channels, ch > 0,
               let bd = stream.bitDepth, bd > 0 {
                stream.bitRate = sr * ch * bd
            }
            metadata.audioStreams.append(stream)

            if metadata.audioCodec == nil { metadata.audioCodec = stream.codec }
            if metadata.audioSampleRate == nil { metadata.audioSampleRate = stream.sampleRate }
            if metadata.audioChannels == nil { metadata.audioChannels = stream.channels }
        } else if isSubtitleHandler(handlerType), !isChapterTextTrack, let stsdBox {
            metadata.streamOrder.append(.subtitle(metadata.subtitleStreams.count))
            var stream = SubtitleStream(index: metadata.subtitleStreams.count)
            stream.duration = trackDuration
            stream.language = language
            parseSubtitleSampleEntry(stsdBox.data, handlerType: handlerType, into: &stream)
            if dispositions.isDefault { stream.isDefault = true }
            if dispositions.isForced { stream.isForced = true }
            if dispositions.isHearingImpaired { stream.isHearingImpaired = true }
            metadata.subtitleStreams.append(stream)
        } else if isDataHandler(handlerType) || isChapterTextTrack {
            // Anything ffprobe reports with `codec_type=data`: timecode
            // (`tmcd`), Apple metadata (`meta`/`mdta`), GoPro GPMF (`gpmd`),
            // embedded thumbnails (`pict`), and the QuickTime text tracks
            // referenced via `tref:chap` for chapter titles. We expose them
            // so per-stream listings line up 1:1 with ffprobe's count.
            metadata.streamOrder.append(.data(metadata.dataStreams.count))
            var stream = DataStream(index: metadata.dataStreams.count, handlerType: handlerType)
            stream.duration = trackDuration
            stream.language = language
            stream.isDefault = tkhdIsDefault
            if let stsdBox {
                parseDataSampleEntry(stsdBox.data, into: &stream)
                // Blackmagic RAW emits per-frame gyroscope and accelerometer
                // streams as `mebx` timed-metadata tracks. We don't decode
                // the per-frame samples (out of scope for the slate pass);
                // just flag presence so consumers know the streams exist.
                detectBRAWMotionTracks(in: stsdBox.data, into: &metadata)
            }
            stream.codecName = stream.codecName ?? dataHandlerLongName(handlerType, isChapter: isChapterTextTrack)
            metadata.dataStreams.append(stream)
        }
    }

    /// Handler types that carry timed metadata payloads rather than rendered
    /// audio/video/subtitle samples. ffprobe groups all of these under
    /// `codec_type=data`.
    private static func isDataHandler(_ type: String) -> Bool {
        switch type {
        case "tmcd", "meta", "mdta", "gpmd", "pict", "url ", "data":
            return true
        default:
            return false
        }
    }

    /// Best-effort human label for a data-track handler. Used when the
    /// stsd sample-entry inspection didn't produce a more specific name.
    private static func dataHandlerLongName(_ type: String, isChapter: Bool) -> String? {
        if isChapter { return "QuickTime Chapter" }
        switch type {
        case "tmcd": return "QuickTime Timecode"
        case "meta", "mdta": return "QuickTime Metadata"
        case "gpmd": return "GoPro GPMF"
        case "pict": return "Image"
        default: return nil
        }
    }

    /// Pull the FourCC from the first sample entry in `stsd` for data
    /// tracks. The ISOBMFF SampleEntry layout is shared, so the same
    /// "skip FullBox header + entry_count + entry_size" recipe used for
    /// audio / subtitle tracks works here too.
    private static func parseDataSampleEntry(_ stsdData: Data, into stream: inout DataStream) {
        guard stsdData.count >= 16 else { return }
        var reader = BinaryReader(data: stsdData)
        _ = try? reader.readBytes(4) // FullBox header
        _ = try? reader.readUInt32BigEndian() // entry_count
        guard reader.remainingCount >= 8 else { return }
        _ = try? reader.readUInt32BigEndian() // entry_size
        guard let codecBytes = try? reader.readBytes(4),
              let codec = String(data: codecBytes, encoding: .ascii) else { return }
        stream.codec = codec
    }

    /// ISOBMFF handler types that advertise subtitle / timed-text / closed-
    /// caption content:
    ///   "subt" — generic subtitle (WebVTT / TTML / 3GPP timed text)
    ///   "text" — QuickTime text track
    ///   "sbtl" — subtitles (also produced by older Apple tools)
    ///   "clcp" — closed captions
    private static func isSubtitleHandler(_ type: String) -> Bool {
        type == "subt" || type == "text" || type == "sbtl" || type == "clcp"
    }

    /// Inspect the first SampleEntry in `stsd` to capture the subtitle codec
    /// FourCC (tx3g / wvtt / stpp / c608 / c708 / text / …) and, for 3GPP
    /// timed-text / QuickTime text tracks, the forced-display bit from
    /// `displayFlags`.
    private static func parseSubtitleSampleEntry(
        _ stsdData: Data,
        handlerType: String,
        into stream: inout SubtitleStream
    ) {
        guard stsdData.count >= 16 else { return }
        var reader = BinaryReader(data: stsdData)
        _ = try? reader.readBytes(4) // FullBox header
        _ = try? reader.readUInt32BigEndian() // entry_count
        guard reader.remainingCount >= 8 else { return }
        _ = try? reader.readUInt32BigEndian() // entry_size
        guard let codecBytes = try? reader.readBytes(4),
              let codec = String(data: codecBytes, encoding: .ascii) else { return }

        stream.codec = codec
        stream.codecName = subtitleLongName(forFourCC: codec, handler: handlerType) ?? codec

        // TextSampleEntry (tx3g, QuickTime text) extends SampleEntry with a
        // 32-bit displayFlags field. Per 3GPP TS 26.245 §5.16, bit 0x40000000
        // = "all samples are forced". ffmpeg writes forced tracks via the
        // `kind` box instead (handled in parseTrak); this path catches
        // muxers that follow the 3GPP spec.
        if codec == "tx3g" || codec == "text" {
            // Skip SampleEntry base: reserved[6] + data_reference_index(2).
            guard (try? reader.readBytes(8)) != nil,
                  let displayFlags = try? reader.readUInt32BigEndian() else { return }
            if (displayFlags & 0x40000000) != 0 {
                stream.isForced = true
            }
        }
    }

    /// DASH Role scheme dispositions recorded on a `trak` via `udta > kind`.
    private struct TrackDispositions {
        var isDefault = false
        var isForced = false
        var isHearingImpaired = false
    }

    /// Walk `trak > udta > kind` boxes, mapping recognised DASH Role values
    /// ("main", "forced-subtitle", "caption", "sign") and TV-Anytime audio
    /// purpose code 4 to subtitle disposition flags.
    private static func parseTrackKindDispositions(
        _ trakChildren: [ISOBMFFBox]
    ) -> TrackDispositions {
        var result = TrackDispositions()
        guard let udta = trakChildren.first(where: { $0.type == "udta" }),
              let udtaChildren = try? ISOBMFFBoxReader.parseBoxes(from: udta.data) else {
            return result
        }
        for kind in udtaChildren where kind.type == "kind" {
            guard let (scheme, value) = parseKindBox(kind.data) else { continue }
            switch scheme {
            case "urn:mpeg:dash:role:2011", "urn:mpeg:dash:role:2012":
                switch value {
                case "main": result.isDefault = true
                case "forced-subtitle": result.isForced = true
                case "caption", "sign": result.isHearingImpaired = true
                default: break
                }
            case "urn:tva:metadata:cs:AudioPurposeCS:2007" where value == "4":
                result.isHearingImpaired = true
            default: break
            }
        }
        return result
    }

    /// Decode a `kind` FullBox payload into (schemeURI, value). Both fields
    /// are NUL-terminated UTF-8 strings per ISO/IEC 14496-12.
    private static func parseKindBox(_ data: Data) -> (scheme: String, value: String)? {
        // FullBox header: version(1) + flags(3).
        guard data.count > 4 else { return nil }
        let payload = data[data.startIndex + 4 ..< data.endIndex]
        let parts = payload.split(separator: 0, maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let scheme = String(data: Data(parts[0]), encoding: .utf8),
              let value = String(data: Data(parts[1]), encoding: .utf8) else {
            return nil
        }
        return (scheme, value)
    }

    private static func subtitleLongName(forFourCC fourCC: String, handler: String) -> String? {
        switch fourCC {
        case "tx3g": return "3GPP Timed Text"
        case "wvtt": return "WebVTT"
        case "stpp": return "TTML"
        case "text": return "QuickTime Text"
        case "c608": return "CEA-608 Closed Captions"
        case "c708": return "CEA-708 Closed Captions"
        default:
            if handler == "clcp" { return "Closed Captions" }
            if handler == "subt" { return "Subtitles" }
            return nil
        }
    }

    /// QuickTime timecode (`tmcd`) track extraction. The trak's stsd sample
    /// entry describes the frame rate + drop-frame/wrap flags; the first
    /// media sample in mdat is a 32-bit frame counter. We locate the sample
    /// via stco (32-bit chunk offsets) or co64 (64-bit) and reach into the
    /// full file blob to read those 4 bytes.
    ///
    /// QuickTime File Format § "Timecode Media Information" — see
    /// https://developer.apple.com/documentation/quicktime-file-format/timecode_sample_description
    private static func parseTmcdTrackTimecode(_ trakData: Data, fullData: Data) -> String? {
        guard let trakChildren = try? ISOBMFFBoxReader.parseBoxes(from: trakData),
              let mdia = trakChildren.first(where: { $0.type == "mdia" }),
              let mdiaChildren = try? ISOBMFFBoxReader.parseBoxes(from: mdia.data),
              let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }),
              hdlr.data.count >= 12 else { return nil }

        let handlerType = String(
            data: hdlr.data[hdlr.data.startIndex + 8 ..< hdlr.data.startIndex + 12],
            encoding: .ascii
        ) ?? ""
        guard handlerType == "tmcd" else { return nil }

        guard let minf = mdiaChildren.first(where: { $0.type == "minf" }),
              let minfChildren = try? ISOBMFFBoxReader.parseBoxes(from: minf.data),
              let stbl = minfChildren.first(where: { $0.type == "stbl" }),
              let stblChildren = try? ISOBMFFBoxReader.parseBoxes(from: stbl.data) else { return nil }

        guard let stsd = stblChildren.first(where: { $0.type == "stsd" }),
              let entry = parseTmcdSampleEntry(stsd.data) else { return nil }

        // Find first chunk offset. Prefer co64 (64-bit) when present.
        let chunkOffset: UInt64? = {
            if let co64 = stblChildren.first(where: { $0.type == "co64" }),
               let off = parseCO64First(co64.data) {
                return off
            }
            if let stco = stblChildren.first(where: { $0.type == "stco" }),
               let off = parseSTCOFirst(stco.data) {
                return UInt64(off)
            }
            return nil
        }()
        guard let offset = chunkOffset,
              offset + 4 <= UInt64(fullData.count) else { return nil }

        let s = fullData.startIndex + Int(offset)
        let counter = (UInt32(fullData[s]) << 24)
            | (UInt32(fullData[s + 1]) << 16)
            | (UInt32(fullData[s + 2]) << 8)
            | UInt32(fullData[s + 3])

        return formatTimecode(
            frameCounter: counter,
            numFrames: entry.numFrames,
            dropFrame: entry.dropFrame
        )
    }

    private struct TmcdSampleEntry {
        let dropFrame: Bool
        let numFrames: Int // frames per second (rounded up: 30 for 29.97, 24 for 23.98)
    }

    /// Decode a `tmcd` SampleEntry from stsd. Layout:
    ///   FullBox header (8 bytes: size + type)
    ///   Reserved(6) + data_reference_index(2)           // SampleEntry
    ///   Reserved(4)                                     // TimeCodeSampleEntry
    ///   Flags(4)  — bit 0 = drop frame, bit 1 = 24h max, bit 2 = negative ok,
    ///               bit 3 = counter
    ///   TimeScale(4)
    ///   FrameDuration(4)
    ///   NumberOfFrames(1)
    ///   Reserved(1)
    private static func parseTmcdSampleEntry(_ stsdData: Data) -> TmcdSampleEntry? {
        guard stsdData.count >= 8 + 8 + 4 + 4 + 4 + 4 + 2 else { return nil }
        var reader = BinaryReader(data: stsdData)
        _ = try? reader.readBytes(4) // FullBox flags/version
        _ = try? reader.readUInt32BigEndian() // entry_count
        // Skip the SampleEntry size+type (8 bytes) and the 8 bytes of
        // reserved+data_reference_index + extra reserved.
        guard let entrySize = try? reader.readUInt32BigEndian(),
              let typeBytes = try? reader.readBytes(4),
              let fourCC = String(data: typeBytes, encoding: .ascii),
              fourCC == "tmcd",
              entrySize >= 34 else { return nil }
        _ = try? reader.readBytes(6) // reserved
        _ = try? reader.readUInt16BigEndian() // data_reference_index
        _ = try? reader.readUInt32BigEndian() // reserved

        guard let flags = try? reader.readUInt32BigEndian(),
              let _ = try? reader.readUInt32BigEndian(), // timescale (unused — numFrames is enough)
              let _ = try? reader.readUInt32BigEndian(), // frame duration
              let numFrames = try? reader.readUInt8() else { return nil }
        let dropFrame = (flags & 0x01) != 0
        return TmcdSampleEntry(dropFrame: dropFrame, numFrames: Int(numFrames))
    }

    /// `stco`: FullBox header(4) + entry_count(4) + entry_count × 32-bit offsets.
    static func parseSTCOFirst(_ data: Data) -> UInt32? {
        guard data.count >= 12 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4) // flags+version
        guard let count = try? reader.readUInt32BigEndian(), count > 0,
              let first = try? reader.readUInt32BigEndian() else { return nil }
        return first
    }

    /// `co64`: FullBox header(4) + entry_count(4) + entry_count × 64-bit offsets.
    static func parseCO64First(_ data: Data) -> UInt64? {
        guard data.count >= 16 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let count = try? reader.readUInt32BigEndian(), count > 0,
              let first = try? reader.readUInt64BigEndian() else { return nil }
        return first
    }

    /// Format a tmcd frame counter to HH:MM:SS:FF (or HH:MM:SS;FF for
    /// drop-frame). Drop-frame arithmetic per SMPTE 12M: skip two frames at
    /// the start of every minute except every tenth minute, for 29.97 fps.
    private static func formatTimecode(frameCounter: UInt32, numFrames: Int, dropFrame: Bool) -> String? {
        guard numFrames > 0 else { return nil }
        var frames = Int(frameCounter)
        let fps = numFrames

        if dropFrame {
            // Drop-frame: commonly 29.97 (numFrames=30) or 59.94 (numFrames=60).
            // Drop `dropCount` frames at the top of every minute except every 10th.
            let dropCount = fps / 15 // 30fps → 2 drops, 60fps → 4 drops
            let framesPer10Min = fps * 60 * 10 - dropCount * 9
            let framesPerMin = fps * 60 - dropCount
            let d = frames / framesPer10Min
            let m = frames % framesPer10Min
            if m > dropCount {
                frames = frames + dropCount * 9 * d + dropCount * ((m - dropCount) / framesPerMin)
            } else {
                frames = frames + dropCount * 9 * d
            }
        }

        let totalSeconds = frames / fps
        let ff = frames % fps
        let ss = totalSeconds % 60
        let mm = (totalSeconds / 60) % 60
        let hh = (totalSeconds / 3600) % 24

        let sep = dropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, sep, ff)
    }

    private static func parseTKHDDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 4 else { return nil }
        var reader = BinaryReader(data: data)
        guard let version = try? reader.readUInt8() else { return nil }
        _ = try? reader.readBytes(3)

        let dimensionOffset: Int
        if version == 0 {
            dimensionOffset = 4 + 76
        } else {
            dimensionOffset = 4 + 88
        }
        guard data.count >= dimensionOffset + 8,
              (try? reader.seek(to: dimensionOffset)) != nil,
              let widthFP = try? reader.readUInt32BigEndian(),
              let heightFP = try? reader.readUInt32BigEndian() else { return nil }

        return (Int(widthFP >> 16), Int(heightFP >> 16))
    }

    /// Decode the display rotation from the `tkhd` 3x3 transformation matrix
    /// (ISO/IEC 14496-12 §8.3.2). The matrix is stored in 16.16 fixed-point
    /// for the upper-left 2x2 (a, b, c, d) and 2.30 fixed-point for the
    /// translation/perspective row, but only `a` and `b` are needed to
    /// recover the rotation angle: `θ = -atan2(b, a)`.
    ///
    /// Matches ffprobe's `side_data_list[].rotation` convention:
    /// - identity → returns nil (no side data emitted)
    /// - portrait phone video (recorded sideways) → -90
    /// - upside-down → -180 (or equivalently 180)
    /// - 90° CCW → 90
    ///
    /// Matrix offset depends on the FullBox version: 40 bytes from the start
    /// for v0 (32-bit times), 52 bytes for v1 (64-bit times).
    private static func parseTKHDRotation(_ data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        let s = data.startIndex
        let version = data[s]
        let matrixOffset = (version == 1) ? 52 : 40
        guard data.count >= matrixOffset + 8 else { return nil }

        func readSignedFixed(_ relOffset: Int) -> Double {
            let p = s + matrixOffset + relOffset
            let raw = (UInt32(data[p]) << 24)
                | (UInt32(data[p + 1]) << 16)
                | (UInt32(data[p + 2]) << 8)
                | UInt32(data[p + 3])
            return Double(Int32(bitPattern: raw)) / 65536.0
        }

        let a = readSignedFixed(0)
        let b = readSignedFixed(4)
        if a == 0 && b == 0 { return nil }

        let degrees = -atan2(b, a) * 180.0 / .pi
        let rounded = Int(degrees.rounded())
        return rounded == 0 ? nil : rounded
    }

    /// tkhd `track_ID` (UInt32). Layout:
    ///   FullBox header(4) + creation_time/mod_time (8 in v0, 16 in v1) + track_ID(4)
    private static func parseTKHDTrackID(_ trakData: Data) -> UInt32? {
        guard let trakChildren = try? ISOBMFFBoxReader.parseBoxes(from: trakData),
              let tkhd = trakChildren.first(where: { $0.type == "tkhd" }),
              tkhd.data.count >= 4 else { return nil }
        let data = tkhd.data
        let s = data.startIndex
        let version = data[s]
        let offset = (version == 1) ? (4 + 16) : (4 + 8)
        guard data.count >= offset + 4 else { return nil }
        return (UInt32(data[s + offset]) << 24)
            | (UInt32(data[s + offset + 1]) << 16)
            | (UInt32(data[s + offset + 2]) << 8)
            | UInt32(data[s + offset + 3])
    }

    /// `trak > tref > tmcd` carries the list of tmcd trackIDs this track uses
    /// for timecode (QuickTime File Format § Track Reference). Returns an
    /// empty array when no such reference exists.
    private static func parseTrefTmcd(_ trakData: Data) -> [UInt32] {
        guard let trakChildren = try? ISOBMFFBoxReader.parseBoxes(from: trakData),
              let tref = trakChildren.first(where: { $0.type == "tref" }),
              let trefChildren = try? ISOBMFFBoxReader.parseBoxes(from: tref.data),
              let tmcdRef = trefChildren.first(where: { $0.type == "tmcd" }) else { return [] }
        let payload = tmcdRef.data
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

    /// Return the four-byte handler type on a trak (`vide`, `soun`, `tmcd`, …),
    /// or nil when the trak lacks mdia/hdlr.
    internal static func trakHandlerType(_ trakData: Data) -> String? {
        guard let trakChildren = try? ISOBMFFBoxReader.parseBoxes(from: trakData),
              let mdia = trakChildren.first(where: { $0.type == "mdia" }),
              let mdiaChildren = try? ISOBMFFBoxReader.parseBoxes(from: mdia.data),
              let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }),
              hdlr.data.count >= 12 else { return nil }
        return String(
            data: hdlr.data[hdlr.data.startIndex + 8 ..< hdlr.data.startIndex + 12],
            encoding: .ascii
        )
    }

    /// tkhd flags live in the bottom 24 bits of the FullBox header. Bit 0 =
    /// track_enabled (the only one ffprobe consults for `disposition.default`).
    /// Bits 1 / 2 / 3 carry in_movie / in_preview / in_poster respectively but
    /// don't influence ffprobe's default-track flag.
    private static func parseTKHDIsDefault(_ data: Data) -> Bool? {
        guard data.count >= 4 else { return nil }
        let s = data.startIndex
        let flags = (UInt32(data[s + 1]) << 16) | (UInt32(data[s + 2]) << 8) | UInt32(data[s + 3])
        return (flags & 0x1) != 0
    }

    /// mdhd (media header): returns duration in seconds (using this track's timescale),
    /// the timescale itself (so callers can compute r_frame_rate from stts), and
    /// the ISO 639-2/T language code if set.
    internal static func parseMDHD(_ data: Data) -> (duration: TimeInterval?, language: String?, timescale: UInt32)? {
        guard data.count >= 4 else { return nil }
        var reader = BinaryReader(data: data)
        guard let version = try? reader.readUInt8() else { return nil }
        _ = try? reader.readBytes(3)

        let timescale: UInt32
        let duration: UInt64
        if version == 0 {
            guard data.count >= 24,
                  (try? reader.skip(8)) != nil, // creation + modification
                  let ts = try? reader.readUInt32BigEndian(),
                  let dur = try? reader.readUInt32BigEndian() else {
                return nil
            }
            timescale = ts
            duration = UInt64(dur)
        } else {
            guard data.count >= 36,
                  (try? reader.skip(16)) != nil, // creation + modification
                  let ts = try? reader.readUInt32BigEndian(),
                  let dur = try? reader.readUInt64BigEndian() else {
                return nil
            }
            timescale = ts
            duration = dur
        }

        // Language is 15 bits packed as three 5-bit values, each + 0x60 = ASCII letter.
        let langRaw = try? reader.readUInt16BigEndian()
        var language: String?
        if let raw = langRaw, raw != 0, (raw & 0x8000) == 0 {
            let c0 = UInt8(((raw >> 10) & 0x1F) + 0x60)
            let c1 = UInt8(((raw >> 5) & 0x1F) + 0x60)
            let c2 = UInt8((raw & 0x1F) + 0x60)
            if let s = String(bytes: [c0, c1, c2], encoding: .ascii),
               s.allSatisfy({ $0.isLetter }) {
                language = s
            }
        }

        let seconds: TimeInterval? = (timescale > 0) ? Double(duration) / Double(timescale) : nil
        return (seconds, language, timescale)
    }

    /// Sum every `segment_duration` in an `elst` FullBox and return the total
    /// in **movie timescale** ticks. An elst can have one entry (the common
    /// B-frame pre-roll trim) or many (ffmpeg's seamless concatenation).
    /// Entries whose media_time is -1 are pure "empty edits" (dwell time
    /// before the first frame) — they still count towards the visible window.
    /// Layout per ISO/IEC 14496-12:
    ///   version(1) + flags(3) + entry_count(4) + entries
    ///   v0 entry: segment_duration(4) + media_time(4) + media_rate_int(2) + media_rate_frac(2)
    ///   v1 entry: segment_duration(8) + media_time(8) + media_rate_int(2) + media_rate_frac(2)
    private static func parseELSTSegmentDuration(_ data: Data) -> UInt64? {
        guard data.count >= 8 else { return nil }
        var reader = BinaryReader(data: data)
        guard let version = try? reader.readUInt8() else { return nil }
        _ = try? reader.readBytes(3) // flags
        guard let entryCount = try? reader.readUInt32BigEndian() else { return nil }
        var total: UInt64 = 0
        for _ in 0..<min(entryCount, 1 << 16) {
            let segDur: UInt64
            if version == 1 {
                guard let v = try? reader.readUInt64BigEndian() else { break }
                segDur = v
                guard (try? reader.readUInt64BigEndian()) != nil else { break } // media_time
            } else {
                guard let v = try? reader.readUInt32BigEndian() else { break }
                segDur = UInt64(v)
                guard (try? reader.readUInt32BigEndian()) != nil else { break } // media_time
            }
            guard (try? reader.readUInt32BigEndian()) != nil else { break } // media_rate
            total &+= segDur
        }
        return total
    }

    /// stsz payload layout: version+flags(4) + sample_size(4) + sample_count(4).
    /// When sample_size is non-zero all samples share a size and sample_count is exact.
    private static func parseSTSZSampleCount(_ box: ISOBMFFBox) -> Int? {
        guard box.data.count >= 12 else { return nil }
        var reader = BinaryReader(data: box.data)
        _ = try? reader.readBytes(4) // version + flags
        _ = try? reader.readUInt32BigEndian() // sample_size
        return (try? reader.readUInt32BigEndian()).map(Int.init)
    }

    /// Sum the byte lengths of every sample in a track. When `sample_size` in
    /// the stsz header is non-zero, all samples share that size — multiply.
    /// Otherwise iterate the per-sample table. Used to derive per-stream
    /// bitrate when no `btrt` / `esds` field provides one.
    private static func parseSTSZTotalBytes(_ box: ISOBMFFBox) -> Int64? {
        guard box.data.count >= 12 else { return nil }
        var reader = BinaryReader(data: box.data)
        _ = try? reader.readBytes(4) // version + flags
        guard let uniformSize = try? reader.readUInt32BigEndian(),
              let count = try? reader.readUInt32BigEndian() else { return nil }
        if uniformSize > 0 {
            return Int64(uniformSize) * Int64(count)
        }
        var total: Int64 = 0
        let cap = min(count, 1 << 24)
        for _ in 0..<cap {
            guard let sz = try? reader.readUInt32BigEndian() else { break }
            total &+= Int64(sz)
        }
        return total > 0 ? total : nil
    }

    /// stts payload: version+flags(4) + entry_count(4) + [sample_count(4) + sample_delta(4)]*.
    /// Sum the sample_count fields to approximate the frame count.
    private static func parseSTTSSampleCount(_ box: ISOBMFFBox) -> Int? {
        guard box.data.count >= 8 else { return nil }
        var reader = BinaryReader(data: box.data)
        _ = try? reader.readBytes(4)
        guard let entryCount = try? reader.readUInt32BigEndian() else { return nil }
        var total: UInt64 = 0
        for _ in 0..<min(entryCount, 1 << 20) {
            guard let sc = try? reader.readUInt32BigEndian(),
                  (try? reader.skip(4)) != nil else {
                break
            }
            total &+= UInt64(sc)
        }
        return total > 0 ? Int(total) : nil
    }

    /// Pick the most-common sample delta across stts entries. ffprobe uses
    /// this to compute `r_frame_rate` — the cadence the decoder ticks at,
    /// independent of any partial trailing sample that nudges samples/duration
    /// off the integer rate.
    private static func parseSTTSDominantDelta(_ box: ISOBMFFBox) -> UInt32? {
        guard box.data.count >= 8 else { return nil }
        var reader = BinaryReader(data: box.data)
        _ = try? reader.readBytes(4)
        guard let entryCount = try? reader.readUInt32BigEndian() else { return nil }
        var counts: [UInt32: UInt64] = [:]
        for _ in 0..<min(entryCount, 1 << 20) {
            guard let sc = try? reader.readUInt32BigEndian(),
                  let sd = try? reader.readUInt32BigEndian() else { break }
            guard sd > 0 else { continue }
            counts[sd, default: 0] &+= UInt64(sc)
        }
        return counts.max(by: { $0.value < $1.value })?.key
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
