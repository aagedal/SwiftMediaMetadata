import Foundation

/// Parse ID3v2/v1 metadata tags from MP3 files.
public struct ID3Parser: Sendable {

    /// Parse an MP3 file and extract metadata from ID3 tags.
    public static func parse(_ data: Data) throws -> AudioMetadata {
        var metadata = AudioMetadata(format: .mp3)
        metadata.codec = "mp3"
        metadata.codecName = "MP3"

        // Try ID3v2 first
        var firstFrameOffset = 0
        if data.count >= 10 && data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33 {
            try parseID3v2(data, into: &metadata)
            // ID3v2 header size is syncsafe in bytes 6..9; the MPEG audio frame
            // starts right after the tag.
            let tagSize = decodeSyncsafe(data[6], data[7], data[8], data[9])
            firstFrameOffset = min(10 + tagSize, data.count)
        }

        // Fallback/supplement with ID3v1
        if data.count >= 128 {
            parseID3v1(data, into: &metadata)
        }

        // Audio-frame derived facts: sample rate, channels, bitrate, duration.
        parseFirstAudioFrame(data, from: firstFrameOffset, into: &metadata)

        return metadata
    }

    // MARK: - MPEG audio frame header

    /// Walk forward from `offset` looking for a valid MPEG audio frame sync
    /// word (FFF…). Decode the first frame we find to extract stream-level
    /// facts. The cost is bounded — we search a small window.
    private static let frameScanWindow = 64 * 1024

    private static func parseFirstAudioFrame(_ data: Data, from offset: Int, into metadata: inout AudioMetadata) {
        let end = min(data.count - 4, offset + frameScanWindow)
        guard offset >= 0, offset < end else { return }

        var i = offset
        while i < end {
            let b0 = data[data.startIndex + i]
            let b1 = data[data.startIndex + i + 1]
            if b0 == 0xFF && (b1 & 0xE0) == 0xE0 {
                let b2 = data[data.startIndex + i + 2]
                let b3 = data[data.startIndex + i + 3]
                if let info = decodeMPEGFrameHeader(b0, b1, b2, b3) {
                    metadata.sampleRate = info.sampleRate
                    metadata.channels = info.channels
                    metadata.bitrate = info.bitrate
                    switch info.layer {
                    case 1: metadata.codecName = "MPEG Layer I"
                    case 2: metadata.codecName = "MP2"
                    case 3: metadata.codecName = "MP3"
                    default: break
                    }
                    // Approximate duration from (file_size - offset) / (bitrate/8).
                    // Accurate VBR files populate this via the Xing/Info frame,
                    // which is out of scope here.
                    if info.bitrate > 0 {
                        let audioBytes = Double(data.count - i)
                        metadata.duration = audioBytes / (Double(info.bitrate) / 8)
                    }
                    return
                }
            }
            i += 1
        }
    }

    private struct MPEGFrameInfo {
        let layer: Int       // 1, 2, 3
        let bitrate: Int     // bps
        let sampleRate: Int  // Hz
        let channels: Int
    }

    private static let bitrateTable: [[[Int]]] = [
        // [version_index][layer_index][bitrate_index] → kbps
        // version: 0=MPEG-1, 1=MPEG-2/2.5
        // layer:   0=Layer I, 1=Layer II, 2=Layer III
        // Entries below are kbps; 0 means "free" (not supported here), -1 means reserved.
        [ // MPEG-1
            [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, -1],
            [0, 32, 48, 56,  64,  80,  96, 112, 128, 160, 192, 224, 256, 320, 384, -1],
            [0, 32, 40, 48,  56,  64,  80,  96, 112, 128, 160, 192, 224, 256, 320, -1],
        ],
        [ // MPEG-2 / MPEG-2.5
            [0, 32, 48, 56,  64,  80,  96, 112, 128, 144, 160, 176, 192, 224, 256, -1],
            [0,  8, 16, 24,  32,  40,  48,  56,  64,  80,  96, 112, 128, 144, 160, -1],
            [0,  8, 16, 24,  32,  40,  48,  56,  64,  80,  96, 112, 128, 144, 160, -1],
        ],
    ]

