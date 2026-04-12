import Foundation

/// Parse XMP XML from an APP1 segment.
public struct XMPReader {

    /// Parse XMP data from APP1 segment payload (after XMP namespace identifier).
    public static func read(from data: Data) throws -> XMPData {
        // Skip the XMP identifier prefix
        let identifierData = JPEGSegment.xmpIdentifier
        guard data.count > identifierData.count,
              data.prefix(identifierData.count) == identifierData else {
            throw MetadataError.invalidXMP("Missing XMP identifier")
        }

        let xmlData = data.suffix(from: data.startIndex + identifierData.count)

        guard let xmlString = String(data: xmlData, encoding: .utf8) else {
            throw MetadataError.invalidXMP("Failed to decode XMP as UTF-8")
        }

        let parser = XMPXMLParser(xmlString: xmlString)
        return try parser.parse()
    }
}

// MARK: - SAX Parser

private class XMPXMLParser: NSObject, XMLParserDelegate {
    let xmlString: String
    private var properties: [String: XMPValue] = [:]
    private var currentElement = ""
    private var currentNamespace = ""
    private var currentText = ""
    private var inDescription = false
    private var inBag = false
    private var inSeq = false
    private var inAlt = false
    private var currentArrayItems: [String] = []
    private var currentArrayProperty = ""
    private var currentArrayNamespace = ""
    private var parseError: Error?

    init(xmlString: String) {
        self.xmlString = xmlString
    }

    func parse() throws -> XMPData {
        guard let data = xmlString.data(using: .utf8) else {
            throw MetadataError.invalidXMP("Failed to encode XML as UTF-8")
        }

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.parse()

        if let error = parseError {
            throw error
        }

        return XMPData(xmlString: xmlString, properties: properties)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        currentText = ""

        if elementName == "Description" {
            inDescription = true
            // Some simple properties are stored as attributes on rdf:Description
            for (key, value) in attributeDict {
                if !key.hasPrefix("xmlns") && key != "about" {
                    // Try to resolve the qualified name to namespace + property
                    let parts = key.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        let prefix = String(parts[0])
                        let prop = String(parts[1])
                        if let ns = resolvePrefix(prefix) {
                            properties["\(ns)\(prop)"] = .simple(value)
                        }
                    }
                }
            }
        } else if elementName == "Bag" {
            inBag = true
            currentArrayItems = []
        } else if elementName == "Seq" {
            inSeq = true
            currentArrayItems = []
        } else if elementName == "Alt" {
            inAlt = true
            currentArrayItems = []
        } else if elementName == "li" {
            currentText = ""
        } else if inDescription && !inBag && !inSeq && !inAlt {
            // This is a property element — remember it for potential child arrays
            currentElement = elementName
            currentNamespace = namespaceURI ?? ""
            currentArrayProperty = elementName
            currentArrayNamespace = namespaceURI ?? ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Description" {
            inDescription = false
        } else if elementName == "li" {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                currentArrayItems.append(trimmed)
            }
        } else if elementName == "Bag" || elementName == "Seq" {
            if !currentArrayNamespace.isEmpty && !currentArrayProperty.isEmpty {
                properties["\(currentArrayNamespace)\(currentArrayProperty)"] = .array(currentArrayItems)
            }
            inBag = false
            inSeq = false
            currentArrayItems = []
        } else if elementName == "Alt" {
            if let first = currentArrayItems.first {
                if !currentArrayNamespace.isEmpty && !currentArrayProperty.isEmpty {
                    properties["\(currentArrayNamespace)\(currentArrayProperty)"] = .langAlternative(first)
                }
            }
            inAlt = false
            currentArrayItems = []
        } else if inDescription && !inBag && !inSeq && !inAlt {
            // Only store as simple if this key wasn't already set (by a child Bag/Seq/Alt)
            let key = "\(namespaceURI ?? "")\(elementName)"
            if properties[key] == nil {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, namespaceURI != nil {
                    properties[key] = .simple(trimmed)
                }
            }
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = MetadataError.invalidXMP(parseError.localizedDescription)
    }

    private func resolvePrefix(_ prefix: String) -> String? {
        switch prefix {
        case "dc": return XMPNamespace.dc
        case "photoshop": return XMPNamespace.photoshop
        case "Iptc4xmpCore": return XMPNamespace.iptcCore
        case "Iptc4xmpExt": return XMPNamespace.iptcExt
        case "xmp": return XMPNamespace.xmp
        case "xmpRights": return XMPNamespace.xmpRights
        default: return nil
        }
    }
}
