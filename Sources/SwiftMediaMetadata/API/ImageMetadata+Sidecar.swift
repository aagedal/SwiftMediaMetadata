import Foundation

extension ImageMetadata {
    // MARK: - IPTC ↔ XMP Sync

    /// Synchronize IPTC values to XMP (one-way: IPTC → XMP).
    public mutating func syncIPTCToXMP() {
        if xmp == nil { xmp = XMPData() }

        for (iptcTag, xmpMapping) in XMPNamespace.iimToXMP {
            if iptcTag.isRepeatable {
                let values = iptc.values(for: iptcTag)
                if !values.isEmpty {
                    xmp?.setValue(.array(values), namespace: xmpMapping.namespace, property: xmpMapping.property)
                }
            } else {
                if let value = iptc.value(for: iptcTag) {
                    // dc:title, dc:description, dc:rights use langAlternative
                    if xmpMapping.namespace == XMPNamespace.dc &&
                       (xmpMapping.property == "title" || xmpMapping.property == "description" || xmpMapping.property == "rights") {
                        xmp?.setValue(.langAlternative(value), namespace: xmpMapping.namespace, property: xmpMapping.property)
                    } else {
                        xmp?.setValue(.simple(value), namespace: xmpMapping.namespace, property: xmpMapping.property)
                    }
                }
            }
        }
    }

    /// Synchronize XMP values to IPTC (one-way: XMP → IPTC).
    /// Throws `MetadataError.encodingError` if any XMP value cannot be encoded for IPTC.
    public mutating func syncXMPToIPTC() throws {
        guard let xmp = xmp else { return }

        for (iptcTag, xmpMapping) in XMPNamespace.iimToXMP {
            if iptcTag.isRepeatable {
                let values = xmp.arrayValue(namespace: xmpMapping.namespace, property: xmpMapping.property)
                if !values.isEmpty {
                    try iptc.setValues(values, for: iptcTag)
                }
            } else {
                if let value = xmp.simpleValue(namespace: xmpMapping.namespace, property: xmpMapping.property) {
                    try iptc.setValue(value, for: iptcTag)
                }
            }
        }
    }

    // MARK: - XMP Sidecar

    /// Read XMP metadata from a sidecar file alongside the given image URL.
    public static func readSidecar(for imageURL: URL) throws -> XMPData {
        let sidecarURL = XMPSidecar.sidecarURL(for: imageURL)
        return try XMPSidecar.read(from: sidecarURL)
    }

    /// Write current XMP metadata as a sidecar file.
    public func writeSidecar(to url: URL, options: WriteOptions = .default) throws {
        _ = try writeSidecarResult(to: url, options: options)
    }

    /// Write current XMP metadata and return the common write outcome.
    public func writeSidecarResult(
        to url: URL,
        options: WriteOptions = .default
    ) throws -> MetadataWriteResult<URL> {
        guard let xmp = xmp else {
            throw MetadataError.writeNotSupported("No XMP data to write as sidecar")
        }
        return try XMPSidecar.writeResult(xmp, to: url, options: options)
    }

    /// Write current XMP metadata as a sidecar file alongside the given image URL.
    public func writeSidecar(for imageURL: URL, options: WriteOptions = .default) throws {
        _ = try writeSidecarResult(for: imageURL, options: options)
    }

    /// Write alongside an image and return the common write outcome.
    public func writeSidecarResult(
        for imageURL: URL,
        options: WriteOptions = .default
    ) throws -> MetadataWriteResult<URL> {
        let sidecarURL = XMPSidecar.sidecarURL(for: imageURL)
        return try writeSidecarResult(to: sidecarURL, options: options)
    }

    // MARK: - XMP Sidecar Sync

    /// Direction for sidecar synchronization.
    public enum SyncDirection: Sendable {
        case sidecarToImage
        case imageToSidecar
    }

    /// Result of comparing sidecar vs embedded XMP.
    public struct SidecarSyncReport: Sendable {
        public let sidecarOnly: [String]
        public let embeddedOnly: [String]
        public let conflicts: [(key: String, sidecarValue: String, embeddedValue: String)]
        public let matching: Int
        public var hasDifferences: Bool { !sidecarOnly.isEmpty || !embeddedOnly.isEmpty || !conflicts.isEmpty }
    }

    /// Embed XMP from a sidecar file into this image's embedded XMP.
    /// Sidecar values overwrite embedded values on conflict.
    public mutating func embedSidecar(from sidecarURL: URL) throws {
        let sidecarXMP = try XMPSidecar.read(from: sidecarURL)
        if xmp == nil { xmp = XMPData() }

        for key in sidecarXMP.allKeys {
            // Parse namespace and property from the full key
            for (ns, _) in XMPNamespace.prefixes.sorted(by: { $0.key.count > $1.key.count }) {
                if key.hasPrefix(ns) {
                    let property = String(key.dropFirst(ns.count))
                    if let value = sidecarXMP.value(namespace: ns, property: property) {
                        xmp?.setValue(value, namespace: ns, property: property)
                    }
                    break
                }
            }
        }

        // Copy regions if present
        if let regions = sidecarXMP.regions {
            xmp?.regions = regions
        }
    }

    /// Compare sidecar XMP vs embedded XMP and report differences.
    public func compareSidecar(at sidecarURL: URL) throws -> SidecarSyncReport {
        let sidecarXMP = try XMPSidecar.read(from: sidecarURL)
        let embeddedXMP = xmp ?? XMPData()

        let sidecarKeys = Set(sidecarXMP.allKeys)
        let embeddedKeys = Set(embeddedXMP.allKeys)

        let sidecarOnly = sidecarKeys.subtracting(embeddedKeys).sorted()
        let embeddedOnly = embeddedKeys.subtracting(sidecarKeys).sorted()

        var conflicts: [(key: String, sidecarValue: String, embeddedValue: String)] = []
        var matching = 0

        for key in sidecarKeys.intersection(embeddedKeys).sorted() {
            let sVal = xmpValueString(sidecarXMP, key: key)
            let eVal = xmpValueString(embeddedXMP, key: key)
            if sVal == eVal {
                matching += 1
            } else {
                conflicts.append((key: key, sidecarValue: sVal, embeddedValue: eVal))
            }
        }

        return SidecarSyncReport(
            sidecarOnly: sidecarOnly,
            embeddedOnly: embeddedOnly,
            conflicts: conflicts,
            matching: matching
        )
    }

    /// Synchronize sidecar and embedded XMP in the chosen direction.
    public mutating func syncWithSidecar(
        at sidecarURL: URL,
        direction: SyncDirection,
        options: WriteOptions = .default
    ) throws {
        switch direction {
        case .sidecarToImage:
            try embedSidecar(from: sidecarURL)
        case .imageToSidecar:
            try writeSidecar(to: sidecarURL, options: options)
        }
    }

    private func xmpValueString(_ xmp: XMPData, key: String) -> String {
        for (ns, _) in XMPNamespace.prefixes.sorted(by: { $0.key.count > $1.key.count }) {
            if key.hasPrefix(ns) {
                let property = String(key.dropFirst(ns.count))
                if let value = xmp.value(namespace: ns, property: property) {
                    switch value {
                    case .simple(let s): return s
                    case .array(let arr): return arr.joined(separator: "; ")
                    case .langAlternative(let s): return s
                    case .structure(let fields):
                        return XMPData.flatten(fields).values.sorted().joined(separator: "; ")
                    case .structuredArray(let items):
                        return items.map { XMPData.flatten($0).values.sorted().joined(separator: ", ") }.joined(separator: "; ")
                    }
                }
                break
            }
        }
        return ""
    }
}
