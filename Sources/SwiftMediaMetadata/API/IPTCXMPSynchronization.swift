import Foundation

/// Policies for standards-aware synchronization between legacy IPTC-IIM and XMP.
public struct IPTCXMPSynchronizationOptions: Sendable {
    /// What to do when the source carrier has no value for a mapped field.
    public enum MissingValuePolicy: Sendable, Equatable {
        /// Leave the destination carrier unchanged.
        case preserve
        /// Remove the destination value, giving synchronization replace semantics.
        case remove
    }

    /// Object Name (IIM 2:05) and `dc:title` are distinct editorial concepts in
    /// modern IPTC Photo Metadata workflows even though the legacy mapping paired them.
    public enum TitlePolicy: Sendable, Equatable {
        /// Never synthesize or replace `dc:title` from IIM Object Name.
        case preserveXMP
        /// Apply the legacy Object Name ↔ `dc:title` mapping.
        case mirrorObjectName
    }

    /// How reduced-precision IIM Date/Time Created interacts with XMP's ISO-8601 value.
    public enum DateCreatedPolicy: Sendable, Equatable {
        /// Keep an existing XMP lexical value, including fractional seconds and timezone precision.
        case preserveXMPPrecision
        /// Replace XMP with the value representable by IIM Date/Time Created.
        case mirrorIIM
    }

    public var missingValuePolicy: MissingValuePolicy
    public var titlePolicy: TitlePolicy
    public var dateCreatedPolicy: DateCreatedPolicy

    /// Tags that should be removed from the destination even when missing values
    /// are otherwise preserved. This carries explicit user clear intent.
    public var explicitlyClearedTags: Set<IPTCTag>

    public init(
        missingValuePolicy: MissingValuePolicy = .preserve,
        titlePolicy: TitlePolicy = .preserveXMP,
        dateCreatedPolicy: DateCreatedPolicy = .preserveXMPPrecision,
        explicitlyClearedTags: Set<IPTCTag> = []
    ) {
        self.missingValuePolicy = missingValuePolicy
        self.titlePolicy = titlePolicy
        self.dateCreatedPolicy = dateCreatedPolicy
        self.explicitlyClearedTags = explicitlyClearedTags
    }

    /// Merge present source values and preserve unrelated destination values.
    public static let merge = IPTCXMPSynchronizationOptions()

    /// Replace mapped destination values, removing fields absent from the source.
    public static let replace = IPTCXMPSynchronizationOptions(missingValuePolicy: .remove)
}

/// One disagreement observed before a synchronization operation chose a carrier.
public struct IPTCXMPConflict: Equatable, Sendable {
    public let iptcTag: IPTCTag
    public let xmpNamespace: String
    public let xmpProperty: String
    public let iptcValues: [String]
    public let xmpValue: XMPValue

    public init(
        iptcTag: IPTCTag,
        xmpNamespace: String,
        xmpProperty: String,
        iptcValues: [String],
        xmpValue: XMPValue
    ) {
        self.iptcTag = iptcTag
        self.xmpNamespace = xmpNamespace
        self.xmpProperty = xmpProperty
        self.iptcValues = iptcValues
        self.xmpValue = xmpValue
    }
}

/// Changes and disagreements produced by standards-aware IPTC/XMP synchronization.
public struct IPTCXMPSynchronizationReport: Equatable, Sendable {
    public let updatedProperties: [String]
    public let removedProperties: [String]
    public let conflicts: [IPTCXMPConflict]

    public init(
        updatedProperties: [String],
        removedProperties: [String],
        conflicts: [IPTCXMPConflict]
    ) {
        self.updatedProperties = updatedProperties
        self.removedProperties = removedProperties
        self.conflicts = conflicts
    }

    public var hasChanges: Bool { !updatedProperties.isEmpty || !removedProperties.isEmpty }
    public var hasConflicts: Bool { !conflicts.isEmpty }
}

