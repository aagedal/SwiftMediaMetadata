import Foundation

/// Parse XMP XML from an APP1 segment or raw XML data.
public struct XMPReader: Sendable {

    /// Parse XMP data from APP1 segment payload (after XMP namespace identifier).
    public static func read(from data: Data) throws -> XMPData {
        // Skip the XMP identifier prefix
        let identifierData = JPEGSegment.xmpIdentifier
        guard data.count > identifierData.count,
              data.prefix(identifierData.count) == identifierData else {
            throw MetadataError.invalidXMP("Missing XMP identifier")
        }

        let xmlData = data.suffix(from: data.startIndex + identifierData.count)
        return try readFromXML(Data(xmlData))
    }

    /// Parse XMP from raw XML data (no JPEG identifier prefix).
    /// Used for TIFF XMP tag (0x02BC), PNG iTXt, JPEG XL xml box, AVIF XMP.
    public static func readFromXML(_ data: Data) throws -> XMPData {
        guard let xmlString = String(data: data, encoding: .utf8) else {
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

    // MWG Region parsing state
    private var inRegions = false
    private var inRegionList = false
    private var inRegionItem = false
    private var regionListRegions: [XMPRegion] = []
    private var currentRegionName: String?
    private var currentRegionType: String?
    private var currentRegionArea: XMPRegionArea?
    private var currentRegionDescription: String?
    private var appliedDimW: Int?
    private var appliedDimH: Int?
    private var appliedDimUnit: String?
    private var regionList: XMPRegionList?

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

        return XMPData(xmlString: xmlString, properties: properties, regions: regionList)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        currentText = ""

        // MWG Region handling
        if namespaceURI == XMPNamespace.mwgRegions && elementName == "Regions" {
            inRegions = true
            return
        }
        if inRegions && namespaceURI == XMPNamespace.mwgRegions && elementName == "RegionList" {
            inRegionList = true
            regionListRegions = []
            return
        }
        if inRegions && namespaceURI == XMPNamespace.mwgRegions && elementName == "AppliedToDimensions" {
            // Dimensions stored as attributes: stDim:w, stDim:h, stDim:unit
            for (key, value) in attributeDict {
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let prop = String(parts[1])
                    switch prop {
                    case "w": appliedDimW = Int(value)
                    case "h": appliedDimH = Int(value)
                    case "unit": appliedDimUnit = value
                    default: break
                    }
                }
            }
            return
        }
        if inRegionList && elementName == "li" {
            inRegionItem = true
            currentRegionName = nil
            currentRegionType = nil
            currentRegionArea = nil
            currentRegionDescription = nil
            return
        }
        if inRegionItem && elementName == "Description" {
            // Region properties may be attributes on rdf:Description
            for (key, value) in attributeDict {
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let prefix = String(parts[0])
                    let prop = String(parts[1])
                    if prefix == "mwg-rs" {
                        switch prop {
                        case "Name": currentRegionName = value
                        case "Type": currentRegionType = value
                        case "Description": currentRegionDescription = value
                        default: break
                        }
                    }
                }
            }
            return
        }
        if inRegionItem && namespaceURI == XMPNamespace.mwgRegions && elementName == "Area" {
            // Area properties as stArea: attributes
            var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
            var unit = "normalized"
            for (key, value) in attributeDict {
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let prop = String(parts[1])
                    switch prop {
                    case "x": x = Double(value) ?? 0
                    case "y": y = Double(value) ?? 0
                    case "w": w = Double(value) ?? 0
                    case "h": h = Double(value) ?? 0
                    case "unit": unit = value
                    default: break
                    }
                }
            }
            currentRegionArea = XMPRegionArea(x: x, y: y, w: w, h: h, unit: unit)
            return
        }

        // Standard XMP handling (skip when inside regions)
        if inRegions { return }

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
        // MWG Region end handling
        if namespaceURI == XMPNamespace.mwgRegions && elementName == "Regions" {
            inRegions = false
            if !regionListRegions.isEmpty || appliedDimW != nil {
                regionList = XMPRegionList(
                    regions: regionListRegions,
                    appliedToDimensionsW: appliedDimW,
                    appliedToDimensionsH: appliedDimH,
                    appliedToDimensionsUnit: appliedDimUnit
                )
            }
            return
        }
        if inRegionList && namespaceURI == XMPNamespace.mwgRegions && elementName == "RegionList" {
            inRegionList = false
            return
        }
        if inRegionItem && elementName == "li" {
            if let area = currentRegionArea {
                regionListRegions.append(XMPRegion(
                    name: currentRegionName,
                    type: currentRegionType.flatMap { XMPRegionType(rawValue: $0) },
                    area: area,
                    description: currentRegionDescription
                ))
            }
            inRegionItem = false
            return
        }
        if inRegionItem {
            // Handle region properties as child elements (not just attributes)
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && namespaceURI == XMPNamespace.mwgRegions {
                switch elementName {
                case "Name": currentRegionName = trimmed
                case "Type": currentRegionType = trimmed
                case "Description": currentRegionDescription = trimmed
                default: break
                }
            }
            return
        }
        if inRegions { return }

        // Standard XMP handling
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
        case "mwg-rs": return XMPNamespace.mwgRegions
        case "stArea": return XMPNamespace.stArea
        case "stDim": return XMPNamespace.stDim
        default: return nil
        }
    }
}
