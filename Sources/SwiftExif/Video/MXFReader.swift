import Foundation

/// Minimal Material eXchange Format (SMPTE 377-1) reader.
///
/// MXF files are structured as a sequence of KLV triplets:
///   - K: 16-byte SMPTE universal label (UL)
///   - L: BER-encoded length
///   - V: value
///
/// SwiftExif's needs are narrow — we only want clip-level metadata that
/// Sony XDCAM/XAVC cameras carry in MXF files. Specifically:
///   1. The Sony NonRealTimeMeta XML payload (RDD-18), which is stored as a
///      KLV whose value is a UTF-8 XML blob; and
///   2. (optionally) raw video frame rate / dimensions exposed via Essence
///      Descriptors (not implemented here — most Sony workflows supply these
///      via the NRT XML anyway).
///
/// This reader skips unknown KLVs and is tolerant of truncated files.
public struct MXFReader: Sendable {

    /// Bytes at the start of every MXF file: the Partition Pack key
    /// (SMPTE 377-1, section 6.3) — the first 11 bytes are a fixed prefix.
    private static let mxfPrefix: [UInt8] = [
        0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
        0x0D, 0x01, 0x02
    ]

    /// Check whether a data blob looks like an MXF file.
    public static func isMXF(_ data: Data) -> Bool {
        guard data.count >= mxfPrefix.count else { return false }
        for (i, b) in mxfPrefix.enumerated() where data[data.startIndex + i] != b {
            return false
        }
        return true
    }

    /// Upper bound on a KLV value we're willing to fully materialize.
    ///
    /// Metadata-bearing KLVs (NRT XML, C2PA manifest stores) are at most a few
    /// MB; raw essence KLVs in a 40 GB XDCAM clip can be many gigabytes. We
    /// peek at the first 64 bytes of every KLV to decide whether it's worth
    /// reading fully, and cap a full read at this size so a malformed length
    /// field on a giant KLV can't OOM us even if our heuristic mis-fires.
    private static let maxMetadataKLVSize = 32 * 1024 * 1024

    /// How many bytes of each KLV value to peek at before deciding whether
    /// it's metadata we care about. Must be large enough to fit an XML
    /// declaration plus the `<NonRealTimeMeta` opening tag, which can appear
    /// a couple hundred bytes in when long xmlns attributes are present.
    private static let klvPeekBytes = 512

