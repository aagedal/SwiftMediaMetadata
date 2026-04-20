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

        // Parse mvhd (movie header)
        if let mvhd = moovChildren.first(where: { $0.type == "mvhd" }) {
            parseMVHD(mvhd.data, into: &metadata)
        }

        // Parse tracks
        for trak in moovChildren.filter({ $0.type == "trak" }) {
            parseTrak(trak.data, into: &metadata)
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

        return metadata
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

    private static func parseMVHD(_ data: Data, into metadata: inout VideoMetadata) {
        guard data.count >= 4 else { return }
        var reader = BinaryReader(data: data)

        // FullBox: version (1 byte) + flags (3 bytes)
        guard let version = try? reader.readUInt8() else { return }
        _ = try? reader.readBytes(3) // flags

        if version == 0 {
            // Version 0: 32-bit fields
            guard data.count >= 20 else { return }
            guard let creationTime = try? reader.readUInt32BigEndian(),
                  let modTime = try? reader.readUInt32BigEndian(),
                  let timescale = try? reader.readUInt32BigEndian(),
                  let duration = try? reader.readUInt32BigEndian() else { return }

            if creationTime > 0 {
                metadata.creationDate = Date(timeIntervalSince1970: Double(creationTime) - epochOffset)
            }
            if modTime > 0 {
                metadata.modificationDate = Date(timeIntervalSince1970: Double(modTime) - epochOffset)
            }
            if timescale > 0 {
                metadata.duration = Double(duration) / Double(timescale)
            }
        } else {
            // Version 1: 64-bit fields
            guard data.count >= 32 else { return }
            guard let creationTime = try? reader.readUInt64BigEndian(),
                  let modTime = try? reader.readUInt64BigEndian(),
                  let timescale = try? reader.readUInt32BigEndian(),
                  let duration = try? reader.readUInt64BigEndian() else { return }

            if creationTime > 0 {
                metadata.creationDate = Date(timeIntervalSince1970: Double(creationTime) - epochOffset)
            }
            if modTime > 0 {
                metadata.modificationDate = Date(timeIntervalSince1970: Double(modTime) - epochOffset)
            }
            if timescale > 0 {
                metadata.duration = Double(duration) / Double(timescale)
            }
        }
    }

    // MARK: - Track Parsing

    private static func parseTrak(_ data: Data, into metadata: inout VideoMetadata) {
        guard let children = try? ISOBMFFBoxReader.parseBoxes(from: data) else { return }

        // tkhd provides track-level display dimensions and flags.
        var trackWidth: Int?
        var trackHeight: Int?
        if let tkhd = children.first(where: { $0.type == "tkhd" }) {
            if let dims = parseTKHDDimensions(tkhd.data) {
                trackWidth = dims.width
                trackHeight = dims.height
            }
        }

        guard let mdia = children.first(where: { $0.type == "mdia" }),
              let mdiaChildren = try? ISOBMFFBoxReader.parseBoxes(from: mdia.data) else {
            return
        }

        // mdhd: per-track timescale + duration + language.
        var trackDuration: TimeInterval?
        var language: String?
        if let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }) {
            if let info = parseMDHD(mdhd.data) {
                trackDuration = info.duration
                language = info.language
            }
        }

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

        // Prefer stsz; stts is a sum of per-run counts but some muxers only populate one.
        let samples = frameCount ?? sttsFrames

        let fps: Double? = {
            guard let samples, samples > 0, let trackDuration, trackDuration > 0 else {
                return nil
            }
            return Double(samples) / trackDuration
        }()

        if handlerType == "vide", let stsdBox {
            var stream = VideoStream(index: metadata.videoStreams.count)
            stream.duration = trackDuration
            stream.frameCount = samples
            stream.frameRate = fps
            parseVisualSampleEntry(stsdBox.data, into: &stream)

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
            if metadata.bitRate == nil, let br = stream.bitRate { metadata.bitRate = br }
        } else if handlerType == "soun", let stsdBox {
            var stream = AudioStream(index: metadata.audioStreams.count)
            stream.duration = trackDuration
            stream.language = language
            parseAudioSampleEntry(stsdBox.data, into: &stream)
            metadata.audioStreams.append(stream)

            if metadata.audioCodec == nil { metadata.audioCodec = stream.codec }
            if metadata.audioSampleRate == nil { metadata.audioSampleRate = stream.sampleRate }
            if metadata.audioChannels == nil { metadata.audioChannels = stream.channels }
        }
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

    /// mdhd (media header): returns duration in seconds (using this track's timescale)
    /// and the ISO 639-2/T language code if set.
    private static func parseMDHD(_ data: Data) -> (duration: TimeInterval?, language: String?)? {
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
        return (seconds, language)
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
            // AVC decoder config stores chroma/bit_depth in the SPS, which
            // requires variable-length decoding beyond our scope. Every AVC
            // profile shipped by Apple/Adobe/NVENC defaults to 4:2:0 8-bit —
            // fill those in for display only.
            if stream.bitDepth == nil { stream.bitDepth = 8 }
            if stream.chromaSubsampling == nil { stream.chromaSubsampling = "4:2:0" }
        case "btrt":
            if let br = parseBTRT(box.data) {
                stream.bitRate = br
            }
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
        let chromaFormatIDC = data[s + 16] & 0x03
        stream.chromaSubsampling = chromaSubsamplingLabel(forIDC: Int(chromaFormatIDC))
        stream.bitDepth = Int(data[s + 17] & 0x07) + 8
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
        let byte2 = data[data.startIndex + 2]
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
                    // MPEG-4 Elementary Stream Descriptor; we peek for the
                    // average bit rate field only.
                    if let br = parseESDSAvgBitRate(kid.data) {
                        stream.bitRate = br
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
