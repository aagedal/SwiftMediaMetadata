import Foundation

/// Prefix- and container-independent identity for one standardized metadata value.
public struct MetadataSemanticIdentity: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let domain: MetadataDomain
    /// A stable path inside the domain, such as `ifd0/0x010F` or an XMP
    /// `{namespaceURI}localName` expanded name.
    public let path: String

    public init(domain: MetadataDomain, path: String) {
        self.domain = domain
        self.path = path
    }

    public var description: String { "\(domain.rawValue):\(path)" }

    public static func < (lhs: MetadataSemanticIdentity, rhs: MetadataSemanticIdentity) -> Bool {
        (lhs.domain.rawValue, lhs.path) < (rhs.domain.rawValue, rhs.path)
    }
}

/// A deterministic representation used when comparing metadata semantics.
///
/// This is intentionally not a wire encoding. Numerics are normalized out of
/// TIFF byte order, XMP names use namespace URIs rather than prefixes, CBOR map
/// order is ignored, and known date/GPS spellings are canonicalized.
public struct MetadataSemanticValue: Sendable, Equatable, CustomStringConvertible {
    public let canonicalRepresentation: String

    public init(canonicalRepresentation: String) {
        self.canonicalRepresentation = canonicalRepresentation
    }

    public var description: String { canonicalRepresentation }
}

public struct MetadataSemanticEntry: Sendable, Equatable {
    public let identity: MetadataSemanticIdentity
    public let value: MetadataSemanticValue

    public init(identity: MetadataSemanticIdentity, value: MetadataSemanticValue) {
        self.identity = identity
        self.value = value
    }
}

public struct MetadataSemanticChange: Sendable, Equatable {
    public let identity: MetadataSemanticIdentity
    public let before: MetadataSemanticValue
    public let after: MetadataSemanticValue

    public init(
        identity: MetadataSemanticIdentity,
        before: MetadataSemanticValue,
        after: MetadataSemanticValue
    ) {
        self.identity = identity
        self.before = before
        self.after = after
    }
}

/// Factual differences observed after metadata crosses a carrier boundary.
/// Applications decide which differences are acceptable for their workflow.
public struct MetadataRoundTripPreservationReport: Sendable, Equatable {
    public let sourceFormat: ImageFormat
    public let destinationFormat: ImageFormat
    public let added: [MetadataSemanticEntry]
    public let removed: [MetadataSemanticEntry]
    public let changed: [MetadataSemanticChange]
    public let unrepresentable: [MetadataSemanticEntry]
    public let opaquePreserved: [MetadataSemanticEntry]

    public init(source: ImageMetadata, roundTripped destination: ImageMetadata) {
        self.sourceFormat = source.format
        self.destinationFormat = destination.format

        let before = source.semanticMetadata
        let after = destination.semanticMetadata
        let beforeKeys = Set(before.keys)
        let afterKeys = Set(after.keys)
        let destinationCapabilities = destination.metadataCapabilities

        self.added = afterKeys.subtracting(beforeKeys).sorted().map {
            MetadataSemanticEntry(identity: $0, value: after[$0]!)
        }

        var removed: [MetadataSemanticEntry] = []
        var unrepresentable: [MetadataSemanticEntry] = []
        for identity in beforeKeys.subtracting(afterKeys).sorted() {
            let entry = MetadataSemanticEntry(identity: identity, value: before[identity]!)
            let capability = destinationCapabilities[identity.domain]
            if capability.write == .unsupported && capability.preservation != .preservedOpaquely {
                unrepresentable.append(entry)
            } else {
                removed.append(entry)
            }
        }
        self.removed = removed
        self.unrepresentable = unrepresentable

        var changed: [MetadataSemanticChange] = []
        var opaquePreserved: [MetadataSemanticEntry] = []
        for identity in beforeKeys.intersection(afterKeys).sorted() {
            let old = before[identity]!
            let new = after[identity]!
            if old != new {
                changed.append(MetadataSemanticChange(identity: identity, before: old, after: new))
            } else if destinationCapabilities[identity.domain].preservation == .preservedOpaquely {
                opaquePreserved.append(MetadataSemanticEntry(identity: identity, value: new))
            }
        }
        self.changed = changed
        self.opaquePreserved = opaquePreserved
    }

    /// True when every source value remains semantically equal and no new value appeared.
    public var isSemanticallyLossless: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty && unrepresentable.isEmpty
    }
}

public extension ImageMetadata {
    /// Canonical values for every standardized domain surfaced by this value.
    var semanticMetadata: [MetadataSemanticIdentity: MetadataSemanticValue] {
        MetadataSemanticCanonicalizer.snapshot(of: self)
    }