    /// Parse an MXF file into a VideoMetadata, extracting camera metadata
    /// where possible.
    ///
    /// The KLV scan only fully materializes values that pass a cheap
    /// content-type peek — essence (video/audio) KLVs, which can be GBs each
    /// in XDCAM/XAVC files, are skipped via a seek without copying into RAM.
    public static func parse(_ data: Data) throws -> VideoMetadata {
        guard isMXF(data) else {
            throw MetadataError.invalidVideo("Not an MXF file — missing partition pack prefix")
        }

        var metadata = VideoMetadata(format: .mxf)

        var reader = BinaryReader(data: data)
        while reader.remainingCount >= 17 {
            guard let key = try? reader.readBytes(16) else { break }
            guard let length = try? readBERLength(&reader) else { break }
            guard length <= reader.remainingCount else { break }

            let valueStart = reader.offset
            let peekCount = min(length, klvPeekBytes)
            guard let peek = try? reader.slice(from: valueStart, count: peekCount) else { break }

            let keyIsC2PA = isC2PAKey(key)
            let peekIsXML = looksLikeNRTXML(peek)
            let peekIsJUMBF = looksLikeJUMBF(peek, totalLength: length)
            let keyIsPictureDescriptor = isPictureEssenceDescriptorKey(key)
            let keyIsSoundDescriptor = isSoundEssenceDescriptorKey(key)
            let isMetadata = keyIsC2PA || peekIsXML || peekIsJUMBF
                || keyIsPictureDescriptor || keyIsSoundDescriptor

            // Skip anything that doesn't look like metadata, plus anything
            // larger than the hard cap (defensive — metadata payloads are
            // never this big).
            guard isMetadata, length <= maxMetadataKLVSize else {
                // Advance past the KLV without copying its value.
                if (try? reader.seek(to: valueStart + length)) == nil { break }
                continue
            }

            guard let value = try? reader.readBytes(length) else { break }

            // Sony NRT XML: RDD-18 clip metadata surfaced through MXF.
            if peekIsXML {
                if let cam = try? NRTXMLParser.parse(value) {
                    metadata.camera = cam
                }
            }

            // C2PA manifest store: either under the registered SMPTE UL or in
            // a "Dark" KLV whose value starts with a JUMBF "jumb" box.
            if metadata.c2pa == nil, keyIsC2PA || peekIsJUMBF {
                extractC2PA(fromKLVValue: value, into: &metadata)
            }

            // Picture/Sound essence descriptors: parse each local-tag → value
            // set to extract resolution, frame rate, scan type, colour.
            if keyIsPictureDescriptor {
                var stream = VideoStream(index: metadata.videoStreams.count)
                parsePictureDescriptor(value, into: &stream, duration: &metadata.duration)
                if stream.width != nil || stream.height != nil || stream.frameRate != nil {
                    metadata.videoStreams.append(stream)
                    if metadata.videoWidth == nil { metadata.videoWidth = stream.width }
                    if metadata.videoHeight == nil { metadata.videoHeight = stream.height }
                    if metadata.videoCodec == nil { metadata.videoCodec = stream.codec }
                    if metadata.frameRate == nil { metadata.frameRate = stream.frameRate }
                    if metadata.fieldOrder == nil { metadata.fieldOrder = stream.fieldOrder }
                    if metadata.bitDepth == nil { metadata.bitDepth = stream.bitDepth }
                    if metadata.colorInfo == nil { metadata.colorInfo = stream.colorInfo }
                    if metadata.displayWidth == nil { metadata.displayWidth = stream.displayWidth }
                    if metadata.displayHeight == nil { metadata.displayHeight = stream.displayHeight }
                }
            }

            if keyIsSoundDescriptor {
                var stream = AudioStream(index: metadata.audioStreams.count)
                parseSoundDescriptor(value, into: &stream)
                if stream.sampleRate != nil || stream.channels != nil {
                    metadata.audioStreams.append(stream)
                    if metadata.audioCodec == nil { metadata.audioCodec = stream.codec }
                    if metadata.audioSampleRate == nil { metadata.audioSampleRate = stream.sampleRate }
                    if metadata.audioChannels == nil { metadata.audioChannels = stream.channels }
                }
            }
        }

        // Fallback: Sony XDCAM/XAVC writers often wrap NRT XML inside an
        // RP 2057 XML Document Set whose value is a local-tag/length/value
        // sequence — the XML bytes therefore live *inside* a KLV value, not
        // at its start, so the top-level peek misses them. Do a bounded
        // substring scan of the header metadata region to catch these.
        if metadata.camera == nil || metadata.camera?.isEmpty == true {
            if let xml = findEmbeddedNRTXML(in: data) {
                if let cam = try? NRTXMLParser.parse(xml), !cam.isEmpty {
                    metadata.camera = cam
                }
            }
        }

        return metadata
    }

    // MARK: - Embedded-NRT fallback

    /// Upper bound on how many bytes we're willing to substring-scan for
    /// `<NonRealTimeMeta`. MXF header metadata lives at the top of the file
    /// (well under 16 MB even for multi-track broadcast clips), and memory
    /// mapping keeps this cheap.
    private static let nrtScanWindow = 16 * 1024 * 1024

    /// Locate a `<?xml … <NonRealTimeMeta … </NonRealTimeMeta>` document
    /// anywhere in the first `nrtScanWindow` bytes of the file and return
    /// it as a standalone UTF-8 buffer. Returns nil if no complete document
    /// is found.
    static func findEmbeddedNRTXML(in data: Data) -> Data? {
        let scanLimit = min(data.count, nrtScanWindow)
        guard scanLimit > 0 else { return nil }

        let haystack = data.prefix(scanLimit)
        let openTag  = Data("<NonRealTimeMeta".utf8)
        let closeTag = Data("</NonRealTimeMeta>".utf8)
        let xmlDecl  = Data("<?xml".utf8)

        guard let openRange = haystack.range(of: openTag) else { return nil }
        guard let closeRange = haystack.range(of: closeTag, in: openRange.upperBound..<haystack.endIndex) else {
            return nil
        }
        // Prefer starting at a preceding <?xml declaration within ~200 bytes
        // of the open tag; fall back to the open tag itself otherwise.
        let searchStart = max(haystack.startIndex, openRange.lowerBound - 256)
        let declRange = haystack.range(of: xmlDecl, in: searchStart..<openRange.lowerBound)
        let start = declRange?.lowerBound ?? openRange.lowerBound
        let end = closeRange.upperBound
        return Data(haystack[start..<end])
    }

