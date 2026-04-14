import Foundation

/// Calculates derived/composite metadata values from existing EXIF data.
/// Equivalent to ExifTool's composite tags.
public struct CompositeTagCalculator: Sendable {

    /// Calculate all available composite tags from the given ExifData.
    /// Returns a dictionary with "Composite:" prefixed keys.
    public static func calculate(from exif: ExifData) -> [String: Any] {
        var dict: [String: Any] = [:]

        if let v = apertureFromAPEX(exif) { dict["Composite:Aperture"] = v }
        if let v = shutterSpeedFromAPEX(exif) { dict["Composite:ShutterSpeed"] = v }
        if let v = megapixels(exif) { dict["Composite:Megapixels"] = v }
        if let v = lensID(exif) { dict["Composite:LensID"] = v }
        if let v = scaleFactor35efl(exif) { dict["Composite:ScaleFactor35efl"] = v }
        if let v = lightValue(exif) { dict["Composite:LightValue"] = v }
        if let v = fieldOfView(exif) { dict["Composite:FOV"] = v }
        if let v = gpsPosition(exif) { dict["Composite:GPSPosition"] = v }

        return dict
    }

    // MARK: - Individual Calculators

    /// Calculate f-number from APEX ApertureValue: f = 2^(ApertureValue/2)
    public static func apertureFromAPEX(_ exif: ExifData) -> Double? {
        guard let av = exif.apertureValue, av.denominator > 0 else { return nil }
        let value = Double(av.numerator) / Double(av.denominator)
        return pow(2.0, value / 2.0)
    }

    /// Calculate exposure time in seconds from APEX ShutterSpeedValue: t = 1 / 2^value
    public static func shutterSpeedFromAPEX(_ exif: ExifData) -> Double? {
        guard let sv = exif.shutterSpeedValue, sv.denominator != 0 else { return nil }
        let value = Double(sv.numerator) / Double(sv.denominator)
        return 1.0 / pow(2.0, value)
    }

    /// Calculate megapixels from PixelXDimension * PixelYDimension / 1_000_000.
    public static func megapixels(_ exif: ExifData) -> Double? {
        guard let w = exif.pixelXDimension, let h = exif.pixelYDimension,
              w > 0, h > 0 else { return nil }
        return Double(w) * Double(h) / 1_000_000.0
    }

    /// Combined LensID from LensMake and LensModel.
    public static func lensID(_ exif: ExifData) -> String? {
        let make = exif.lensMake
        let model = exif.lensModel
        if let make = make, let model = model {
            if model.lowercased().hasPrefix(make.lowercased()) {
                return model
            }
            return "\(make) \(model)"
        }
        return model ?? make
    }

    /// Scale factor: FocalLengthIn35mmFilm / FocalLength.
    public static func scaleFactor35efl(_ exif: ExifData) -> Double? {
        guard let fl35 = exif.focalLengthIn35mmFilm, fl35 > 0,
              let fl = exif.focalLength, fl.denominator > 0 else { return nil }
        let focalLength = Double(fl.numerator) / Double(fl.denominator)
        guard focalLength > 0 else { return nil }
        return Double(fl35) / focalLength
    }

    /// Light Value (EV at ISO 100): log2(f^2 / t) adjusted for ISO.
    public static func lightValue(_ exif: ExifData) -> Double? {
        let fNum: Double
        if let fn = exif.fNumber, fn.denominator > 0 {
            fNum = Double(fn.numerator) / Double(fn.denominator)
        } else if let av = apertureFromAPEX(exif) {
            fNum = av
        } else {
            return nil
        }

        let shutterTime: Double
        if let et = exif.exposureTime, et.denominator > 0 {
            shutterTime = Double(et.numerator) / Double(et.denominator)
        } else if let ss = shutterSpeedFromAPEX(exif) {
            shutterTime = ss
        } else {
            return nil
        }

        guard fNum > 0, shutterTime > 0 else { return nil }

        let ev100 = log2((fNum * fNum) / shutterTime)

        guard let iso = exif.isoSpeed, iso > 0 else { return ev100 }
        return ev100 - log2(Double(iso) / 100.0)
    }

    /// Field of view in degrees, computed from focal length and sensor dimensions.
    public static func fieldOfView(_ exif: ExifData) -> Double? {
        guard let fl = exif.focalLength, fl.denominator > 0 else { return nil }
        let focalLength = Double(fl.numerator) / Double(fl.denominator)
        guard focalLength > 0 else { return nil }

        // Try to determine sensor width from FocalPlaneXResolution + ResolutionUnit
        guard let fpxrEntry = exif.exifIFD?.entry(for: ExifTag.focalPlaneXResolution),
              let fpxr = fpxrEntry.rationalValue(endian: exif.byteOrder),
              fpxr.denominator > 0 else { return nil }

        let fpxResolution = Double(fpxr.numerator) / Double(fpxr.denominator)
        guard fpxResolution > 0 else { return nil }

        // Get pixel width
        guard let pixelWidth = exif.pixelXDimension, pixelWidth > 0 else { return nil }

        // FocalPlaneResolutionUnit: 2=inches, 3=cm, default to inches
        let unitEntry = exif.exifIFD?.entry(for: ExifTag.focalPlaneResolutionUnit)
        let unit = unitEntry?.uint16Value(endian: exif.byteOrder) ?? 2
        let mmPerUnit: Double = (unit == 3) ? 10.0 : 25.4

        let sensorWidth = Double(pixelWidth) / fpxResolution * mmPerUnit
        return 2.0 * atan(sensorWidth / (2.0 * focalLength)) * 180.0 / .pi
    }

    /// Combined GPS position string: "lat, lon".
    public static func gpsPosition(_ exif: ExifData) -> String? {
        guard let lat = exif.gpsLatitude, let lon = exif.gpsLongitude else { return nil }
        return String(format: "%.6f, %.6f", lat, lon)
    }
}
