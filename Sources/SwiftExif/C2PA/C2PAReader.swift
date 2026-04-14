import Foundation

/// Reads and parses C2PA manifest stores from image data.
public struct C2PAReader: Sendable {

    /// UUID user type for C2PA in BMFF uuid boxes (AVIF/HEIF/MP4).
    static let bmffC2PAUUID: [UInt8] = [
        0xD8, 0xFE, 0xC3, 0xD6, 0x1B, 0x0E, 0x48, 0x3C,
        0x92, 0x97, 0x58, 0x28, 0x87, 0x7E, 0xC4, 0x81,
    ]

    // MARK: - Format-Specific JUMBF Extraction

    /// Extract JUMBF data from JPEG APP11 segments.
    public static func extractJUMBFFromJPEG(_ jpegFile: JPEGFile) throws -> Data? {
        let app11Segments = jpegFile.segments.filter { $0.rawMarker == JPEGMarker.app11.rawValue }
        guard !app11Segments.isEmpty else { return nil }
        return try JUMBFParser.reassembleFromAPP11(app11Segments)
    }

    /// Extract JUMBF data from a PNG caBX chunk.
    public static func extractJUMBFFromPNG(_ pngFile: PNGFile) -> Data? {
        pngFile.findChunk("caBX")?.data
    }

    /// Extract JUMBF data from JPEG XL boxes.
    public static func extractJUMBFFromJPEGXL(_ jxlFile: JXLFile) -> Data? {
        // Look for a top-level jumb box
        if let jumbBox = jxlFile.findBox("jumb") {
            // Return the box data wrapped with its header so we can parse it as ISOBMFF
            return buildBoxData(type: "jumb", payload: jumbBox.data)
        }
        return nil
    }

    /// Extract JUMBF data from HEIF/HEIC BMFF boxes.
    public static func extractJUMBFFromHEIF(_ heifFile: HEIFFile) -> Data? {
        extractJUMBFFromISOBMFF(heifFile.boxes)
    }

    /// Extract JUMBF data from AVIF/BMFF boxes.
    public static func extractJUMBFFromAVIF(_ avifFile: AVIFFile) -> Data? {
        extractJUMBFFromISOBMFF(avifFile.boxes)
    }

    /// Shared JUMBF extraction for any ISOBMFF-based format.
    private static func extractJUMBFFromISOBMFF(_ boxes: [ISOBMFFBox]) -> Data? {
        // First try: top-level jumb box
        if let jumbBox = boxes.first(where: { $0.type == "jumb" }) {
            return buildBoxData(type: "jumb", payload: jumbBox.data)
        }

        // Second try: uuid box with C2PA user type
        for box in boxes where box.type == "uuid" {
            guard box.data.count > 16 else { continue }
            let userType = [UInt8](box.data.prefix(16))
            guard userType == bmffC2PAUUID else { continue }

            let payload = Data(box.data.suffix(from: box.data.startIndex + 16))
            if let jumbfStart = findJUMBFStart(in: payload) {
                return Data(payload.suffix(from: payload.startIndex + jumbfStart))
            }
        }

        return nil
    }

    // MARK: - Manifest Store Parsing

    /// Parse a C2PA manifest store from raw JUMBF data.
    public static func parseManifestStore(from jumbfData: Data) throws -> C2PAData? {
        // Parse outer ISOBMFF boxes
        let outerBoxes = try ISOBMFFBoxReader.parseBoxes(from: jumbfData)

        // Find the jumb box containing the manifest store
        guard let jumbBox = outerBoxes.first(where: { $0.type == "jumb" }) else {
            return nil
        }

        let store = try JUMBFParser.parseSuperbox(from: jumbBox.data)
        guard JUMBFParser.isManifestStore(store.description) else {
            return nil
        }

        // Each child of the manifest store is a manifest
        var manifests: [C2PAManifest] = []
        for child in store.children {
            guard JUMBFParser.isManifest(child.description) else { continue }
            if let manifest = try? parseManifest(child) {
                manifests.append(manifest)
            }
        }

        guard !manifests.isEmpty else { return nil }
        return C2PAData(manifests: manifests)
    }

    // MARK: - Manifest Parsing

    static func parseManifest(_ box: JUMBFBox) throws -> C2PAManifest {
        let label = box.description.label ?? "unknown"

        var claim: C2PAClaim?
        var signature: C2PASignature?
        var assertions: [C2PAAssertion] = []

        for child in box.children {
            if JUMBFParser.isClaim(child.description) {
                claim = try parseClaim(child)
            } else if JUMBFParser.isSignature(child.description) {
                signature = try parseSignature(child)
            } else if JUMBFParser.isAssertionStore(child.description) {
                assertions = try parseAssertionStore(child)
            }
        }

        guard let claim else {
            throw MetadataError.invalidC2PA("Manifest missing claim")
        }
        guard let signature else {
            throw MetadataError.invalidC2PA("Manifest missing signature")
        }

        return C2PAManifest(label: label, claim: claim, signature: signature, assertions: assertions)
    }

