import Foundation

/// Scan/field order for video essence.
public enum VideoFieldOrder: String, Sendable, Equatable {
    case progressive
    case topFieldFirst = "top-field-first"
    case bottomFieldFirst = "bottom-field-first"
    case mixed
    case unknown
}

/// Parsed color-space metadata for a video track.
/// Values use the numeric codes defined in ITU-T H.273 / ISO/IEC 23091-2.
public struct VideoColorInfo: Sendable, Equatable {
    /// Color primaries (H.273 Table 2). Common: 1=BT.709, 9=BT.2020, 6/7=BT.601.
    public var primaries: Int?
    /// Transfer characteristics (H.273 Table 3). Common: 1=BT.709, 16=PQ (SMPTE ST 2084), 18=HLG.
    public var transfer: Int?
    /// Matrix coefficients (H.273 Table 4). Common: 1=BT.709, 9=BT.2020-NCL, 6/7=BT.601.
    public var matrix: Int?
    /// `true` = full (0-255), `false` = limited (16-235).
    public var fullRange: Bool?

    public init(primaries: Int? = nil, transfer: Int? = nil, matrix: Int? = nil, fullRange: Bool? = nil) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.fullRange = fullRange
    }

    /// True when every field is nil.
    public var isEmpty: Bool {
        primaries == nil && transfer == nil && matrix == nil && fullRange == nil
    }

    /// Human-readable label for the color space — e.g. "bt709", "bt2020-pq", "bt2020-hlg".
    public var label: String? {
        guard let matrix else { return nil }
        let base: String
        switch matrix {
        case 1: base = "bt709"
        case 6, 7: base = "bt601"
        case 9: base = "bt2020"
        default: base = "mc\(matrix)"
        }
        switch transfer {
        case 16: return "\(base)-pq"
        case 18: return "\(base)-hlg"
        default: return base
        }
    }
}

/// A video track (stream) inside a container.
public struct VideoStream: Sendable, Equatable {
    public var index: Int
    public var codec: String?
    public var codecName: String?
    /// Codec profile name (e.g. "Main", "Main 10", "High", "Main 4:4:4 12",
    /// "Constrained Baseline"). Populated where the codec's decoder-config
    /// record carries an unambiguous profile_idc (HEVC, AV1, AVC).
    public var profile: String?
    public var width: Int?
    public var height: Int?
    public var displayWidth: Int?
    public var displayHeight: Int?
    /// Pixel aspect ratio as (horizontal, vertical).
    public var pixelAspectRatio: (Int, Int)?
    public var bitDepth: Int?
    /// Stream bitrate in bits per second (if advertised by the container).
    public var bitRate: Int?
    /// Single frame-rate figure (kept for backwards compatibility — equals
    /// `avgFrameRate` when available, else `rFrameRate`).
    public var frameRate: Double?
    /// Average frame rate across the stream (ffprobe `avg_frame_rate`).
    public var avgFrameRate: Double?
    /// "Real" frame rate — the base cadence the decoder ticks at, typically
    /// equal to the inverse of DefaultDuration / sample delta (ffprobe
    /// `r_frame_rate`).
    public var rFrameRate: Double?
    public var duration: TimeInterval?
    public var fieldOrder: VideoFieldOrder?
    public var colorInfo: VideoColorInfo?
    /// Chroma subsampling notation (e.g. "4:2:0", "4:2:2", "4:4:4", "4:0:0").
    public var chromaSubsampling: String?
    /// Chroma sample location (e.g. "left", "center", "topleft", "top",
    /// "bottomleft", "bottom"). Matches ffprobe `chroma_location`.
    public var chromaLocation: String?
    /// ffprobe-style pixel format string (e.g. "yuv420p", "yuv420p10le",
    /// "yuvj420p", "yuv444p12le"). Derived from codec + bit depth + chroma
    /// subsampling + color range when the container doesn't name one directly.
    public var pixelFormat: String?
    /// Number of video frames (from container metadata).
    public var frameCount: Int?
    /// True when the track is a cover-art / attached-picture track rather
    /// than a timed video track (ffprobe `DISPOSITION:attached_pic`).
    public var isAttachedPic: Bool?
    /// Default-track flag (ffprobe `DISPOSITION:default`). When the container
    /// is Matroska and the element is absent, defaults to `true` per spec.
    public var isDefault: Bool?
    /// Forced-display flag (ffprobe `DISPOSITION:forced`).
    public var isForced: Bool?
    /// Per-stream timecode (HH:MM:SS:FF) where available.
    public var timecode: String?
    /// Optional human-readable track title / label set by the muxer.
    public var title: String?

