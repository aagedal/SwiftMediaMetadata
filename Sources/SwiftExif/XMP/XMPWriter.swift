import Foundation

/// Serialize XMPData to XMP XML.
public struct XMPWriter: Sendable {

    /// Serialize XMPData to APP1 segment payload (including XMP namespace identifier prefix).
    public static func write(_ xmpData: XMPData) -> Data {
        let xml = generateXML(xmpData)

        var result = Data(JPEGSegment.xmpIdentifier)
        result.append(Data(xml.utf8))
        return result
    }

    /// Generate XMP XML string from properties.
    public static func generateXML(_ xmpData: XMPData) -> String {
        var usedNamespaces: Set<String> = []

        // Collect used namespaces (including from structure field keys)
        for key in xmpData.allKeys {
            for (ns, _) in XMPNamespace.prefixes {
                if key.hasPrefix(ns) {
                    usedNamespaces.insert(ns)
                }
            }
            // Also scan structure/structuredArray field keys for additional namespaces
            if let value = findValue(in: xmpData, key: key) {
                switch value {
                case .structure(let fields):
                    for fieldKey in fields.keys {
                        for (ns, _) in XMPNamespace.prefixes {
                            if fieldKey.hasPrefix(ns) { usedNamespaces.insert(ns); break }
                        }
                    }
                case .structuredArray(let items):
                    for item in items {
                        for fieldKey in item.keys {
                            for (ns, _) in XMPNamespace.prefixes {
                                if fieldKey.hasPrefix(ns) { usedNamespaces.insert(ns); break }
                            }
                        }
                    }
                default: break
                }
            }
        }

        // Add region namespaces if needed
        if let regions = xmpData.regions, !regions.regions.isEmpty {
            usedNamespaces.insert(XMPNamespace.mwgRegions)
            usedNamespaces.insert(XMPNamespace.stArea)
            usedNamespaces.insert(XMPNamespace.stDim)
        }

        // Build namespace declarations
        var nsDeclarations = ""
        for ns in usedNamespaces.sorted() {
            if let prefix = XMPNamespace.prefixes[ns] {
                nsDeclarations += "\n   xmlns:\(prefix)=\"\(ns)\""
            }
        }

        // Build properties
        var simpleProps = ""
        var complexProps = ""

        for key in xmpData.allKeys.sorted() {
            guard let (prefix, localName) = resolveKey(key) else { continue }

            if let value = findValue(in: xmpData, key: key) {
                switch value {
                case .simple(let s):
                    simpleProps += "\n   \(prefix):\(localName)=\"\(escapeXML(s))\""

                case .array(let items):
                    complexProps += "\n  <\(prefix):\(localName)>\n   <rdf:Bag>\n"
                    for item in items {
                        complexProps += "    <rdf:li>\(escapeXML(item))</rdf:li>\n"
                    }
                    complexProps += "   </rdf:Bag>\n  </\(prefix):\(localName)>"

                case .langAlternative(let s):
                    complexProps += "\n  <\(prefix):\(localName)>\n   <rdf:Alt>\n"
                    complexProps += "    <rdf:li xml:lang=\"x-default\">\(escapeXML(s))</rdf:li>\n"
                    complexProps += "   </rdf:Alt>\n  </\(prefix):\(localName)>"

                case .structure(let fields):
                    complexProps += "\n  <\(prefix):\(localName)>"
                    complexProps += "\n   <rdf:Description"
                    for (fieldKey, fieldValue) in fields.sorted(by: { $0.key < $1.key }) {
                        if let (fieldPrefix, fieldLocal) = resolveKey(fieldKey) {
                            complexProps += " \(fieldPrefix):\(fieldLocal)=\"\(escapeXML(fieldValue))\""
                        }
                    }
                    complexProps += "/>"
                    complexProps += "\n  </\(prefix):\(localName)>"

                case .structuredArray(let items):
                    complexProps += "\n  <\(prefix):\(localName)>\n   <rdf:Bag>"
                    for item in items {
                        complexProps += "\n    <rdf:li>"
                        complexProps += "\n     <rdf:Description"
                        for (fieldKey, fieldValue) in item.sorted(by: { $0.key < $1.key }) {
                            if let (fieldPrefix, fieldLocal) = resolveKey(fieldKey) {
                                complexProps += " \(fieldPrefix):\(fieldLocal)=\"\(escapeXML(fieldValue))\""
                            }
                        }
                        complexProps += "/>"
                        complexProps += "\n    </rdf:li>"
                    }
                    complexProps += "\n   </rdf:Bag>\n  </\(prefix):\(localName)>"
                }
            }
        }

        // Add region XML if present
        if let regions = xmpData.regions, !regions.regions.isEmpty {
            complexProps += writeRegions(regions)
        }

        let hasComplexProps = !complexProps.isEmpty

        var xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="\(XMPNamespace.rdf)"\(nsDeclarations)>
        """

        if hasComplexProps {
            xml += "\n <rdf:Description rdf:about=\"\"\(simpleProps)>"
            xml += complexProps
            xml += "\n </rdf:Description>"
        } else {
            xml += "\n <rdf:Description rdf:about=\"\"\(simpleProps)/>"
        }

        xml += "\n</rdf:RDF>\n</x:xmpmeta>\n"

        // Add padding (2KB of spaces) for future in-place edits
        let padding = String(repeating: " ", count: 2048) + "\n"
        xml += padding
        xml += "<?xpacket end=\"w\"?>"

        return xml
    }

    /// Serialize MWG regions to XMP XML fragment.
    private static func writeRegions(_ regionList: XMPRegionList) -> String {
        var xml = "\n  <mwg-rs:Regions>"

        // AppliedToDimensions
        if let w = regionList.appliedToDimensionsW, let h = regionList.appliedToDimensionsH {
            let unit = regionList.appliedToDimensionsUnit ?? "pixel"
            xml += "\n   <mwg-rs:AppliedToDimensions stDim:w=\"\(w)\" stDim:h=\"\(h)\" stDim:unit=\"\(unit)\"/>"
        }

        // RegionList
        xml += "\n   <mwg-rs:RegionList>\n    <rdf:Bag>"

        for region in regionList.regions {
            xml += "\n     <rdf:li>"
            xml += "\n      <rdf:Description"
            if let name = region.name {
                xml += " mwg-rs:Name=\"\(escapeXML(name))\""
            }
            if let type = region.type {
                xml += " mwg-rs:Type=\"\(type.rawValue)\""
            }
            if let desc = region.description {
                xml += " mwg-rs:Description=\"\(escapeXML(desc))\""
            }
            xml += ">"
            let a = region.area
            xml += "\n       <mwg-rs:Area stArea:x=\"\(formatDouble(a.x))\" stArea:y=\"\(formatDouble(a.y))\""
            xml += " stArea:w=\"\(formatDouble(a.w))\" stArea:h=\"\(formatDouble(a.h))\""
            xml += " stArea:unit=\"\(a.unit)\"/>"
            xml += "\n      </rdf:Description>"
            xml += "\n     </rdf:li>"
        }

        xml += "\n    </rdf:Bag>\n   </mwg-rs:RegionList>"
        xml += "\n  </mwg-rs:Regions>"
        return xml
    }

    /// Format a double for XMP output, removing trailing zeros.
    private static func formatDouble(_ value: Double) -> String {
        let s = String(format: "%.6f", value)
        // Remove trailing zeros but keep at least one decimal place
        var trimmed = s
        while trimmed.hasSuffix("0") && !trimmed.hasSuffix(".0") {
            trimmed = String(trimmed.dropLast())
        }
        return trimmed
    }

    // MARK: - Private

    /// Sorted namespace list (longest first) to avoid prefix ambiguity.
    /// e.g. "http://ns.adobe.com/xap/1.0/rights/" must match before "http://ns.adobe.com/xap/1.0/"
    private static let sortedPrefixes: [(ns: String, prefix: String)] = {
        XMPNamespace.prefixes.sorted { $0.key.count > $1.key.count }.map { (ns: $0.key, prefix: $0.value) }
    }()

    private static func resolveKey(_ key: String) -> (prefix: String, localName: String)? {
        for entry in sortedPrefixes {
            if key.hasPrefix(entry.ns) {
                let localName = String(key.dropFirst(entry.ns.count))
                // Only match if the local name is a valid XML name (no slashes)
                guard !localName.isEmpty && !localName.contains("/") else { continue }
                return (entry.prefix, localName)
            }
        }
        return nil
    }

    private static func findValue(in xmpData: XMPData, key: String) -> XMPValue? {
        for entry in sortedPrefixes {
            if key.hasPrefix(entry.ns) {
                let property = String(key.dropFirst(entry.ns.count))
                guard !property.isEmpty && !property.contains("/") else { continue }
                return xmpData.value(namespace: entry.ns, property: property)
            }
        }
        return nil
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
