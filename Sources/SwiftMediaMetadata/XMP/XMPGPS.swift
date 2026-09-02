import Foundation

public enum XMPGPSAxis: String, Sendable, Equatable {
    case latitude
    case longitude
}

public enum XMPGPSDirectionReference: String, Sendable, Equatable {
    case trueNorth = "T"
    case magneticNorth = "M"
}

public enum XMPGPSParsingError: Error, Sendable, Equatable, LocalizedError {
    case emptyValue
    case malformedValue(String)
    case invalidHemisphere(String, axis: XMPGPSAxis)
    case contradictorySignAndHemisphere(String)
    case outOfRange(value: Double, axis: XMPGPSAxis)
    case invalidAltitudeReference(String)
    case invalidDirectionReference(String)
    case directionOutOfRange(Double)

    public var errorDescription: String? {
        switch self {
        case .emptyValue: return "The XMP GPS value is empty"
        case .malformedValue(let value): return "Malformed XMP GPS value: \(value)"
        case .invalidHemisphere(let value, let axis):
            return "Hemisphere \(value) is invalid for \(axis.rawValue)"
        case .contradictorySignAndHemisphere(let value):
            return "GPS sign and hemisphere contradict each other: \(value)"
        case .outOfRange(let value, let axis):
            return "GPS \(axis.rawValue) \(value) is out of range"
        case .invalidAltitudeReference(let value): return "Invalid GPSAltitudeRef: \(value)"
        case .invalidDirectionReference(let value): return "Invalid GPS direction reference: \(value)"
        case .directionOutOfRange(let value): return "GPS direction \(value) must be in 0..<360"
        }
    }
}

/// A parsed XMP coordinate together with the spelling found in the packet.
public struct XMPGPSCoordinate: Sendable, Equatable {
    public let decimalDegrees: Double
    public let axis: XMPGPSAxis
    public let hemisphere: String
    public let originalLexicalValue: String?

    public init(decimalDegrees: Double, axis: XMPGPSAxis) throws {
        try Self.validate(decimalDegrees, axis: axis)
        self.decimalDegrees = decimalDegrees
        self.axis = axis
        self.hemisphere = Self.hemisphere(for: decimalDegrees, axis: axis)
        self.originalLexicalValue = nil
    }

    /// Parse decimal degrees, directional decimal, degrees/minutes/seconds, or
    /// degrees/decimal-minutes. Separators may be whitespace, comma, or degree/
    /// minute/second symbols. A suffix or separate reference may supply N/S/E/W.
    public init(parsing value: String, axis: XMPGPSAxis, reference: String? = nil) throws {
        let parsed = try Self.parse(value, axis: axis, reference: reference)
        self.decimalDegrees = parsed.degrees
        self.axis = axis
        self.hemisphere = parsed.hemisphere
        self.originalLexicalValue = value
    }

    /// XMP Exif's canonical degrees/decimal-minutes spelling, such as
    /// `59,54.000000N`. `fractionalMinuteDigits` defaults to six (roughly
    /// millimetre numeric precision before source accuracy is considered).
    public func xmpString(fractionalMinuteDigits: Int = 6) -> String {
        let digits = min(max(fractionalMinuteDigits, 0), 12)
        let magnitude = abs(decimalDegrees)
        var degrees = floor(magnitude)
        var minutes = (magnitude - degrees) * 60
        let scale = pow(10.0, Double(digits))
        minutes = (minutes * scale).rounded() / scale
        if minutes >= 60 {
            degrees += 1
            minutes = 0
        }
        let minutesText = String(
            format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, minutes
        )
        return "\(Int(degrees)),\(minutesText)\(hemisphere)"
    }