    public init(index: Int) {
        self.index = index
    }

    public static func == (lhs: VideoStream, rhs: VideoStream) -> Bool {
        lhs.index == rhs.index
            && lhs.codec == rhs.codec
            && lhs.codecName == rhs.codecName
            && lhs.profile == rhs.profile
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.displayWidth == rhs.displayWidth
            && lhs.displayHeight == rhs.displayHeight
            && lhs.pixelAspectRatio?.0 == rhs.pixelAspectRatio?.0
            && lhs.pixelAspectRatio?.1 == rhs.pixelAspectRatio?.1
            && lhs.bitDepth == rhs.bitDepth
            && lhs.bitRate == rhs.bitRate
            && lhs.frameRate == rhs.frameRate
            && lhs.avgFrameRate == rhs.avgFrameRate
            && lhs.rFrameRate == rhs.rFrameRate
            && lhs.duration == rhs.duration
            && lhs.fieldOrder == rhs.fieldOrder
            && lhs.colorInfo == rhs.colorInfo
            && lhs.chromaSubsampling == rhs.chromaSubsampling
            && lhs.chromaLocation == rhs.chromaLocation
            && lhs.pixelFormat == rhs.pixelFormat
            && lhs.frameCount == rhs.frameCount
            && lhs.isAttachedPic == rhs.isAttachedPic
            && lhs.isDefault == rhs.isDefault
            && lhs.isForced == rhs.isForced
            && lhs.timecode == rhs.timecode
            && lhs.title == rhs.title
    }
}

/// A subtitle / timed-text / closed-caption track inside a container.
public struct SubtitleStream: Sendable, Equatable {
    public var index: Int
    /// Short codec identifier as stored in the container (e.g. "tx3g", "wvtt",
    /// "stpp", "c608", "c708", "S_TEXT/UTF8", "S_TEXT/ASS", "S_HDMV/PGS",
    /// "S_VOBSUB", "dvb_subtitle", "dvb_teletext").
    public var codec: String?
    /// Human-readable codec label ("WebVTT", "TTML", "3GPP Timed Text",
    /// "SubRip", "ASS", "PGS", "VobSub", "DVB Subtitles", …).
    public var codecName: String?
    /// ISO 639-2/T language code (e.g. "eng", "nor", "swe"), when declared.
    public var language: String?
    /// Optional human-readable track title / label.
    public var title: String?
    /// Default-track flag if the container signals one.
    public var isDefault: Bool?
    /// Forced-display flag (e.g. foreign-audio burn-in tracks).
    public var isForced: Bool?
    /// Hearing-impaired flag (SDH).
    public var isHearingImpaired: Bool?
    public var duration: TimeInterval?

    public init(index: Int) {
        self.index = index
    }
}

/// An audio track (stream) inside a container.
public struct AudioStream: Sendable, Equatable {
    public var index: Int
    public var codec: String?
    public var codecName: String?
    /// Codec profile (e.g. "LC", "HE-AAC", "HE-AACv2", "Main", "LTP").
    public var profile: String?
    public var sampleRate: Int?
    public var channels: Int?
    public var channelLayout: String?
    public var bitDepth: Int?
    public var bitRate: Int?
    public var duration: TimeInterval?
    public var language: String?
    /// Default-track flag if the container signals one.
    public var isDefault: Bool?
    /// Optional human-readable track title / label set by the muxer.
    public var title: String?

    public init(index: Int) {
        self.index = index
    }
}