    /// Compare this source value with metadata read after serialization or a
    /// cross-container conversion.
    func preservationReport(
        comparedTo roundTripped: ImageMetadata
    ) -> MetadataRoundTripPreservationReport {
        MetadataRoundTripPreservationReport(source: self, roundTripped: roundTripped)
    }
}

private enum MetadataSemanticCanonicalizer {
    static func snapshot(of metadata: ImageMetadata) -> [MetadataSemanticIdentity: MetadataSemanticValue] {
        var result: [MetadataSemanticIdentity: MetadataSemanticValue] = [:]
        appendExif(metadata.exif, to: &result)
        appendIPTC(metadata.iptc, to: &result)
        appendXMP(metadata.xmp, to: &result)
        if let profile = metadata.iccProfile {
            put(.icc, "profile", "sha256:\(FileHasher.sha256(profile.data))", in: &result)
        }
        appendC2PA(metadata.c2pa, to: &result)
        return result
    }

    // MARK: Exif

    private static func appendExif(
        _ exif: ExifData?,
        to result: inout [MetadataSemanticIdentity: MetadataSemanticValue]
    ) {
        guard let exif else { return }
        appendIFD(exif.ifd0, scope: "ifd0", endian: exif.byteOrder, to: &result)
        appendIFD(exif.ifd1, scope: "ifd1", endian: exif.byteOrder, to: &result)
        appendIFD(exif.exifIFD, scope: "exif", endian: exif.byteOrder, to: &result)
        appendIFD(exif.gpsIFD, scope: "gps", endian: exif.byteOrder, to: &result)
    }

    /// Pointer/offset and embedded-carrier tags describe layout, not metadata meaning.
    private static let ignoredExifTags: Set<UInt16> = [
        0x0111, 0x0117, 0x0144, 0x0145, 0x014A,
        ExifTag.exifIFDPointer, ExifTag.gpsIFDPointer, ExifTag.interopIFDPointer,
        ExifTag.xmpTag, ExifTag.iptcNAA, ExifTag.photoshopIRB, ExifTag.iccProfile,
    ]

    private static func appendIFD(
        _ ifd: IFD?,
        scope: String,
        endian: ByteOrder,
        to result: inout [MetadataSemanticIdentity: MetadataSemanticValue]
    ) {
        guard let ifd else { return }
        var occurrences: [UInt16: Int] = [:]
        for entry in ifd.entries where !ignoredExifTags.contains(entry.tag) {
            let occurrence = occurrences[entry.tag, default: 0]
            occurrences[entry.tag] = occurrence + 1
            let suffix = occurrence == 0 ? "" : "#\(occurrence)"
            let tag = String(format: "0x%04X", entry.tag)
            put(.exif, "\(scope)/\(tag)\(suffix)", canonicalExif(entry, endian: endian), in: &result)
        }
    }

    private static func canonicalExif(_ entry: IFDEntry, endian: ByteOrder) -> String {
        if entry.type == .ascii, let string = entry.stringValue(endian: endian) {
            return canonicalString(string, hint: ExifTag.name(for: entry.tag))
        }

        var reader = BinaryReader(data: entry.valueData)
        var values: [String] = []
        for _ in 0..<entry.count {
            let value: String?
            switch entry.type {
            case .byte:
                value = (try? reader.readUInt8()).map(String.init)
            case .sbyte:
                value = (try? reader.readUInt8()).map { String(Int8(bitPattern: $0)) }
            case .short:
                value = (try? reader.readUInt16(endian: endian)).map(String.init)
            case .sshort:
                value = (try? reader.readInt16(endian: endian)).map(String.init)
            case .long:
                value = (try? reader.readUInt32(endian: endian)).map(String.init)
            case .slong:
                value = (try? reader.readInt32(endian: endian)).map(String.init)
            case .rational:
                if let n = try? reader.readUInt32(endian: endian),
                   let d = try? reader.readUInt32(endian: endian) {
                    value = canonicalRatio(Double(n), Double(d))
                } else { value = nil }
            case .srational:
                if let n = try? reader.readInt32(endian: endian),
                   let d = try? reader.readInt32(endian: endian) {
                    value = canonicalRatio(Double(n), Double(d))
                } else { value = nil }
            case .float:
                value = (try? reader.readFloat32(endian: endian)).map { canonicalNumber(Double($0)) }
            case .double:
                value = (try? reader.readUInt64(endian: endian)).map {
                    canonicalNumber(Double(bitPattern: $0))
                }
            case .ascii, .undefined:
                value = nil
            }
            guard let value else {
                return canonicalBytes(entry.valueData)
            }
            values.append(value)
        }
        return "[\(values.joined(separator: ","))]"
    }

    // MARK: IPTC-IIM

