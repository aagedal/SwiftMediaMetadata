import Foundation

/// An IPTC IIM tag identified by record and dataset number.
public struct IPTCTag: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let record: UInt8
    public let dataSet: UInt8

    public init(record: UInt8, dataSet: UInt8) {
        self.record = record
        self.dataSet = dataSet
    }

    /// Parse from "record:dataset" notation, e.g. "2:25".
    public init?(_ notation: String) {
        let parts = notation.split(separator: ":")
        guard parts.count == 2,
              let record = UInt8(parts[0]),
              let dataSet = UInt8(parts[1])
        else { return nil }
        self.record = record
        self.dataSet = dataSet
    }

    public var description: String {
        let meta = IPTCTag.metadata[self]
        let name = meta?.name ?? "Unknown"
        return "\(record):\(String(format: "%03d", dataSet)) \(name)"
    }

    public static func < (lhs: IPTCTag, rhs: IPTCTag) -> Bool {
        if lhs.record != rhs.record { return lhs.record < rhs.record }
        return lhs.dataSet < rhs.dataSet
    }

    // MARK: - Tag Properties

    /// Human-readable name for this tag.
    public var name: String {
        IPTCTag.metadata[self]?.name ?? "Unknown(\(record):\(dataSet))"
    }

    /// Maximum byte length for this tag's value, or nil for unlimited.
    public var maxLength: Int? {
        IPTCTag.metadata[self]?.maxLength
    }

    /// Whether multiple instances of this tag are allowed.
    public var isRepeatable: Bool {
        IPTCTag.metadata[self]?.isRepeatable ?? false
    }

    /// The data type for this tag.
    public var dataType: IPTCDataType {
        IPTCTag.metadata[self]?.dataType ?? .string
    }

    // MARK: - Record 1 Tags (Envelope)

    public static let envelopeRecordVersion = IPTCTag(record: 1, dataSet: 0)
    public static let codedCharacterSet     = IPTCTag(record: 1, dataSet: 90)

    // MARK: - Record 2 Tags (Application)

    public static let applicationRecordVersion      = IPTCTag(record: 2, dataSet: 0)
    public static let objectTypeReference            = IPTCTag(record: 2, dataSet: 3)
    public static let objectAttributeReference       = IPTCTag(record: 2, dataSet: 4)
    public static let objectName                     = IPTCTag(record: 2, dataSet: 5)
    public static let editStatus                     = IPTCTag(record: 2, dataSet: 7)
    public static let editorialUpdate                = IPTCTag(record: 2, dataSet: 8)
    public static let urgency                        = IPTCTag(record: 2, dataSet: 10)
    public static let subjectReference               = IPTCTag(record: 2, dataSet: 12)
    public static let category                       = IPTCTag(record: 2, dataSet: 15)
    public static let supplementalCategories         = IPTCTag(record: 2, dataSet: 20)
    public static let fixtureIdentifier              = IPTCTag(record: 2, dataSet: 22)
    public static let keywords                       = IPTCTag(record: 2, dataSet: 25)
    public static let contentLocationCode            = IPTCTag(record: 2, dataSet: 26)
    public static let contentLocationName            = IPTCTag(record: 2, dataSet: 27)
    public static let releaseDate                    = IPTCTag(record: 2, dataSet: 30)
    public static let releaseTime                    = IPTCTag(record: 2, dataSet: 35)
    public static let expirationDate                 = IPTCTag(record: 2, dataSet: 37)
    public static let expirationTime                 = IPTCTag(record: 2, dataSet: 38)
    public static let specialInstructions            = IPTCTag(record: 2, dataSet: 40)
    public static let actionAdvised                  = IPTCTag(record: 2, dataSet: 42)
    public static let referenceService               = IPTCTag(record: 2, dataSet: 45)
    public static let referenceDate                  = IPTCTag(record: 2, dataSet: 47)
    public static let referenceNumber                = IPTCTag(record: 2, dataSet: 50)
    public static let dateCreated                    = IPTCTag(record: 2, dataSet: 55)
    public static let timeCreated                    = IPTCTag(record: 2, dataSet: 60)
    public static let digitalCreationDate            = IPTCTag(record: 2, dataSet: 62)
    public static let digitalCreationTime            = IPTCTag(record: 2, dataSet: 63)
    public static let originatingProgram             = IPTCTag(record: 2, dataSet: 65)
    public static let programVersion                 = IPTCTag(record: 2, dataSet: 70)
    public static let objectCycle                    = IPTCTag(record: 2, dataSet: 75)
    public static let byline                         = IPTCTag(record: 2, dataSet: 80)
    public static let bylineTitle                    = IPTCTag(record: 2, dataSet: 85)
    public static let city                           = IPTCTag(record: 2, dataSet: 90)
    public static let sublocation                    = IPTCTag(record: 2, dataSet: 92)
    public static let provinceState                  = IPTCTag(record: 2, dataSet: 95)
    public static let countryPrimaryLocationCode     = IPTCTag(record: 2, dataSet: 100)
    public static let countryPrimaryLocationName     = IPTCTag(record: 2, dataSet: 101)
    public static let originalTransmissionReference  = IPTCTag(record: 2, dataSet: 103)
    public static let headline                       = IPTCTag(record: 2, dataSet: 105)
    public static let credit                         = IPTCTag(record: 2, dataSet: 110)
    public static let source                         = IPTCTag(record: 2, dataSet: 115)
    public static let copyrightNotice                = IPTCTag(record: 2, dataSet: 116)
    public static let contact                        = IPTCTag(record: 2, dataSet: 118)
    public static let captionAbstract                = IPTCTag(record: 2, dataSet: 120)
    public static let writerEditor                   = IPTCTag(record: 2, dataSet: 122)
    public static let languageIdentifier             = IPTCTag(record: 2, dataSet: 135)

    // MARK: - Tag Metadata

    struct TagMetadata {
        let name: String
        let maxLength: Int?
        let isRepeatable: Bool
        let dataType: IPTCDataType
    }

    static let metadata: [IPTCTag: TagMetadata] = [
        // Record 1
        .envelopeRecordVersion:     TagMetadata(name: "EnvelopeRecordVersion", maxLength: 2, isRepeatable: false, dataType: .int16u),
        .codedCharacterSet:         TagMetadata(name: "CodedCharacterSet", maxLength: 32, isRepeatable: false, dataType: .binary),

        // Record 2
        .applicationRecordVersion:  TagMetadata(name: "ApplicationRecordVersion", maxLength: 2, isRepeatable: false, dataType: .int16u),
        .objectTypeReference:       TagMetadata(name: "ObjectTypeReference", maxLength: 67, isRepeatable: false, dataType: .string),
        .objectAttributeReference:  TagMetadata(name: "ObjectAttributeReference", maxLength: 68, isRepeatable: true, dataType: .string),
        .objectName:                TagMetadata(name: "ObjectName", maxLength: 64, isRepeatable: false, dataType: .string),
        .editStatus:                TagMetadata(name: "EditStatus", maxLength: 64, isRepeatable: false, dataType: .string),
        .editorialUpdate:           TagMetadata(name: "EditorialUpdate", maxLength: 2, isRepeatable: false, dataType: .digits),
        .urgency:                   TagMetadata(name: "Urgency", maxLength: 1, isRepeatable: false, dataType: .digits),
        .subjectReference:          TagMetadata(name: "SubjectReference", maxLength: 236, isRepeatable: true, dataType: .string),
        .category:                  TagMetadata(name: "Category", maxLength: 3, isRepeatable: false, dataType: .string),
        .supplementalCategories:    TagMetadata(name: "SupplementalCategories", maxLength: 32, isRepeatable: true, dataType: .string),
        .fixtureIdentifier:         TagMetadata(name: "FixtureIdentifier", maxLength: 32, isRepeatable: false, dataType: .string),
        .keywords:                  TagMetadata(name: "Keywords", maxLength: 64, isRepeatable: true, dataType: .string),
        .contentLocationCode:       TagMetadata(name: "ContentLocationCode", maxLength: 3, isRepeatable: true, dataType: .string),
        .contentLocationName:       TagMetadata(name: "ContentLocationName", maxLength: 64, isRepeatable: true, dataType: .string),
        .releaseDate:               TagMetadata(name: "ReleaseDate", maxLength: 8, isRepeatable: false, dataType: .digits),
        .releaseTime:               TagMetadata(name: "ReleaseTime", maxLength: 11, isRepeatable: false, dataType: .string),
        .expirationDate:            TagMetadata(name: "ExpirationDate", maxLength: 8, isRepeatable: false, dataType: .digits),
        .expirationTime:            TagMetadata(name: "ExpirationTime", maxLength: 11, isRepeatable: false, dataType: .string),
        .specialInstructions:       TagMetadata(name: "SpecialInstructions", maxLength: 256, isRepeatable: false, dataType: .string),
        .actionAdvised:             TagMetadata(name: "ActionAdvised", maxLength: 2, isRepeatable: false, dataType: .digits),
        .referenceService:          TagMetadata(name: "ReferenceService", maxLength: 10, isRepeatable: true, dataType: .string),
        .referenceDate:             TagMetadata(name: "ReferenceDate", maxLength: 8, isRepeatable: true, dataType: .digits),
        .referenceNumber:           TagMetadata(name: "ReferenceNumber", maxLength: 8, isRepeatable: true, dataType: .digits),
        .dateCreated:               TagMetadata(name: "DateCreated", maxLength: 8, isRepeatable: false, dataType: .digits),
        .timeCreated:               TagMetadata(name: "TimeCreated", maxLength: 11, isRepeatable: false, dataType: .string),
        .digitalCreationDate:       TagMetadata(name: "DigitalCreationDate", maxLength: 8, isRepeatable: false, dataType: .digits),
        .digitalCreationTime:       TagMetadata(name: "DigitalCreationTime", maxLength: 11, isRepeatable: false, dataType: .string),
        .originatingProgram:        TagMetadata(name: "OriginatingProgram", maxLength: 32, isRepeatable: false, dataType: .string),
        .programVersion:            TagMetadata(name: "ProgramVersion", maxLength: 10, isRepeatable: false, dataType: .string),
        .objectCycle:               TagMetadata(name: "ObjectCycle", maxLength: 1, isRepeatable: false, dataType: .string),
        .byline:                    TagMetadata(name: "By-line", maxLength: 32, isRepeatable: true, dataType: .string),
        .bylineTitle:               TagMetadata(name: "By-lineTitle", maxLength: 32, isRepeatable: true, dataType: .string),
        .city:                      TagMetadata(name: "City", maxLength: 32, isRepeatable: false, dataType: .string),
        .sublocation:               TagMetadata(name: "Sub-location", maxLength: 32, isRepeatable: false, dataType: .string),
        .provinceState:             TagMetadata(name: "Province-State", maxLength: 32, isRepeatable: false, dataType: .string),
        .countryPrimaryLocationCode:TagMetadata(name: "Country-PrimaryLocationCode", maxLength: 3, isRepeatable: false, dataType: .string),
        .countryPrimaryLocationName:TagMetadata(name: "Country-PrimaryLocationName", maxLength: 64, isRepeatable: false, dataType: .string),
        .originalTransmissionReference: TagMetadata(name: "OriginalTransmissionReference", maxLength: 32, isRepeatable: false, dataType: .string),
        .headline:                  TagMetadata(name: "Headline", maxLength: 256, isRepeatable: false, dataType: .string),
        .credit:                    TagMetadata(name: "Credit", maxLength: 32, isRepeatable: false, dataType: .string),
        .source:                    TagMetadata(name: "Source", maxLength: 32, isRepeatable: false, dataType: .string),
        .copyrightNotice:           TagMetadata(name: "CopyrightNotice", maxLength: 128, isRepeatable: false, dataType: .string),
        .contact:                   TagMetadata(name: "Contact", maxLength: 128, isRepeatable: true, dataType: .string),
        .captionAbstract:           TagMetadata(name: "Caption-Abstract", maxLength: 2000, isRepeatable: false, dataType: .string),
        .writerEditor:              TagMetadata(name: "Writer-Editor", maxLength: 32, isRepeatable: true, dataType: .string),
        .languageIdentifier:        TagMetadata(name: "LanguageIdentifier", maxLength: 3, isRepeatable: false, dataType: .string),
    ]
}

public enum IPTCDataType: Sendable {
    case string    // Text string
    case digits    // Numeric characters only
    case int16u    // 2-byte unsigned integer (big-endian)
    case binary    // Raw bytes
}