    private static func parse(
        _ original: String,
        axis: XMPGPSAxis,
        reference: String?
    ) throws -> (degrees: Double, hemisphere: String) {
        var text = original.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !text.isEmpty else { throw XMPGPSParsingError.emptyValue }

        var suffix: String?
        if let last = text.last, "NSEW".contains(last) {
            suffix = String(last)
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let explicitReference = reference?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let explicitReference, !explicitReference.isEmpty {
            guard explicitReference.count == 1, "NSEW".contains(explicitReference) else {
                throw XMPGPSParsingError.invalidHemisphere(explicitReference, axis: axis)
            }
            if let suffix, suffix != explicitReference {
                throw XMPGPSParsingError.contradictorySignAndHemisphere(original)
            }
            suffix = explicitReference
        }
        if let suffix { try validate(suffix, axis: axis) }

        let explicitNegative = text.hasPrefix("-")
        let explicitPositive = text.hasPrefix("+")
        let separators = CharacterSet(charactersIn: "°º'\"′″,; ")
        let components = text.components(separatedBy: separators).filter { !$0.isEmpty }
        guard (1...3).contains(components.count),
              let first = Double(components[0]) else {
            throw XMPGPSParsingError.malformedValue(original)
        }
        var magnitude = abs(first)
        if components.count > 1 {
            guard let minutes = Double(components[1]), minutes >= 0, minutes < 60 else {
                throw XMPGPSParsingError.malformedValue(original)
            }
            magnitude += minutes / 60
        }
        if components.count > 2 {
            guard let seconds = Double(components[2]), seconds >= 0, seconds < 60 else {
                throw XMPGPSParsingError.malformedValue(original)
            }
            magnitude += seconds / 3600
        }

        let negativeHemisphere = suffix == "S" || suffix == "W"
        if suffix != nil && ((explicitNegative && !negativeHemisphere) || (explicitPositive && negativeHemisphere)) {
            throw XMPGPSParsingError.contradictorySignAndHemisphere(original)
        }
        let negative = explicitNegative || negativeHemisphere
        let degrees = negative ? -magnitude : magnitude
        try validate(degrees, axis: axis)
        return (degrees, suffix ?? hemisphere(for: degrees, axis: axis))
    }

    private static func validate(_ hemisphere: String, axis: XMPGPSAxis) throws {
        let valid = axis == .latitude ? ["N", "S"] : ["E", "W"]
        guard valid.contains(hemisphere) else {
            throw XMPGPSParsingError.invalidHemisphere(hemisphere, axis: axis)
        }
    }

    private static func validate(_ value: Double, axis: XMPGPSAxis) throws {
        let limit = axis == .latitude ? 90.0 : 180.0
        guard value.isFinite, abs(value) <= limit else {
            throw XMPGPSParsingError.outOfRange(value: value, axis: axis)
        }
    }

    private static func hemisphere(for value: Double, axis: XMPGPSAxis) -> String {
        switch (axis, value < 0) {
        case (.latitude, false): return "N"
        case (.latitude, true): return "S"
        case (.longitude, false): return "E"
        case (.longitude, true): return "W"
        }
    }
}

/// A parsed rational/decimal GPS scalar retaining its packet spelling.
public struct XMPGPSScalar: Sendable, Equatable {
    public let value: Double
    public let originalLexicalValue: String

    public init(value: Double, originalLexicalValue: String) {
        self.value = value
        self.originalLexicalValue = originalLexicalValue
    }
}

public struct XMPGPSMetadata: Sendable, Equatable {
    public let latitude: XMPGPSCoordinate?
    public let longitude: XMPGPSCoordinate?
    /// Signed meters; negative is below sea level.
    public let altitude: XMPGPSScalar?
    public let imageDirection: XMPGPSScalar?
    public let imageDirectionReference: XMPGPSDirectionReference?

    public init(
        latitude: XMPGPSCoordinate?,
        longitude: XMPGPSCoordinate?,
        altitude: XMPGPSScalar?,
        imageDirection: XMPGPSScalar?,
        imageDirectionReference: XMPGPSDirectionReference?
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.imageDirection = imageDirection
        self.imageDirectionReference = imageDirectionReference
    }
}

public extension XMPData {
    func gpsLatitudeCoordinate(reference: String? = nil) throws -> XMPGPSCoordinate? {
        guard let value = simpleValue(namespace: XMPNamespace.exif, property: "GPSLatitude") else { return nil }
        return try XMPGPSCoordinate(parsing: value, axis: .latitude, reference: reference)
    }

    func gpsLongitudeCoordinate(reference: String? = nil) throws -> XMPGPSCoordinate? {
        guard let value = simpleValue(namespace: XMPNamespace.exif, property: "GPSLongitude") else { return nil }
        return try XMPGPSCoordinate(parsing: value, axis: .longitude, reference: reference)
    }

    func gpsAltitudeValue() throws -> XMPGPSScalar? {
        guard let lexical = simpleValue(namespace: XMPNamespace.exif, property: "GPSAltitude") else {
            return nil
        }
        guard var value = Self.parseGPSNumber(lexical) else {
            throw XMPGPSParsingError.malformedValue(lexical)
        }
        if let reference = simpleValue(namespace: XMPNamespace.exif, property: "GPSAltitudeRef") {
            guard reference == "0" || reference == "1" else {
                throw XMPGPSParsingError.invalidAltitudeReference(reference)
            }
            if value < 0 && reference == "0" {
                throw XMPGPSParsingError.contradictorySignAndHemisphere(lexical)
            }
            if reference == "1" { value = -abs(value) }
        }
        return XMPGPSScalar(value: value, originalLexicalValue: lexical)
    }

