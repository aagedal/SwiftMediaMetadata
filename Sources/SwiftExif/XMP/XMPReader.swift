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

    // Structure parsing state
    private var inStructuredItem = false
    private var currentStructureFields: [String: String] = [:]
    private var currentStructuredArrayItems: [[String: String]] = []
    private var isStructuredBag = false
    private var inPropertyStructure = false
    private var propertyStructureFields: [String: String] = [:]
    private var propertyStructureProperty = ""
    private var propertyStructureNamespace = ""
    private var structureChildElement = ""
    private var structureChildNamespace = ""
    /// Tracks when we're inside a property element awaiting a value (child Bag/Alt/simple text or nested Description).
    private var inPendingProperty = false

    /// Stack of active xmlns prefix → URI mappings. XMLParser doesn't resolve attribute namespaces,
    /// so we honor the document's live declarations to avoid silently dropping unknown-prefix attribute-form
    /// properties (which is how Lightroom/Capture One/Photo Mechanic write most fields).
    private var prefixStack: [(prefix: String, uri: String)] = []

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
        parser.shouldReportNamespacePrefixes = true
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

        // Handle structure child elements (rdf:parseType="Resource" style)
        if inPropertyStructure {
            structureChildElement = elementName
            structureChildNamespace = namespaceURI ?? ""
            currentText = ""
            return
        }

        // Handle structured items inside Bag/Seq (Description inside li)
        if inStructuredItem && elementName == "Description" {
            // Parse attributes as structure fields
            for (key, value) in attributeDict {
                if Self.isMetaAttribute(key) { continue }
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let prefix = String(parts[0])
                    let prop = String(parts[1])
                    if let ns = resolvePrefix(prefix) {
                        currentStructureFields["\(ns)\(prop)"] = value
                    }
                }
            }
            return
        }
        if inStructuredItem {
            // Child element inside a structured item (element form)
            structureChildElement = elementName
            structureChildNamespace = namespaceURI ?? ""
            currentText = ""
            return
        }

        if elementName == "Description" && inPendingProperty {
            // Nested rdf:Description inside a property element → structure
            inPropertyStructure = true
            propertyStructureProperty = currentArrayProperty
            propertyStructureNamespace = currentArrayNamespace
            inPendingProperty = false
            // Parse attributes as structure fields
            for (key, value) in attributeDict {
                if Self.isMetaAttribute(key) { continue }
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let prefix = String(parts[0])
                    let prop = String(parts[1])
                    if let ns = resolvePrefix(prefix) {
                        propertyStructureFields["\(ns)\(prop)"] = value
                    }
                }
            }
        } else if elementName == "Description" {
            inDescription = true
            // Some simple properties are stored as attributes on rdf:Description
            for (key, value) in attributeDict {
                if !Self.isMetaAttribute(key) {
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
            inPendingProperty = false
            currentArrayItems = []
            isStructuredBag = false
            currentStructuredArrayItems = []
        } else if elementName == "Seq" {
            inSeq = true
            inPendingProperty = false
            currentArrayItems = []
        } else if elementName == "Alt" {
            inAlt = true
            inPendingProperty = false
            currentArrayItems = []
        } else if elementName == "li" {
            currentText = ""
            // If inside a Bag, prepare for potential structured item
            if inBag {
                inStructuredItem = true
                currentStructureFields = [:]
            }
        } else if inDescription && !inBag && !inSeq && !inAlt {
            // This is a property element — remember it for potential child arrays
            currentElement = elementName
            currentNamespace = namespaceURI ?? ""
            currentArrayProperty = elementName
            currentArrayNamespace = namespaceURI ?? ""
            inPendingProperty = true

            // Check for rdf:parseType="Resource" indicating a single structure
            if attributeDict["rdf:parseType"] == "Resource" || attributeDict["parseType"] == "Resource" {
                inPropertyStructure = true
                inPendingProperty = false
                propertyStructureFields = [:]
                propertyStructureProperty = elementName
                propertyStructureNamespace = namespaceURI ?? ""
            } else {
                // Check for structure attributes directly on the property element (compact form)
                var structAttrs: [String: String] = [:]
                for (key, value) in attributeDict {
                    if Self.isMetaAttribute(key) { continue }
                    let parts = key.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        let prefix = String(parts[0])
                        let prop = String(parts[1])
                        if let ns = resolvePrefix(prefix) {
                            structAttrs["\(ns)\(prop)"] = value
                        }
                    }
                }
                if !structAttrs.isEmpty {
                    // This property element has namespaced attributes — treat as single structure
                    inPropertyStructure = true
                    inPendingProperty = false
                    propertyStructureFields = structAttrs
                    propertyStructureProperty = elementName
                    propertyStructureNamespace = namespaceURI ?? ""
                }
            }
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

        // Handle end of structure child elements
        if inPropertyStructure && elementName != propertyStructureProperty {
            if elementName == "Description" {
                // End of rdf:Description inside the property — fields already captured
                return
            }
            // Child element text value
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let ns = namespaceURI, !ns.isEmpty {
                propertyStructureFields["\(ns)\(elementName)"] = trimmed
            }
            structureChildElement = ""
            structureChildNamespace = ""
            return
        }

        // End of property structure element
        if inPropertyStructure && elementName == propertyStructureProperty {
            if !propertyStructureFields.isEmpty {
                let key = "\(propertyStructureNamespace)\(propertyStructureProperty)"
                properties[key] = .structure(propertyStructureFields)
            }
            inPropertyStructure = false
            propertyStructureFields = [:]
            propertyStructureProperty = ""
            propertyStructureNamespace = ""
            return
        }

        // Handle structured items inside bag
        if inStructuredItem && elementName != "li" && elementName != "Description" {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let ns = namespaceURI, !ns.isEmpty {
                currentStructureFields["\(ns)\(elementName)"] = trimmed
            }
            structureChildElement = ""
            structureChildNamespace = ""
            return
        }
        if inStructuredItem && elementName == "Description" {
            // End of rdf:Description inside li — fields already captured from attributes
            return
        }

        // Standard XMP handling
        if elementName == "Description" {
            inDescription = false
        } else if elementName == "li" {
            if inStructuredItem && !currentStructureFields.isEmpty {
                // This was a structured item in a Bag
                isStructuredBag = true
                currentStructuredArrayItems.append(currentStructureFields)
                inStructuredItem = false
                currentStructureFields = [:]
            } else {
                inStructuredItem = false
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    currentArrayItems.append(trimmed)
                }
            }
        } else if elementName == "Bag" || elementName == "Seq" {
            if isStructuredBag && !currentStructuredArrayItems.isEmpty {
                // Store as structured array
                if !currentArrayNamespace.isEmpty && !currentArrayProperty.isEmpty {
                    properties["\(currentArrayNamespace)\(currentArrayProperty)"] = .structuredArray(currentStructuredArrayItems)
                }
            } else if !currentArrayNamespace.isEmpty && !currentArrayProperty.isEmpty {
                properties["\(currentArrayNamespace)\(currentArrayProperty)"] = .array(currentArrayItems)
            }
            inBag = false
            inSeq = false
            isStructuredBag = false
            currentArrayItems = []
            currentStructuredArrayItems = []
        } else if elementName == "Alt" {
            if let first = currentArrayItems.first {
                if !currentArrayNamespace.isEmpty && !currentArrayProperty.isEmpty {
                    properties["\(currentArrayNamespace)\(currentArrayProperty)"] = .langAlternative(first)
                }
            }
            inAlt = false
            currentArrayItems = []
        } else if inDescription && !inBag && !inSeq && !inAlt {
            inPendingProperty = false
            // Only store as simple if this key wasn't already set (by a child Bag/Seq/Alt/structure)
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

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixStack.append((prefix, namespaceURI))
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        if let idx = prefixStack.lastIndex(where: { $0.prefix == prefix }) {
            prefixStack.remove(at: idx)
        }
    }

    private func resolvePrefix(_ prefix: String) -> String? {
        // Innermost xmlns declaration wins — mirrors XML scoping rules.
        if let uri = prefixStack.reversed().first(where: { $0.prefix == prefix })?.uri {
            return uri
        }
        // Fallback for documents that reference a prefix without declaring xmlns (malformed but tolerated).
        return XMPNamespace.namespace(for: prefix)
    }

    /// RDF/XML meta-attributes that exist for parser control, not as user metadata. These must
    /// never be stored as properties (rdf:about, xml:lang, etc. are infrastructure).
    private static func isMetaAttribute(_ key: String) -> Bool {
        if key.hasPrefix("xmlns") { return true }
        if key == "about" || key == "parseType" || key == "ID" || key == "nodeID" || key == "resource" { return true }
        if key.hasPrefix("rdf:") || key.hasPrefix("xml:") { return true }
        return false
    }
}
