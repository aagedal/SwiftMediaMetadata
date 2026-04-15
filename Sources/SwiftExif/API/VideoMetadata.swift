import Foundation

/// Metadata for MP4/MOV/M4V video files. Supports both reading and writing.
public struct VideoMetadata: Sendable {
    public var format: VideoFormat
    public var duration: TimeInterval?
    public var creationDate: Date?
    public var modificationDate: Date?
    public var videoWidth: Int?
    public var videoHeight: Int?
    public var videoCodec: String?
    public var audioCodec: String?
    public var frameRate: Double?
    public var title: String?
    public var artist: String?
    public var comment: String?
    public var gpsLatitude: Double?
    public var gpsLongitude: Double?
    public var gpsAltitude: Double?
    public var xmp: XMPData?
    public var warnings: [String]

    /// The original file data (needed for writing back).
    internal var originalData: Data?

    public init(format: VideoFormat) {
        self.format = format
        self.warnings = []
    }

    // MARK: - Reading

    /// Read video metadata from a file URL.
    public static func read(from url: URL) throws -> VideoMetadata {
        let data = try Data(contentsOf: url)
        var metadata = try MP4Parser.parse(data)
        metadata.originalData = data
        return metadata
    }

    /// Read video metadata from data.
    public static func read(from data: Data) throws -> VideoMetadata {
        var metadata = try MP4Parser.parse(data)
        metadata.originalData = data
        return metadata
    }

    // MARK: - Writing

    /// Write updated metadata back to a new Data blob.
    public func writeToData() throws -> Data {
        guard let original = originalData else {
            throw MetadataError.writeNotSupported("No original video data available for writing")
        }
        return try MP4Writer.write(self, to: original)
    }

    /// Write updated metadata to a file URL.
    public func write(to url: URL) throws {
        try write(to: url, options: .default)
    }

    /// Write metadata to a file URL with options (atomic, backup).
    public func write(to url: URL, options: ImageMetadata.WriteOptions) throws {
        let data = try writeToData()
        let fm = FileManager.default

        if options.createBackup && fm.fileExists(atPath: url.path) {
            let backupURL = ImageMetadata.backupURL(for: url, suffix: options.backupSuffix)
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: url, to: backupURL)
        }

        if options.atomic {
            let dir = url.deletingLastPathComponent()
            let tempURL = dir.appendingPathComponent(".swiftexif_tmp_\(UUID().uuidString)")
            do {
                try data.write(to: tempURL)
                _ = try fm.replaceItemAt(url, withItemAt: tempURL)
            } catch {
                try? fm.removeItem(at: tempURL)
                throw MetadataError.fileWriteError("Atomic write failed: \(error.localizedDescription)")
            }
        } else {
            try data.write(to: url)
        }
    }

    // MARK: - Stripping

    /// Strip all user metadata (title, artist, comment, GPS, XMP).
    public mutating func stripMetadata() {
        title = nil
        artist = nil
        comment = nil
        gpsLatitude = nil
        gpsLongitude = nil
        gpsAltitude = nil
        xmp = nil
    }

    /// Strip only GPS metadata.
    public mutating func stripGPS() {
        gpsLatitude = nil
        gpsLongitude = nil
        gpsAltitude = nil
    }

    /// Strip only XMP metadata.
    public mutating func stripXMP() {
        xmp = nil
    }
}
