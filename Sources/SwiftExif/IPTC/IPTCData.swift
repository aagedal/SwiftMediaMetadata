import Foundation

/// A collection of IPTC datasets representing all IPTC metadata in a file.
public struct IPTCData: Equatable, Sendable {
    public private(set) var datasets: [IPTCDataSet]

    /// The detected encoding from Record 1:90 CodedCharacterSet.
    /// Defaults to .utf8 for new data.
    public var encoding: String.Encoding

    public init(datasets: [IPTCDataSet] = [], encoding: String.Encoding = .utf8) {
        self.datasets = datasets
        self.encoding = encoding
    }

    public var isUTF8: Bool { encoding == .utf8 }

    // MARK: - Single-Value Access

    /// Get the first value for a tag as a string.
    public func value(for tag: IPTCTag) -> String? {
        datasets.first { $0.tag == tag }?.stringValue(encoding: encoding)
    }

    /// Get the raw data for a tag.
    public func rawValue(for tag: IPTCTag) -> Data? {
        datasets.first { $0.tag == tag }?.rawValue
    }

    // MARK: - Multi-Value Access

    /// Get all values for a tag (for repeatable fields like keywords).
    public func values(for tag: IPTCTag) -> [String] {
        datasets.filter { $0.tag == tag }.compactMap { $0.stringValue(encoding: encoding) }
    }

    /// Get all datasets for a specific tag.
    public func dataSets(for tag: IPTCTag) -> [IPTCDataSet] {
        datasets.filter { $0.tag == tag }
    }

    // MARK: - Mutation

    /// Set a single value for a tag (replaces all existing instances).
    public mutating func setValue(_ value: String, for tag: IPTCTag) {
        removeAll(for: tag)
        datasets.append(IPTCDataSet(tag: tag, stringValue: value, encoding: encoding))
    }

    /// Set multiple values for a repeatable tag (replaces all existing instances).
    public mutating func setValues(_ values: [String], for tag: IPTCTag) {
        removeAll(for: tag)
        for value in values {
            datasets.append(IPTCDataSet(tag: tag, stringValue: value, encoding: encoding))
        }
    }

    /// Add a value for a repeatable tag (appends, does not replace).
    public mutating func addValue(_ value: String, for tag: IPTCTag) {
        datasets.append(IPTCDataSet(tag: tag, stringValue: value, encoding: encoding))
    }

    /// Remove all datasets for a specific tag.
    public mutating func removeAll(for tag: IPTCTag) {
        datasets.removeAll { $0.tag == tag }
    }

    // MARK: - Convenience Properties (Journalism Fields)

    public var headline: String? {
        get { value(for: .headline) }
        set {
            if let v = newValue { setValue(v, for: .headline) }
            else { removeAll(for: .headline) }
        }
    }

    public var caption: String? {
        get { value(for: .captionAbstract) }
        set {
            if let v = newValue { setValue(v, for: .captionAbstract) }
            else { removeAll(for: .captionAbstract) }
        }
    }

    public var byline: String? {
        get { value(for: .byline) }
        set {
            if let v = newValue { setValue(v, for: .byline) }
            else { removeAll(for: .byline) }
        }
    }

    public var bylines: [String] {
        get { values(for: .byline) }
        set { setValues(newValue, for: .byline) }
    }

    public var keywords: [String] {
        get { values(for: .keywords) }
        set { setValues(newValue, for: .keywords) }
    }

    public var city: String? {
        get { value(for: .city) }
        set {
            if let v = newValue { setValue(v, for: .city) }
            else { removeAll(for: .city) }
        }
    }

    public var sublocation: String? {
        get { value(for: .sublocation) }
        set {
            if let v = newValue { setValue(v, for: .sublocation) }
            else { removeAll(for: .sublocation) }
        }
    }

    public var provinceState: String? {
        get { value(for: .provinceState) }
        set {
            if let v = newValue { setValue(v, for: .provinceState) }
            else { removeAll(for: .provinceState) }
        }
    }

    public var countryCode: String? {
        get { value(for: .countryPrimaryLocationCode) }
        set {
            if let v = newValue { setValue(v, for: .countryPrimaryLocationCode) }
            else { removeAll(for: .countryPrimaryLocationCode) }
        }
    }

    public var countryName: String? {
        get { value(for: .countryPrimaryLocationName) }
        set {
            if let v = newValue { setValue(v, for: .countryPrimaryLocationName) }
            else { removeAll(for: .countryPrimaryLocationName) }
        }
    }

    public var credit: String? {
        get { value(for: .credit) }
        set {
            if let v = newValue { setValue(v, for: .credit) }
            else { removeAll(for: .credit) }
        }
    }

    public var source: String? {
        get { value(for: .source) }
        set {
            if let v = newValue { setValue(v, for: .source) }
            else { removeAll(for: .source) }
        }
    }

    public var copyright: String? {
        get { value(for: .copyrightNotice) }
        set {
            if let v = newValue { setValue(v, for: .copyrightNotice) }
            else { removeAll(for: .copyrightNotice) }
        }
    }

    public var dateCreated: String? {
        get { value(for: .dateCreated) }
        set {
            if let v = newValue { setValue(v, for: .dateCreated) }
            else { removeAll(for: .dateCreated) }
        }
    }

    public var timeCreated: String? {
        get { value(for: .timeCreated) }
        set {
            if let v = newValue { setValue(v, for: .timeCreated) }
            else { removeAll(for: .timeCreated) }
        }
    }

    public var specialInstructions: String? {
        get { value(for: .specialInstructions) }
        set {
            if let v = newValue { setValue(v, for: .specialInstructions) }
            else { removeAll(for: .specialInstructions) }
        }
    }

    public var objectName: String? {
        get { value(for: .objectName) }
        set {
            if let v = newValue { setValue(v, for: .objectName) }
            else { removeAll(for: .objectName) }
        }
    }

    public var writerEditor: String? {
        get { value(for: .writerEditor) }
        set {
            if let v = newValue { setValue(v, for: .writerEditor) }
            else { removeAll(for: .writerEditor) }
        }
    }

    public var originatingProgram: String? {
        get { value(for: .originatingProgram) }
        set {
            if let v = newValue { setValue(v, for: .originatingProgram) }
            else { removeAll(for: .originatingProgram) }
        }
    }

    public var programVersion: String? {
        get { value(for: .programVersion) }
        set {
            if let v = newValue { setValue(v, for: .programVersion) }
            else { removeAll(for: .programVersion) }
        }
    }
}
