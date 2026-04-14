import Foundation

/// Converts raw Exif numeric values to human-readable strings.
/// Equivalent to ExifTool's print conversion (default vs `-n` mode).
public struct PrintConverter: Sendable {

    /// Build a human-readable dictionary from metadata, converting raw values where applicable.
    public static func buildReadableDictionary(_ metadata: ImageMetadata) -> [String: String] {
        let rawDict = MetadataExporter.buildDictionary(metadata)
        var result: [String: String] = [:]

        for (key, value) in rawDict {
            result[key] = convertValue(key: key, value: value, metadata: metadata)
        }

        return result
    }

    /// Convert a single metadata value to its human-readable form.
    public static func convertValue(key: String, value: Any, metadata: ImageMetadata) -> String {
        switch key {
        case "Orientation":
            if let v = value as? Int { return orientation(v) }
        case "ExposureTime":
            if let s = value as? String { return exposureTime(s) }
        case "FNumber":
            if let v = value as? Double { return fNumber(v) }
        case "ExposureProgram":
            if let v = value as? Int { return exposureProgram(v) }
        case "MeteringMode":
            if let v = value as? Int { return meteringMode(v) }
        case "Flash":
            if let v = value as? Int { return flash(v) }
        case "ColorSpace":
            if let v = value as? Int { return colorSpace(v) }
        case "WhiteBalance":
            if let v = value as? Int { return whiteBalance(v) }
        case "SceneCaptureType":
            if let v = value as? Int { return sceneCaptureType(v) }
        case "ExposureMode":
            if let v = value as? Int { return exposureMode(v) }
        case "CustomRendered":
            if let v = value as? Int { return customRendered(v) }
        case "FocalLength":
            if let v = value as? Double { return focalLength(v) }
        case "FocalLengthIn35mmFilm":
            if let v = value as? Int { return "\(v) mm" }
        case "ResolutionUnit":
            if let v = value as? Int { return resolutionUnit(v) }
        case "SensingMethod":
            if let v = value as? Int { return sensingMethod(v) }
        case "LightSource":
            if let v = value as? Int { return lightSource(v) }
        case "Compression":
            if let v = value as? Int { return compression(v) }
        case "GPSLatitude":
            if let v = value as? Double {
                return formatGPSCoordinate(v, isLatitude: true)
            }
        case "GPSLongitude":
            if let v = value as? Double {
                return formatGPSCoordinate(v, isLongitude: true)
            }
        case "ISO":
            if let v = value as? Int { return String(v) }
        case "Composite:Aperture":
            if let v = value as? Double { return fNumber(v) }
        case "Composite:ShutterSpeed":
            if let v = value as? Double { return formatShutterSpeed(v) }
        case "Composite:Megapixels":
            if let v = value as? Double { return String(format: "%.1f", v) }
        case "Composite:LightValue":
            if let v = value as? Double { return String(format: "%.1f", v) }
        case "Composite:ScaleFactor35efl":
            if let v = value as? Double { return String(format: "%.1fx", v) }
        case "Composite:FOV":
            if let v = value as? Double { return String(format: "%.1f deg", v) }
        default:
            break
        }

        // Default: stringify
        if let arr = value as? [String] {
            return arr.joined(separator: ", ")
        }
        return String(describing: value)
    }

    // MARK: - Orientation

    public static func orientation(_ value: Int) -> String {
        switch value {
        case 1: return "Horizontal (normal)"
        case 2: return "Mirror horizontal"
        case 3: return "Rotate 180"
        case 4: return "Mirror vertical"
        case 5: return "Mirror horizontal and rotate 270 CW"
        case 6: return "Rotate 90 CW"
        case 7: return "Mirror horizontal and rotate 90 CW"
        case 8: return "Rotate 270 CW"
        default: return "Unknown (\(value))"
        }
    }

    // MARK: - Exposure Time

    public static func exposureTime(_ rational: String) -> String {
        // Input is "numerator/denominator" from MetadataExporter
        let parts = rational.split(separator: "/")
        guard parts.count == 2,
              let num = UInt32(parts[0]),
              let den = UInt32(parts[1]),
              den > 0 else { return rational }

        if num >= den {
            // >= 1 second
            let seconds = Double(num) / Double(den)
            if seconds == Double(Int(seconds)) {
                return "\(Int(seconds))s"
            }
            return String(format: "%.1fs", seconds)
        } else {
            // Fractional: show as 1/X
            let simplified = den / num
            return "1/\(simplified)s"
        }
    }

    // MARK: - F-Number

    public static func fNumber(_ value: Double) -> String {
        if value == Double(Int(value)) {
            return "f/\(Int(value))"
        }
        return String(format: "f/%.1f", value)
    }

    // MARK: - Focal Length

    public static func focalLength(_ value: Double) -> String {
        if value == Double(Int(value)) {
            return "\(Int(value)).0 mm"
        }
        return String(format: "%.1f mm", value)
    }

    // MARK: - Exposure Program

    public static func exposureProgram(_ value: Int) -> String {
        switch value {
        case 0: return "Not Defined"
        case 1: return "Manual"
        case 2: return "Normal Program"
        case 3: return "Aperture Priority"
        case 4: return "Shutter Priority"
        case 5: return "Creative Program"
        case 6: return "Action Program"
        case 7: return "Portrait Mode"
        case 8: return "Landscape Mode"
        default: return "Unknown (\(value))"
        }
    }

    // MARK: - Metering Mode

    public static func meteringMode(_ value: Int) -> String {
        switch value {
        case 0: return "Unknown"
        case 1: return "Average"
        case 2: return "Center-weighted average"
        case 3: return "Spot"
        case 4: return "Multi-spot"
        case 5: return "Multi-segment"
        case 6: return "Partial"
        case 255: return "Other"
        default: return "Unknown (\(value))"
        }
    }