    // MARK: - Claim Parsing

    static func parseClaim(_ box: JUMBFBox) throws -> C2PAClaim {
        // The claim is CBOR-encoded in a cbor content box
        guard let cborBox = box.contentBoxes.first(where: { $0.type == "cbor" }) else {
            throw MetadataError.invalidC2PA("Claim missing CBOR content box")
        }

        let cbor = try CBORDecoder.decode(from: cborBox.data)

        // Extract fields from the CBOR map
        // v2: claim_generator_info (map with name/version)
        // v1: claim_generator (string)
        var generator = "unknown"
        var generatorInfo: C2PAGeneratorInfo?

        if let info = cbor["claim_generator_info"] {
            let name = info["name"]?.textStringValue ?? "unknown"
            let version = info["version"]?.textStringValue
            generatorInfo = C2PAGeneratorInfo(name: name, version: version)
            generator = version != nil ? "\(name) \(version!)" : name
        } else if let gen = cbor["claim_generator"]?.textStringValue {
            generator = gen
        }

        let instanceID = cbor["instanceID"]?.textStringValue
        let format = cbor["dc:format"]?.textStringValue
        let title = cbor["dc:title"]?.textStringValue
        let algorithm = cbor["alg"]?.textStringValue

        // Parse assertion references
        var assertionRefs: [C2PAHashedURI] = []
        if let created = cbor["created_assertions"]?.arrayValue {
            assertionRefs.append(contentsOf: created.compactMap { parseHashedURI($0) })
        }
        if let gathered = cbor["gathered_assertions"]?.arrayValue {
            assertionRefs.append(contentsOf: gathered.compactMap { parseHashedURI($0) })
        }

        return C2PAClaim(
            claimGenerator: generator,
            claimGeneratorInfo: generatorInfo,
            instanceID: instanceID,
            format: format,
            title: title,
            algorithm: algorithm,
            assertionReferences: assertionRefs,
            raw: cbor
        )
    }

    static func parseHashedURI(_ cbor: CBORValue) -> C2PAHashedURI? {
        guard let url = cbor["url"]?.textStringValue else { return nil }
        let algorithm = cbor["alg"]?.textStringValue
        let hash = cbor["hash"]?.byteStringValue ?? Data()
        return C2PAHashedURI(url: url, algorithm: algorithm, hash: hash)
    }

    // MARK: - Signature Parsing (COSE Sign1)

    static func parseSignature(_ box: JUMBFBox) throws -> C2PASignature {
        guard let cborBox = box.contentBoxes.first(where: { $0.type == "cbor" }) else {
            throw MetadataError.invalidC2PA("Signature missing CBOR content box")
        }

        let cbor = try CBORDecoder.decode(from: cborBox.data)

        // COSE_Sign1_Tagged = tag(18, [protected, unprotected, payload, signature])
        let coseArray: [CBORValue]
        if let tagged = cbor.taggedValue, tagged.tag == 18 {
            guard let arr = tagged.value.arrayValue, arr.count >= 4 else {
                throw MetadataError.invalidC2PA("Invalid COSE Sign1 structure")
            }
            coseArray = arr
        } else if let arr = cbor.arrayValue, arr.count >= 4 {
            // Some implementations omit the tag
            coseArray = arr
        } else {
            throw MetadataError.invalidC2PA("Invalid COSE Sign1 structure")
        }

        // [0] protected: bstr (serialized CBOR map)
        var algorithm: C2PASignatureAlgorithm?
        var certChain: [Data] = []

        if let protectedBytes = coseArray[0].byteStringValue, !protectedBytes.isEmpty {
            let protectedMap = try CBORDecoder.decode(from: protectedBytes)
            // Key 1 = alg
            if let algValue = protectedMap[intKey: 1]?.intValue {
                algorithm = C2PASignatureAlgorithm(coseValue: algValue)
            }
            // Key 33 = x5chain (single cert or array of certs)
            if let chainValue = protectedMap[intKey: 33] {
                switch chainValue {
                case .byteString(let cert):
                    certChain = [cert]
                case .array(let certs):
                    certChain = certs.compactMap { $0.byteStringValue }
                default:
                    break
                }
            }
        }

        // [1] unprotected: map — check for timestamp
        var timestamp: Data?
        if case .map(let entries) = coseArray[1] {
            // sigTst or sigTst2
            for entry in entries {
                if entry.key.textStringValue == "sigTst" {
                    // { "tstTokens": [ { "val": bstr } ] }
                    if let tokens = entry.value["tstTokens"]?.arrayValue,
                       let first = tokens.first,
                       let val = first["val"]?.byteStringValue {
                        timestamp = val
                    }
                } else if entry.key.textStringValue == "sigTst2" {
                    timestamp = entry.value.byteStringValue
                }
            }
        }

        // [3] signature: bstr
        let signatureBytes = coseArray[3].byteStringValue ?? Data()

        return C2PASignature(
            algorithm: algorithm,
            certificateChain: certChain,
            timestamp: timestamp,
            signatureBytes: signatureBytes,
            raw: cbor
        )
    }

