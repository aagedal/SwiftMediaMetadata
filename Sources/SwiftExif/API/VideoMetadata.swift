import Foundation

/// Read-only metadata extracted from MP4/MOV/M4V video files.
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

    public init(format: VideoFormat) {
        self.format = format
        self.warnings = []
    }

    /// Read video metadata from a file URL.
    public static func read(from url: URL) throws -> VideoMetadata {
        let data = try Data(contentsOf: url)
        return try read(from: data)
    }

    /// Read video metadata from data.
    public static func read(from data: Data) throws -> VideoMetadata {
        return try MP4Parser.parse(data)
    }
}
