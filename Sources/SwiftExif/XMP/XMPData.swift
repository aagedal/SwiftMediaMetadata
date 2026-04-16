import Foundation

/// XMP value types.
public enum XMPValue: Equatable, Sendable {
    case simple(String)
    case array([String])                     // rdf:Bag or rdf:Seq
    case langAlternative(String)             // rdf:Alt with xml:lang="x-default"
    case structure([String: String])         // Single rdf:Description with fields
    case structuredArray([[String: String]]) // rdf:Bag of rdf:Description items
}

/// Parsed XMP metadata.
public struct XMPData: Equatable, Sendable {
    /// The raw XMP XML string (preserved for round-trip fidelity when possible).
    public var xmlString: String

    /// Parsed property values keyed by "namespace:property".
    private var properties: [String: XMPValue]

    /// Face/object regions (MWG Regions specification).
    public var regions: XMPRegionList?

    public init(xmlString: String = "", properties: [String: XMPValue] = [:], regions: XMPRegionList? = nil) {
        self.xmlString = xmlString
        self.properties = properties
        self.regions = regions
    }

    // MARK: - Property Access

    public func value(namespace: String, property: String) -> XMPValue? {
        properties["\(namespace)\(property)"]
    }

    public mutating func setValue(_ value: XMPValue, namespace: String, property: String) {
        properties["\(namespace)\(property)"] = value
    }

    public mutating func removeValue(namespace: String, property: String) {
        properties.removeValue(forKey: "\(namespace)\(property)")
    }

    /// Get a simple string value.
    public func simpleValue(namespace: String, property: String) -> String? {
        if case .simple(let s) = value(namespace: namespace, property: property) { return s }
        if case .langAlternative(let s) = value(namespace: namespace, property: property) { return s }
        return nil
    }

    /// Get an array value.
    public func arrayValue(namespace: String, property: String) -> [String] {
        if case .array(let arr) = value(namespace: namespace, property: property) { return arr }
        return []
    }

    /// Get a structure value (single rdf:Description with fields).
    public func structureValue(namespace: String, property: String) -> [String: String]? {
        if case .structure(let fields) = value(namespace: namespace, property: property) { return fields }
        return nil
    }

    /// Get a structured array value (rdf:Bag of rdf:Description items).
    public func structuredArrayValue(namespace: String, property: String) -> [[String: String]]? {
        if case .structuredArray(let items) = value(namespace: namespace, property: property) { return items }
        return nil
    }

    /// All property keys.
    public var allKeys: [String] { Array(properties.keys) }

    // MARK: - Convenience Properties (IPTC-mapped fields)

    public var title: String? {
        get { simpleValue(namespace: XMPNamespace.dc, property: "title") }
        set {
            if let v = newValue { setValue(.langAlternative(v), namespace: XMPNamespace.dc, property: "title") }
            else { removeValue(namespace: XMPNamespace.dc, property: "title") }
        }
    }

    public var description: String? {
        get { simpleValue(namespace: XMPNamespace.dc, property: "description") }
        set {
            if let v = newValue { setValue(.langAlternative(v), namespace: XMPNamespace.dc, property: "description") }
            else { removeValue(namespace: XMPNamespace.dc, property: "description") }
        }
    }

    public var creator: [String] {
        get { arrayValue(namespace: XMPNamespace.dc, property: "creator") }
        set { setValue(.array(newValue), namespace: XMPNamespace.dc, property: "creator") }
    }

    public var subject: [String] {
        get { arrayValue(namespace: XMPNamespace.dc, property: "subject") }
        set { setValue(.array(newValue), namespace: XMPNamespace.dc, property: "subject") }
    }

    public var rights: String? {
        get { simpleValue(namespace: XMPNamespace.dc, property: "rights") }
        set {
            if let v = newValue { setValue(.langAlternative(v), namespace: XMPNamespace.dc, property: "rights") }
            else { removeValue(namespace: XMPNamespace.dc, property: "rights") }
        }
    }

