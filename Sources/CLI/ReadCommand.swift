import ArgumentParser
import Foundation
import SwiftExif

struct ReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read and display metadata from image/video files."
    )

    @Argument(help: "Image or video files to read.")
    var files: [String]

    @OptionGroup var fileFilter: FileFilterOptions

    @Option(name: .long, help: "Output format: table (default), json, csv, xml.")
    var format: OutputFormat = .table

    @Option(name: .long, help: "Filter by metadata group: exif, iptc, xmp, c2pa, icc, makernote, composite, file.")
    var group: [String] = []

    @Flag(name: .shortAndLong, help: "Show raw numeric values (skip print conversion).")
    var numeric = false

    @Option(name: .long, help: "Only include specific fields (comma-separated).")
    var fields: String?

    @Option(name: .long, help: "Filter condition (e.g. 'Make=Canon', 'ISO>800').")
    var `if`: [String] = []

    @Option(name: .long, help: "Include only tags matching glob pattern (e.g. 'IPTC:*').")
    var tags: [String] = []

    @Option(name: .long, help: "Exclude tags matching glob pattern (e.g. 'MakerNote:*').")
    var excludeTags: [String] = []

    @Flag(name: .long, help: "Compute File:MD5 and File:SHA256 hashes (slow on large files).")
    var hash = false

    @Flag(name: .long, help: "For video/audio files, emit per-stream detail (ffprobe-style).")
    var streams = false

    @Option(name: [.customShort("d"), .long],
            help: "Reformat date/time tags using a strftime pattern (e.g. \"%Y-%m-%d\", \"%FT%T\"). Applies to DateTime*, GPS*Date*, FileModifyDate, etc.")
    var dateFormat: String?

    @Flag(name: [.customShort("G"), .customLong("show-groups")],
          help: "Prefix every output key with its metadata group (EXIF:, File:, IPTC:, …) — matches ExifTool's -G flag.")
    var showGroups = false

    func run() throws {
        let urls = try resolveFiles(files, filter: fileFilter)
        let condition = try parseConditions(self.if)
        let fieldList = fields?.split(separator: ",").map(String.init)
        let groups = Set(group)
        let tagFilter = (!tags.isEmpty || !excludeTags.isEmpty)
            ? TagFilter(tags: tags, excludeTags: excludeTags) : nil

        var imageDicts: [[String: String]] = []
        var videoDicts: [[String: String]] = []
        var audioDicts: [[String: String]] = []
        var imageNames: [String] = []
        var videoNames: [String] = []
        var audioNames: [String] = []
        // Raw video clip-level blocks preserved with nested arrays/dicts (Timecodes,
        // MCAAudioLabeling, …) for the JSON output path. Index-aligned with
        // `videoDicts` so we can swap one for the other when emitting JSON.
        var videoRawDicts: [[String: Any]] = []
        // `format` carries the video "clip-level" block — emitted via JSON
        // serialization, so the value type is `[String: Any]` to preserve
        // nested arrays (e.g. Timecodes: [{ value, source, frameRate }]).
        var perStreamReports: [(name: String, format: [String: Any], streams: [[String: Any]], chapters: [[String: Any]])] = []

        for url in urls {
            if supportedAudioExtensions.contains(url.pathExtension.lowercased()) {
                let am = try AudioMetadata.read(from: url)
                var dict = AudioMetadataExporter.buildDictionary(am).mapValues { String(describing: $0) }
                if showGroups { dict = applyGroupPrefix(to: dict, defaultGroup: "Audio") }
                applyDateFormat(to: &dict, pattern: dateFormat)
                audioDicts.append(dict)
                audioNames.append(url.lastPathComponent)
                if streams {
                    // Audio files have one stream; emit the same shape as
                    // ffprobe so downstream tooling can treat .mp3/.m4a/.flac
                    // exactly like a single-track container.
                    let fileSize = (try? FileManager.default
                        .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
                    let format = buildAudioFileFormatDict(am, fileSize: fileSize)
                    let streamDicts = [buildAudioFileStreamDict(am)]
                    perStreamReports.append((url.lastPathComponent, format,
                                             streamDicts, []))
                }
            } else if supportedVideoExtensions.contains(url.pathExtension.lowercased()) {
                let vm = try VideoMetadata.read(from: url)
                var rawDict = VideoMetadataExporter.buildDictionary(vm)
                if showGroups { rawDict = applyGroupPrefix(to: rawDict, defaultGroup: "Video") }
                // Stringify for the display/CSV/table path; retain the
                // native typed dict for JSON stream output so nested arrays
                // like Timecodes serialise as real JSON arrays.
                var dict = rawDict.mapValues { String(describing: $0) }
                applyDateFormat(to: &dict, pattern: dateFormat)
                videoDicts.append(dict)
                videoRawDicts.append(rawDict)
                videoNames.append(url.lastPathComponent)
                if streams {
                    perStreamReports.append((url.lastPathComponent, rawDict,
                                             buildStreamDicts(vm),
                                             buildChapterDicts(vm)))
                }
            } else {
                let metadata = try ImageMetadata.read(from: url)
                if let condition, !condition.matches(metadata) { continue }

                let dict: [String: String]
                if numeric {
                    let raw = MetadataExporter.buildDictionary(metadata, fileURL: url, includeHashes: hash)
                    dict = raw.mapValues { value in
                        if let arr = value as? [String] { return arr.joined(separator: ", ") }
                        return String(describing: value)
                    }
                } else {
                    dict = PrintConverter.buildReadableDictionary(metadata, fileURL: url, includeHashes: hash)
                }
                var filtered = filterByGroups(dict, groups: groups, fields: fieldList)
                if let tagFilter { filtered = tagFilter.apply(to: filtered).mapValues { String(describing: $0) } }
                if showGroups { filtered = applyGroupPrefix(to: filtered, defaultGroup: "EXIF") }
                applyDateFormat(to: &filtered, pattern: dateFormat)
                imageDicts.append(filtered)
                imageNames.append(url.lastPathComponent)
            }
        }

        let allDicts = imageDicts + videoDicts + audioDicts
        let allNames = imageNames + videoNames + audioNames

        switch format {
        case .json:
            if streams && !perStreamReports.isEmpty {
                printStreamsJSON(perStreamReports)
            } else {
                // For JSON we want nested arrays/dicts (Timecodes, MCAAudioLabeling,
                // …) to come through structured, not stringified. Substitute the raw
                // typed video dicts back into the combined ordering.
                var mixedAny: [Any] = []
                for d in imageDicts { mixedAny.append(d) }
                for d in videoRawDicts { mixedAny.append(d) }
                for d in audioDicts { mixedAny.append(d) }
                if let data = try? JSONSerialization.data(withJSONObject: mixedAny, options: [.prettyPrinted, .sortedKeys]) {
                    print(String(data: data, encoding: .utf8) ?? "[]")
                }
            }
        case .csv:
            printCSV(allDicts)
        case .xml:
            for dict in allDicts {
                printXML(dict)
            }
        case .table:
            for (i, dict) in allDicts.enumerated() {
                if allDicts.count > 1 {
                    printSeparator(allNames[i])
                }
                printTable(dict)
            }
            if streams {
                for report in perStreamReports {
                    printSeparator("\(report.name) — streams")
                    for (i, sd) in report.streams.enumerated() {
                        if report.streams.count > 1 { print("--- Stream #\(i) ---") }
                        // Table path displays a textual projection of the
                        // typed stream dict — structured per-stream values
                        // (just Timecode today) still collapse to a string.
                        printTable(sd.mapValues { String(describing: $0) })
                    }
                }
            }
        }
    }

    private func buildStreamDicts(_ vm: VideoMetadata) -> [[String: Any]] {
        // When the parser populated streamOrder (MP4/MOV/M4V today) we emit
        // streams in the source's trak iteration order — that's what ffprobe
        // does, and it preserves any audio-first / video-second files like
        // the Atomos Ninja ProRes RAW recordings. Other parsers (MKV, MXF,
        // AVI, MPEG) still grouped-by-type until they're migrated; in that
        // case we keep the legacy [video, audio, subtitle] ordering.
        if !vm.streamOrder.isEmpty {
            var rows: [[String: Any]] = []
            for kind in vm.streamOrder {
                switch kind {
                case .video(let i)    where i < vm.videoStreams.count:
                    rows.append(buildVideoStreamDict(vm.videoStreams[i]))
                case .audio(let i)    where i < vm.audioStreams.count:
                    rows.append(buildAudioStreamDict(vm.audioStreams[i]))
                case .subtitle(let i) where i < vm.subtitleStreams.count:
                    rows.append(buildSubtitleStreamDict(vm.subtitleStreams[i]))
                case .data(let i)     where i < vm.dataStreams.count:
                    rows.append(buildDataStreamDict(vm.dataStreams[i]))
                default: continue
                }
            }
            return rows
        }
        var rows: [[String: Any]] = []
        for stream in vm.videoStreams { rows.append(buildVideoStreamDict(stream)) }
        for stream in vm.audioStreams { rows.append(buildAudioStreamDict(stream)) }
        for stream in vm.subtitleStreams { rows.append(buildSubtitleStreamDict(stream)) }
        return rows
    }

    private func buildVideoStreamDict(_ stream: VideoStream) -> [String: Any] {
        var d: [String: Any] = ["StreamType": "video", "Index": String(stream.index)]
            if let v = stream.codec          { d["Codec"]            = v }
            if let v = stream.codecName      { d["CodecName"]        = v }
            if let v = stream.codec, let s = ffprobeShortVideoCodec(v) { d["CodecShort"] = s }
            if let v = stream.profile        { d["Profile"]          = v }
            if let v = stream.width          { d["Width"]            = String(v) }
            if let v = stream.height         { d["Height"]           = String(v) }
            if let v = stream.displayWidth   { d["DisplayWidth"]     = String(v) }
            if let v = stream.displayHeight  { d["DisplayHeight"]    = String(v) }
            if let p = stream.pixelAspectRatio { d["PixelAspectRatio"] = "\(p.0):\(p.1)" }
            if let w = stream.displayWidth, let h = stream.displayHeight, w > 0, h > 0 {
                let g = gcdInt(w, h)
                d["DisplayAspectRatio"] = "\(w / g):\(h / g)"
            }
            if let v = stream.bitDepth       { d["BitDepth"]         = String(v) }
            if let v = stream.bitRate        { d["BitRate"]          = String(v) }
            if let v = stream.frameRate      { d["FrameRate"]        = String(v) }
            if let v = stream.avgFrameRate   { d["AvgFrameRate"]     = String(v) }
            if let v = stream.rFrameRate     { d["RFrameRate"]       = String(v) }
            if let v = stream.duration       { d["Duration"]         = String(v) }
            if let v = stream.fieldOrder     { d["FieldOrder"]       = v.rawValue }
            if let v = stream.chromaSubsampling { d["ChromaSubsampling"] = v }
            if let v = stream.chromaLocation { d["ChromaLocation"]   = v }
            if let v = stream.pixelFormat    { d["PixelFormat"]      = v }
            if let v = stream.frameCount     { d["FrameCount"]       = String(v) }
            // Disposition flags — always emit so JSON consumers can read a
            // stable shape rather than guess at missing keys.
            d["IsAttachedPic"]    = String(stream.isAttachedPic ?? false)
            d["IsDefault"]        = String(stream.isDefault ?? true)
            d["IsForced"]         = String(stream.isForced ?? false)
            if let v = stream.timecode       { d["Timecode"]         = v }
            if let v = stream.title          { d["Title"]            = v }
            if let v = stream.rotation       { d["Rotation"]         = String(v) }
            if let hdr = stream.hdr {
                if let md = hdr.masteringDisplay {
                    d["MasteringDisplayPrimariesR"] = String(format: "%.4f,%.4f", md.redX, md.redY)
                    d["MasteringDisplayPrimariesG"] = String(format: "%.4f,%.4f", md.greenX, md.greenY)
                    d["MasteringDisplayPrimariesB"] = String(format: "%.4f,%.4f", md.blueX, md.blueY)
                    d["MasteringDisplayWhitePoint"] = String(format: "%.4f,%.4f", md.whitePointX, md.whitePointY)
                    d["MasteringDisplayLuminance"]  = String(format: "%.1f-%.4f cd/m^2", md.maxLuminance, md.minLuminance)
                }
                if let cll = hdr.contentLightLevel {
                    d["MaxCLL"]  = String(cll.maxCLL)
                    d["MaxFALL"] = String(cll.maxFALL)
                }
                if let dv = hdr.dolbyVision {
                    d["DolbyVisionProfile"] = String(dv.profile)
                    d["DolbyVisionLevel"]   = String(dv.level)
                    d["DolbyVisionVersion"] = "\(dv.versionMajor).\(dv.versionMinor)"
                    d["DolbyVisionBLCompatibility"] = String(dv.blSignalCompatibilityID)
                }
            }
            if let c = stream.colorInfo {
                if let p = c.primaries { d["ColorPrimaries"] = String(p) }
                if let t = c.transfer  { d["TransferCharacteristics"] = String(t) }
                if let m = c.matrix    { d["MatrixCoefficients"] = String(m) }
                if let r = c.fullRange { d["ColorRange"] = r ? "pc" : "tv" }
                if let l = c.label     { d["ColorSpace"] = l }
            }
            return d
    }

    private func buildAudioStreamDict(_ stream: AudioStream) -> [String: Any] {
        var d: [String: Any] = ["StreamType": "audio", "Index": String(stream.index)]
        if let v = stream.codec         { d["Codec"]         = v }
        if let v = stream.codecName     { d["CodecName"]     = v }
        if let v = stream.codec, let s = ffprobeShortAudioCodec(v, bitDepth: stream.bitDepth) {
            d["CodecShort"] = s
        }
        if let v = stream.profile       { d["Profile"]       = v }
        if let v = stream.sampleRate    { d["SampleRate"]    = String(v) }
        if let v = stream.channels      { d["Channels"]      = String(v) }
        if let v = stream.channelLayout { d["ChannelLayout"] = v }
        if let v = stream.bitDepth      { d["BitDepth"]      = String(v) }
        if let v = stream.bitRate       { d["BitRate"]       = String(v) }
        if let v = stream.duration      { d["Duration"]      = String(v) }
        if let v = stream.language      { d["Language"]      = v }
        d["IsDefault"] = String(stream.isDefault ?? true)
        if let v = stream.title         { d["Title"]         = v }
        if let v = stream.mcaChannelLabel             { d["MCAChannelLabel"]             = v }
        if let v = stream.mcaChannelName              { d["MCAChannelName"]              = v }
        if let v = stream.mcaSoundfieldGroup          { d["MCASoundfieldGroup"]          = v }
        if let v = stream.mcaGroupOfSoundfieldGroups  { d["MCAGroupOfSoundfieldGroups"]  = v }
        return d
    }

    private func buildSubtitleStreamDict(_ stream: SubtitleStream) -> [String: Any] {
        var d: [String: Any] = ["StreamType": "subtitle", "Index": String(stream.index)]
        if let v = stream.codec             { d["Codec"]     = v }
        if let v = stream.codecName         { d["CodecName"] = v }
        if let v = stream.codec, let s = ffprobeShortSubtitleCodec(v) { d["CodecShort"] = s }
        if let v = stream.language          { d["Language"]  = v }
        if let v = stream.title             { d["Title"]     = v }
        d["IsDefault"]         = String(stream.isDefault ?? true)
        d["IsForced"]          = String(stream.isForced ?? false)
        d["IsHearingImpaired"] = String(stream.isHearingImpaired ?? false)
        if let v = stream.duration          { d["Duration"]  = String(v) }
        return d
    }

    private func buildDataStreamDict(_ stream: DataStream) -> [String: Any] {
        var d: [String: Any] = ["StreamType": "data", "Index": String(stream.index)]
        d["HandlerType"] = stream.handlerType
        if let v = stream.codec     { d["Codec"]     = v }
        if let v = stream.codecName { d["CodecName"] = v }
        if let s = ffprobeShortDataCodec(handler: stream.handlerType, codec: stream.codec) {
            d["CodecShort"] = s
        }
        if let v = stream.language  { d["Language"]  = v }
        if let v = stream.title     { d["Title"]     = v }
        if let v = stream.duration  { d["Duration"]  = String(v) }
        d["IsDefault"] = String(stream.isDefault ?? false)
        return d
    }

    /// Mirror ffprobe's `codec_name` for a data-track handler. ffprobe maps
    /// QuickTime chapter-text tracks to `bin_data` (despite the stsd FourCC
    /// being `text`); for `tmcd`/`mebx`/`mdta` it leaves codec_name unset.
    private func ffprobeShortDataCodec(handler: String, codec: String?) -> String? {
        if handler == "text" { return "bin_data" }
        return nil
    }

    private func gcdInt(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }

    /// Map container-native video codec ids onto ffmpeg's short codec names
    /// (e.g. "hvc1" / "V_MPEGH/ISO/HEVC" → "hevc"). Consumers that already key
    /// off ffprobe output can drop SwiftExif in without a translation table.
    private func ffprobeShortVideoCodec(_ codec: String) -> String? {
        switch codec {
        case "V_MPEG4/ISO/AVC", "avc1", "avc3": return "h264"
        case "V_MPEGH/ISO/HEVC", "hvc1", "hev1", "hev2", "dvh1", "dvhe": return "hevc"
        case "V_AV1", "av01": return "av1"
        case "V_VP8", "vp08": return "vp8"
        case "V_VP9", "vp09": return "vp9"
        case "V_MPEG4/ISO/ASP", "mp4v": return "mpeg4"
        case "V_MPEG2": return "mpeg2video"
        case "V_MPEG1": return "mpeg1video"
        case "V_PRORES", "apch", "apcn", "apcs", "apco", "ap4h", "ap4x": return "prores"
        case "aprh", "aprn": return "prores_raw"
        case "apv1": return "apv"
        case "V_THEORA": return "theora"
        case "V_MJPEG", "mjpa", "mjpb", "jpeg": return "mjpeg"
        case "vvc1", "vvi1": return "vvc"
        default: return nil
        }
    }

    /// Map container-native audio codec ids onto ffmpeg's short codec names.
    /// PCM short names depend on bit depth and endianness (e.g. `pcm_s24le`,
    /// `pcm_s16be`) — ISOBMFF spells endianness in the FourCC (`sowt`/`twos`),
    /// Matroska in the codec id, and bit depth comes from the audio sample
    /// entry. We mirror ffprobe's naming convention so downstream tooling can
    /// pattern-match a single string.
    private func ffprobeShortAudioCodec(_ codec: String, bitDepth: Int?) -> String? {
        switch codec {
        case "A_AAC", "A_AAC/MPEG4/LC", "A_AAC/MPEG4/LC/SBR", "mp4a": return "aac"
        case "A_AC3", "ac-3": return "ac3"
        case "A_EAC3", "ec-3": return "eac3"
        case "A_DTS", "A_DTS/EXPRESS", "A_DTS/LOSSLESS": return "dts"
        case "A_FLAC", "fLaC": return "flac"
        case "A_OPUS", "Opus": return "opus"
        case "A_VORBIS": return "vorbis"
        case "A_MPEG/L3": return "mp3"
        case "A_MPEG/L2": return "mp2"
        case "A_TRUEHD": return "truehd"
        case "alac": return "alac"
        // PCM family — ffprobe encodes bit depth + endianness in the codec
        // name. Match that so consumers can parse a single string.
        case "lpcm":
            return pcmShortName(bitDepth: bitDepth, endian: .little, signed: true)
        case "ipcm":
            return pcmShortName(bitDepth: bitDepth, endian: .big, signed: true)
        case "sowt":
            return pcmShortName(bitDepth: bitDepth, endian: .little, signed: true)
        case "twos":
            return pcmShortName(bitDepth: bitDepth, endian: .big, signed: true)
        case "in24":
            return pcmShortName(bitDepth: 24, endian: .big, signed: true)
        case "in32":
            return pcmShortName(bitDepth: 32, endian: .big, signed: true)
        case "fl32":
            return "pcm_f32be"
        case "fl64":
            return "pcm_f64be"
        case "A_PCM/INT/LIT":
            return pcmShortName(bitDepth: bitDepth, endian: .little, signed: true)
        case "A_PCM/INT/BIG":
            return pcmShortName(bitDepth: bitDepth, endian: .big, signed: true)
        case "A_PCM/FLOAT/IEEE":
            return (bitDepth ?? 32) == 64 ? "pcm_f64le" : "pcm_f32le"
        default: return nil
        }
    }

    private enum PCMEndian { case little, big }

    private func pcmShortName(bitDepth: Int?, endian: PCMEndian, signed: Bool) -> String {
        let depth = bitDepth ?? 16
        let suffix = endian == .little ? "le" : "be"
        let prefix = signed ? "s" : "u"
        return "pcm_\(prefix)\(depth)\(suffix)"
    }

    private func ffprobeShortSubtitleCodec(_ codec: String) -> String? {
        switch codec {
        case "S_TEXT/UTF8": return "subrip"
        case "S_TEXT/ASS": return "ass"
        case "S_TEXT/SSA": return "ssa"
        case "S_TEXT/WEBVTT", "wvtt": return "webvtt"
        case "S_VOBSUB": return "dvd_subtitle"
        case "S_HDMV/PGS": return "hdmv_pgs_subtitle"
        case "S_HDMV/TEXTST": return "hdmv_text_subtitle"
        // ffmpeg maps both 3GPP timed text (`tx3g`) and QuickTime text
        // (`text`) sample entries to AV_CODEC_ID_MOV_TEXT, so its
        // `codec_name` is `mov_text` for either FourCC.
        case "tx3g", "text": return "mov_text"
        default: return nil
        }
    }

    private func printStreamsJSON(_ reports: [(name: String, format: [String: Any], streams: [[String: Any]], chapters: [[String: Any]])]) {
        var out: [[String: Any]] = []
        for report in reports {
            // Mirror ffprobe's `-show_streams -show_chapters` shape: streams
            // and chapters are sibling top-level arrays. Chapters used to be
            // mixed into `streams` with StreamType="chapter", which inflated
            // the stream count for files like ChapterMarkerTest.mov; ffprobe
            // never reports them that way.
            var rec: [String: Any] = [
                "file": report.name,
                // Clip-level metadata (ffprobe "format") — exposes Timecode,
                // Duration, BitRate, FormatLongName, creation dates, GPS, etc.
                // that don't belong on any single stream.
                "format": report.format,
                "streams": report.streams,
            ]
            if !report.chapters.isEmpty { rec["chapters"] = report.chapters }
            out.append(rec)
        }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: data, encoding: .utf8) ?? "[]")
        }
    }

    /// Build a single-stream dict for an audio file. ffprobe surfaces the
    /// same fields for `mp3`/`m4a`/`flac`/`opus`/`ogg` audio under
    /// `streams[0]` (codec_type=audio).
    private func buildAudioFileStreamDict(_ am: AudioMetadata) -> [String: Any] {
        var d: [String: Any] = ["StreamType": "audio", "Index": "0"]
        if let v = am.codec         { d["Codec"]         = v }
        if let v = am.codecName     { d["CodecName"]     = v }
        if let v = am.codec, let s = ffprobeShortAudioCodec(v, bitDepth: am.bitDepth) {
            d["CodecShort"] = s
        }
        if let v = am.sampleRate    { d["SampleRate"]    = String(v) }
        if let v = am.channels      { d["Channels"]      = String(v) }
        // ffprobe always emits a channel_layout for audio streams. Fall back
        // to the channel-count default when the parser didn't set one
        // explicitly (typical for MP3, where ID3v2 has no layout field).
        if let layout = am.channelLayout ?? defaultChannelLayout(am.channels) {
            d["ChannelLayout"] = layout
        }
        if let v = am.bitDepth      { d["BitDepth"]      = String(v) }
        if let v = am.bitrate       { d["BitRate"]       = String(v) }
        if let v = am.duration      { d["Duration"]      = String(v) }
        d["IsDefault"] = "true"
        if let v = am.title         { d["Title"]         = v }
        return d
    }

    /// Build the clip-level `format` block for an audio file. Mirrors the
    /// fields ffprobe puts under `format` for the same input.
    ///
    /// `format.bit_rate` is the **whole-file** rate (file_size × 8 ÷ duration),
    /// which differs from the audio stream's declared bitrate whenever the
    /// container has overhead or the encoder used AAC priming/postroll
    /// (iTunSMPB-style padding for lossless trim). ffprobe always reports the
    /// whole-file rate at format level; the per-stream value lives on the
    /// stream dict (`am.bitrate`).
    private func buildAudioFileFormatDict(_ am: AudioMetadata, fileSize: Int64? = nil) -> [String: Any] {
        var f: [String: Any] = [:]
        f["FileFormat"] = audioFormatLongName(am.format)
        f["FormatLongName"] = audioFormatLongName(am.format)
        f["NumStreams"] = 1
        f["AudioStreamCount"] = 1
        if let v = am.duration { f["Duration"] = v }
        if let size = fileSize, size > 0, let dur = am.duration, dur > 0 {
            f["BitRate"] = Int(Double(size) * 8.0 / dur)
        } else if let v = am.bitrate {
            f["BitRate"] = v
        }
        if let v = am.codec     { f["AudioCodec"]      = v }
        if let v = am.sampleRate { f["AudioSampleRate"] = v }
        if let v = am.channels   { f["AudioChannels"]   = v }
        if let v = am.title      { f["Title"]    = v }
        if let v = am.artist     { f["Artist"]   = v }
        if let v = am.album      { f["Album"]    = v }
        return f
    }

    private func defaultChannelLayout(_ channels: Int?) -> String? {
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        case 3: return "3.0"
        case 4: return "4.0"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return nil
        }
    }

    private func audioFormatLongName(_ format: AudioFormat) -> String {
        switch format {
        case .mp3:        return "MP3"
        case .flac:       return "FLAC"
        case .m4a:        return "MPEG-4 Audio"
        case .opus:       return "Opus"
        case .oggVorbis:  return "Ogg Vorbis"
        case .wav:        return "WAV"
        case .aiff:       return "AIFF"
        }
    }

    private func buildChapterDicts(_ vm: VideoMetadata) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for ch in vm.chapters {
            var d: [String: Any] = ["Index": String(ch.index)]
            if let id = ch.id { d["ChapterUID"] = String(id) }
            d["StartTime"] = String(ch.startTime)
            if let v = ch.endTime  { d["EndTime"]  = String(v) }
            if let v = ch.duration { d["Duration"] = String(v) }
            if let v = ch.title    { d["Title"]    = v }
            if let v = ch.language { d["Language"] = v }
            rows.append(d)
        }
        return rows
    }

    private func printTable(_ dict: [String: String]) {
        guard !dict.isEmpty else { return }
        let maxKey = dict.keys.map(\.count).max() ?? 20
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            print("\(key.padding(toLength: maxKey + 2, withPad: " ", startingAt: 0)): \(value)")
        }
    }

    private func printCSV(_ dicts: [[String: String]]) {
        guard !dicts.isEmpty else { return }

        var allKeys = Set<String>()
        for dict in dicts { allKeys.formUnion(dict.keys) }
        let columns = allKeys.sorted()

        // Header
        print(columns.joined(separator: ","))

        // Rows
        for dict in dicts {
            let row = columns.map { key -> String in
                let value = dict[key] ?? ""
                if value.contains(",") || value.contains("\"") || value.contains("\n") {
                    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
                }
                return value
            }
            print(row.joined(separator: ","))
        }
    }

    private func printXML(_ dict: [String: String]) {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n"
        xml += "<rdf:Description>\n"
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            let tag = key.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "_")
            let escaped = value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            xml += "  <\(tag)>\(escaped)</\(tag)>\n"
        }
        xml += "</rdf:Description>\n"
        xml += "</rdf:RDF>\n"
        print(xml)
    }

    private func filterByGroups(_ dict: [String: String], groups: Set<String>, fields: [String]?) -> [String: String] {
        if let fields {
            let fieldSet = Set(fields)
            return dict.filter { fieldSet.contains($0.key) }
        }

        guard !groups.isEmpty else { return dict }

        let exifKeys: Set<String> = [
            "Make", "Model", "Software", "DateTime", "DateTimeOriginal", "DateTimeDigitized",
            "Copyright", "Artist", "LensModel", "LensMake", "Orientation", "ISO",
            "ExposureTime", "FNumber", "FocalLength", "FocalLengthIn35mmFilm",
            "ExposureProgram", "MeteringMode", "Flash", "ColorSpace", "WhiteBalance",
            "SceneCaptureType", "ExposureMode", "CustomRendered", "SensingMethod",
            "LightSource", "ResolutionUnit", "Compression", "PixelXDimension",
            "PixelYDimension", "ImageWidth", "ImageHeight",
            "GPSLatitude", "GPSLongitude",
        ]

        return dict.filter { key, _ in
            for g in groups {
                switch g.lowercased() {
                case "exif": if exifKeys.contains(key) { return true }
                case "iptc": if key.hasPrefix("IPTC:") { return true }
                case "xmp": if key.hasPrefix("XMP-") { return true }
                case "icc": if key.hasPrefix("ICCProfile:") { return true }
                case "makernote": if key.hasPrefix("MakerNote:") { return true }
                case "composite": if key.hasPrefix("Composite:") { return true }
                case "c2pa": if key.hasPrefix("C2PA:") { return true }
                case "file": if key.hasPrefix("File:") { return true }
                default: break
                }
            }
            return false
        }
    }
}

enum OutputFormat: String, ExpressibleByArgument, Sendable {
    case table, json, csv, xml
}
