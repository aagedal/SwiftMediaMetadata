import Foundation

/// Standardized fields exposed by `PhotoMetadata` independently of their wire carrier.
public enum PhotoMetadataField: String, CaseIterable, Sendable, Hashable {
    case title, headline, description, creators, creatorJobTitle, keywords
    case instructions, dateCreated, city, sublocation, state, countryCode, country
    case transmissionReference, credit, source, rights, descriptionWriter
    case creatorContactInfo, locationCreated, locationShown, registryID
    case artworkOrObject, imageCreator, copyrightOwner, licensor, imageSupplier
    case cameraMake, cameraModel, lensModel, dateTimeOriginal
    case gpsLatitude, gpsLongitude, gpsAltitude, gpsImageDirection, gpsImageDirectionReference
}

/// Carrier-independent value used by the typed photo-metadata projection.
public enum PhotoMetadataValue: Equatable, Sendable {
    case string(String)
    case strings([String])
    case number(Double)
    case languageAlternatives([XMPLanguageAlternative])
    case structure([String: XMPValue])
    case structuredArray([[String: XMPValue]])
}

/// The physical carrier from which a projected value was read.
public enum PhotoMetadataSource: String, Sendable, Equatable {
    case xmp
    case iptcIIM
    case exif
}

public struct PhotoMetadataCandidate: Equatable, Sendable {
    public let source: PhotoMetadataSource
    public let value: PhotoMetadataValue

    public init(source: PhotoMetadataSource, value: PhotoMetadataValue) {
        self.source = source
        self.value = value
    }
}

/// One resolved field, retaining all carrier candidates and disagreement state.
public struct ResolvedPhotoMetadataField: Equatable, Sendable {
    public let value: PhotoMetadataValue
    public let source: PhotoMetadataSource
    public let candidates: [PhotoMetadataCandidate]

    public init(preferred: PhotoMetadataCandidate, candidates: [PhotoMetadataCandidate]) {
        self.value = preferred.value
        self.source = preferred.source
        self.candidates = candidates
    }

    public var hasConflict: Bool {
        guard let first = candidates.first?.value else { return false }
        return candidates.dropFirst().contains { !first.semanticallyEquals($0.value) }
    }
}

/// XMP-preferred, IIM-fallback projection of standardized photo metadata.
///
/// `rawXMP` preserves the complete XMP graph for clients that also carry app-private
/// or future fields. Structured projected values remain recursive `XMPValue` objects.
public struct PhotoMetadata: Equatable, Sendable {
    public let fields: [PhotoMetadataField: ResolvedPhotoMetadataField]
    public let rawXMP: XMPData?

    public init(_ metadata: ImageMetadata) {
        self.rawXMP = metadata.xmp
        self.fields = Self.project(metadata)
    }

    public subscript(_ field: PhotoMetadataField) -> ResolvedPhotoMetadataField? {
        fields[field]
    }

    public func string(_ field: PhotoMetadataField) -> String? {
        fields[field]?.value.preferredString
    }

    public func strings(_ field: PhotoMetadataField) -> [String]? {
        switch fields[field]?.value {
        case .strings(let values): return values
        case .string(let value): return [value]
        default: return nil
        }
    }

    public func number(_ field: PhotoMetadataField) -> Double? {
        if case .number(let value) = fields[field]?.value { return value }
        return nil
    }

    public var conflicts: [PhotoMetadataField: ResolvedPhotoMetadataField] {
        fields.filter { $0.value.hasConflict }
    }
}

/// Explicit canonical edits to apply to an `ImageMetadata` value.
public struct PhotoMetadataMutation: Equatable, Sendable {
    public var values: [PhotoMetadataField: PhotoMetadataValue]
    public var clearedFields: Set<PhotoMetadataField>

    public init(
        values: [PhotoMetadataField: PhotoMetadataValue] = [:],
        clearedFields: Set<PhotoMetadataField> = []
    ) {
        self.values = values
        self.clearedFields = clearedFields
    }
}

