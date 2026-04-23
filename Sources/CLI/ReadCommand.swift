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
        var perStreamReports: [(name: String, format: [String: String], streams: [[String: String]])] = []

        for url in urls {
            if supportedAudioExtensions.contains(url.pathExtension.lowercased()) {
                let am = try AudioMetadata.read(from: url)
                let dict = AudioMetadataExporter.buildDictionary(am).mapValues { String(describing: $0) }
                audioDicts.append(dict)
                audioNames.append(url.lastPathComponent)
            } else if supportedVideoExtensions.contains(url.pathExtension.lowercased()) {
                let vm = try VideoMetadata.read(from: url)
                let dict = VideoMetadataExporter.buildDictionary(vm).mapValues { String(describing: $0) }
                videoDicts.append(dict)
                videoNames.append(url.lastPathComponent)
                if streams {
                    perStreamReports.append((url.lastPathComponent, dict, buildStreamDicts(vm)))
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
            } else if let data = try? JSONSerialization.data(withJSONObject: allDicts, options: [.prettyPrinted, .sortedKeys]) {
                print(String(data: data, encoding: .utf8) ?? "[]")
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
                        printTable(sd)
                    }
                }
            }
        }
    }

    private func buildStreamDicts(_ vm: VideoMetadata) -> [[String: String]] {
        var rows: [[String: String]] = []
        for stream in vm.videoStreams {
            var d: [String: String] = ["StreamType": "video", "Index": String(stream.index)]
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
            if let c = stream.colorInfo {
                if let p = c.primaries { d["ColorPrimaries"] = String(p) }
                if let t = c.transfer  { d["TransferCharacteristics"] = String(t) }
                if let m = c.matrix    { d["MatrixCoefficients"] = String(m) }
                if let r = c.fullRange { d["ColorRange"] = r ? "pc" : "tv" }
                if let l = c.label     { d["ColorSpace"] = l }
            }
            rows.append(d)
        }
        for stream in vm.audioStreams {
            var d: [String: String] = ["StreamType": "audio", "Index": String(stream.index)]
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
            rows.append(d)
        }
        for stream in vm.subtitleStreams {
            var d: [String: String] = ["StreamType": "subtitle", "Index": String(stream.index)]
            if let v = stream.codec             { d["Codec"]     = v }
            if let v = stream.codecName         { d["CodecName"] = v }
            if let v = stream.codec, let s = ffprobeShortSubtitleCodec(v) { d["CodecShort"] = s }
            if let v = stream.language          { d["Language"]  = v }
            if let v = stream.title             { d["Title"]     = v }
            d["IsDefault"]         = String(stream.isDefault ?? true)
            d["IsForced"]          = String(stream.isForced ?? false)
            d["IsHearingImpaired"] = String(stream.isHearingImpaired ?? false)
            if let v = stream.duration          { d["Duration"]  = String(v) }
            rows.append(d)
        }
        return rows
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
        default: return nil
        }
    }

    private func printStreamsJSON(_ reports: [(name: String, format: [String: String], streams: [[String: String]])]) {
        var out: [[String: Any]] = []
        for report in reports {
            out.append([
                "file": report.name,
                // Clip-level metadata (ffprobe "format") — exposes Timecode,
                // Duration, BitRate, FormatLongName, creation dates, GPS, etc.
                // that don't belong on any single stream.
                "format": report.format,
                "streams": report.streams,
            ])
        }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: data, encoding: .utf8) ?? "[]")
        }
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