    /// MPEG audio frame header (4 bytes):
    ///   b0         sync byte (0xFF)
    ///   b1[7..5]   sync (111)
    ///   b1[4..3]   version (00=MPEG-2.5, 10=MPEG-2, 11=MPEG-1)
    ///   b1[2..1]   layer   (01=III, 10=II, 11=I)
    ///   b1[0]      protection
    ///   b2[7..4]   bitrate index
    ///   b2[3..2]   sampling frequency index
    ///   b2[1]      padding
    ///   b3[7..6]   channel mode (00=stereo,01=joint,10=dual,11=mono)
    private static func decodeMPEGFrameHeader(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> MPEGFrameInfo? {
        let versionBits = (b1 >> 3) & 0x03
        let layerBits = (b1 >> 1) & 0x03
        let bitrateIdx = Int((b2 >> 4) & 0x0F)
        let freqIdx = Int((b2 >> 2) & 0x03)
        let channelMode = (b3 >> 6) & 0x03

        guard versionBits != 0x01 else { return nil } // reserved
        guard layerBits != 0x00 else { return nil }   // reserved
        guard bitrateIdx > 0, bitrateIdx < 15 else { return nil }
        guard freqIdx != 3 else { return nil }

        let versionIndex = versionBits == 0x03 ? 0 : 1 // MPEG-1 vs MPEG-2/2.5
        let layer: Int
        let layerIndex: Int
        switch layerBits {
        case 0x03: layer = 1; layerIndex = 0
        case 0x02: layer = 2; layerIndex = 1
        case 0x01: layer = 3; layerIndex = 2
        default: return nil
        }

        let kbps = bitrateTable[versionIndex][layerIndex][bitrateIdx]
        guard kbps > 0 else { return nil }

        // Sample rate tables (Hz).
        let mpeg1Rates = [44100, 48000, 32000]
        let mpeg2Rates = [22050, 24000, 16000]
        let mpeg25Rates = [11025, 12000, 8000]
        let sampleRate: Int
        switch versionBits {
        case 0x03: sampleRate = mpeg1Rates[freqIdx]
        case 0x02: sampleRate = mpeg2Rates[freqIdx]
        case 0x00: sampleRate = mpeg25Rates[freqIdx]
        default: return nil
        }

        let channels = channelMode == 0x03 ? 1 : 2
        return MPEGFrameInfo(layer: layer, bitrate: kbps * 1000, sampleRate: sampleRate, channels: channels)
    }

    // MARK: - ID3v2

    private static func parseID3v2(_ data: Data, into metadata: inout AudioMetadata) throws {
        // Header: "ID3" (3) + version major (1) + version minor (1) + flags (1) + size (4)
        guard data.count >= 10 else { return }

        let versionMajor = Int(data[3])
        // let versionMinor = Int(data[4])
        // let flags = data[5]
        let tagSize = decodeSyncsafe(data[6], data[7], data[8], data[9])

        guard versionMajor >= 2 && versionMajor <= 4 else {
            throw MetadataError.invalidMP3("Unsupported ID3v2 version: \(versionMajor)")
        }

        let headerSize = 10
        let endOffset = min(headerSize + tagSize, data.count)

        var offset = headerSize

        while offset + 10 <= endOffset {
            // Frame header: ID (4) + size (4) + flags (2) for v2.3/v2.4
            let frameID: String
            let frameSize: Int

            if versionMajor >= 3 {
                guard offset + 10 <= endOffset else { break }
                guard let id = String(data: data[offset..<offset + 4], encoding: .ascii) else { break }
                frameID = id

                if versionMajor == 4 {
                    frameSize = decodeSyncsafe(data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7])
                } else {
                    frameSize = Int(data[offset + 4]) << 24 | Int(data[offset + 5]) << 16 |
                                Int(data[offset + 6]) << 8 | Int(data[offset + 7])
                }

                offset += 10  // Skip header
            } else {
                // ID3v2.2: 3-byte ID + 3-byte size
                guard offset + 6 <= endOffset else { break }
                guard let id = String(data: data[offset..<offset + 3], encoding: .ascii) else { break }
                frameID = id
                frameSize = Int(data[offset + 3]) << 16 | Int(data[offset + 4]) << 8 | Int(data[offset + 5])
                offset += 6
            }

            // Validate
            guard frameSize > 0, offset + frameSize <= endOffset else { break }

            // Null frame ID means padding
            if frameID.hasPrefix("\0") { break }

            let frameData = Data(data[offset..<offset + frameSize])
            offset += frameSize

            // Map frame IDs (v2.3/v2.4, with v2.2 aliases)
            switch frameID {
            case "TIT2", "TT2":
                metadata.title = metadata.title ?? decodeTextFrame(frameData)
            case "TPE1", "TP1":
                metadata.artist = metadata.artist ?? decodeTextFrame(frameData)
            case "TALB", "TAL":
                metadata.album = metadata.album ?? decodeTextFrame(frameData)
            case "TRCK", "TRK":
                if let text = decodeTextFrame(frameData) {
                    // May be "3/12" format
                    let parts = text.split(separator: "/")
                    metadata.trackNumber = metadata.trackNumber ?? Int(parts.first ?? "")
                }
            case "TPOS", "TPA":
                if let text = decodeTextFrame(frameData) {
                    let parts = text.split(separator: "/")
                    metadata.discNumber = metadata.discNumber ?? Int(parts.first ?? "")
                }
            case "TDRC", "TYER", "TYE":
                metadata.year = metadata.year ?? decodeTextFrame(frameData)
            case "TCON", "TCO":
                if let text = decodeTextFrame(frameData) {
                    // May contain numeric genre ID like "(13)" or "(13)Pop"
                    metadata.genre = metadata.genre ?? cleanGenre(text)
                }
            case "TPE2":
                metadata.albumArtist = metadata.albumArtist ?? decodeTextFrame(frameData)
            case "TCOM", "TCM":
                metadata.composer = metadata.composer ?? decodeTextFrame(frameData)
            case "COMM", "COM":
                if metadata.comment == nil {
                    metadata.comment = decodeCommentFrame(frameData)
                }
            case "APIC", "PIC":
                if metadata.coverArt == nil {
                    metadata.coverArt = extractAPIC(frameData)
                }
            default:
                break
            }
        }
    }