    // MARK: - Assertion Parsing

    static func parseAssertionStore(_ box: JUMBFBox) throws -> [C2PAAssertion] {
        var assertions: [C2PAAssertion] = []

        for child in box.children {
            let label = child.description.label ?? "unknown"
            let content = try parseAssertionContent(label: label, box: child)
            assertions.append(C2PAAssertion(label: label, content: content))
        }

        return assertions
    }

    static func parseAssertionContent(label: String, box: JUMBFBox) throws -> C2PAAssertionContent {
        // Thumbnails are stored as embedded files (bfdb + bidb)
        if label.hasPrefix("c2pa.thumbnail.") {
            let format = String(label.dropFirst("c2pa.thumbnail.claim.".count))
            if let bidb = box.contentBoxes.first(where: { $0.type == "bidb" }) {
                return .thumbnail(bidb.data, format: format)
            }
            return .thumbnail(Data(), format: format)
        }

        // CBOR content box
        if let cborBox = box.contentBoxes.first(where: { $0.type == "cbor" }) {
            let cbor = try CBORDecoder.decode(from: cborBox.data)
            return parseTypedAssertion(label: label, cbor: cbor)
        }

        // JSON content box
        if let jsonBox = box.contentBoxes.first(where: { $0.type == "json" }) {
            return .json(jsonBox.data)
        }

        // Binary content (bidb without thumbnail label)
        if let bidb = box.contentBoxes.first(where: { $0.type == "bidb" }) {
            return .binary(bidb.data)
        }

        // Fallback: return the first content box data as binary
        if let first = box.contentBoxes.first {
            return .binary(first.data)
        }

        return .binary(Data())
    }

    static func parseTypedAssertion(label: String, cbor: CBORValue) -> C2PAAssertionContent {
        if label.hasPrefix("c2pa.actions") {
            return parseActionsAssertion(cbor)
        }
        if label == "c2pa.hash.data" {
            return parseHashDataAssertion(cbor)
        }
        if label.hasPrefix("c2pa.ingredient") {
            return parseIngredientAssertion(cbor)
        }
        return .cbor(cbor)
    }

    static func parseActionsAssertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        guard let actionsArray = cbor["actions"]?.arrayValue else {
            return .cbor(cbor)
        }

        let actions = actionsArray.compactMap { item -> C2PAAction? in
            guard let action = item["action"]?.textStringValue else { return nil }

            // softwareAgent: v1 is a string, v2 is a map with "name"
            var softwareAgent: String?
            if let agent = item["softwareAgent"] {
                switch agent {
                case .textString(let s): softwareAgent = s
                case .map: softwareAgent = agent["name"]?.textStringValue
                default: break
                }
            }

            return C2PAAction(
                action: action,
                softwareAgent: softwareAgent,
                description: item["description"]?.textStringValue,
                digitalSourceType: item["digitalSourceType"]?.textStringValue,
                parameters: item["parameters"]
            )
        }

        return .actions(C2PAActions(actions: actions))
    }

    static func parseHashDataAssertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        guard let alg = cbor["alg"]?.textStringValue,
              let hash = cbor["hash"]?.byteStringValue else {
            return .cbor(cbor)
        }

        var exclusions: [C2PAExclusion] = []
        if let exclArray = cbor["exclusions"]?.arrayValue {
            for item in exclArray {
                if let start = item["start"]?.unsignedIntValue,
                   let length = item["length"]?.unsignedIntValue {
                    exclusions.append(C2PAExclusion(start: start, length: length))
                }
            }
        }

        return .hashData(C2PAHashData(algorithm: alg, hash: hash, exclusions: exclusions))
    }

    static func parseIngredientAssertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        let ingredient = C2PAIngredient(
            title: cbor["dc:title"]?.textStringValue,
            format: cbor["dc:format"]?.textStringValue,
            instanceID: cbor["instanceID"]?.textStringValue,
            relationship: cbor["relationship"]?.textStringValue
        )
        return .ingredient(ingredient)
    }

    // MARK: - Helpers

    /// Build a complete ISOBMFF box from type + payload (for wrapping back into parseable data).
    static func buildBoxData(type: String, payload: Data) -> Data {
        let size = UInt32(8 + payload.count)
        var data = Data(capacity: Int(size))
        data.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
        data.append(type.data(using: .ascii) ?? Data(count: 4))
        data.append(payload)
        return data
    }

    /// Find the start offset of JUMBF data within a buffer (looks for a valid jumb box header).
    static func findJUMBFStart(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        // Scan for "jumb" box type at offset+4
        for i in 0..<max(0, bytes.count - 8) {
            if bytes[i + 4] == 0x6A && bytes[i + 5] == 0x75
                && bytes[i + 6] == 0x6D && bytes[i + 7] == 0x62 { // "jumb"
                // Validate that the size makes sense
                let size = UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16
                    | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
                if size > 8 && Int(size) + i <= bytes.count + 8 {
                    return i
                }
            }
        }
        return nil
    }
}