    private static func appendIPTC(
        _ iptc: IPTCData,
        to result: inout [MetadataSemanticIdentity: MetadataSemanticValue]
    ) {
        let grouped = Dictionary(grouping: iptc.datasets, by: \.tag)
        for tag in grouped.keys.sorted() {
            let values = grouped[tag, default: []].map { dataset -> String in
                if let text = dataset.stringValue(encoding: iptc.encoding) {
                    return canonicalString(text, hint: tag.name)
                }
                if let number = dataset.uint32Value() { return String(number) }
                if let number = dataset.uint16Value() { return String(number) }
                return canonicalBytes(dataset.rawValue)
            }.sorted()
            let path = "\(tag.record):\(String(format: "%03d", tag.dataSet))"
            put(.iptcIIM, path, list(values), in: &result)
        }
    }

    // MARK: XMP / Camera Raw

    private static func appendXMP(
        _ xmp: XMPData?,
        to result: inout [MetadataSemanticIdentity: MetadataSemanticValue]
    ) {
        guard let xmp else { return }
        for key in xmp.allProperties.keys.sorted() {
            guard let value = xmp.allProperties[key] else { continue }
            let (namespace, localName) = splitXMPKey(key)
            let domain: MetadataDomain = namespace == XMPNamespace.crs ? .cameraRaw : .xmp
            let path = "{\(namespace)}\(localName)"
            let form = xmp.arrayForm(forQualifiedKey: key)
            put(domain, path, canonicalXMP(value, hint: localName, arrayForm: form), in: &result)
        }
    }

    private static func splitXMPKey(_ key: String) -> (String, String) {
        if let namespace = XMPNamespace.prefixes.keys
            .sorted(by: { $0.count > $1.count })
            .first(where: { key.hasPrefix($0) }) {
            return (namespace, String(key.dropFirst(namespace.count)))
        }
        if let boundary = key.lastIndex(where: { $0 == "/" || $0 == "#" }) {
            let next = key.index(after: boundary)
            return (String(key[..<next]), String(key[next...]))
        }
        return ("", key)
    }

    private static func canonicalXMP(
        _ value: XMPValue,
        hint: String,
        arrayForm: XMPArrayForm? = nil
    ) -> String {
        switch value {
        case .simple(let value), .langAlternative(let value):
            return canonicalString(value, hint: hint)
        case .array(let values):
            let canonical = values.map { canonicalString($0, hint: hint) }
            return list(arrayForm == .seq ? canonical : canonical.sorted())
        case .languageAlternative(let alternatives):
            let values = alternatives.map {
                "\($0.language.lowercased())=\(lengthPrefixed(canonicalString($0.value, hint: hint)))"
            }.sorted()
            return list(values)
        case .structure(let fields):
            return object(fields.mapValues { canonicalXMP($0, hint: hint) })
        case .structuredArray(let items):
            let values = items.map { object($0.mapValues { canonicalXMP($0, hint: hint) }) }
            return list(arrayForm == .seq ? values : values.sorted())
        }
    }

    // MARK: C2PA

    private static func appendC2PA(
        _ c2pa: C2PAData?,
        to result: inout [MetadataSemanticIdentity: MetadataSemanticValue]
    ) {
        guard let c2pa else { return }
        for (manifestIndex, manifest) in c2pa.manifests.enumerated() {
            let root = "manifest[\(manifestIndex)]/\(lengthPrefixed(manifest.label))"
            put(.c2pa, "\(root)/claim", canonicalCBOR(manifest.claim.raw), in: &result)
            put(.c2pa, "\(root)/signature", manifest.signature.signatureBytes.base64EncodedString(), in: &result)

            let references = manifest.claim.assertionReferences.sorted {
                if $0.url != $1.url { return $0.url < $1.url }
                return $0.hash.lexicographicallyPrecedes($1.hash)
            }
            for (index, reference) in references.enumerated() {
                let value = "\(reference.algorithm?.lowercased() ?? ""):\(reference.hash.base64EncodedString())"
                put(.c2pa, "\(root)/assertion[\(index)]/\(lengthPrefixed(reference.url))", value, in: &result)
            }
        }
    }

    private static func canonicalCBOR(_ value: CBORValue) -> String {
        switch value {
        case .unsignedInt(let value): return "u:\(value)"
        case .negativeInt(let value): return "i:\(value)"
        case .byteString(let data): return "b:\(data.base64EncodedString())"
        case .textString(let string): return "s:\(lengthPrefixed(string))"
        case .array(let values): return list(values.map(canonicalCBOR))
        case .map(let entries):
            let pairs = entries.map {
                "\(lengthPrefixed(canonicalCBOR($0.key)))=\(lengthPrefixed(canonicalCBOR($0.value)))"
            }.sorted()
            return "{" + pairs.joined(separator: ",") + "}"
        case .tagged(let tag, let value): return "tag:\(tag):\(canonicalCBOR(value))"
        case .boolean(let value): return value ? "true" : "false"
        case .null: return "null"
        case .undefined: return "undefined"
        case .float(let value): return "f:\(String(value.bitPattern, radix: 16))"
        case .simple(let value): return "simple:\(value)"
        }
    }

