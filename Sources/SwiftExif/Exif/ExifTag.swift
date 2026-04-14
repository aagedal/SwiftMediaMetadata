import Foundation

/// Standard Exif tag constants.
public enum ExifTag: Sendable {
    // MARK: - IFD0 (Main Image)
    public static let imageWidth: UInt16            = 0x0100
    public static let imageHeight: UInt16           = 0x0101
    public static let bitsPerSample: UInt16         = 0x0102
    public static let compression: UInt16           = 0x0103
    public static let photometricInterpretation: UInt16 = 0x0106
    public static let imageDescription: UInt16      = 0x010E
    public static let make: UInt16                  = 0x010F
    public static let model: UInt16                 = 0x0110
    public static let orientation: UInt16           = 0x0112
    public static let samplesPerPixel: UInt16       = 0x0115
    public static let xResolution: UInt16           = 0x011A
    public static let yResolution: UInt16           = 0x011B
    public static let resolutionUnit: UInt16        = 0x0128
    public static let software: UInt16              = 0x0131
    public static let dateTime: UInt16              = 0x0132
    public static let artist: UInt16                = 0x013B
    public static let copyright: UInt16             = 0x8298
    public static let exifIFDPointer: UInt16        = 0x8769
    public static let gpsIFDPointer: UInt16         = 0x8825

    // MARK: - Exif Sub-IFD
    public static let exposureTime: UInt16          = 0x829A
    public static let fNumber: UInt16               = 0x829D
    public static let exposureProgram: UInt16       = 0x8822
    public static let isoSpeedRatings: UInt16       = 0x8827
    public static let exifVersion: UInt16           = 0x9000
    public static let dateTimeOriginal: UInt16      = 0x9003
    public static let dateTimeDigitized: UInt16     = 0x9004
    public static let shutterSpeedValue: UInt16     = 0x9201
    public static let apertureValue: UInt16         = 0x9202
    public static let brightnessValue: UInt16       = 0x9203
    public static let exposureBiasValue: UInt16     = 0x9204
    public static let maxApertureValue: UInt16      = 0x9205
    public static let meteringMode: UInt16          = 0x9207
    public static let lightSource: UInt16           = 0x9208
    public static let flash: UInt16                 = 0x9209
    public static let focalLength: UInt16           = 0x920A
    public static let userComment: UInt16           = 0x9286
    public static let colorSpace: UInt16            = 0xA001
    public static let pixelXDimension: UInt16       = 0xA002
    public static let pixelYDimension: UInt16       = 0xA003
    public static let focalPlaneXResolution: UInt16 = 0xA20E
    public static let focalPlaneYResolution: UInt16 = 0xA20F
    public static let focalPlaneResolutionUnit: UInt16 = 0xA210
    public static let sensingMethod: UInt16         = 0xA217
    public static let customRendered: UInt16        = 0xA401
    public static let exposureMode: UInt16          = 0xA402
    public static let whiteBalance: UInt16          = 0xA403
    public static let digitalZoomRatio: UInt16      = 0xA404
    public static let focalLengthIn35mmFilm: UInt16 = 0xA405
    public static let sceneCaptureType: UInt16      = 0xA406
    public static let lensModel: UInt16             = 0xA434
    public static let lensMake: UInt16              = 0xA433
    public static let lensSpecification: UInt16     = 0xA432

    // MARK: - IFD1 (Thumbnail)
    public static let jpegIFOffset: UInt16          = 0x0201  // Thumbnail data offset
    public static let jpegIFByteCount: UInt16       = 0x0202  // Thumbnail data length

    // MARK: - GPS IFD
    public static let gpsVersionID: UInt16          = 0x0000
    public static let gpsLatitudeRef: UInt16        = 0x0001
    public static let gpsLatitude: UInt16           = 0x0002
    public static let gpsLongitudeRef: UInt16       = 0x0003
    public static let gpsLongitude: UInt16          = 0x0004
    public static let gpsAltitudeRef: UInt16        = 0x0005
    public static let gpsAltitude: UInt16           = 0x0006
    public static let gpsTimeStamp: UInt16          = 0x0007
    public static let gpsDateStamp: UInt16          = 0x001D

    // MARK: - TIFF Embedded Metadata Tags
    public static let iptcNAA: UInt16      = 0x83BB  // Raw IPTC-NAA data in IFD
    public static let photoshopIRB: UInt16 = 0x8649  // Photoshop IRB (contains IPTC)
    public static let xmpTag: UInt16       = 0x02BC  // Raw XMP XML string
    public static let iccProfile: UInt16   = 0x8773  // ICC color profile (InterColorProfile)

    // MARK: - IFD Type

    public enum IFDType: Sendable {
        case ifd0, ifd1, exifIFD, gpsIFD
    }

    // MARK: - Name Lookup

    public static func name(for tag: UInt16, ifd: IFDType = .ifd0) -> String {
        switch ifd {
        case .gpsIFD:
            return gpsTagNames[tag] ?? "GPS_0x\(String(tag, radix: 16, uppercase: true))"
        case .exifIFD:
            return exifTagNames[tag] ?? ifd0TagNames[tag] ?? "Exif_0x\(String(tag, radix: 16, uppercase: true))"
        default:
            return ifd0TagNames[tag] ?? "IFD_0x\(String(tag, radix: 16, uppercase: true))"
        }
    }

    private static let ifd0TagNames: [UInt16: String] = [
        0x0100: "ImageWidth", 0x0101: "ImageHeight", 0x0102: "BitsPerSample",
        0x0103: "Compression", 0x010E: "ImageDescription", 0x010F: "Make",
        0x0110: "Model", 0x0112: "Orientation", 0x011A: "XResolution",
        0x011B: "YResolution", 0x0128: "ResolutionUnit", 0x0131: "Software",
        0x0132: "DateTime", 0x013B: "Artist", 0x8298: "Copyright",
        0x8769: "ExifIFDPointer", 0x8825: "GPSIFDPointer",
    ]

    private static let exifTagNames: [UInt16: String] = [
        0x829A: "ExposureTime", 0x829D: "FNumber", 0x8822: "ExposureProgram",
        0x8827: "ISOSpeedRatings", 0x9000: "ExifVersion",
        0x9003: "DateTimeOriginal", 0x9004: "DateTimeDigitized",
        0x9201: "ShutterSpeedValue", 0x9202: "ApertureValue",
        0x9204: "ExposureBiasValue", 0x9207: "MeteringMode",
        0x9209: "Flash", 0x920A: "FocalLength", 0xA001: "ColorSpace",
        0xA002: "PixelXDimension", 0xA003: "PixelYDimension",
        0xA434: "LensModel", 0xA433: "LensMake",
    ]

    private static let gpsTagNames: [UInt16: String] = [
        0x0000: "GPSVersionID", 0x0001: "GPSLatitudeRef", 0x0002: "GPSLatitude",
        0x0003: "GPSLongitudeRef", 0x0004: "GPSLongitude",
        0x0005: "GPSAltitudeRef", 0x0006: "GPSAltitude",
        0x0007: "GPSTimeStamp", 0x001D: "GPSDateStamp",
    ]
}