public struct PhotoMetadataMutationReport: Equatable, Sendable {
    public let synchronization: IPTCXMPSynchronizationReport
    public let unappliedFields: [PhotoMetadataField]

    public init(
        synchronization: IPTCXMPSynchronizationReport,
        unappliedFields: [PhotoMetadataField]
    ) {
        self.synchronization = synchronization
        self.unappliedFields = unappliedFields
    }
}

public extension ImageMetadata {
    /// Build an XMP-preferred, IIM-fallback standardized projection.
    var photoMetadata: PhotoMetadata { PhotoMetadata(self) }

    /// Apply canonical photo-metadata edits, mirror the IIM fields through the
    /// standards-aware synchronizer, and report read-only fields that were not applied.
    @discardableResult
    mutating func applyPhotoMetadataMutation(
        _ mutation: PhotoMetadataMutation
    ) throws -> PhotoMetadataMutationReport {
        var clearedTags: Set<IPTCTag> = []
        var unapplied: [PhotoMetadataField] = []

        for field in mutation.clearedFields.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let tag = Self.iimTag(for: field) {
                iptc.removeAll(for: tag)
                if tag == .dateCreated { iptc.removeAll(for: .timeCreated) }
                clearedTags.insert(tag)
            } else if Self.clearXMPField(field, in: &self) {
                continue
            } else {
                unapplied.append(field)
            }
        }

        for (field, value) in mutation.values.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if field == .title {
                if xmp == nil { xmp = XMPData() }
                xmp?.setValue(value.xmpValueForText, namespace: XMPNamespace.dc, property: "title")
                continue
            }
            if field == .dateCreated, let lexical = value.preferredString {
                let parts = Self.iimDateTime(fromISO8601: lexical)
                if let date = parts.date { try iptc.setValue(date, for: .dateCreated) }
                if let time = parts.time { try iptc.setValue(time, for: .timeCreated) }
                if xmp == nil { xmp = XMPData() }
                xmp?.setValue(.simple(lexical), namespace: XMPNamespace.photoshop, property: "DateCreated")
                continue
            }
            if let tag = Self.iimTag(for: field) {
                switch value {
                case .strings(let values) where tag == .byline || tag == .keywords:
                    try iptc.setValues(values, for: tag)
                default:
                    guard let string = value.preferredString else {
                        unapplied.append(field)
                        continue
                    }
                    try iptc.setValue(string, for: tag)
                }
                continue
            }
            if Self.setStructuredXMPField(field, value: value, in: &self) { continue }
            unapplied.append(field)
        }

        let synchronization = synchronizeIPTCToXMP(options: .init(
            explicitlyClearedTags: clearedTags
        ))
        return PhotoMetadataMutationReport(
            synchronization: synchronization,
            unappliedFields: unapplied.sorted { $0.rawValue < $1.rawValue }
        )
    }
}