    // MARK: - ID3v1

    private static func parseID3v1(_ data: Data, into metadata: inout AudioMetadata) {
        let start = data.count - 128
        guard start >= 0 else { return }
        guard data[start] == 0x54 && data[start + 1] == 0x41 && data[start + 2] == 0x47 else { return } // "TAG"

        let readField: (Int, Int) -> String? = { offset, length in
            let fieldData = data[start + offset..<start + offset + length]
            return String(data: fieldData, encoding: .isoLatin1)?
                .trimmingCharacters(in: .controlCharacters)
                .trimmingCharacters(in: .whitespaces)
                .nilIfEmpty
        }

        metadata.title = metadata.title ?? readField(3, 30)
        metadata.artist = metadata.artist ?? readField(33, 30)
        metadata.album = metadata.album ?? readField(63, 30)
        metadata.year = metadata.year ?? readField(93, 4)
        metadata.comment = metadata.comment ?? readField(97, 28)

        // ID3v1.1: track number in byte 125 if byte 124 is 0
        if metadata.trackNumber == nil && data[start + 125] == 0 && data[start + 126] != 0 {
            metadata.trackNumber = Int(data[start + 126])
        }

        // Genre byte
        if metadata.genre == nil {
            let genreID = Int(data[start + 127])
            if genreID < id3v1Genres.count {
                metadata.genre = id3v1Genres[genreID]
            }
        }
    }

