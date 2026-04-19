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

    /// Parse an MXF file into a VideoMetadata, extracting camera metadata
    /// where possible.
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
            guard let value = try? reader.readBytes(length) else { break }

            // Look for an embedded XML KLV whose value starts with a "<" byte
            // and contains "NonRealTimeMeta". This is how Sony cameras and
            // ExifTool's RDD-18 workflow surface NRT metadata inside MXF.
            if looksLikeNRTXML(value) {
                if let cam = try? NRTXMLParser.parse(value) {
                    metadata.camera = cam
                }
            }

            // (Optional future work: parse Generic Track Descriptor KLVs to
            //  extract video width/height/codec. Sony clip workflows typically
            //  supply this via the NRT XML so we defer until needed.)

            _ = key // keys are ignored for now
        }

        return metadata
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
