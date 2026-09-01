import Foundation

/// Unified metadata access for an image file.
public struct ImageMetadata: Sendable {
    public var container: ImageContainer
    public var format: ImageFormat
    public var iptc: IPTCData
    public var exif: ExifData?
    public var xmp: XMPData?
    public var c2pa: C2PAData?
    public var iccProfile: ICCProfile?
    /// JPEG Multi-Picture Format (CIPA DC-007) index. Present when an APP2
    /// segment carries the MPF block — typical for Apple Live Photo aux
    /// images, Sony multi-shot bursts, and stereo / 3D JPEG pairs.
    public var mpf: MPFData?
    /// Adobe DNG private tags (color matrices, default crop, opcode lists,
    /// noise profile). Populated only for files marked with DNGVersion (0xC612).
    public var dng: DNGMetadata?

    /// HDR static metadata for HDR HEIC / AVIF stills (mastering display
    /// colour volume + content light level), shared with `VideoStream.hdr`
    /// so HDR consumers see one shape across video and still containers.
    /// Populated from `mdcv` / `clli` properties under the HEIF / AVIF
    /// `meta → iprp → ipco` hierarchy.
    public var hdr: HDRMetadata?

    /// Non-fatal issues encountered during parsing (e.g. corrupted C2PA data).
    public var warnings: [String]

    public init(container: ImageContainer = .jpeg(JPEGFile()), format: ImageFormat = .jpeg, iptc: IPTCData = IPTCData(), exif: ExifData? = nil, xmp: XMPData? = nil, c2pa: C2PAData? = nil, iccProfile: ICCProfile? = nil, mpf: MPFData? = nil, dng: DNGMetadata? = nil, hdr: HDRMetadata? = nil, warnings: [String] = []) {
        self.container = container
        self.format = format
        self.iptc = iptc
        self.exif = exif
        self.xmp = xmp
        self.c2pa = c2pa
        self.iccProfile = iccProfile
        self.mpf = mpf
        self.dng = dng
        self.hdr = hdr
        self.warnings = warnings
    }
}