    // MARK: - C2PA

    /// SMPTE UL assigned to the C2PA manifest store in MXF (see C2PA spec, MXF annex).
    /// The final byte varies across drafts; we match on the first 13 bytes only.
    private static let c2paULPrefix: [UInt8] = [
        0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01,
        0x0D, 0x01, 0x03, 0x01, 0x20,
    ]

    private static func isC2PAKey(_ key: Data) -> Bool {
        guard key.count >= c2paULPrefix.count else { return false }
        for (i, b) in c2paULPrefix.enumerated() where key[key.startIndex + i] != b {
            return false
        }
        return true
    }

    /// True if the peek bytes look like the start of a JUMBF "jumb" box
    /// whose declared size is self-consistent with the total KLV length.
    ///
    /// `totalLength` is the full KLV value length (the peek is only the first
    /// few hundred bytes of that value) — the size field in the jumb header
    /// is allowed to extend beyond the peek window, but must fit inside the
    /// value as a whole.
    private static func looksLikeJUMBF(_ peek: Data, totalLength: Int) -> Bool {
        guard peek.count >= 8 else { return false }
        let bytes = [UInt8](peek.prefix(min(peek.count, 32)))
        // Fast path: first box is "jumb" at offset 4.
        if bytes.count >= 8,
           bytes[4] == 0x6A, bytes[5] == 0x75, bytes[6] == 0x6D, bytes[7] == 0x62 {
            let size = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
            if size >= 8 && Int(size) <= totalLength { return true }
        }
        // Slow path: scan the peek window for a valid jumb box header.
        return C2PAReader.findJUMBFStart(in: peek) != nil
    }

    private static func extractC2PA(fromKLVValue value: Data, into metadata: inout VideoMetadata) {
        // Find the JUMBF start offset (handles payloads that begin with a
        // small prefix before the jumb box).
        let jumbfData: Data
        if let offset = C2PAReader.findJUMBFStart(in: value) {
            jumbfData = Data(value.suffix(from: value.startIndex + offset))
        } else {
            jumbfData = value
        }

        do {
            if let c2pa = try C2PAReader.parseManifestStore(from: jumbfData) {
                metadata.c2pa = c2pa
            }
        } catch {
            metadata.warnings.append("MXF C2PA parse error: \(error)")
        }
    }

    // MARK: - BER length

    /// Decode a SMPTE ST 379 / BER-encoded length field.
    /// Short form: one byte, top bit clear, value = byte.
    /// Long form: first byte 0x80 | N, followed by N big-endian bytes.
    static func readBERLength(_ reader: inout BinaryReader) throws -> Int {
        let first = try reader.readUInt8()
        if first & 0x80 == 0 {
            return Int(first)
        }
        let byteCount = Int(first & 0x7F)
        guard byteCount > 0 && byteCount <= 8 else {
            throw MetadataError.invalidVideo("Invalid BER length: \(byteCount) bytes")
        }
        var length: UInt64 = 0
        for _ in 0..<byteCount {
            let b = try reader.readUInt8()
            length = (length << 8) | UInt64(b)
        }
        guard length <= UInt64(Int.max) else {
            throw MetadataError.invalidVideo("BER length overflow")
        }
        return Int(length)
    }

    // MARK: - Essence Descriptors
    //
    // MXF header metadata is a set of "local sets" — each metadata set's value
    // is a sequence of 2-byte local tag + 2-byte BER length + payload. Local
    // tags are mapped to full SMPTE universal labels (ULs) via a Primer Pack
    // at the start of the header metadata.
    //
    // The industry has converged on a de-facto stable set of static local tags
    // that most MXF writers use (SMPTE RP 210). We parse those directly here —
    // which avoids having to locate the Primer Pack first and correctly
    // decodes every MXF file we've encountered from Sony, Panasonic, Canon,
    // ARRI, Grass Valley, FFmpeg, and Avid.