    public var headline: String? {
        get { simpleValue(namespace: XMPNamespace.photoshop, property: "Headline") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.photoshop, property: "Headline") }
            else { removeValue(namespace: XMPNamespace.photoshop, property: "Headline") }
        }
    }

    public var city: String? {
        get { simpleValue(namespace: XMPNamespace.photoshop, property: "City") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.photoshop, property: "City") }
            else { removeValue(namespace: XMPNamespace.photoshop, property: "City") }
        }
    }

    public var state: String? {
        get { simpleValue(namespace: XMPNamespace.photoshop, property: "State") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.photoshop, property: "State") }
            else { removeValue(namespace: XMPNamespace.photoshop, property: "State") }
        }
    }

    public var country: String? {
        get { simpleValue(namespace: XMPNamespace.photoshop, property: "Country") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.photoshop, property: "Country") }
            else { removeValue(namespace: XMPNamespace.photoshop, property: "Country") }
        }
    }

    public var credit: String? {
        get { simpleValue(namespace: XMPNamespace.photoshop, property: "Credit") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.photoshop, property: "Credit") }
            else { removeValue(namespace: XMPNamespace.photoshop, property: "Credit") }
        }
    }

    public var source: String? {
        get { simpleValue(namespace: XMPNamespace.photoshop, property: "Source") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.photoshop, property: "Source") }
            else { removeValue(namespace: XMPNamespace.photoshop, property: "Source") }
        }
    }

    public var jobId: String? {
        get { simpleValue(namespace: XMPNamespace.photoshop, property: "TransmissionReference") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.photoshop, property: "TransmissionReference") }
            else { removeValue(namespace: XMPNamespace.photoshop, property: "TransmissionReference") }
        }
    }

    // MARK: - IPTC Core Properties (Iptc4xmpCore)

    /// Extended description for accessibility (Iptc4xmpCore:ExtDescrAccessibility).
    public var extendedDescription: String? {
        get { simpleValue(namespace: XMPNamespace.iptcCore, property: "ExtDescrAccessibility") }
        set {
            if let v = newValue { setValue(.langAlternative(v), namespace: XMPNamespace.iptcCore, property: "ExtDescrAccessibility") }
            else { removeValue(namespace: XMPNamespace.iptcCore, property: "ExtDescrAccessibility") }
        }
    }

    /// Alt text for accessibility (Iptc4xmpCore:AltTextAccessibility).
    public var altText: String? {
        get { simpleValue(namespace: XMPNamespace.iptcCore, property: "AltTextAccessibility") }
        set {
            if let v = newValue { setValue(.langAlternative(v), namespace: XMPNamespace.iptcCore, property: "AltTextAccessibility") }
            else { removeValue(namespace: XMPNamespace.iptcCore, property: "AltTextAccessibility") }
        }
    }

    /// Intellectual genre of the content (Iptc4xmpCore:IntellectualGenre).
    public var intellectualGenre: String? {
        get { simpleValue(namespace: XMPNamespace.iptcCore, property: "IntellectualGenre") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcCore, property: "IntellectualGenre") }
            else { removeValue(namespace: XMPNamespace.iptcCore, property: "IntellectualGenre") }
        }
    }

    /// IPTC Scene codes — 6-digit codes from IPTC Scene NewsCodes (Iptc4xmpCore:Scene).
    public var scene: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcCore, property: "Scene") }
        set { setValue(.array(newValue), namespace: XMPNamespace.iptcCore, property: "Scene") }
    }

    /// IPTC Subject codes (Iptc4xmpCore:SubjectCode).
    public var subjectCode: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcCore, property: "SubjectCode") }
        set { setValue(.array(newValue), namespace: XMPNamespace.iptcCore, property: "SubjectCode") }
    }

    /// Creator contact information (Iptc4xmpCore:CreatorContactInfo) — structured type.
    public var creatorContactInfo: IPTCCreatorContactInfo? {
        get {
            guard let fields = structureValue(namespace: XMPNamespace.iptcCore, property: "CreatorContactInfo") else { return nil }
            return IPTCCreatorContactInfo(fields: fields)
        }
        set {
            if let v = newValue { setValue(.structure(v.toFields()), namespace: XMPNamespace.iptcCore, property: "CreatorContactInfo") }
            else { removeValue(namespace: XMPNamespace.iptcCore, property: "CreatorContactInfo") }
        }
    }

    // MARK: - IPTC Extension Properties (Iptc4xmpExt)

    /// Persons shown in the image (Iptc4xmpExt:PersonInImage).
    public var personInImage: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcExt, property: "PersonInImage") }
        set { setValue(.array(newValue), namespace: XMPNamespace.iptcExt, property: "PersonInImage") }
    }

    /// IPTC Digital Source Type URI (Iptc4xmpExt:DigitalSourceType).
    /// Uses IPTC controlled vocabulary URIs, e.g. "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture".
    public var digitalSourceType: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "DigitalSourceType") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "DigitalSourceType") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "DigitalSourceType") }
        }
    }

    /// Event name (Iptc4xmpExt:Event).
    public var event: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "Event") }
        set {
            if let v = newValue { setValue(.langAlternative(v), namespace: XMPNamespace.iptcExt, property: "Event") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "Event") }
        }
    }

    /// Organizations shown in image by code (Iptc4xmpExt:OrganisationInImageCode).
    public var organisationInImageCode: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcExt, property: "OrganisationInImageCode") }
        set { setValue(.array(newValue), namespace: XMPNamespace.iptcExt, property: "OrganisationInImageCode") }
    }

    /// Organizations shown in image by name (Iptc4xmpExt:OrganisationInImageName).
    public var organisationInImageName: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcExt, property: "OrganisationInImageName") }
        set { setValue(.array(newValue), namespace: XMPNamespace.iptcExt, property: "OrganisationInImageName") }
    }

    /// Maximum available image height in pixels (Iptc4xmpExt:MaxAvailHeight).
    public var maxAvailHeight: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "MaxAvailHeight") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "MaxAvailHeight") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "MaxAvailHeight") }
        }
    }

    /// Maximum available image width in pixels (Iptc4xmpExt:MaxAvailWidth).
    public var maxAvailWidth: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "MaxAvailWidth") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "MaxAvailWidth") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "MaxAvailWidth") }
        }
    }

    /// Additional information about models in the image (Iptc4xmpExt:AddlModelInfo).
    public var additionalModelInformation: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "AddlModelInfo") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "AddlModelInfo") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "AddlModelInfo") }
        }
    }

    /// Model release status URI (Iptc4xmpExt:ModelReleaseStatus).
    public var modelReleaseStatus: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "ModelReleaseStatus") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "ModelReleaseStatus") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "ModelReleaseStatus") }
        }
    }

    /// Property release status URI (Iptc4xmpExt:PropertyReleaseStatus).
    public var propertyReleaseStatus: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "PropertyReleaseStatus") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "PropertyReleaseStatus") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "PropertyReleaseStatus") }
        }
    }

    /// Model release document identifiers (Iptc4xmpExt:ModelReleaseDocument).
    public var modelReleaseDocument: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcExt, property: "ModelReleaseDocument") }
        set { setValue(.array(newValue), namespace: XMPNamespace.iptcExt, property: "ModelReleaseDocument") }
    }

    /// Property release document identifiers (Iptc4xmpExt:PropertyReleaseDocument).
    public var propertyReleaseDocument: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcExt, property: "PropertyReleaseDocument") }
        set { setValue(.array(newValue), namespace: XMPNamespace.iptcExt, property: "PropertyReleaseDocument") }
    }

    /// Globally unique identifier for the image (Iptc4xmpExt:DigitalImageGUID).
    public var digitalImageGUID: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "DigitalImageGUID") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "DigitalImageGUID") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "DigitalImageGUID") }
        }
    }

    /// Image supplier's image ID (Iptc4xmpExt:ImageSupplierImageID).
    public var imageSupplierImageID: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "ImageSupplierImageID") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "ImageSupplierImageID") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "ImageSupplierImageID") }
        }
    }

    /// Locations where the image was created (Iptc4xmpExt:LocationCreated) — structured array.
    public var locationCreated: [IPTCLocation] {
        get {
            guard let items = structuredArrayValue(namespace: XMPNamespace.iptcExt, property: "LocationCreated") else { return [] }
            return items.map { IPTCLocation(fields: $0) }
        }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.iptcExt, property: "LocationCreated") }
            else { setValue(.structuredArray(newValue.map { $0.toFields() }), namespace: XMPNamespace.iptcExt, property: "LocationCreated") }
        }
    }

    /// Locations shown in the image (Iptc4xmpExt:LocationShown) — structured array.
    public var locationShown: [IPTCLocation] {
        get {
            guard let items = structuredArrayValue(namespace: XMPNamespace.iptcExt, property: "LocationShown") else { return [] }
            return items.map { IPTCLocation(fields: $0) }
        }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.iptcExt, property: "LocationShown") }
            else { setValue(.structuredArray(newValue.map { $0.toFields() }), namespace: XMPNamespace.iptcExt, property: "LocationShown") }
        }
    }

    /// Registry entries for the image (Iptc4xmpExt:RegistryId) — structured array.
    public var registryId: [IPTCRegistryEntry] {
        get {
            guard let items = structuredArrayValue(namespace: XMPNamespace.iptcExt, property: "RegistryId") else { return [] }
            return items.map { IPTCRegistryEntry(fields: $0) }
        }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.iptcExt, property: "RegistryId") }
            else { setValue(.structuredArray(newValue.map { $0.toFields() }), namespace: XMPNamespace.iptcExt, property: "RegistryId") }
        }
    }

    /// Artwork or objects in the image (Iptc4xmpExt:ArtworkOrObject) — structured array.
    public var artworkOrObject: [IPTCArtworkOrObject] {
        get {
            guard let items = structuredArrayValue(namespace: XMPNamespace.iptcExt, property: "ArtworkOrObject") else { return [] }
            return items.map { IPTCArtworkOrObject(fields: $0) }
        }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.iptcExt, property: "ArtworkOrObject") }
            else { setValue(.structuredArray(newValue.map { $0.toFields() }), namespace: XMPNamespace.iptcExt, property: "ArtworkOrObject") }
        }
    }

    // MARK: - PLUS Properties (Picture Licensing Universal System)

    /// Minor model age disclosure URI (plus:MinorModelAgeDisclosure).
    public var minorModelAgeDisclosure: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "MinorModelAgeDisclosure") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.plus, property: "MinorModelAgeDisclosure") }
            else { removeValue(namespace: XMPNamespace.plus, property: "MinorModelAgeDisclosure") }
        }
    }

    /// PLUS model release identifiers (plus:ModelReleaseID).
    public var plusModelReleaseID: [String] {
        get { arrayValue(namespace: XMPNamespace.plus, property: "ModelReleaseID") }
        set { setValue(.array(newValue), namespace: XMPNamespace.plus, property: "ModelReleaseID") }
    }

    /// PLUS property release identifiers (plus:PropertyReleaseID).
    public var plusPropertyReleaseID: [String] {
        get { arrayValue(namespace: XMPNamespace.plus, property: "PropertyReleaseID") }
        set { setValue(.array(newValue), namespace: XMPNamespace.plus, property: "PropertyReleaseID") }
    }

    // MARK: - Rights & Usage Terms

    /// Usage terms for the image (xmpRights:UsageTerms).
    public var usageTerms: String? {
        get { simpleValue(namespace: XMPNamespace.xmpRights, property: "UsageTerms") }
        set {
            if let v = newValue { setValue(.langAlternative(v), namespace: XMPNamespace.xmpRights, property: "UsageTerms") }
            else { removeValue(namespace: XMPNamespace.xmpRights, property: "UsageTerms") }
        }
    }

    /// URL of a web page describing the license or usage terms (xmpRights:WebStatement).
    public var webStatement: String? {
        get { simpleValue(namespace: XMPNamespace.xmpRights, property: "WebStatement") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.xmpRights, property: "WebStatement") }
            else { removeValue(namespace: XMPNamespace.xmpRights, property: "WebStatement") }
        }
    }
}
