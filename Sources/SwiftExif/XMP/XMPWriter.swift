import Foundation

/// Serialize XMPData to XMP XML.
public struct XMPWriter {

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

        // Collect used namespaces
        for key in xmpData.allKeys {
            for (ns, _) in XMPNamespace.prefixes {
                if key.hasPrefix(ns) {
                    usedNamespaces.insert(ns)
                }
            }
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
                }
            }
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

    // MARK: - Private

    private static func resolveKey(_ key: String) -> (prefix: String, localName: String)? {
        for (ns, prefix) in XMPNamespace.prefixes {
            if key.hasPrefix(ns) {
                let localName = String(key.dropFirst(ns.count))
                return (prefix, localName)
            }
        }
        return nil
    }

    private static func findValue(in xmpData: XMPData, key: String) -> XMPValue? {
        for (ns, _) in XMPNamespace.prefixes {
            if key.hasPrefix(ns) {
                let property = String(key.dropFirst(ns.count))
                return xmpData.value(namespace: ns, property: property)
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