private extension PhotoMetadata {
    static func project(_ metadata: ImageMetadata) -> [PhotoMetadataField: ResolvedPhotoMetadataField] {
        var result: [PhotoMetadataField: ResolvedPhotoMetadataField] = [:]

        func add(
            _ field: PhotoMetadataField,
            xmp namespace: String,
            _ property: String,
            iim tag: IPTCTag? = nil,
            iimArray: Bool = false
        ) {
            var candidates: [PhotoMetadataCandidate] = []
            if let value = metadata.xmp?.value(namespace: namespace, property: property) {
                candidates.append(.init(source: .xmp, value: PhotoMetadataValue(value)))
            }
            if let tag {
                let values = iimArray ? metadata.iptc.values(for: tag) : metadata.iptc.value(for: tag).map { [$0] } ?? []
                if !values.isEmpty {
                    candidates.append(.init(
                        source: .iptcIIM,
                        value: iimArray ? .strings(values) : .string(values[0])
                    ))
                }
            }
            if let preferred = candidates.first {
                result[field] = ResolvedPhotoMetadataField(preferred: preferred, candidates: candidates)
            }
        }

        add(.title, xmp: XMPNamespace.dc, "title", iim: .objectName)
        add(.headline, xmp: XMPNamespace.photoshop, "Headline", iim: .headline)
        add(.description, xmp: XMPNamespace.dc, "description", iim: .captionAbstract)
        add(.creators, xmp: XMPNamespace.dc, "creator", iim: .byline, iimArray: true)
        add(.creatorJobTitle, xmp: XMPNamespace.photoshop, "AuthorsPosition", iim: .bylineTitle)
        add(.keywords, xmp: XMPNamespace.dc, "subject", iim: .keywords, iimArray: true)
        add(.instructions, xmp: XMPNamespace.photoshop, "Instructions", iim: .specialInstructions)
        add(.dateCreated, xmp: XMPNamespace.photoshop, "DateCreated")
        if let iimDate = projectedIIMDateCreated(metadata.iptc) {
            let candidate = PhotoMetadataCandidate(source: .iptcIIM, value: .string(iimDate))
            if let existing = result[.dateCreated] {
                result[.dateCreated] = ResolvedPhotoMetadataField(
                    preferred: existing.candidates[0],
                    candidates: existing.candidates + [candidate]
                )
            } else {
                result[.dateCreated] = ResolvedPhotoMetadataField(
                    preferred: candidate,
                    candidates: [candidate]
                )
            }
        }
        add(.city, xmp: XMPNamespace.photoshop, "City", iim: .city)
        add(.sublocation, xmp: XMPNamespace.iptcCore, "Location", iim: .sublocation)
        add(.state, xmp: XMPNamespace.photoshop, "State", iim: .provinceState)
        add(.countryCode, xmp: XMPNamespace.iptcCore, "CountryCode", iim: .countryPrimaryLocationCode)
        add(.country, xmp: XMPNamespace.photoshop, "Country", iim: .countryPrimaryLocationName)
        add(.transmissionReference, xmp: XMPNamespace.photoshop, "TransmissionReference", iim: .originalTransmissionReference)
        add(.credit, xmp: XMPNamespace.photoshop, "Credit", iim: .credit)
        add(.source, xmp: XMPNamespace.photoshop, "Source", iim: .source)
        add(.rights, xmp: XMPNamespace.dc, "rights", iim: .copyrightNotice)
        add(.descriptionWriter, xmp: XMPNamespace.photoshop, "CaptionWriter", iim: .writerEditor)

        add(.creatorContactInfo, xmp: XMPNamespace.iptcCore, "CreatorContactInfo")
        add(.locationCreated, xmp: XMPNamespace.iptcExt, "LocationCreated")
        add(.locationShown, xmp: XMPNamespace.iptcExt, "LocationShown")
        add(.registryID, xmp: XMPNamespace.iptcExt, "RegistryId")
        add(.artworkOrObject, xmp: XMPNamespace.iptcExt, "ArtworkOrObject")
        add(.imageCreator, xmp: XMPNamespace.iptcExt, "ImageCreator")
        add(.copyrightOwner, xmp: XMPNamespace.plus, "CopyrightOwner")
        add(.licensor, xmp: XMPNamespace.plus, "Licensor")
        add(.imageSupplier, xmp: XMPNamespace.plus, "ImageSupplier")

        addEXIF(.cameraMake, xmpNamespace: XMPNamespace.tiff, property: "Make", value: metadata.exif?.make, to: &result, xmp: metadata.xmp)
        addEXIF(.cameraModel, xmpNamespace: XMPNamespace.tiff, property: "Model", value: metadata.exif?.model, to: &result, xmp: metadata.xmp)
        addEXIF(.lensModel, xmpNamespace: XMPNamespace.aux, property: "Lens", value: metadata.exif?.lensModel, to: &result, xmp: metadata.xmp)
        addEXIF(.dateTimeOriginal, xmpNamespace: XMPNamespace.exif, property: "DateTimeOriginal", value: metadata.exif?.dateTimeOriginal, to: &result, xmp: metadata.xmp)
        addGPS(.gpsLatitude, xmpValue: try? metadata.xmp?.gpsLatitudeCoordinate()?.decimalDegrees,
               exifValue: metadata.exif?.gpsLatitude, to: &result)
        addGPS(.gpsLongitude, xmpValue: try? metadata.xmp?.gpsLongitudeCoordinate()?.decimalDegrees,
               exifValue: metadata.exif?.gpsLongitude, to: &result)
        addGPS(.gpsAltitude, xmpValue: try? metadata.xmp?.gpsAltitudeValue()?.value,
               exifValue: metadata.exif?.gpsAltitude, to: &result)
        addGPS(.gpsImageDirection, xmpValue: try? metadata.xmp?.gpsImageDirectionValue()?.value,
               exifValue: metadata.exif?.gpsImgDirection, to: &result)
        addEXIF(.gpsImageDirectionReference, xmpNamespace: XMPNamespace.exif,
                property: "GPSImgDirectionRef", value: metadata.exif?.gpsImgDirectionRef,
                to: &result, xmp: metadata.xmp)
        return result
    }