    /// Universal label (UL) prefix for picture-essence descriptor sets:
    /// Generic/CDCI/RGBA/MPEG/AVC/JPEG2000/WAVE-descended descriptors all begin
    /// with this 13-byte prefix (byte 13 is the essence coding kind).
    ///
    /// - 06.0E.2B.34.02.53.01.01 = SMPTE metadata dictionary, variable-length
    /// - 0D.01.01.01.01.01.2?    = generic picture essence descriptor family
    private static let pictureDescriptorPrefix: [UInt8] = [
        0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01,
        0x0D, 0x01, 0x01, 0x01, 0x01, 0x01,
    ]

    /// byte 14 = descriptor kind. Picture descriptors span:
    ///   0x25 = FileDescriptor (abstract) — skipped
    ///   0x27 = GenericPictureEssenceDescriptor
    ///   0x28 = CDCIEssenceDescriptor
    ///   0x29 = RGBAEssenceDescriptor
    ///   0x41 = GenericDataEssenceDescriptor
    ///   0x51 = MPEGVideoDescriptor
    ///   0x5B = AVCSubDescriptor (via parent)
    ///   0x62 = ProResEssenceDescriptor (SMPTE 2067-40)
    private static func isPictureEssenceDescriptorKey(_ key: Data) -> Bool {
        guard key.count >= 15 else { return false }
        let s = key.startIndex
        for (i, b) in pictureDescriptorPrefix.enumerated() where key[s + i] != b { return false }
        let kind = key[s + 14]
        return kind == 0x27 || kind == 0x28 || kind == 0x29 || kind == 0x51 || kind == 0x62
    }

    /// byte 14 = 0x42 (GenericSoundEssenceDescriptor) or 0x48 (AES-3/BWF).
    private static func isSoundEssenceDescriptorKey(_ key: Data) -> Bool {
        guard key.count >= 15 else { return false }
        let s = key.startIndex
        for (i, b) in pictureDescriptorPrefix.enumerated() where key[s + i] != b { return false }
        let kind = key[s + 14]
        return kind == 0x42 || kind == 0x47 || kind == 0x48
    }

    /// Walk the local set `(tag, length, value)` triplets inside a picture
    /// essence descriptor and surface the fields we care about.
    static func parsePictureDescriptor(
        _ data: Data,
        into stream: inout VideoStream,
        duration: inout TimeInterval?
    ) {
        var sampleRateNum: UInt32 = 0
        var sampleRateDen: UInt32 = 0
        var containerDuration: UInt64 = 0
        var frameLayout: UInt8?
        var horizontalSubsampling: UInt32 = 0
        var verticalSubsampling: UInt32 = 0

        walkLocalSet(data) { tag, value in
            switch tag {
            case 0x3001:
                if let r = parseRational(value) {
                    sampleRateNum = r.num
                    sampleRateDen = r.den
                }
            case 0x3002:
                if let d = parseUInt64(value) { containerDuration = d }
            case 0x3202: // StoredHeight (UInt32)
                if let v = parseUInt32(value) { stream.height = Int(v) }
            case 0x3203: // StoredWidth (UInt32)
                if let v = parseUInt32(value) { stream.width = Int(v) }
            case 0x3208: // DisplayHeight
                if let v = parseUInt32(value) { stream.displayHeight = Int(v) }
            case 0x3209: // DisplayWidth
                if let v = parseUInt32(value) { stream.displayWidth = Int(v) }
            case 0x320C: // FrameLayout (UInt8)
                if value.count >= 1 { frameLayout = value[value.startIndex] }
            case 0x320E: // AspectRatio (Rational)
                if let r = parseRational(value) {
                    // nothing to do here beyond remembering — DAR can be derived
                    // later if stream already has w/h
                    _ = r
                }
            case 0x3201: // PictureEssenceCoding (UL)
                if let codec = codecNameForUL(value) {
                    stream.codec = codec.codec
                    stream.codecName = codec.longName
                }
            case 0x3301: // ComponentDepth (UInt32)
                if let v = parseUInt32(value) { stream.bitDepth = Int(v) }
            case 0x3302: // HorizontalSubsampling (UInt32) — chroma horz subsampling
                if let v = parseUInt32(value) { horizontalSubsampling = v }
            case 0x3308: // VerticalSubsampling (UInt32)
                if let v = parseUInt32(value) { verticalSubsampling = v }
            case 0x3219: // CodingEquations (UL) — matrix coefficients
                var info = stream.colorInfo ?? VideoColorInfo()
                info.matrix = colorULCode(value, kind: .matrix)
                stream.colorInfo = info
            case 0x3210: // CaptureGamma (UL) — transfer characteristic
                var info = stream.colorInfo ?? VideoColorInfo()
                info.transfer = colorULCode(value, kind: .transfer)
                stream.colorInfo = info
            case 0x321A, 0x321D: // ColorPrimaries (UL)
                var info = stream.colorInfo ?? VideoColorInfo()
                info.primaries = colorULCode(value, kind: .primaries)
                stream.colorInfo = info
            default:
                break
            }
        }

        if sampleRateDen > 0, sampleRateNum > 0 {
            let fps = Double(sampleRateNum) / Double(sampleRateDen)
            stream.frameRate = fps
            if containerDuration > 0 {
                let secs = Double(containerDuration) / fps
                if duration == nil || duration == 0 { duration = secs }
                stream.duration = secs
                stream.frameCount = Int(containerDuration)
            }
        }

        if let fl = frameLayout {
            stream.fieldOrder = fieldOrderFromLayout(fl)
        }

        // CDCI essence descriptors carry explicit subsampling ratios. 4:2:0 is
        // signalled as (horiz=2, vert=2), 4:2:2 as (2,1), 4:4:4 as (1,1).
        switch (horizontalSubsampling, verticalSubsampling) {
        case (2, 2): stream.chromaSubsampling = "4:2:0"
        case (2, 1): stream.chromaSubsampling = "4:2:2"
        case (1, 1): stream.chromaSubsampling = "4:4:4"
        default: break
        }
    }

