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
            let isMetadata = keyIsC2PA || peekIsXML || peekIsJUMBF

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