public extension ImageMetadata {
    /// Synchronize IIM into XMP with explicit merge/replace/clear semantics.
    ///
    /// Unlike `syncIPTCToXMP()`, this API preserves `dc:title` by default,
    /// keeps Photoshop scalar properties scalar, can remove stale mirrored
    /// values, retains a full-precision XMP Date Created value, and reports
    /// carrier disagreements observed before applying the selected policy.
    @discardableResult
    mutating func synchronizeIPTCToXMP(
        options: IPTCXMPSynchronizationOptions = .merge
    ) -> IPTCXMPSynchronizationReport {
        var updated: [String] = []
        var removed: [String] = []
        var conflicts: [IPTCXMPConflict] = []

        for (tag, mapping) in Self.orderedIIMMappings {
            if tag == .objectName, options.titlePolicy == .preserveXMP { continue }

            let key = mapping.namespace + mapping.property
            let current = xmp?.value(namespace: mapping.namespace, property: mapping.property)
            let sourceValues = sourceValuesForSynchronization(tag)
            let desired = xmpValue(for: tag, values: sourceValues)
            let explicitClear = options.explicitlyClearedTags.contains(tag)
                || (tag == .dateCreated && options.explicitlyClearedTags.contains(.timeCreated))

            if let desired, let current, desired != current {
                conflicts.append(IPTCXMPConflict(
                    iptcTag: tag,
                    xmpNamespace: mapping.namespace,
                    xmpProperty: mapping.property,
                    iptcValues: sourceValues,
                    xmpValue: current
                ))
            }

            if explicitClear || (desired == nil && options.missingValuePolicy == .remove) {
                if current != nil {
                    xmp?.removeValue(namespace: mapping.namespace, property: mapping.property)
                    removed.append(key)
                }
                continue
            }

            guard let desired else { continue }
            if tag == .dateCreated,
               options.dateCreatedPolicy == .preserveXMPPrecision,
               current != nil {
                continue
            }
            guard current != desired else { continue }
            if xmp == nil { xmp = XMPData() }
            xmp?.setValue(desired, namespace: mapping.namespace, property: mapping.property)
            updated.append(key)
        }

        return IPTCXMPSynchronizationReport(
            updatedProperties: updated,
            removedProperties: removed,
            conflicts: conflicts
        )
    }

    /// Synchronize XMP into IIM using the same explicit policies.
    @discardableResult
    mutating func synchronizeXMPToIPTC(
        options: IPTCXMPSynchronizationOptions = .merge
    ) throws -> IPTCXMPSynchronizationReport {
        guard let xmp else {
            if options.missingValuePolicy == .remove {
                for (tag, _) in Self.orderedIIMMappings where
                    !(tag == .objectName && options.titlePolicy == .preserveXMP) {
                    iptc.removeAll(for: tag)
                    if tag == .dateCreated { iptc.removeAll(for: .timeCreated) }
                }
            }
            return IPTCXMPSynchronizationReport(updatedProperties: [], removedProperties: [], conflicts: [])
        }

        var updated: [String] = []
        var removed: [String] = []
        var conflicts: [IPTCXMPConflict] = []

        for (tag, mapping) in Self.orderedIIMMappings {
            if tag == .objectName, options.titlePolicy == .preserveXMP { continue }
            let key = mapping.namespace + mapping.property
            let source = xmp.value(namespace: mapping.namespace, property: mapping.property)
            let currentValues = sourceValuesForSynchronization(tag)
            let xmpValues = Self.stringValues(from: source)

            if let source, !currentValues.isEmpty,
               xmpValue(for: tag, values: currentValues) != source {
                conflicts.append(IPTCXMPConflict(
                    iptcTag: tag,
                    xmpNamespace: mapping.namespace,
                    xmpProperty: mapping.property,
                    iptcValues: currentValues,
                    xmpValue: source
                ))
            }

            let explicitClear = options.explicitlyClearedTags.contains(tag)
                || (tag == .dateCreated && options.explicitlyClearedTags.contains(.timeCreated))
            if explicitClear || (source == nil && options.missingValuePolicy == .remove) {
                if !currentValues.isEmpty {
                    iptc.removeAll(for: tag)
                    if tag == .dateCreated { iptc.removeAll(for: .timeCreated) }
                    removed.append(key)
                }
                continue
            }

            guard source != nil else { continue }
            if tag == .dateCreated {
                let parts = Self.iimDateTime(fromXMP: xmpValues.first)
                if let date = parts.date { try iptc.setValue(date, for: .dateCreated) }
                else { iptc.removeAll(for: .dateCreated) }
                if let time = parts.time { try iptc.setValue(time, for: .timeCreated) }
                else { iptc.removeAll(for: .timeCreated) }
            } else if Self.arrayIIMTags.contains(tag) {
                try iptc.setValues(xmpValues, for: tag)
            } else if let value = xmpValues.first {
                try iptc.setValue(value, for: tag)
            }
            updated.append(key)
        }

        return IPTCXMPSynchronizationReport(
            updatedProperties: updated,
            removedProperties: removed,
            conflicts: conflicts
        )
    }
}