    // MARK: - Text Decoding

    /// Decode a text frame: encoding byte + text data.
    static func decodeTextFrame(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let encoding = data[0]
        let textData = data.dropFirst()
        return decodeString(textData, encoding: encoding)
    }

    /// Decode a COMM frame: encoding (1) + language (3) + short desc (null-terminated) + text
    private static func decodeCommentFrame(_ data: Data) -> String? {
        guard data.count >= 5 else { return nil }
        let encoding = data[0]
        // Skip language (3 bytes)
        var offset = 4

        // Skip short description (null-terminated)
        if encoding == 1 || encoding == 2 {
            // UTF-16: null terminator is 2 bytes
            while offset + 1 < data.count {
                if data[offset] == 0 && data[offset + 1] == 0 { offset += 2; break }
                offset += 2
            }
        } else {
            while offset < data.count {
                if data[offset] == 0 { offset += 1; break }
                offset += 1
            }
        }

        guard offset < data.count else { return nil }
        return decodeString(data[offset...], encoding: encoding)
    }

    /// Extract image data from APIC frame.
    private static func extractAPIC(_ data: Data) -> Data? {
        guard data.count > 4 else { return nil }
        let encoding = data[0]
        var offset = 1

        // Skip MIME type (null-terminated ASCII)
        while offset < data.count && data[offset] != 0 { offset += 1 }
        offset += 1 // skip null

        guard offset < data.count else { return nil }
        // Skip picture type byte
        offset += 1

        // Skip description (null-terminated, encoding-aware)
        if encoding == 1 || encoding == 2 {
            while offset + 1 < data.count {
                if data[offset] == 0 && data[offset + 1] == 0 { offset += 2; break }
                offset += 2
            }
        } else {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }

        guard offset < data.count else { return nil }
        return Data(data[offset...])
    }

    private static func decodeString(_ data: Data.SubSequence, encoding: UInt8) -> String? {
        let rawData = Data(data)
        let result: String?
        switch encoding {
        case 0:
            result = String(data: rawData, encoding: .isoLatin1)
        case 1:
            result = String(data: rawData, encoding: .utf16)
        case 2:
            result = String(data: rawData, encoding: .utf16BigEndian)
        case 3:
            result = String(data: rawData, encoding: .utf8)
        default:
            result = String(data: rawData, encoding: .utf8)
        }
        // Trim null terminators and whitespace
        return result?.trimmingCharacters(in: .controlCharacters)
            .trimmingCharacters(in: .whitespaces)
            .nilIfEmpty
    }

    // MARK: - Syncsafe Integer

    /// Decode a 4-byte syncsafe integer (7 bits per byte, MSB always 0).
    public static func decodeSyncsafe(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> Int {
        (Int(b0) << 21) | (Int(b1) << 14) | (Int(b2) << 7) | Int(b3)
    }

    /// Encode an integer as 4-byte syncsafe.
    public static func encodeSyncsafe(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
         UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    // MARK: - Genre Helpers

    private static func cleanGenre(_ text: String) -> String {
        // Handle formats like "(13)", "(13)Pop", "13"
        if text.hasPrefix("("), let endIdx = text.firstIndex(of: ")") {
            let numStr = text[text.index(after: text.startIndex)..<endIdx]
            if let num = Int(numStr), num < id3v1Genres.count {
                let remainder = String(text[text.index(after: endIdx)...]).trimmingCharacters(in: .whitespaces)
                return remainder.isEmpty ? id3v1Genres[num] : remainder
            }
        }
        if let num = Int(text), num < id3v1Genres.count {
            return id3v1Genres[num]
        }
        return text
    }

    /// Standard ID3v1 genre list.
    static let id3v1Genres: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop",
        "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap",
        "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks",
        "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance",
        "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock",
        "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream",
        "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
        "Native American", "Cabaret", "New Wave", "Psychadelic", "Rave", "Showtunes", "Trailer", "Lo-Fi",
        "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
    ]
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