    static func projectedIIMDateCreated(_ iptc: IPTCData) -> String? {
        guard let date = iptc.value(for: .dateCreated), date.count == 8 else { return nil }
        var value = "\(date.prefix(4))-\(date.dropFirst(4).prefix(2))-\(date.suffix(2))"
        guard let time = iptc.value(for: .timeCreated), time.count >= 6 else { return value }
        value += "T\(time.prefix(2)):\(time.dropFirst(2).prefix(2)):\(time.dropFirst(4).prefix(2))"
        let suffix = time.dropFirst(6)
        if suffix.count == 5, suffix.first == "+" || suffix.first == "-" {
            value += "\(suffix.prefix(3)):\(suffix.suffix(2))"
        }
        return value
    }

    static func addEXIF(
        _ field: PhotoMetadataField,
        xmpNamespace: String,
        property: String,
        value: String?,
        to result: inout [PhotoMetadataField: ResolvedPhotoMetadataField],
        xmp: XMPData?
    ) {
        var candidates: [PhotoMetadataCandidate] = []
        if let xmpValue = xmp?.value(namespace: xmpNamespace, property: property) {
            candidates.append(.init(source: .xmp, value: PhotoMetadataValue(xmpValue)))
        }
        if let value { candidates.append(.init(source: .exif, value: .string(value))) }
        if let preferred = candidates.first {
            result[field] = .init(preferred: preferred, candidates: candidates)
        }
    }

    static func addGPS(
        _ field: PhotoMetadataField,
        xmpValue: Double?,
        exifValue: Double?,
        to result: inout [PhotoMetadataField: ResolvedPhotoMetadataField]
    ) {
        var candidates: [PhotoMetadataCandidate] = []
        if let xmpValue { candidates.append(.init(source: .xmp, value: .number(xmpValue))) }
        if let exifValue { candidates.append(.init(source: .exif, value: .number(exifValue))) }
        if let preferred = candidates.first {
            result[field] = .init(preferred: preferred, candidates: candidates)
        }
    }
}

private extension PhotoMetadataValue {
    init(_ value: XMPValue) {
        switch value {
        case .simple(let value), .langAlternative(let value): self = .string(value)
        case .languageAlternative(let values): self = .languageAlternatives(values)
        case .array(let values): self = .strings(values)
        case .structure(let fields): self = .structure(fields)
        case .structuredArray(let items): self = .structuredArray(items)
        }
    }

    var preferredString: String? {
        switch self {
        case .string(let value): return value
        case .strings(let values): return values.first
        case .number: return nil
        case .languageAlternatives(let values):
            return values.first(where: {
                $0.language.caseInsensitiveCompare("x-default") == .orderedSame
            })?.value ?? values.first?.value
        case .structure, .structuredArray: return nil
        }
    }

