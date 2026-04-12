import Foundation

/// XMP value types.
public enum XMPValue: Equatable, Sendable {
    case simple(String)
    case array([String])              // rdf:Bag or rdf:Seq
    case langAlternative(String)      // rdf:Alt with xml:lang="x-default"
}

/// Parsed XMP metadata.
public struct XMPData: Equatable, Sendable {
    /// The raw XMP XML string (preserved for round-trip fidelity when possible).
    public var xmlString: String

    /// Parsed property values keyed by "namespace:property".
    private var properties: [String: XMPValue]

    public init(xmlString: String = "", properties: [String: XMPValue] = [:]) {
        self.xmlString = xmlString
        self.properties = properties
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
}