    // MARK: Scalar normalization

    private static func canonicalString(_ value: String, hint: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerHint = hint.lowercased()
        if lowerHint.contains("gpslatitude"), let number = parseCoordinate(trimmed, latitude: true) {
            return "degrees:\(canonicalNumber(number))"
        }
        if lowerHint.contains("gpslongitude"), let number = parseCoordinate(trimmed, latitude: false) {
            return "degrees:\(canonicalNumber(number))"
        }
        if lowerHint.contains("gpsaltitude") || lowerHint.contains("direction") || lowerHint.contains("bearing") {
            if let number = parseNumberOrRatio(trimmed) { return "number:\(canonicalNumber(number))" }
        }
        if lowerHint.contains("date") || lowerHint.contains("time") {
            if let date = canonicalDate(trimmed) { return "date:\(date)" }
        }
        return "text:\(lengthPrefixed(trimmed.precomposedStringWithCanonicalMapping))"
    }

    private static func canonicalDate(_ value: String) -> String? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: value)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime]
            date = iso.date(from: value)
        }
        if let date {
            iso.timeZone = TimeZone(secondsFromGMT: 0)
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.string(from: date)
        }

        let normalizedExif: String
        if value.count >= 10 {
            var characters = Array(value)
            if characters.indices.contains(4), characters[4] == ":" { characters[4] = "-" }
            if characters.indices.contains(7), characters[7] == ":" { characters[7] = "-" }
            normalizedExif = String(characters)
        } else {
            normalizedExif = value
        }
        let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyyMMdd", "HHmmssZ", "HHmmss"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: normalizedExif) {
                formatter.dateFormat = format.contains("H") ? "yyyy-MM-dd'T'HH:mm:ssXXXXX" : "yyyy-MM-dd"
                return formatter.string(from: date)
            }
        }
        return nil
    }

    private static func parseCoordinate(_ value: String, latitude: Bool) -> Double? {
        var text = value.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var hemisphere: Character?
        if let last = text.last, "NSEW".contains(last) {
            hemisphere = last
            text.removeLast()
        }
        let separators = CharacterSet(charactersIn: "°º'\"′″,; ")
        let numbers = text.components(separatedBy: separators).filter { !$0.isEmpty }.compactMap(Double.init)
        guard (1...3).contains(numbers.count) else { return nil }
        let explicitNegative = numbers[0] < 0
        var magnitude = abs(numbers[0])
        if numbers.count > 1 {
            guard numbers[1] >= 0, numbers[1] < 60 else { return nil }
            magnitude += numbers[1] / 60
        }
        if numbers.count > 2 {
            guard numbers[2] >= 0, numbers[2] < 60 else { return nil }
            magnitude += numbers[2] / 3600
        }
        let hemisphereNegative = hemisphere == "S" || hemisphere == "W"
        let number = (explicitNegative || hemisphereNegative) ? -magnitude : magnitude
        let limit = latitude ? 90.0 : 180.0
        return abs(number) <= limit ? number : nil
    }

    private static func parseNumberOrRatio(_ value: String) -> Double? {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        if pieces.count == 1 { return Double(value) }
        guard pieces.count == 2, let numerator = Double(pieces[0]),
              let denominator = Double(pieces[1]), denominator != 0 else { return nil }
        return numerator / denominator
    }

    private static func canonicalRatio(_ numerator: Double, _ denominator: Double) -> String {
        guard denominator != 0 else { return "\(canonicalNumber(numerator))/0" }
        return canonicalNumber(numerator / denominator)
    }

    private static func canonicalNumber(_ value: Double) -> String {
        if value == 0 { return "0" }
        return String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func canonicalBytes(_ data: Data) -> String {
        if data.count <= 64 { return "bytes:\(data.base64EncodedString())" }
        return "bytes:\(data.count):sha256:\(FileHasher.sha256(data))"
    }

    private static func list(_ values: [String]) -> String {
        "[" + values.map(lengthPrefixed).joined(separator: ",") + "]"
    }

    private static func object(_ values: [String: String]) -> String {
        "{" + values.keys.sorted().map {
            "\(lengthPrefixed($0))=\(lengthPrefixed(values[$0]!))"
        }.joined(separator: ",") + "}"
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    private static func put(
        _ domain: MetadataDomain,
        _ path: String,
        _ value: String,
        in result: inout [MetadataSemanticIdentity: MetadataSemanticValue]
    ) {
        result[MetadataSemanticIdentity(domain: domain, path: path)] =
            MetadataSemanticValue(canonicalRepresentation: value)
    }
}
