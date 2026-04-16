import Foundation

/// Metadata for audio files (MP3, FLAC, M4A).
public struct AudioMetadata: Sendable {
    public var format: AudioFormat
    public var title: String?
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: String?
    public var genre: String?
    public var comment: String?
    public var duration: TimeInterval?
    public var bitrate: Int?
    public var sampleRate: Int?
    public var channels: Int?
    public var albumArtist: String?
    public var composer: String?
    public var coverArt: Data?
    public var warnings: [String]

    internal var originalData: Data?

    public init(format: AudioFormat) {
        self.format = format
        self.warnings = []
    }

    // MARK: - Reading

    public static func read(from url: URL) throws -> AudioMetadata {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let format: AudioFormat
        if let detected = FormatDetector.detectAudio(data) {
            format = detected
        } else if let detected = FormatDetector.detectAudioFromExtension(ext) {
            format = detected
        } else {
            throw MetadataError.unsupportedFormat
        }
        return try read(from: data, format: format)
    }

    public static func read(from data: Data, format: AudioFormat) throws -> AudioMetadata {
        switch format {
        case .mp3:
            var m = try ID3Parser.parse(data)
            m.originalData = data
            return m
        case .flac:
            var m = try FLACParser.parse(data)
            m.originalData = data
            return m
        case .m4a:
            let vm = try MP4Parser.parse(data)
            var m = AudioMetadata(format: .m4a)
            m.title = vm.title
            m.artist = vm.artist
            m.comment = vm.comment
            m.duration = vm.duration
            m.originalData = data
            return m
        }
    }

    // MARK: - Writing

    public func writeToData() throws -> Data {
        guard let original = originalData else {
            throw MetadataError.writeNotSupported("No original audio data available for writing")
        }
        switch format {
        case .mp3:
            return try ID3Writer.write(self, to: original)
        case .flac:
            return try FLACWriter.write(self, to: original)
        case .m4a:
            // M4A writing delegates to the video writer infrastructure
            var vm = try MP4Parser.parse(original)
            vm.title = title
            vm.artist = artist
            vm.comment = comment
            return try MP4Writer.write(vm, to: original)
        }
    }

    public func write(to url: URL) throws {
        let data = try writeToData()
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent(".swiftexif_tmp_\(UUID().uuidString)")
        do {
            try data.write(to: tempURL)
            _ = try fm.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? fm.removeItem(at: tempURL)
            throw MetadataError.fileWriteError("Audio write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Stripping

    public mutating func stripMetadata() {
        title = nil
        artist = nil
        album = nil
        trackNumber = nil
        discNumber = nil
        year = nil
        genre = nil
        comment = nil
        albumArtist = nil
        composer = nil
        coverArt = nil
    }
}