    var xmpValueForText: XMPValue {
        switch self {
        case .languageAlternatives(let values): return .languageAlternative(values)
        case .string(let value): return .langAlternative(value)
        case .strings(let values): return .array(values)
        case .number(let value): return .simple(String(value))
        case .structure(let fields): return .structure(fields)
        case .structuredArray(let items): return .structuredArray(items)
        }
    }

    func semanticallyEquals(_ other: PhotoMetadataValue) -> Bool {
        if self == other { return true }
        if case .number(let lhs) = self, case .number(let rhs) = other {
            return abs(lhs - rhs) <= 0.000_000_001
        }
        if let lhs = preferredString, let rhs = other.preferredString { return lhs == rhs }
        return false
    }
}

private extension ImageMetadata {
    static func iimTag(for field: PhotoMetadataField) -> IPTCTag? {
        switch field {
        case .headline: return .headline
        case .description: return .captionAbstract
        case .creators: return .byline
        case .creatorJobTitle: return .bylineTitle
        case .keywords: return .keywords
        case .instructions: return .specialInstructions
        case .dateCreated: return .dateCreated
        case .city: return .city
        case .sublocation: return .sublocation
        case .state: return .provinceState
        case .countryCode: return .countryPrimaryLocationCode
        case .country: return .countryPrimaryLocationName
        case .transmissionReference: return .originalTransmissionReference
        case .credit: return .credit
        case .source: return .source
        case .rights: return .copyrightNotice
        case .descriptionWriter: return .writerEditor
        default: return nil
        }
    }

    static func xmpLocation(for field: PhotoMetadataField) -> (String, String)? {
        switch field {
        case .title: return (XMPNamespace.dc, "title")
        case .creatorContactInfo: return (XMPNamespace.iptcCore, "CreatorContactInfo")
        case .locationCreated: return (XMPNamespace.iptcExt, "LocationCreated")
        case .locationShown: return (XMPNamespace.iptcExt, "LocationShown")
        case .registryID: return (XMPNamespace.iptcExt, "RegistryId")
        case .artworkOrObject: return (XMPNamespace.iptcExt, "ArtworkOrObject")
        case .imageCreator: return (XMPNamespace.iptcExt, "ImageCreator")
        case .copyrightOwner: return (XMPNamespace.plus, "CopyrightOwner")
        case .licensor: return (XMPNamespace.plus, "Licensor")
        case .imageSupplier: return (XMPNamespace.plus, "ImageSupplier")
        default: return nil
        }
    }

    static func clearXMPField(_ field: PhotoMetadataField, in metadata: inout ImageMetadata) -> Bool {
        guard let (namespace, property) = xmpLocation(for: field) else { return false }
        metadata.xmp?.removeValue(namespace: namespace, property: property)
        return true
    }

    static func setStructuredXMPField(
        _ field: PhotoMetadataField,
        value: PhotoMetadataValue,
        in metadata: inout ImageMetadata
    ) -> Bool {
        guard let (namespace, property) = xmpLocation(for: field), field != .title else { return false }
        let xmpValue: XMPValue
        switch value {
        case .structure(let fields): xmpValue = .structure(fields)
        case .structuredArray(let items): xmpValue = .structuredArray(items)
        default: return false
        }
        if metadata.xmp == nil { metadata.xmp = XMPData() }
        metadata.xmp?.setValue(xmpValue, namespace: namespace, property: property)
        return true
    }

    static func iimDateTime(fromISO8601 value: String) -> (date: String?, time: String?) {
        let digits = value.filter(\.isNumber)
        guard digits.count >= 8 else { return (nil, nil) }
        let date = String(digits.prefix(8))
        guard digits.count >= 14 else { return (date, nil) }
        var time = String(digits.dropFirst(8).prefix(6))
        if let offset = value.dropFirst(min(value.count, 10)).firstIndex(where: { $0 == "+" || $0 == "-" }) {
            let offsetDigits = value[offset...].filter(\.isNumber)
            if offsetDigits.count >= 4 {
                time += String(value[offset]) + String(offsetDigits.prefix(4))
            }
        }
        return (date, time)
    }
}
