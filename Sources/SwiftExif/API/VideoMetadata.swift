import Foundation

/// Metadata for video container files (MP4, MOV, M4V, MXF, MKV, WebM, AVI, MPEG-PS/TS).
/// Reading is supported for all container formats; writing is currently only supported
/// for MP4/MOV/M4V (see `writeToData()` for details).
public struct VideoMetadata: Sendable {
    public var format: VideoFormat
    /// Human-readable container name, ffprobe-compatible (e.g. "QuickTime / MOV",
    /// "MP4 (MPEG-4 Part 14)", "Matroska / WebM", "AVI (Audio Video Interleave)",
    /// "MXF (Material eXchange Format)", "MPEG-TS (MPEG-2 Transport Stream)").
    public var formatLongName: String?
    /// File size in bytes (when read from a file or data blob).
    public var fileSize: Int64?
    /// Clip-level timecode (HH:MM:SS:FF) when the container embeds a dedicated
    /// timecode track (e.g. QuickTime `tmcd`).
    public var timecode: String?
    public var duration: TimeInterval?
    public var creationDate: Date?
    public var modificationDate: Date?
    /// Primary video stream width (in pixels). Populated from the first video track.
    public var videoWidth: Int?
    /// Primary video stream height (in pixels). Populated from the first video track.
    public var videoHeight: Int?
    public var videoCodec: String?
    public var audioCodec: String?
    public var frameRate: Double?
    /// Scan type of the primary video stream.
    public var fieldOrder: VideoFieldOrder?
    /// Color-space metadata for the primary video stream.
    public var colorInfo: VideoColorInfo?
    /// Bit depth per color component of the primary video stream.
    public var bitDepth: Int?
    /// Chroma subsampling notation for the primary video stream (e.g. "4:2:0").
    public var chromaSubsampling: String?
    /// Pixel aspect ratio of the primary video stream, expressed as (horizontal, vertical).
    public var pixelAspectRatio: (Int, Int)?
    /// Display width of the primary video stream (PAR-adjusted) if advertised by the container.
    public var displayWidth: Int?
    /// Display height of the primary video stream (PAR-adjusted) if advertised by the container.
    public var displayHeight: Int?
    /// Sample rate (Hz) of the primary audio stream.
    public var audioSampleRate: Int?
    /// Channel count of the primary audio stream.
    public var audioChannels: Int?
    /// Per-track video streams (for multi-track files).
    public var videoStreams: [VideoStream]
    /// Per-track audio streams (for multi-track files).
    public var audioStreams: [AudioStream]
    /// Per-track subtitle / timed-text / closed-caption streams.
    public var subtitleStreams: [SubtitleStream]
    /// Overall container bit rate in bits/second, when the container advertises one.
    public var bitRate: Int?
    public var title: String?
    public var artist: String?
    public var comment: String?
    public var gpsLatitude: Double?
    public var gpsLongitude: Double?
    public var gpsAltitude: Double?
    public var xmp: XMPData?
    /// Parsed C2PA manifests (if the video is C2PA-signed).
    public var c2pa: C2PAData?
    /// Camera/clip metadata from Sony NonRealTimeMeta (embedded or sidecar XML).
    public var camera: CameraMetadata?
    public var warnings: [String]

    /// The original file data (needed for writing back).
    internal var originalData: Data?

    public init(format: VideoFormat) {
        self.format = format
        self.warnings = []
        self.videoStreams = []
        self.audioStreams = []
        self.subtitleStreams = []
    }

    // MARK: - Reading

    /// Read video metadata from a file URL.
    ///
    /// If the URL points at an MXF file or a container with a Sony NonRealTimeMeta
    /// sidecar (e.g. `CLIP.MXF` next to `CLIP.XML`), the sidecar is auto-discovered
    /// and merged into `camera`.
    ///
    /// The file is memory-mapped when safe (`.mappedIfSafe`) so multi-gigabyte
    /// video essence (mdat, MXF KLV body) never needs to be fully resident — only
    /// the metadata-bearing boxes/KLVs the parsers touch end up paged in.
    public static func read(from url: URL) throws -> VideoMetadata {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var metadata = try parseContainer(data)
        metadata.originalData = data
        if metadata.fileSize == nil { metadata.fileSize = Int64(data.count) }
        if metadata.formatLongName == nil { metadata.formatLongName = defaultFormatLongName(metadata.format) }

        // Auto-probe NRT sidecar if no embedded camera metadata is present.
        if metadata.camera == nil || metadata.camera?.isEmpty == true {
            if let sidecarURL = NRTXMLParser.sidecarURL(for: url) {
                if let sidecarData = try? Data(contentsOf: sidecarURL),
                   let cam = try? NRTXMLParser.parse(sidecarData) {
                    metadata.camera = cam
                }
            }
        }

        return metadata
    }

    /// Read video metadata from data.
    public static func read(from data: Data) throws -> VideoMetadata {
        var metadata = try parseContainer(data)
        metadata.originalData = data
        if metadata.fileSize == nil { metadata.fileSize = Int64(data.count) }
        if metadata.formatLongName == nil { metadata.formatLongName = defaultFormatLongName(metadata.format) }
        return metadata
    }

    private static func defaultFormatLongName(_ format: VideoFormat) -> String {
        switch format {
        case .mp4: return "MP4 (MPEG-4 Part 14)"
        case .mov: return "QuickTime / MOV"
        case .m4v: return "Apple iTunes Video (M4V)"
        case .mxf: return "MXF (Material eXchange Format)"
        case .mkv: return "Matroska"
        case .webm: return "WebM"
        case .avi: return "AVI (Audio Video Interleave)"
        case .mpg: return "MPEG-PS / MPEG-TS"
        }
    }

    private static func parseContainer(_ data: Data) throws -> VideoMetadata {
        if MXFReader.isMXF(data) {
            return try MXFReader.parse(data)
        }
        if MatroskaReader.isMatroska(data) {
            return try MatroskaReader.parse(data)
        }
        if AVIReader.isAVI(data) {
            return try AVIReader.parse(data)
        }
        if MPEGReader.isMPEG(data) {
            return try MPEGReader.parse(data)
        }
        return try MP4Parser.parse(data)
    }

    // MARK: - Writing

    /// Write updated metadata back to a new Data blob.
    ///
    /// Writing is only supported for ISOBMFF containers (MP4/MOV/M4V); all other
    /// formats throw `MetadataError.writeNotSupported`.
    public func writeToData() throws -> Data {
        guard let original = originalData else {
            throw MetadataError.writeNotSupported("No original video data available for writing")
        }
        switch format {
        case .mp4, .mov, .m4v:
            return try MP4Writer.write(self, to: original)
        case .mxf, .mkv, .webm, .avi, .mpg:
            throw MetadataError.writeNotSupported("Writing is not supported for \(format.rawValue.uppercased()) containers")
        }
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

    /// Strip all user metadata (title, artist, comment, GPS, XMP, C2PA, camera).
    public mutating func stripMetadata() {
        title = nil
        artist = nil
        comment = nil
        gpsLatitude = nil
        gpsLongitude = nil
        gpsAltitude = nil
        xmp = nil
        c2pa = nil
        camera = nil
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