    static func parseSoundDescriptor(_ data: Data, into stream: inout AudioStream) {
        walkLocalSet(data) { tag, value in
            switch tag {
            case 0x3001:
                if let r = parseRational(value), r.den > 0 {
                    // Sample rate = num/den (often 48000/1).
                    stream.sampleRate = Int(r.num / max(r.den, 1))
                }
            case 0x3D03: // AudioSamplingRate (Rational)
                if let r = parseRational(value), r.den > 0 {
                    stream.sampleRate = Int(r.num / max(r.den, 1))
                }
            case 0x3D06: // SoundEssenceCompression (UL)
                if let codec = codecNameForUL(value) {
                    stream.codec = codec.codec
                    stream.codecName = codec.longName
                }
            case 0x3D07: // ChannelCount (UInt32)
                if let v = parseUInt32(value) { stream.channels = Int(v) }
            case 0x3D01: // QuantizationBits (UInt32)
                if let v = parseUInt32(value) { stream.bitDepth = Int(v) }
            default:
                break
            }
        }

        if stream.channelLayout == nil, let ch = stream.channels {
            stream.channelLayout = defaultChannelLayout(forChannels: ch)
        }
    }

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

    private static func walkLocalSet(_ data: Data, _ body: (UInt16, Data) -> Void) {
        var reader = BinaryReader(data: data)
        while reader.remainingCount >= 4 {
            guard let tag = try? reader.readUInt16BigEndian(),
                  let len = try? reader.readUInt16BigEndian() else { return }
            let length = Int(len)
            guard length <= reader.remainingCount else { return }
            guard let value = try? reader.readBytes(length) else { return }
            body(tag, value)
        }
    }

    private static func parseUInt32(_ data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        var r = BinaryReader(data: data)
        return try? r.readUInt32BigEndian()
    }

    private static func parseUInt64(_ data: Data) -> UInt64? {
        guard data.count >= 8 else { return nil }
        var r = BinaryReader(data: data)
        return try? r.readUInt64BigEndian()
    }

    private static func parseRational(_ data: Data) -> (num: UInt32, den: UInt32)? {
        guard data.count >= 8 else { return nil }
        var r = BinaryReader(data: data)
        guard let n = try? r.readUInt32BigEndian(),
              let d = try? r.readUInt32BigEndian() else { return nil }
        return (n, d)
    }

