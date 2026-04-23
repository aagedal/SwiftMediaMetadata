import Foundation

/// Parses MP4/MOV/M4V video files to extract metadata.
/// Reuses ISOBMFFBoxReader for box-level parsing.
public struct MP4Parser: Sendable {

    // Seconds between 1904-01-01 and 1970-01-01 (QuickTime epoch to Unix epoch)
    private static let epochOffset: TimeInterval = 2082844800

    // XMP UUID prefix: BE7ACFCB-97A9-42E8-9C71-999491E3AFAC
    private static let xmpUUID = Data([
        0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8,
        0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC,
    ])

    /// Parse video metadata from data.
    public static func parse(_ data: Data) throws -> VideoMetadata {
        // Parse top-level boxes, but skip mdat payload to save memory
        let boxes = try parseTopLevelBoxes(data)

        // Determine format from ftyp
        guard let ftyp = boxes.first(where: { $0.type == "ftyp" }) else {
            throw MetadataError.invalidVideo("Missing ftyp box")
        }
        let format = detectFormat(from: ftyp)

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

        // Parse tracks
        for trak in moovChildren.filter({ $0.type == "trak" }) {
            parseTrak(trak.data, movieTimescale: movieTimescale, into: &metadata)
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

        // Parse udta -> meta -> ilst (QuickTime metadata)
        if let udta = moovChildren.first(where: { $0.type == "udta" }) {
            parseUDTA(udta.data, into: &metadata)
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

        // Container bit_rate fallback (matches ffprobe `format.bit_rate`).
        let containerBytes = metadata.fileSize ?? Int64(data.count)
        if metadata.bitRate == nil,
           let dur = metadata.duration, dur > 0, containerBytes > 0 {
            metadata.bitRate = Int(Double(containerBytes) * 8.0 / dur)
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
        into metadata: inout VideoMetadata
    ) {
        guard let children = try? ISOBMFFBoxReader.parseBoxes(from: data) else { return }

        // tkhd provides track-level display dimensions and flags.
        var trackWidth: Int?
        var trackHeight: Int?
        var tkhdIsDefault: Bool?
        if let tkhd = children.first(where: { $0.type == "tkhd" }) {
            if let dims = parseTKHDDimensions(tkhd.data) {
                trackWidth = dims.width
                trackHeight = dims.height
            }
            tkhdIsDefault = parseTKHDIsDefault(tkhd.data)
        }

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
            parseVisualSampleEntry(stsdBox.data, into: &stream)
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
        } else if isSubtitleHandler(handlerType), let stsdBox {
            var stream = SubtitleStream(index: metadata.subtitleStreams.count)
            stream.duration = trackDuration
            stream.language = language
            parseSubtitleSampleEntry(stsdBox.data, handlerType: handlerType, into: &stream)
            if dispositions.isDefault { stream.isDefault = true }
            if dispositions.isForced { stream.isForced = true }
            if dispositions.isHearingImpaired { stream.isHearingImpaired = true }
            metadata.subtitleStreams.append(stream)
        }
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
    private static func parseSTCOFirst(_ data: Data) -> UInt32? {
        guard data.count >= 12 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4) // flags+version
        guard let count = try? reader.readUInt32BigEndian(), count > 0,
              let first = try? reader.readUInt32BigEndian() else { return nil }
        return first
    }

    /// `co64`: FullBox header(4) + entry_count(4) + entry_count × 64-bit offsets.
    private static func parseCO64First(_ data: Data) -> UInt64? {
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
    private static func trakHandlerType(_ trakData: Data) -> String? {
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
    private static func parseMDHD(_ data: Data) -> (duration: TimeInterval?, language: String?, timescale: UInt32)? {
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

    // MARK: - Visual sample entry

    /// stsd contains one or more SampleEntry boxes. For video, the entry is a
    /// VisualSampleEntry whose fixed header is 78 bytes (after the 8-byte box
    /// header) and is followed by optional child boxes (avcC, hvcC, colr, fiel,
    /// pasp, btrt …).
    private static func parseVisualSampleEntry(_ stsdData: Data, into stream: inout VideoStream) {
        guard stsdData.count >= 16 else { return }
        var reader = BinaryReader(data: stsdData)
        _ = try? reader.readBytes(4) // FullBox header
        _ = try? reader.readUInt32BigEndian() // entry_count

        guard reader.remainingCount >= 8 else { return }
        let entryStart = reader.offset
        guard let entrySize32 = try? reader.readUInt32BigEndian(),
              let codecBytes = try? reader.readBytes(4),
              let codec = String(data: codecBytes, encoding: .ascii) else { return }

        stream.codec = codec
        stream.codecName = codecLongName(codec) ?? codec

        // Fixed VisualSampleEntry header: 78 bytes after the 8-byte box header.
        // Offsets within the entry payload:
        //   0..5   reserved
        //   6..7   data_reference_index
        //   8..23  pre_defined(16)
        //   24..27 horizresolution + 28..31 vertresolution  (both fixed-point 16.16)
        //   32..35 reserved
        //   36..37 frame_count
        //   38..69 compressor_name (Pascal string in 32 bytes)
        //   70..71 depth
        //   72..73 pre_defined (−1)
        // We still need the width/height, which live at offsets 24..27 in reality.
        // The ISO spec actually places them at offsets 24..27 — that's what we'll read.

        let payloadBase = entryStart + 8 // past size + type
        // width @ +24, height @ +26  (relative to the VisualSampleEntry start)
        if stsdData.count >= payloadBase + 32 {
            if (try? reader.seek(to: payloadBase + 24)) != nil,
               let w = try? reader.readUInt16BigEndian(),
               let h = try? reader.readUInt16BigEndian() {
                if w > 0 { stream.width = Int(w) }
                if h > 0 { stream.height = Int(h) }
            }
        }

        // depth at +74 within the VisualSampleEntry payload (see ISO/IEC 14496-12).
        // Most codecs advertise 0x18 (24 = packed RGB 8-bit) here; higher-bit-depth
        // values are rare and unreliable — the codec-specific config box (hvcC,
        // av1C, prores atom …) is the real source of truth, parsed below.
        if stsdData.count >= payloadBase + 76 {
            if (try? reader.seek(to: payloadBase + 74)) != nil,
               let depth = try? reader.readUInt16BigEndian() {
                if depth > 0, depth != 0x18, depth % 3 == 0, depth <= 96 {
                    stream.bitDepth = Int(depth / 3)
                }
            }
        }

        // The sample entry payload extends to entryStart + entrySize32; children
        // start 8 bytes after the fixed VisualSampleEntry header at payloadBase + 78.
        let entryEnd = entryStart + Int(entrySize32)
        let childrenStart = payloadBase + 78
        guard childrenStart < entryEnd, entryEnd <= stsdData.count else { return }

        let childrenData = Data(
            stsdData[(stsdData.startIndex + childrenStart) ..< (stsdData.startIndex + entryEnd)]
        )
        if let kids = try? ISOBMFFBoxReader.parseBoxes(from: childrenData) {
            for kid in kids {
                applyVisualChildBox(kid, into: &stream)
            }
        }

        // Sample entries whose FourCC uniquely identifies the codec variant
        // (ProRes, APV, ProRes RAW) can skip frame-header parsing entirely —
        // fill in profile/chroma/bit_depth from the FourCC.
        applyFourCCDefaults(codec, into: &stream)
    }

    private static func applyVisualChildBox(_ box: ISOBMFFBox, into stream: inout VideoStream) {
        switch box.type {
        case "colr":
            if let info = parseColrBox(box.data) {
                stream.colorInfo = info
            }
        case "fiel":
            if let fo = parseFielBox(box.data) {
                stream.fieldOrder = fo
            }
        case "pasp":
            if let par = parsePaspBox(box.data) {
                stream.pixelAspectRatio = par
                if let w = stream.width, par.0 > 0, par.1 > 0 {
                    stream.displayWidth = w * par.0 / par.1
                }
                if let h = stream.height { stream.displayHeight = h }
            }
        case "hvcC":
            parseHVCC(box.data, into: &stream)
        case "av1C":
            parseAV1C(box.data, into: &stream)
        case "avcC":
            // AVCDecoderConfigurationRecord (ISO/IEC 14496-15 §5.2.4.1.1):
            //   byte 0 : configurationVersion (1)
            //   byte 1 : AVCProfileIndication  (profile_idc from SPS)
            //   byte 2 : profile_compatibility
            //   byte 3 : AVCLevelIndication
            // Chroma/bit_depth live in the SPS (variable-length decode beyond
            // scope); every AVC profile shipped by Apple/Adobe/NVENC defaults
            // to 4:2:0 8-bit, so surface that.
            if box.data.count >= 2 {
                let profileIDC = box.data[box.data.startIndex + 1]
                stream.profile = avcProfileName(profileIDC)
            }
            if stream.bitDepth == nil { stream.bitDepth = 8 }
            if stream.chromaSubsampling == nil { stream.chromaSubsampling = "4:2:0" }
        case "btrt":
            if let br = parseBTRT(box.data) {
                stream.bitRate = br
            }
        case "vvcC":
            parseVVCC(box.data, into: &stream)
        default:
            break
        }
    }

    /// VvcDecoderConfigurationRecord (ISO/IEC 14496-15 §11.3) — the fields we
    /// need live in the first few bytes:
    ///   byte 0 : LengthSizeMinusOne(2) | ptl_present_flag(1) | reserved(5)
    ///   bytes 1–2 : ols_idx(9) / num_sublayers(3) / constant_frame_rate(2) /
    ///                chroma_format_idc(2)
    ///   byte 3 : bit_depth_minus8 (3 bits in the high nibble)
    /// We only peek at the chroma and bit depth — profile lives in an optional
    /// PTL record and varies too much across VVC drafts to map reliably here.
    private static func parseVVCC(_ data: Data, into stream: inout VideoStream) {
        guard data.count >= 4 else { return }
        let s = data.startIndex
        let ptlPresent = (data[s] >> 5) & 0x01
        guard ptlPresent == 1, data.count >= 5 else {
            // Without PTL the chroma/bit_depth fields aren't guaranteed — bail
            // out after setting defensible defaults (every shipping VVC clip we
            // care about is 10-bit 4:2:0 Main 10 Intra or Main 10).
            if stream.chromaSubsampling == nil { stream.chromaSubsampling = "4:2:0" }
            if stream.bitDepth == nil { stream.bitDepth = 10 }
            return
        }
        // ptl_present_flag = 1: next 2 bytes are ols_idx(9)+sublayers(3)+cfr(2)+
        // chroma_format_idc(2). Bit_depth_minus_8 is in the high 3 bits of the
        // byte that follows.
        let byte2 = data[s + 2]
        let chromaIDC = Int(byte2 & 0x03)
        let bitDepthMinus8 = Int((data[s + 3] >> 5) & 0x07)
        if stream.chromaSubsampling == nil {
            switch chromaIDC {
            case 0: stream.chromaSubsampling = "4:0:0"
            case 1: stream.chromaSubsampling = "4:2:0"
            case 2: stream.chromaSubsampling = "4:2:2"
            case 3: stream.chromaSubsampling = "4:4:4"
            default: break
            }
        }
        if stream.bitDepth == nil, bitDepthMinus8 >= 0, bitDepthMinus8 <= 8 {
            stream.bitDepth = bitDepthMinus8 + 8
        }
    }

    /// Deterministic pix_fmt / profile / bit_depth for codecs whose sample
    /// entry FourCC uniquely identifies the subcodec — notably ProRes, APV
    /// and ProRes RAW. ffprobe reads the same fields from the frame header,
    /// but every FourCC here maps 1:1 so surfacing them from the container
    /// side matches ffprobe's output without any bitstream parsing.
    private static func applyFourCCDefaults(_ codec: String, into stream: inout VideoStream) {
        switch codec {
        // Apple ProRes (SMPTE RP 2019)
        case "apco": // 422 Proxy
            stream.profile = stream.profile ?? "Proxy"
            stream.chromaSubsampling = stream.chromaSubsampling ?? "4:2:2"
            stream.bitDepth = stream.bitDepth ?? 10
        case "apcs": // 422 LT
            stream.profile = stream.profile ?? "LT"
            stream.chromaSubsampling = stream.chromaSubsampling ?? "4:2:2"
            stream.bitDepth = stream.bitDepth ?? 10
        case "apcn": // 422 Standard
            stream.profile = stream.profile ?? "Standard"
            stream.chromaSubsampling = stream.chromaSubsampling ?? "4:2:2"
            stream.bitDepth = stream.bitDepth ?? 10
        case "apch": // 422 HQ
            stream.profile = stream.profile ?? "HQ"
            stream.chromaSubsampling = stream.chromaSubsampling ?? "4:2:2"
            stream.bitDepth = stream.bitDepth ?? 10
        case "ap4h": // 4444 — always carries alpha, 12-bit YUV
            stream.profile = stream.profile ?? "4444"
            stream.chromaSubsampling = stream.chromaSubsampling ?? "4:4:4"
            stream.bitDepth = stream.bitDepth ?? 12
            stream.pixelFormat = stream.pixelFormat ?? "yuva444p12le"
        case "ap4x": // 4444 XQ
            stream.profile = stream.profile ?? "4444XQ"
            stream.chromaSubsampling = stream.chromaSubsampling ?? "4:4:4"
            stream.bitDepth = stream.bitDepth ?? 12
            stream.pixelFormat = stream.pixelFormat ?? "yuva444p12le"
        // Apple ProRes RAW
        case "aprn":
            stream.profile = stream.profile ?? "RAW"
            stream.bitDepth = stream.bitDepth ?? 12
        case "aprh":
            stream.profile = stream.profile ?? "RAW HQ"
            stream.bitDepth = stream.bitDepth ?? 12
        // APV (Advanced Professional Video, SMPTE ST 2130) — the sample entry
        // FourCC `apv1` always carries 10-bit 4:2:2 Main profile (profile_idc
        // 33). Newer 4:4:4 / 12-bit variants will need a real APVC box.
        case "apv1":
            stream.profile = stream.profile ?? "33"
            stream.chromaSubsampling = stream.chromaSubsampling ?? "4:2:2"
            stream.bitDepth = stream.bitDepth ?? 10
        default:
            break
        }
    }

    /// `btrt` (BitRateBox): buffer_size_db(4) + max_bitrate(4) + avg_bitrate(4).
    /// We prefer avg_bitrate; fall back to max_bitrate when avg is 0.
    private static func parseBTRT(_ data: Data) -> Int? {
        guard data.count >= 12 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readUInt32BigEndian() // buffer_size_db
        let maxBR = (try? reader.readUInt32BigEndian()) ?? 0
        let avgBR = (try? reader.readUInt32BigEndian()) ?? 0
        if avgBR > 0 { return Int(avgBR) }
        if maxBR > 0 { return Int(maxBR) }
        return nil
    }

    /// `colr` box: type FullBox variant. First 4 bytes are the color_type.
    ///   - "nclx": 2+2+2+1 bytes: primaries, transfer, matrix, flag (bit 7 = full_range).
    ///   - "nclc": 2+2+2 bytes: primaries, transfer, matrix (no range flag).
    ///   - "prof"/"rICC": ICC profile payload — we skip it.
    private static func parseColrBox(_ data: Data) -> VideoColorInfo? {
        guard data.count >= 4 else { return nil }
        let colorType = String(data: data.prefix(4), encoding: .ascii) ?? ""
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)

        switch colorType {
        case "nclx":
            guard data.count >= 11,
                  let p = try? reader.readUInt16BigEndian(),
                  let t = try? reader.readUInt16BigEndian(),
                  let m = try? reader.readUInt16BigEndian(),
                  let flag = try? reader.readUInt8() else { return nil }
            return VideoColorInfo(
                primaries: Int(p),
                transfer: Int(t),
                matrix: Int(m),
                fullRange: (flag & 0x80) != 0
            )
        case "nclc":
            guard data.count >= 10,
                  let p = try? reader.readUInt16BigEndian(),
                  let t = try? reader.readUInt16BigEndian(),
                  let m = try? reader.readUInt16BigEndian() else { return nil }
            return VideoColorInfo(primaries: Int(p), transfer: Int(t), matrix: Int(m), fullRange: nil)
        default:
            return nil
        }
    }

    /// `fiel` box: 1 byte field_count (1 = progressive, 2 = interlaced),
    /// 1 byte field_ordering (0/1 = TFF, 6 = BFF for MP4; 9/14 for QuickTime).
    private static func parseFielBox(_ data: Data) -> VideoFieldOrder? {
        guard data.count >= 1 else { return nil }
        let fieldCount = data[data.startIndex]
        if fieldCount == 1 { return .progressive }
        guard fieldCount == 2, data.count >= 2 else { return .mixed }
        switch data[data.startIndex + 1] {
        case 0, 1, 9: return .topFieldFirst
        case 6, 14: return .bottomFieldFirst
        default: return .unknown
        }
    }

    /// `pasp` box: 4 bytes hSpacing + 4 bytes vSpacing.
    private static func parsePaspBox(_ data: Data) -> (Int, Int)? {
        guard data.count >= 8 else { return nil }
        var reader = BinaryReader(data: data)
        guard let h = try? reader.readUInt32BigEndian(),
              let v = try? reader.readUInt32BigEndian(),
              h > 0, v > 0 else { return nil }
        return (Int(h), Int(v))
    }

    /// HEVCDecoderConfigurationRecord (ISO/IEC 14496-15, §8.3.3.1.2). The box is
    /// *not* a FullBox — the payload starts at configurationVersion.
    /// Byte offsets in the record:
    ///   0       configurationVersion
    ///   1       profile_space(2) + tier_flag(1) + profile_idc(5)
    ///   2..5    general_profile_compatibility_flags
    ///   6..11   general_constraint_indicator_flags
    ///   12      general_level_idc
    ///   13..14  reserved + min_spatial_segmentation_idc
    ///   15      reserved + parallelismType
    ///   16      reserved + chroma_format_idc   ← 0=4:0:0, 1=4:2:0, 2=4:2:2, 3=4:4:4
    ///   17      reserved + bit_depth_luma_minus8
    ///   18      reserved + bit_depth_chroma_minus8
    private static func parseHVCC(_ data: Data, into stream: inout VideoStream) {
        guard data.count >= 23 else { return }
        let s = data.startIndex
        // Byte 1 low 5 bits are profile_idc (0-31). 2=Main10, 1=Main, 3=Main
        // Still Picture, 4=Range Extensions (with chroma_format_idc deciding
        // "Main 4:2:2 10", "Main 4:4:4 12" etc.).
        let profileIDC = Int(data[s + 1] & 0x1F)
        let chromaFormatIDC = Int(data[s + 16] & 0x03)
        let bitDepthLuma = Int(data[s + 17] & 0x07) + 8
        stream.chromaSubsampling = chromaSubsamplingLabel(forIDC: chromaFormatIDC)
        stream.bitDepth = bitDepthLuma
        stream.profile = hevcProfileName(
            profileIDC: profileIDC,
            chromaFormatIDC: chromaFormatIDC,
            bitDepth: bitDepthLuma
        )
    }

    /// Map H.264 / AVC profile_idc (ISO/IEC 14496-10 Annex A.2) to the
    /// ffprobe-compatible label. Covers the common profiles encoders actually
    /// ship — rarer ones (Multiview, Stereo High) fall through to nil.
    private static func avcProfileName(_ profileIDC: UInt8) -> String? {
        switch profileIDC {
        case 66: return "Constrained Baseline"
        case 77: return "Main"
        case 88: return "Extended"
        case 100: return "High"
        case 110: return "High 10"
        case 122: return "High 4:2:2"
        case 244: return "High 4:4:4 Predictive"
        case 44: return "CAVLC 4:4:4 Intra"
        case 83: return "Scalable Baseline"
        case 86: return "Scalable High"
        case 118: return "Multiview High"
        case 128: return "Stereo High"
        default: return nil
        }
    }

    /// Map HEVC profile_idc → ffprobe-style profile string. Range-Extensions
    /// profile names depend on chroma_format_idc and bit depth, so they're
    /// composed here rather than via a flat table.
    private static func hevcProfileName(profileIDC: Int, chromaFormatIDC: Int, bitDepth: Int) -> String? {
        switch profileIDC {
        case 1: return "Main"
        case 2: return "Main 10"
        case 3: return "Main Still Picture"
        case 4:
            let chromaLabel: String
            switch chromaFormatIDC {
            case 0: return "Monochrome \(bitDepth)"
            case 1: chromaLabel = "4:2:0"
            case 2: chromaLabel = "4:2:2"
            case 3: chromaLabel = "4:4:4"
            default: return "Range Extensions"
            }
            return "Main \(chromaLabel) \(bitDepth)"
        default:
            return nil
        }
    }

    /// AV1CodecConfigurationRecord (AV1 in ISOBMFF spec, §2.3.3).
    /// Byte 2 bit layout (MSB first):
    ///   bit7 seq_tier_0
    ///   bit6 high_bitdepth
    ///   bit5 twelve_bit
    ///   bit4 monochrome
    ///   bit3 chroma_subsampling_x
    ///   bit2 chroma_subsampling_y
    ///   bits 0-1 chroma_sample_position
    private static func parseAV1C(_ data: Data, into stream: inout VideoStream) {
        guard data.count >= 3 else { return }
        let byte1 = data[data.startIndex + 1]
        let byte2 = data[data.startIndex + 2]
        // Byte 1: marker(1) + version(7), but AV1 actually uses top 3 bits as
        // seq_profile (0=Main, 1=High, 2=Professional). Seven bits would waste
        // 4 bits; ffmpeg reads byte[1] & 0xE0 >> 5.
        let seqProfile = Int((byte1 & 0xE0) >> 5)
        let highBitDepth = (byte2 >> 6) & 0x01
        let twelveBit = (byte2 >> 5) & 0x01
        let monochrome = (byte2 >> 4) & 0x01
        let ssx = (byte2 >> 3) & 0x01
        let ssy = (byte2 >> 2) & 0x01

        stream.bitDepth = twelveBit == 1 ? 12 : (highBitDepth == 1 ? 10 : 8)
        if monochrome == 1 {
            stream.chromaSubsampling = "4:0:0"
        } else if ssx == 1 && ssy == 1 {
            stream.chromaSubsampling = "4:2:0"
        } else if ssx == 1 && ssy == 0 {
            stream.chromaSubsampling = "4:2:2"
        } else if ssx == 0 && ssy == 0 {
            stream.chromaSubsampling = "4:4:4"
        }
        switch seqProfile {
        case 0: stream.profile = "Main"
        case 1: stream.profile = "High"
        case 2: stream.profile = "Professional"
        default: break
        }
    }

    private static func chromaSubsamplingLabel(forIDC idc: Int) -> String? {
        switch idc {
        case 0: return "4:0:0"
        case 1: return "4:2:0"
        case 2: return "4:2:2"
        case 3: return "4:4:4"
        default: return nil
        }
    }

    // MARK: - Audio sample entry

    /// QuickTime / ISO audio sample entry. The layout branches on a Version
    /// field in the QuickTime-specific header: Version 0 is the common case
    /// (plain PCM or compressed audio), Version 1 adds sound-description
    /// extensions used by variable-bitrate formats, and Version 2 is the
    /// full QuickTime "Sound Description V2" used by high-bit-depth LPCM.
    private static func parseAudioSampleEntry(_ stsdData: Data, into stream: inout AudioStream) {
        guard stsdData.count >= 16 else { return }
        var reader = BinaryReader(data: stsdData)
        _ = try? reader.readBytes(4) // FullBox header
        _ = try? reader.readUInt32BigEndian() // entry_count
        guard reader.remainingCount >= 8 else { return }
        let entryStart = reader.offset
        guard let entrySize32 = try? reader.readUInt32BigEndian(),
              let codecBytes = try? reader.readBytes(4),
              let codec = String(data: codecBytes, encoding: .ascii) else { return }

        stream.codec = codec
        stream.codecName = codecLongName(codec) ?? codec

        // Skip reserved(6) + data_reference_index(2).
        guard (try? reader.skip(8)) != nil else { return }

        // QuickTime audio sample entries all start with a Version field; ISO
        // files leave this as 0. The layout *after* Version differs per version.
        guard let soundVersion = try? reader.readUInt16BigEndian() else { return }
        _ = try? reader.readUInt16BigEndian() // revision_level
        _ = try? reader.readUInt32BigEndian() // vendor

        var channels = 0
        var sampleRate = 0
        var bitDepth = 0

        if soundVersion == 0 || soundVersion == 1 {
            // V0 layout (also the ISO layout):
            //   channelcount(2) + samplesize(2) + pre_defined(2) + reserved(2)
            //   + samplerate (32-bit fixed-point, Hz << 16)
            let ch = (try? reader.readUInt16BigEndian()) ?? 0
            let ss = (try? reader.readUInt16BigEndian()) ?? 0
            _ = try? reader.readUInt16BigEndian() // pre_defined/compression_id
            _ = try? reader.readUInt16BigEndian() // packet_size
            let sampleRateFP = (try? reader.readUInt32BigEndian()) ?? 0
            channels = Int(ch)
            bitDepth = Int(ss)
            sampleRate = Int(sampleRateFP >> 16)

            // V1 appends 16 bytes of compressed-sound extensions; skip them
            // so we land at the start of any child boxes.
            if soundVersion == 1 {
                _ = try? reader.skip(16)
            }
        } else if soundVersion == 2 {
            // V2 Sound Description (QuickTime File Format Reference). After
            // version/revision/vendor the layout is 16 bytes of constants
            // (repurposing V0's 16–27 slots with magic values) plus the
            // V2-specific fields:
            //   always_3(2) + always_16(2) + always_-2(2) + reserved(2)
            //   + always_65536(4) + sizeOfStructOnly(4)
            //   + audioSampleRate(Float64)
            //   + numAudioChannels(4) + always_0x7F000000(4)
            //   + constBitsPerChannel(4) + formatSpecificFlags(4)
            //   + constBytesPerAudioPacket(4) + constLPCMFramesPerAudioPacket(4)
            _ = try? reader.readUInt16BigEndian() // always_3
            _ = try? reader.readUInt16BigEndian() // always_16
            _ = try? reader.readUInt16BigEndian() // always_-2 (Int16, read as bits)
            _ = try? reader.readUInt16BigEndian() // reserved
            _ = try? reader.readUInt32BigEndian() // always_65536
            _ = try? reader.readUInt32BigEndian() // sizeOfStructOnly

            let sr64 = (try? reader.readUInt64BigEndian()) ?? 0
            let channels32 = (try? reader.readUInt32BigEndian()) ?? 0
            _ = try? reader.readUInt32BigEndian() // always_0x7F000000
            let bitsPerChannel = (try? reader.readUInt32BigEndian()) ?? 0
            _ = try? reader.readUInt32BigEndian() // formatSpecificFlags
            _ = try? reader.readUInt32BigEndian() // constBytesPerAudioPacket
            _ = try? reader.readUInt32BigEndian() // constLPCMFramesPerAudioPacket

            let srDouble = Double(bitPattern: sr64)
            if srDouble.isFinite, srDouble > 0, srDouble < Double(Int.max) {
                sampleRate = Int(srDouble)
            }
            channels = Int(channels32)
            bitDepth = Int(bitsPerChannel)
        } else {
            // Unknown version — bail out before we read bogus fields.
            return
        }

        if channels > 0 { stream.channels = channels }
        if sampleRate > 0 { stream.sampleRate = sampleRate }
        if bitDepth > 0 { stream.bitDepth = bitDepth }

        // Now scan child boxes for `chan` (channel layout), `esds`/`dOps` (codec
        // config), and `btrt` (bit rate).
        let entryEnd = entryStart + Int(entrySize32)
        guard reader.offset < entryEnd, entryEnd <= stsdData.count else { return }
        let childrenData = Data(
            stsdData[(stsdData.startIndex + reader.offset) ..< (stsdData.startIndex + entryEnd)]
        )
        if let kids = try? ISOBMFFBoxReader.parseBoxes(from: childrenData) {
            for kid in kids {
                switch kid.type {
                case "chan":
                    if let layout = parseCHAN(kid.data) {
                        stream.channelLayout = layout
                    }
                case "btrt":
                    if let br = parseBTRT(kid.data) {
                        stream.bitRate = br
                    }
                case "esds":
                    // MPEG-4 Elementary Stream Descriptor: average bit rate
                    // (DecoderConfigDescriptor) + AOT-derived profile name
                    // (DecoderSpecificInfo).
                    if let br = parseESDSAvgBitRate(kid.data) {
                        stream.bitRate = br
                    }
                    if stream.codec == "mp4a", stream.profile == nil,
                       let profile = parseESDSAACProfile(kid.data) {
                        stream.profile = profile
                    }
                default:
                    break
                }
            }
        }

        // If we still have no channel layout but `channels` is a standard
        // value, synthesize a sensible label (matches ffprobe's default).
        if stream.channelLayout == nil, let ch = stream.channels {
            stream.channelLayout = defaultChannelLayout(forChannels: ch)
        }

        // AAC profile fallback: when esds didn't surface DecoderSpecificInfo,
        // default to "LC" (the overwhelming majority of mp4a streams). ffprobe
        // does the equivalent: when avcodec can't decode the AOT it shows the
        // codec as plain `aac` with no profile, but every iPhone / Android
        // recorder we care about emits LC.
        if stream.codec == "mp4a", stream.profile == nil {
            stream.profile = "LC"
        }
    }

    /// QuickTime `chan` (ChannelLayoutBox) — FullBox(version, flags) then:
    ///   channelLayoutTag(4) + channelBitmap(4) + numberChannelDescriptions(4) + [descriptor…]
    /// Rather than maintaining a 240-entry layout tag table, we translate the
    /// most common layouts camera and editing workflows produce.
    private static func parseCHAN(_ data: Data) -> String? {
        guard data.count >= 16 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4) // FullBox header
        guard let tag = try? reader.readUInt32BigEndian() else { return nil }
        _ = try? reader.readUInt32BigEndian() // channelBitmap (when tag == UseChannelBitmap)
        _ = try? reader.readUInt32BigEndian() // numberChannelDescriptions

        // CoreAudio channel layout tags — the top 16 bits identify the family;
        // the low 16 bits store a channel count for kAudioChannelLayoutTag_Mono/Stereo/… .
        switch tag {
        case 0x64_0001: return "mono"          // Mono
        case 0x65_0002: return "stereo"        // Stereo
        case 0x66_0002: return "stereo-headphones"
        case 0x67_0004: return "4.0"           // Quadraphonic
        case 0x6C_0005: return "5.0"           // MPEG 5.0 B
        case 0x81_0006: return "5.1"           // MPEG 5.1 D
        case 0xAF_0008: return "7.1"           // AAC 7.1
        default:
            // Families that embed the channel count in the low 16 bits.
            let family = tag >> 16
            let count = Int(tag & 0xFFFF)
            if family == 0x0064, count == 1 { return "mono" }
            if family == 0x0065, count == 2 { return "stereo" }
            if count > 0 { return defaultChannelLayout(forChannels: count) }
            return nil
        }
    }

    /// Parse the MP4 Elementary Stream Descriptor for an audio track's
    /// average bit rate. Layout: [ES_Descriptor tag(1) + length(varint)]
    /// ES_ID(2) + flags(1) + [stream_dependence/URL/OCR data] +
    /// DecoderConfigDescriptor tag(1) + length(varint) + objectTypeIndication(1) +
    /// streamType+upStream+reserved(1) + bufferSizeDB(3) + maxBitrate(4) + avgBitrate(4).
    /// Here we do the minimum: locate 0x04 (DecoderConfigDescriptor) and read
    /// fields at the known offsets.
    private static func parseESDSAvgBitRate(_ data: Data) -> Int? {
        // Skip FullBox header.
        guard data.count > 4 else { return nil }
        let payload = data.suffix(from: data.startIndex + 4)
        // Find the DecoderConfigDescriptor (tag 0x04) which holds the bitrates.
        for i in payload.startIndex..<payload.endIndex {
            if payload[i] == 0x04, i + 1 < payload.endIndex {
                // Next bytes are a variable-length size (1–4 bytes, each with MSB
                // flag). Skip it.
                var off = i + 1
                var seen = 0
                while off < payload.endIndex && seen < 4 {
                    let b = payload[off]
                    off += 1; seen += 1
                    if (b & 0x80) == 0 { break }
                }
                // DecoderConfigDescriptor body: objType(1) + stream+flags(1) +
                // bufferSizeDB(3) + maxBitrate(4) + avgBitrate(4).
                guard off + 13 <= payload.endIndex else { return nil }
                let mb = UInt32(payload[off + 5]) << 24
                    | UInt32(payload[off + 6]) << 16
                    | UInt32(payload[off + 7]) << 8
                    | UInt32(payload[off + 8])
                let ab = UInt32(payload[off + 9]) << 24
                    | UInt32(payload[off + 10]) << 16
                    | UInt32(payload[off + 11]) << 8
                    | UInt32(payload[off + 12])
                if ab > 0 { return Int(ab) }
                if mb > 0 { return Int(mb) }
                return nil
            }
        }
        return nil
    }

    /// Pull the MPEG-4 audio object type out of an `esds` box and map it to the
    /// short profile labels ffprobe reports (`LC`, `HE-AAC`, `HE-AACv2`, `LD`).
    /// Layout: ES_Descriptor (tag 0x03) → DecoderConfigDescriptor (0x04) →
    /// DecoderSpecificInfo (0x05) whose first 5 bits are the audio object type.
    private static func parseESDSAACProfile(_ data: Data) -> String? {
        guard data.count > 4 else { return nil }
        let payload = data.suffix(from: data.startIndex + 4)
        // Locate the DecoderSpecificInfo descriptor (tag 0x05) directly — its
        // payload begins with the AudioObjectType packed in the high 5 bits.
        var i = payload.startIndex
        while i < payload.endIndex {
            if payload[i] == 0x05, i + 1 < payload.endIndex {
                var off = i + 1
                var size = 0
                var seen = 0
                while off < payload.endIndex, seen < 4 {
                    let b = payload[off]
                    size = (size << 7) | Int(b & 0x7F)
                    off += 1; seen += 1
                    if (b & 0x80) == 0 { break }
                }
                guard size >= 1, off < payload.endIndex else { return nil }
                let aot = Int(payload[off] >> 3) & 0x1F
                switch aot {
                case 1: return "Main"
                case 2: return "LC"
                case 3: return "SSR"
                case 4: return "LTP"
                case 5: return "HE-AAC"
                case 6: return "Scalable"
                case 7: return "TwinVQ"
                case 17: return "ER LC"
                case 19: return "ER LTP"
                case 23: return "LD"
                case 29: return "HE-AACv2"
                case 39: return "ELD"
                default: return nil
                }
            }
            i += 1
        }
        return nil
    }

    /// ffprobe-style default channel layout for a given count. We use these
    /// names for consistency with the rest of the AV ecosystem.
    private static func defaultChannelLayout(forChannels n: Int) -> String? {
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

    // MARK: - Codec name lookup

    private static func codecLongName(_ fourCC: String) -> String? {
        switch fourCC {
        case "avc1", "avc3": return "H.264 / AVC"
        case "hvc1", "hev1": return "H.265 / HEVC"
        case "hev2", "dvh1", "dvhe": return "HEVC (Dolby Vision)"
        case "vvc1", "vvi1": return "H.266 / VVC"
        case "av01": return "AV1"
        case "vp08": return "VP8"
        case "vp09": return "VP9"
        case "apch", "apcn", "apcs", "apco", "ap4h", "ap4x": return "Apple ProRes"
        case "aprh", "aprn": return "Apple ProRes RAW"
        case "mp4v": return "MPEG-4 Visual"
        case "s263": return "H.263"
        case "dvh1\0": return "Dolby Vision HEVC"
        case "mp4a": return "AAC"
        case "alac": return "ALAC"
        case "ac-3": return "Dolby Digital (AC-3)"
        case "ec-3": return "Dolby Digital Plus (E-AC-3)"
        case "Opus": return "Opus"
        case "twos", "sowt": return "PCM (signed, big/little endian)"
        case "lpcm": return "Linear PCM"
        case "fl32", "fl64": return "PCM (floating point)"
        case "in24", "in32": return "PCM (signed 24/32-bit)"
        case "samr": return "AMR"
        case "mlpa": return "MLP"
        default: return nil
        }
    }

    // MARK: - User Data (udta -> meta -> ilst)

    private static func parseUDTA(_ data: Data, into metadata: inout VideoMetadata) {
        guard let children = try? ISOBMFFBoxReader.parseBoxes(from: data) else { return }

        if let meta = children.first(where: { $0.type == "meta" }) {
            parseMetaBox(meta.data, into: &metadata)
        }

        // QuickTime user-data timecode atoms written by Sony/Panasonic/ARRI
        // broadcast camcorders directly under moov > udta (not under ilst):
        //   ©TIM / @TIM — UTF-8 timecode string (HH:MM:SS:FF)
        //   tmcd       — same 4-byte frame counter as the tmcd track form,
        //                using the following TimecodeSampleDescription
        //                layout. Rare in practice; ffprobe ignores it.
        //
        // ISOBMFF/QuickTime user-data text atoms have the layout
        // `UInt16 textSize + UInt16 language + UTF-8 text`. Some writers put
        // the raw UTF-8 string directly instead — detect both.
        for child in children {
            let type = child.type
            let isTimText = (type == "\u{00A9}TIM" || type == "@TIM")
            guard isTimText else { continue }
            if let tc = decodeUDTATextAtom(child.data) {
                metadata.recordTimecode(tc, source: .quicktimeUdta)
            }
        }
    }

    /// Decode a QuickTime user-data text atom payload, handling both the
    /// `UInt16 length + UInt16 language + UTF-8` shape and the bare-UTF-8
    /// shape some muxers emit. Returns nil when the payload doesn't look
    /// like printable text.
    private static func decodeUDTATextAtom(_ data: Data) -> String? {
        guard data.count >= 1 else { return nil }

        // Prefer the `length + language + text` shape when the declared
        // length fits inside the payload. QuickTime uses this exact layout
        // for every ©xxx atom under moov > udta.
        if data.count >= 4 {
            let s = data.startIndex
            let len = (Int(data[s]) << 8) | Int(data[s + 1])
            if len > 0, data.count >= 4 + len {
                let textRange = (s + 4)..<(s + 4 + len)
                if let str = String(data: Data(data[textRange]), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty {
                    return str
                }
            }
        }

        // Fallback: raw UTF-8 (a handful of older Panasonic P2 files do this).
        if let str = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)),
           !str.isEmpty,
           str.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/-:;. ".contains($0)) }) {
            return str
        }

        return nil
    }

    private static func parseMetaBox(_ data: Data, into metadata: inout VideoMetadata) {
        // meta is a FullBox — skip 4-byte version/flags header
        guard data.count > 4 else { return }
        let metaPayload = data.suffix(from: data.startIndex + 4)
        guard let children = try? ISOBMFFBoxReader.parseBoxes(from: Data(metaPayload)) else { return }

        if let ilst = children.first(where: { $0.type == "ilst" }) {
            parseILST(ilst.data, into: &metadata)
        }

        // Check for xml box (XMP)
        if let xml = children.first(where: { $0.type == "xml " }) {
            if let xmpData = try? XMPReader.readFromXML(xml.data) {
                metadata.xmp = xmpData
            }
        }
    }

    private static func parseILST(_ data: Data, into metadata: inout VideoMetadata) {
        guard let items = try? ISOBMFFBoxReader.parseBoxes(from: data) else { return }

        for item in items {
            // Each item contains a "data" sub-box
            guard let dataBox = (try? ISOBMFFBoxReader.parseBoxes(from: item.data))?.first(where: { $0.type == "data" }) else {
                continue
            }

            // data box: type_indicator (4 bytes) + locale (4 bytes) + payload
            guard dataBox.data.count > 8 else { continue }
            let payload = dataBox.data.suffix(from: dataBox.data.startIndex + 8)

            // Get type indicator (first 4 bytes, big-endian UInt32)
            var typeReader = BinaryReader(data: dataBox.data)
            let typeIndicator = (try? typeReader.readUInt32BigEndian()) ?? 0

            // Map item type to metadata field
            let rawType = item.type

            // QuickTime keys use byte 0xA9 (©) which maps to \u{00A9} in isoLatin1
            let key: String
            if rawType.count == 4 && rawType.unicodeScalars.first?.value == 0xA9 {
                key = String(rawType.dropFirst())
            } else {
                key = rawType
            }

            switch key {
            case "nam":
                if typeIndicator == 1, let s = String(data: payload, encoding: .utf8) {
                    metadata.title = s
                }
            case "ART":
                if typeIndicator == 1, let s = String(data: payload, encoding: .utf8) {
                    metadata.artist = s
                }
            case "cmt":
                if typeIndicator == 1, let s = String(data: payload, encoding: .utf8) {
                    metadata.comment = s
                }
            case "day":
                // Date — just store as-is in comment for now
                break
            case "xyz":
                // GPS: "+DD.DDDD+DDD.DDDD/" or "+DD.DDDD+DDD.DDDD+AAAA.AA/"
                if let s = String(data: payload, encoding: .utf8) {
                    parseGPSXYZ(s, into: &metadata)
                }
            default:
                break
            }
        }
    }

    // MARK: - GPS from ©xyz

    static func parseGPSXYZ(_ string: String, into metadata: inout VideoMetadata) {
        // Format: "+DD.DDDD+DDD.DDDD/" or "+DD.DDDD-DDD.DDDD+AAAA.AA/"
        var cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("/") { cleaned = String(cleaned.dropLast()) }
        guard !cleaned.isEmpty else { return }

        // Split on +/- boundaries, keeping the sign
        var components: [String] = []
        var current = ""
        for char in cleaned {
            if (char == "+" || char == "-") && !current.isEmpty {
                components.append(current)
                current = String(char)
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { components.append(current) }

        if components.count >= 2 {
            metadata.gpsLatitude = Double(components[0])
            metadata.gpsLongitude = Double(components[1])
        }
        if components.count >= 3 {
            metadata.gpsAltitude = Double(components[2])
        }
    }

    // MARK: - UUID (XMP / embedded XML)

    private static func parseUUIDBox(_ data: Data, into metadata: inout VideoMetadata) {
        guard data.count > 16 else { return }
        let uuid = data.prefix(16)
        let payload = Data(data.suffix(from: data.startIndex + 16))

        if uuid == xmpUUID {
            if let xmpData = try? XMPReader.readFromXML(payload) {
                metadata.xmp = xmpData
            }
            return
        }

        // Some Sony MP4 cameras embed NonRealTimeMeta inside a uuid box.
        // The user-type UUID varies between firmware versions, so content-sniff
        // instead of matching a fixed UUID.
        if looksLikeNRT(payload) {
            if let cam = try? NRTXMLParser.parse(payload) {
                metadata.camera = cam
            }
        }
    }

    private static func looksLikeNRT(_ data: Data) -> Bool {
        guard data.count > 16 else { return false }
        let scanLimit = min(data.count, 4096)
        guard let head = String(data: data.prefix(scanLimit), encoding: .utf8) else {
            return false
        }
        return head.contains("NonRealTimeMeta")
    }
}