    // MARK: - Flash

    public static func flash(_ value: Int) -> String {
        let fired = (value & 0x01) != 0
        let returnMode = (value >> 1) & 0x03
        let mode = (value >> 3) & 0x03
        let function = (value >> 5) & 0x01
        let redEye = (value >> 6) & 0x01

        var parts: [String] = []

        if fired {
            parts.append("Fired")
        } else {
            parts.append("Did not fire")
        }

        switch returnMode {
        case 2: parts.append("return not detected")
        case 3: parts.append("return detected")
        default: break
        }

        switch mode {
        case 1: parts.append("compulsory firing")
        case 2: parts.append("compulsory suppression")
        case 3: parts.append("auto mode")
        default: break
        }

        if function == 1 {
            parts.append("no flash function")
        }

        if redEye == 1 {
            parts.append("red-eye reduction")
        }

        return parts.joined(separator: ", ")
    }

    // MARK: - Color Space

    public static func colorSpace(_ value: Int) -> String {
        switch value {
        case 1: return "sRGB"
        case 65535: return "Uncalibrated"
        default: return "Unknown (\(value))"
        }
    }

    // MARK: - White Balance

    public static func whiteBalance(_ value: Int) -> String {
        switch value {
        case 0: return "Auto"
        case 1: return "Manual"
        default: return "Unknown (\(value))"
        }
    }

    // MARK: - Scene Capture Type

    public static func sceneCaptureType(_ value: Int) -> String {
        switch value {
        case 0: return "Standard"
        case 1: return "Landscape"
        case 2: return "Portrait"
        case 3: return "Night Scene"
        default: return "Unknown (\(value))"
        }
    }

    // MARK: - Exposure Mode

    public static func exposureMode(_ value: Int) -> String {
        switch value {
        case 0: return "Auto"
        case 1: return "Manual"
        case 2: return "Auto Bracket"
        default: return "Unknown (\(value))"
        }
    }

    // MARK: - Custom Rendered

    public static func customRendered(_ value: Int) -> String {
        switch value {
        case 0: return "Normal"
        case 1: return "Custom"
        default: return "Unknown (\(value))"
        }
    }

    // MARK: - Resolution Unit

    public static func resolutionUnit(_ value: Int) -> String {
        switch value {
        case 1: return "No Unit"
        case 2: return "inches"
        case 3: return "centimeters"
        default: return "Unknown (\(value))"
        }
    }

    // MARK: - Sensing Method

    public static func sensingMethod(_ value: Int) -> String {
        switch value {
        case 1: return "Not defined"
        case 2: return "One-chip color area"
        case 3: return "Two-chip color area"
        case 4: return "Three-chip color area"
        case 5: return "Color sequential area"
        case 7: return "Trilinear"
        case 8: return "Color sequential linear"
        default: return "Unknown (\(value))"
        }
    }

    // MARK: - Light Source

    public static func lightSource(_ value: Int) -> String {
        switch value {
        case 0: return "Unknown"
        case 1: return "Daylight"
        case 2: return "Fluorescent"
        case 3: return "Tungsten"
        case 4: return "Flash"
        case 9: return "Fine Weather"
        case 10: return "Cloudy"
        case 11: return "Shade"
        case 12: return "Daylight Fluorescent"
        case 13: return "Day White Fluorescent"
        case 14: return "Cool White Fluorescent"
        case 15: return "White Fluorescent"
        case 17: return "Standard Light A"
        case 18: return "Standard Light B"
        case 19: return "Standard Light C"
        case 20: return "D55"
        case 21: return "D65"
        case 22: return "D75"
        case 23: return "D50"
        case 24: return "ISO Studio Tungsten"
        case 255: return "Other"
        default: return "Unknown (\(value))"
        }
    }

    // MARK: - Compression

    public static func compression(_ value: Int) -> String {
        switch value {
        case 1: return "Uncompressed"
        case 6: return "JPEG"
        case 7: return "JPEG (DCT)"
        case 34712: return "JPEG 2000"
        default: return "Unknown (\(value))"
        }
    }

    // MARK: - Shutter Speed

    public static func formatShutterSpeed(_ seconds: Double) -> String {
        if seconds >= 1.0 {
            if seconds == Double(Int(seconds)) { return "\(Int(seconds))s" }
            return String(format: "%.1fs", seconds)
        }
        let reciprocal = Int(round(1.0 / seconds))
        return "1/\(reciprocal)s"
    }

    // MARK: - GPS Coordinates

    public static func formatGPSCoordinate(_ decimal: Double, isLatitude: Bool = false, isLongitude: Bool = false) -> String {
        let abs = Swift.abs(decimal)
        let degrees = Int(abs)
        let minutesDecimal = (abs - Double(degrees)) * 60.0
        let minutes = Int(minutesDecimal)
        let seconds = (minutesDecimal - Double(minutes)) * 60.0

        let direction: String
        if isLatitude {
            direction = decimal >= 0 ? "N" : "S"
        } else if isLongitude {
            direction = decimal >= 0 ? "E" : "W"
        } else {
            direction = ""
        }

        return String(format: "%d° %d' %.2f\" %@", degrees, minutes, seconds, direction).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - MetadataExporter Integration

extension MetadataExporter {

    /// Export metadata as a human-readable JSON string with print conversions applied.
    public static func toReadableJSON(_ metadata: ImageMetadata) -> String {
        let dict = PrintConverter.buildReadableDictionary(metadata)
        let sorted = dict.sorted { $0.key < $1.key }
        let obj = Dictionary(uniqueKeysWithValues: sorted)
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