    func gpsImageDirectionValue() throws -> XMPGPSScalar? {
        guard let lexical = simpleValue(namespace: XMPNamespace.exif, property: "GPSImgDirection") else {
            return nil
        }
        guard let value = Self.parseGPSNumber(lexical) else {
            throw XMPGPSParsingError.malformedValue(lexical)
        }
        guard value >= 0, value < 360 else {
            throw XMPGPSParsingError.directionOutOfRange(value)
        }
        return XMPGPSScalar(value: value, originalLexicalValue: lexical)
    }

    func gpsImageDirectionReferenceValue() throws -> XMPGPSDirectionReference? {
        guard let reference = simpleValue(namespace: XMPNamespace.exif, property: "GPSImgDirectionRef") else {
            return nil
        }
        guard let parsed = XMPGPSDirectionReference(rawValue: reference.uppercased()) else {
            throw XMPGPSParsingError.invalidDirectionReference(reference)
        }
        return parsed
    }

    func parsedGPS() throws -> XMPGPSMetadata {
        return XMPGPSMetadata(
            latitude: try gpsLatitudeCoordinate(),
            longitude: try gpsLongitudeCoordinate(),
            altitude: try gpsAltitudeValue(),
            imageDirection: try gpsImageDirectionValue(),
            imageDirectionReference: try gpsImageDirectionReferenceValue()
        )
    }

    mutating func setGPSLatitude(_ decimalDegrees: Double, fractionalMinuteDigits: Int = 6) throws {
        let coordinate = try XMPGPSCoordinate(decimalDegrees: decimalDegrees, axis: .latitude)
        setValue(.simple(coordinate.xmpString(fractionalMinuteDigits: fractionalMinuteDigits)),
                 namespace: XMPNamespace.exif, property: "GPSLatitude")
    }

    mutating func setGPSLongitude(_ decimalDegrees: Double, fractionalMinuteDigits: Int = 6) throws {
        let coordinate = try XMPGPSCoordinate(decimalDegrees: decimalDegrees, axis: .longitude)
        setValue(.simple(coordinate.xmpString(fractionalMinuteDigits: fractionalMinuteDigits)),
                 namespace: XMPNamespace.exif, property: "GPSLongitude")
    }

    mutating func setGPSAltitude(_ meters: Double, fractionalDigits: Int = 3) throws {
        guard meters.isFinite else { throw XMPGPSParsingError.malformedValue(String(meters)) }
        let rational = Self.gpsRational(abs(meters), fractionalDigits: fractionalDigits)
        setValue(.simple(rational), namespace: XMPNamespace.exif, property: "GPSAltitude")
        setValue(.simple(meters < 0 ? "1" : "0"), namespace: XMPNamespace.exif, property: "GPSAltitudeRef")
    }

    mutating func setGPSImageDirection(
        _ degrees: Double,
        reference: XMPGPSDirectionReference = .trueNorth,
        fractionalDigits: Int = 3
    ) throws {
        guard degrees.isFinite, degrees >= 0, degrees < 360 else {
            throw XMPGPSParsingError.directionOutOfRange(degrees)
        }
        setValue(.simple(Self.gpsRational(degrees, fractionalDigits: fractionalDigits)),
                 namespace: XMPNamespace.exif, property: "GPSImgDirection")
        setValue(.simple(reference.rawValue), namespace: XMPNamespace.exif, property: "GPSImgDirectionRef")
    }

    private static func parseGPSNumber(_ value: String) -> Double? {
        let pieces = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        if pieces.count == 1 { return Double(pieces[0]) }
        guard pieces.count == 2, let numerator = Double(pieces[0]),
              let denominator = Double(pieces[1]), denominator != 0 else { return nil }
        return numerator / denominator
    }

    private static func gpsRational(_ value: Double, fractionalDigits: Int) -> String {
        let digits = min(max(fractionalDigits, 0), 9)
        let denominator = Int64(pow(10.0, Double(digits)))
        let numerator = Int64((value * Double(denominator)).rounded())
        let divisor = greatestCommonDivisor(abs(numerator), denominator)
        return "\(numerator / divisor)/\(denominator / divisor)"
    }

    private static func greatestCommonDivisor(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        var a = lhs
        var b = rhs
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }
}