    /// FrameLayout (SMPTE 377-1 table 13):
    ///   0 = full-frame (progressive), 1 = separated fields (interlaced — order
    ///   signalled by VideoLineMap), 2 = single field (odd/even), 3 = mixed,
    ///   4 = segmented frame (PsF — progressive stored as fields).
    /// Without the VideoLineMap we can't distinguish TFF from BFF, so we
    /// report interlaced streams as `.unknown` for field order.
    private static func fieldOrderFromLayout(_ layout: UInt8) -> VideoFieldOrder {
        switch layout {
        case 0, 4: return .progressive
        case 1, 3: return .unknown
        case 2: return .unknown
        default: return .unknown
        }
    }

    /// Map a picture essence coding UL to a short codec name and long name.
    /// Only the last few bytes of the UL are distinguishing — we inspect those.
    private static func codecNameForUL(_ ul: Data) -> (codec: String, longName: String)? {
        guard ul.count >= 16 else { return nil }
        let s = ul.startIndex
        let kind = ul[s + 11]
        let variant = ul[s + 13]
        // Kind 0x04 = compressed picture essence coding family
        if kind == 0x04 {
            switch variant {
            case 0x01: return ("mpeg2video", "MPEG-2 Video")
            case 0x02: return ("dv", "DV")
            case 0x0A: return ("j2k", "JPEG 2000")
            case 0x20: return ("mpeg4", "MPEG-4 Visual")
            case 0x41: return ("apch", "Apple ProRes")
            case 0x31: return ("avc1", "H.264 / AVC")
            case 0x32: return ("hvc1", "H.265 / HEVC")
            default: break
            }
        }
        return nil
    }

    private enum ColorULKind { case matrix, transfer, primaries }

    /// SMPTE ST 2067-21 / H.273 UL mapping — translates MXF ULs to H.273 codes
    /// so VideoColorInfo speaks the same vocabulary as MP4/MKV.
    private static func colorULCode(_ ul: Data, kind: ColorULKind) -> Int? {
        guard ul.count >= 16 else { return nil }
        let s = ul.startIndex
        let last = ul[s + 14]
        switch kind {
        case .primaries:
            switch last {
            case 0x01: return 1 // ITU-R BT.709
            case 0x04: return 6 // BT.601 625
            case 0x06: return 9 // BT.2020
            case 0x07: return 12 // SMPTE 428 (XYZ)
            default: return nil
            }
        case .transfer:
            switch last {
            case 0x01: return 1 // BT.709
            case 0x02: return 4 // BT.470M
            case 0x04: return 6 // BT.601
            case 0x05: return 8 // Linear
            case 0x06: return 14 // BT.2020 10-bit
            case 0x08: return 16 // SMPTE ST 2084 (PQ)
            case 0x0B: return 18 // ARIB STD-B67 (HLG)
            default: return nil
            }
        case .matrix:
            switch last {
            case 0x01: return 1 // BT.709
            case 0x02: return 5 // BT.470BG / BT.601 625
            case 0x03: return 6 // BT.601 525
            case 0x06: return 9 // BT.2020 non-constant luminance
            default: return nil
            }
        }
    }

    // MARK: - Heuristics

    /// True if the payload looks like a Sony NonRealTimeMeta XML document.
    private static func looksLikeNRTXML(_ data: Data) -> Bool {
        guard data.count > 16 else { return false }
        // Find first non-whitespace byte — accepts BOM'd files and files that
        // start with an XML declaration.
        var i = data.startIndex
        while i < data.endIndex {
            let b = data[i]
            if b != 0x20 && b != 0x09 && b != 0x0A && b != 0x0D && b != 0xEF && b != 0xBB && b != 0xBF {
                break
            }
            i = data.index(after: i)
        }
        guard i < data.endIndex, data[i] == 0x3C /* '<' */ else { return false }

        // Bounded substring search for "NonRealTimeMeta" — scan the first ~4 KB
        // to keep cost low on large MXF essence payloads.
        let scanLimit = min(data.count, 4096)
        let haystack = data.prefix(scanLimit)
        guard let text = String(data: haystack, encoding: .utf8) else { return false }
        return text.contains("NonRealTimeMeta")
    }
}
