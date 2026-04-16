import Foundation

/// Parse FLAC metadata blocks.
public struct FLACParser: Sendable {

    static let magic = Data([0x66, 0x4C, 0x61, 0x43]) // "fLaC"

    /// Metadata block types.
    enum BlockType: UInt8 {
        case streaminfo = 0
        case padding = 1
        case application = 2
        case seektable = 3
        case vorbisComment = 4
        case cuesheet = 5
        case picture = 6
    }

    /// A parsed FLAC metadata block.
    struct MetadataBlock: Sendable {
        let type: UInt8
        let isLast: Bool
        let data: Data
    }

    /// Parse a FLAC file and extract metadata.
    public static func parse(_ data: Data) throws -> AudioMetadata {
        guard data.count >= 8 && data.prefix(4) == magic else {
            throw MetadataError.invalidFLAC("Invalid FLAC signature")
        }

        var metadata = AudioMetadata(format: .flac)
        let blocks = try parseBlocks(data)

        // STREAMINFO (type 0) -- always first block
        if let streaminfo = blocks.first(where: { $0.type == 0 }), streaminfo.data.count >= 18 {
            parseStreamInfo(streaminfo.data, into: &metadata)
        }

        // VORBIS_COMMENT (type 4)
        if let vorbisBlock = blocks.first(where: { $0.type == 4 }) {
            let vc = try VorbisComment.parse(vorbisBlock.data)
            metadata.title = vc.value(for: "TITLE")
            metadata.artist = vc.value(for: "ARTIST")
            metadata.album = vc.value(for: "ALBUM")
            metadata.year = vc.value(for: "DATE")
            metadata.genre = vc.value(for: "GENRE")
            metadata.comment = vc.value(for: "COMMENT") ?? vc.value(for: "DESCRIPTION")
            metadata.albumArtist = vc.value(for: "ALBUMARTIST")
            metadata.composer = vc.value(for: "COMPOSER")
            if let trackStr = vc.value(for: "TRACKNUMBER") { metadata.trackNumber = Int(trackStr) }
            if let discStr = vc.value(for: "DISCNUMBER") { metadata.discNumber = Int(discStr) }
        }

        // PICTURE (type 6)
        if let pictureBlock = blocks.first(where: { $0.type == 6 }) {
            metadata.coverArt = extractPicture(pictureBlock.data)
        }

        return metadata
    }

    /// Parse all metadata blocks from a FLAC file.
    static func parseBlocks(_ data: Data) throws -> [MetadataBlock] {
        var blocks: [MetadataBlock] = []
        var offset = 4 // Skip "fLaC" magic

        while offset < data.count {
            guard offset + 4 <= data.count else { break }

            let header = data[offset]
            let isLast = (header & 0x80) != 0
            let blockType = header & 0x7F

            let blockLength = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4

            guard offset + blockLength <= data.count else { break }
            let blockData = Data(data[offset..<offset + blockLength])
            offset += blockLength

            blocks.append(MetadataBlock(type: blockType, isLast: isLast, data: blockData))

            if isLast { break }
        }

        return blocks
    }

    /// Parse STREAMINFO block for sample rate, channels, etc.
    private static func parseStreamInfo(_ data: Data, into metadata: inout AudioMetadata) {
        guard data.count >= 18 else { return }

        // Bytes 10-12 contain sample rate (20 bits), channels (3 bits), bits per sample (5 bits)
        let sampleRate = (Int(data[10]) << 12) | (Int(data[11]) << 4) | (Int(data[12]) >> 4)
        let channels = ((Int(data[12]) >> 1) & 0x07) + 1

        // Total samples: 36 bits starting at bit 4 of byte 13
        let totalSamples = (UInt64(data[13] & 0x0F) << 32) |
                           (UInt64(data[14]) << 24) |
                           (UInt64(data[15]) << 16) |
                           (UInt64(data[16]) << 8) |
                           UInt64(data[17])

        metadata.sampleRate = sampleRate
        metadata.channels = channels
        if sampleRate > 0 && totalSamples > 0 {
            metadata.duration = Double(totalSamples) / Double(sampleRate)
        }
    }

    /// Extract picture data from a PICTURE block.
    private static func extractPicture(_ data: Data) -> Data? {
        guard data.count > 32 else { return nil }
        var offset = 4 // Skip picture type

        // MIME type
        guard offset + 4 <= data.count else { return nil }
        let mimeLen = readUInt32BE(data, at: offset)
        offset += 4 + Int(mimeLen)

        // Description
        guard offset + 4 <= data.count else { return nil }
        let descLen = readUInt32BE(data, at: offset)
        offset += 4 + Int(descLen)

        // Width, height, depth, colors (4 * 4 bytes)
        offset += 16

        // Picture data
        guard offset + 4 <= data.count else { return nil }
        let picLen = readUInt32BE(data, at: offset)
        offset += 4
        guard offset + Int(picLen) <= data.count else { return nil }
        return Data(data[offset..<offset + Int(picLen)])
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
        UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
}
