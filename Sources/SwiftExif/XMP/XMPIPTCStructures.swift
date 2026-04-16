import Foundation

// MARK: - IPTC Creator Contact Info

/// IPTC Creator Contact Information structure (Iptc4xmpCore:CreatorContactInfo).
/// Contains contact details for the creator of the image.
public struct IPTCCreatorContactInfo: Equatable, Sendable {
    /// City of the creator's address.
    public var city: String?
    /// Country of the creator's address.
    public var country: String?
    /// Street address (may include multiple lines).
    public var address: String?
    /// Postal code.
    public var postalCode: String?
    /// State or province.
    public var region: String?
    /// Work email address.
    public var emailWork: String?
    /// Work phone number.
    public var phoneWork: String?
    /// Work URL.
    public var webUrl: String?

    public init(
        city: String? = nil, country: String? = nil, address: String? = nil,
        postalCode: String? = nil, region: String? = nil,
        emailWork: String? = nil, phoneWork: String? = nil, webUrl: String? = nil
    ) {
        self.city = city
        self.country = country
        self.address = address
        self.postalCode = postalCode
        self.region = region
        self.emailWork = emailWork
        self.phoneWork = phoneWork
        self.webUrl = webUrl
    }

    /// Initialize from raw XMP structure fields (namespace-qualified keys).
    public init(fields: [String: String]) {
        let ns = XMPNamespace.iptcCore
        self.city = fields[ns + "CiAdrCity"]
        self.country = fields[ns + "CiAdrCtry"]
        self.address = fields[ns + "CiAdrExtadr"]
        self.postalCode = fields[ns + "CiAdrPcode"]
        self.region = fields[ns + "CiAdrRegion"]
        self.emailWork = fields[ns + "CiEmailWork"]
        self.phoneWork = fields[ns + "CiTelWork"]
        self.webUrl = fields[ns + "CiUrlWork"]
    }

    /// Convert to raw XMP structure fields with namespace-qualified keys.
    public func toFields() -> [String: String] {
        let ns = XMPNamespace.iptcCore
        var fields: [String: String] = [:]
        if let v = city { fields[ns + "CiAdrCity"] = v }
        if let v = country { fields[ns + "CiAdrCtry"] = v }
        if let v = address { fields[ns + "CiAdrExtadr"] = v }
        if let v = postalCode { fields[ns + "CiAdrPcode"] = v }
        if let v = region { fields[ns + "CiAdrRegion"] = v }
        if let v = emailWork { fields[ns + "CiEmailWork"] = v }
        if let v = phoneWork { fields[ns + "CiTelWork"] = v }
        if let v = webUrl { fields[ns + "CiUrlWork"] = v }
        return fields
    }
}

// MARK: - IPTC Location

/// IPTC Location structure used for LocationCreated and LocationShown (Iptc4xmpExt).
public struct IPTCLocation: Equatable, Sendable {
    public var city: String?
    public var countryCode: String?
    public var countryName: String?
    public var provinceState: String?
    public var sublocation: String?
    public var worldRegion: String?

    public init(
        city: String? = nil, countryCode: String? = nil, countryName: String? = nil,
        provinceState: String? = nil, sublocation: String? = nil, worldRegion: String? = nil
    ) {
        self.city = city
        self.countryCode = countryCode
        self.countryName = countryName
        self.provinceState = provinceState
        self.sublocation = sublocation
        self.worldRegion = worldRegion
    }

    /// Initialize from raw XMP structure fields (namespace-qualified keys).
    public init(fields: [String: String]) {
        let ns = XMPNamespace.iptcExt
        self.city = fields[ns + "City"]
        self.countryCode = fields[ns + "CountryCode"]
        self.countryName = fields[ns + "CountryName"]
        self.provinceState = fields[ns + "ProvinceState"]
        self.sublocation = fields[ns + "Sublocation"]
        self.worldRegion = fields[ns + "WorldRegion"]
    }