private extension ImageMetadata {
    static let orderedIIMMappings = XMPNamespace.iimToXMP.sorted { $0.key < $1.key }

    /// IPTC Photo Metadata cardinality, not the permissive legacy IIM repeatability table.
    static let arrayIIMTags: Set<IPTCTag> = [.keywords, .byline]

    func sourceValuesForSynchronization(_ tag: IPTCTag) -> [String] {
        if tag == .dateCreated {
            guard let value = Self.xmpDateTime(
                iimDate: iptc.value(for: .dateCreated),
                iimTime: iptc.value(for: .timeCreated)
            ) else { return [] }
            return [value]
        }
        return Self.arrayIIMTags.contains(tag) ? iptc.values(for: tag) : iptc.value(for: tag).map { [$0] } ?? []
    }

    func xmpValue(for tag: IPTCTag, values: [String]) -> XMPValue? {
        guard !values.isEmpty else { return nil }
        if Self.arrayIIMTags.contains(tag) { return .array(values) }
        let value = values[0]
        if tag == .objectName || tag == .captionAbstract || tag == .copyrightNotice {
            return .langAlternative(value)
        }
        return .simple(value)
    }

    static func stringValues(from value: XMPValue?) -> [String] {
        switch value {
        case .simple(let value), .langAlternative(let value): return [value]
        case .languageAlternative(let values):
            return [values.first(where: {
                $0.language.caseInsensitiveCompare("x-default") == .orderedSame
            })?.value ?? values.first?.value].compactMap { $0 }
        case .array(let values): return values
        default: return []
        }
    }

    static func xmpDateTime(iimDate: String?, iimTime: String?) -> String? {
        guard let iimDate, iimDate.count == 8 else { return nil }
        let year = iimDate.prefix(4)
        let month = iimDate.dropFirst(4).prefix(2)
        let day = iimDate.dropFirst(6).prefix(2)
        var result = "\(year)-\(month)-\(day)"
        guard let iimTime, iimTime.count >= 6 else { return result }
        let hour = iimTime.prefix(2)
        let minute = iimTime.dropFirst(2).prefix(2)
        let second = iimTime.dropFirst(4).prefix(2)
        result += "T\(hour):\(minute):\(second)"
        let suffix = iimTime.dropFirst(6)
        if suffix.count == 5, suffix.first == "+" || suffix.first == "-" {
            result += "\(suffix.prefix(3)):\(suffix.suffix(2))"
        }
        return result
    }

    static func iimDateTime(fromXMP value: String?) -> (date: String?, time: String?) {
        guard let value else { return (nil, nil) }
        let digits = value.filter(\.isNumber)
        guard digits.count >= 8 else { return (nil, nil) }
        let date = String(digits.prefix(8))
        guard digits.count >= 14 else { return (date, nil) }
        var time = String(digits.dropFirst(8).prefix(6))

        if let timezoneStart = value.dropFirst(min(value.count, 10)).firstIndex(where: { $0 == "+" || $0 == "-" }) {
            let timezoneDigits = value[timezoneStart...].filter(\.isNumber)
            if timezoneDigits.count >= 4 {
                time += String(value[timezoneStart]) + String(timezoneDigits.prefix(4))
            }
        }
        return (date, time)
    }
}