    /// Convert to raw XMP structure fields with namespace-qualified keys.
    public func toFields() -> [String: String] {
        let ns = XMPNamespace.iptcExt
        var fields: [String: String] = [:]
        if let v = city { fields[ns + "City"] = v }
        if let v = countryCode { fields[ns + "CountryCode"] = v }
        if let v = countryName { fields[ns + "CountryName"] = v }
        if let v = provinceState { fields[ns + "ProvinceState"] = v }
        if let v = sublocation { fields[ns + "Sublocation"] = v }
        if let v = worldRegion { fields[ns + "WorldRegion"] = v }
        return fields
    }
}

// MARK: - IPTC Registry Entry

/// IPTC Registry Entry structure (Iptc4xmpExt:RegistryId).
public struct IPTCRegistryEntry: Equatable, Sendable {
    /// The identifier assigned by the registry.
    public var regItemId: String?
    /// The identifier of the registry (organization).
    public var regOrgId: String?

    public init(regItemId: String? = nil, regOrgId: String? = nil) {
        self.regItemId = regItemId
        self.regOrgId = regOrgId
    }

    /// Initialize from raw XMP structure fields (namespace-qualified keys).
    public init(fields: [String: String]) {
        let ns = XMPNamespace.iptcExt
        self.regItemId = fields[ns + "RegItemId"]
        self.regOrgId = fields[ns + "RegOrgId"]
    }

    /// Convert to raw XMP structure fields with namespace-qualified keys.
    public func toFields() -> [String: String] {
        let ns = XMPNamespace.iptcExt
        var fields: [String: String] = [:]
        if let v = regItemId { fields[ns + "RegItemId"] = v }
        if let v = regOrgId { fields[ns + "RegOrgId"] = v }
        return fields
    }
}

// MARK: - IPTC Artwork or Object

/// IPTC Artwork or Object structure (Iptc4xmpExt:ArtworkOrObject).
public struct IPTCArtworkOrObject: Equatable, Sendable {
    /// Title of the artwork or object.
    public var title: String?
    /// Creator of the artwork or object.
    public var creator: String?
    /// Date the artwork or object was created.
    public var dateCreated: String?
    /// Source of the artwork or object.
    public var source: String?
    /// Source inventory number.
    public var sourceInventoryNo: String?
    /// Copyright notice for the artwork or object.
    public var copyrightNotice: String?

    public init(
        title: String? = nil, creator: String? = nil, dateCreated: String? = nil,
        source: String? = nil, sourceInventoryNo: String? = nil, copyrightNotice: String? = nil
    ) {
        self.title = title
        self.creator = creator
        self.dateCreated = dateCreated
        self.source = source
        self.sourceInventoryNo = sourceInventoryNo
        self.copyrightNotice = copyrightNotice
    }

    /// Initialize from raw XMP structure fields (namespace-qualified keys).
    public init(fields: [String: String]) {
        let ns = XMPNamespace.iptcExt
        self.title = fields[ns + "AOTitle"]
        self.creator = fields[ns + "AOCreator"]
        self.dateCreated = fields[ns + "AODateCreated"]
        self.source = fields[ns + "AOSource"]
        self.sourceInventoryNo = fields[ns + "AOSourceInvNo"]
        self.copyrightNotice = fields[ns + "AOCopyrightNotice"]
    }

    /// Convert to raw XMP structure fields with namespace-qualified keys.
    public func toFields() -> [String: String] {
        let ns = XMPNamespace.iptcExt
        var fields: [String: String] = [:]
        if let v = title { fields[ns + "AOTitle"] = v }
        if let v = creator { fields[ns + "AOCreator"] = v }
        if let v = dateCreated { fields[ns + "AODateCreated"] = v }
        if let v = source { fields[ns + "AOSource"] = v }
        if let v = sourceInventoryNo { fields[ns + "AOSourceInvNo"] = v }
        if let v = copyrightNotice { fields[ns + "AOCopyrightNotice"] = v }
        return fields
    }
}
