import XCTest
@testable import SwiftExif

final class C2PAReaderTests: XCTestCase {

    // MARK: - Manifest Store Parsing

    func testParseManifestStore() throws {
        let jumbfData = buildMinimalManifestStore()
        let c2pa = try C2PAReader.parseManifestStore(from: jumbfData)

        XCTAssertNotNil(c2pa)
        XCTAssertEqual(c2pa?.manifests.count, 1)

        let manifest = c2pa?.activeManifest
        XCTAssertNotNil(manifest)
        XCTAssertEqual(manifest?.label, "urn:c2pa:test-manifest")
        XCTAssertEqual(manifest?.claim.claimGenerator, "SwiftExif Test")
        XCTAssertNotNil(manifest?.signature)
    }

    func testParseManifestStoreNoJUMBFReturnsNil() throws {
        let data = Data([0x00, 0x00, 0x00, 0x08, 0x66, 0x72, 0x65, 0x65]) // "free" box
        let result = try C2PAReader.parseManifestStore(from: data)
        XCTAssertNil(result)
    }

    // MARK: - Claim Parsing

    func testParseClaimV1() throws {
        let jumbfData = buildMinimalManifestStore(claimGenerator: "TestTool 1.0")
        let c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
        let claim = c2pa?.activeManifest?.claim

        XCTAssertEqual(claim?.claimGenerator, "TestTool 1.0")
        XCTAssertNil(claim?.claimGeneratorInfo)
    }

    func testParseClaimV2WithGeneratorInfo() throws {
        let jumbfData = buildManifestStoreV2(name: "SwiftExif", version: "2.0")
        let c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
        let claim = c2pa?.activeManifest?.claim

        XCTAssertNotNil(claim?.claimGeneratorInfo)
        XCTAssertEqual(claim?.claimGeneratorInfo?.name, "SwiftExif")
        XCTAssertEqual(claim?.claimGeneratorInfo?.version, "2.0")
        XCTAssertEqual(claim?.claimGenerator, "SwiftExif 2.0")
    }

    func testParseClaimWithAssertionReferences() throws {
        let jumbfData = buildManifestStoreWithAssertionRefs()
        let c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
        let refs = c2pa?.activeManifest?.claim.assertionReferences

        XCTAssertEqual(refs?.count, 1)
        XCTAssertEqual(refs?.first?.url, "self#jumbf=/c2pa/test/c2pa.assertions/c2pa.hash.data")
        XCTAssertEqual(refs?.first?.algorithm, "sha256")
    }

    // MARK: - Signature Parsing

    func testParseSignature() throws {
        let jumbfData = buildMinimalManifestStore()
        let c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
        let sig = c2pa?.activeManifest?.signature

        XCTAssertNotNil(sig)
        XCTAssertEqual(sig?.algorithm?.description, "ES256")
    }

    // MARK: - Assertion Parsing

    func testParseActionsAssertion() throws {
        let jumbfData = buildManifestStoreWithActions()
        let c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
        let assertions = c2pa?.activeManifest?.assertions

        let actionsAssertion = assertions?.first(where: { $0.label == "c2pa.actions" })
        XCTAssertNotNil(actionsAssertion)

        if case .actions(let actions) = actionsAssertion?.content {
            XCTAssertEqual(actions.actions.count, 1)
            XCTAssertEqual(actions.actions.first?.action, "c2pa.created")
        } else {
            XCTFail("Expected actions assertion content")
        }
    }

    func testParseHashDataAssertion() throws {
        let jumbfData = buildManifestStoreWithHashData()
        let c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
        let assertions = c2pa?.activeManifest?.assertions

        let hashAssertion = assertions?.first(where: { $0.label == "c2pa.hash.data" })
        XCTAssertNotNil(hashAssertion)

        if case .hashData(let hashData) = hashAssertion?.content {
            XCTAssertEqual(hashData.algorithm, "sha256")
            XCTAssertEqual(hashData.hash.count, 32)
            XCTAssertEqual(hashData.exclusions.count, 1)
            XCTAssertEqual(hashData.exclusions.first?.start, 100)
            XCTAssertEqual(hashData.exclusions.first?.length, 200)
        } else {
            XCTFail("Expected hash data assertion content")
        }
    }

    func testParseThumbnailAssertion() throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0xCA, 0xFE, 0xBA, 0xBE]) // pseudo-JPEG
        let jumbfData = buildManifestStoreWithThumbnail(label: "c2pa.thumbnail.claim.jpeg", bytes: bytes)
        let c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
        let assertions = c2pa?.activeManifest?.assertions

        let thumb = assertions?.first(where: { $0.label == "c2pa.thumbnail.claim.jpeg" })
        XCTAssertNotNil(thumb)

        if case .thumbnail(let data, let format) = thumb?.content {
            XCTAssertEqual(data, bytes)
            XCTAssertEqual(format, "jpeg")
        } else {
            XCTFail("Expected thumbnail assertion content")
        }
    }

    func testExtractC2PAThumbnailsAccessor() throws {
        let claimBytes = Data(repeating: 0xAA, count: 32)
        let ingredientBytes = Data(repeating: 0xBB, count: 16)

        // Build a manifest with two thumbnails — claim + ingredient
        let claimAssertion = buildThumbnailAssertionBox(label: "c2pa.thumbnail.claim.jpeg", bytes: claimBytes)
        let ingredientAssertion = buildThumbnailAssertionBox(label: "c2pa.thumbnail.ingredient.png", bytes: ingredientBytes)
        let claim = buildClaim(generator: "test")
        let manifest = buildManifest(label: "urn:c2pa:two-thumbs", claimCBOR: claim,
                                     assertionBoxes: [claimAssertion, ingredientAssertion])
        let jumbfData = wrapInManifestStore(manifest)

        let c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
        XCTAssertNotNil(c2pa)

        // Construct an ImageMetadata that carries the parsed C2PA payload
        let metadata = ImageMetadata(container: .jpeg(JPEGFile(segments: [])),
                                     format: .jpeg, c2pa: c2pa)
        let thumbs = metadata.extractC2PAThumbnails()

        XCTAssertEqual(thumbs.count, 2)
        XCTAssertEqual(thumbs[0].label, "c2pa.thumbnail.claim.jpeg")
        XCTAssertEqual(thumbs[0].data, claimBytes)
        XCTAssertEqual(thumbs[0].format, "jpeg")
        XCTAssertEqual(thumbs[1].label, "c2pa.thumbnail.ingredient.png")
        XCTAssertEqual(thumbs[1].data, ingredientBytes)
        XCTAssertEqual(thumbs[1].format, "png")
    }

    func testExtractC2PAThumbnailsEmptyWhenNoC2PA() {
        let metadata = ImageMetadata(container: .jpeg(JPEGFile(segments: [])), format: .jpeg)
        XCTAssertTrue(metadata.extractC2PAThumbnails().isEmpty)
    }

    /// Thumbnail assertions with no `bidb` payload (empty Data) should be filtered out — the
    /// label exists but there's no actual image to extract. The accessor must skip these.
    func testExtractC2PAThumbnailsSkipsEmptyBidb() throws {
        // Build an assertion with a c2pa.thumbnail.* label but NO bidb content box.
        // The reader emits .thumbnail(Data(), format:...) for that case; the accessor must skip it.
        var assertionPayload = Data()
        let jumd = buildJUMDPayload(prefix: "c2as", label: "c2pa.thumbnail.claim.jpeg")
        appendBox(to: &assertionPayload, type: "jumd", data: jumd)
        // Note: no bidb box here.
        var assertionBox = Data()
        appendBox(to: &assertionBox, type: "jumb", data: assertionPayload)

        let claim = buildClaim(generator: "test")
        let manifest = buildManifest(label: "urn:c2pa:empty-thumb", claimCBOR: claim,
                                     assertionBoxes: [assertionBox])
        let jumbfData = wrapInManifestStore(manifest)

        let c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
        let metadata = ImageMetadata(container: .jpeg(JPEGFile(segments: [])),
                                     format: .jpeg, c2pa: c2pa)
        XCTAssertTrue(metadata.extractC2PAThumbnails().isEmpty,
                      "Empty-bytes thumbnails should not be returned")
    }

    /// A manifest whose only assertions are non-thumbnail (actions, hash, ingredient) should
    /// produce an empty result without errors.
    func testExtractC2PAThumbnailsSkipsNonThumbnailAssertions() throws {
        let jumbfData = buildManifestStoreWithActions()
        let c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
        let metadata = ImageMetadata(container: .jpeg(JPEGFile(segments: [])),
                                     format: .jpeg, c2pa: c2pa)
        XCTAssertTrue(metadata.extractC2PAThumbnails().isEmpty)
    }

    func testParseIngredientAssertion() throws {
        let jumbfData = buildManifestStoreWithIngredient()
        let c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
        let assertions = c2pa?.activeManifest?.assertions

        let ingredientAssertion = assertions?.first(where: { $0.label == "c2pa.ingredient" })
        XCTAssertNotNil(ingredientAssertion)

        if case .ingredient(let ingredient) = ingredientAssertion?.content {
            XCTAssertEqual(ingredient.title, "source.jpg")
            XCTAssertEqual(ingredient.format, "image/jpeg")
            XCTAssertEqual(ingredient.relationship, "parentOf")
        } else {
            XCTFail("Expected ingredient assertion content")
        }
    }

    // MARK: - Format-Specific Extraction

    func testExtractJUMBFFromPNG() {
        var pngFile = PNGFile(chunks: [])
        let jumbfData = buildMinimalManifestStore()
        pngFile.chunks.append(PNGChunk(type: "caBX", data: jumbfData, crc: 0))

        let result = C2PAReader.extractJUMBFFromPNG(pngFile)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, jumbfData)
    }

    func testExtractJUMBFFromPNGMissingReturnsNil() {
        let pngFile = PNGFile(chunks: [
            PNGChunk(type: "IHDR", data: Data(count: 13), crc: 0),
            PNGChunk(type: "IEND", data: Data(), crc: 0),
        ])
        XCTAssertNil(C2PAReader.extractJUMBFFromPNG(pngFile))
    }

    func testExtractJUMBFFromJPEGXL() {
        let jumbfPayload = buildMinimalJUMBFPayload()
        let jxlFile = JXLFile(isContainer: true, boxes: [
            ISOBMFFBox(type: "jbrd", data: Data()),
            ISOBMFFBox(type: "jumb", data: jumbfPayload),
        ])

        let result = C2PAReader.extractJUMBFFromJPEGXL(jxlFile)
        XCTAssertNotNil(result)
    }

    func testExtractJUMBFFromAVIFTopLevelJumb() {
        let jumbfPayload = buildMinimalJUMBFPayload()
        let avifFile = AVIFFile(boxes: [
            ISOBMFFBox(type: "ftyp", data: Data([0x61, 0x76, 0x69, 0x66])), // "avif"
            ISOBMFFBox(type: "jumb", data: jumbfPayload),
        ], brand: "avif")

        let result = C2PAReader.extractJUMBFFromAVIF(avifFile)
        XCTAssertNotNil(result)
    }

    // MARK: - CBOR Builder Helpers

    private func cborUInt(_ value: UInt64) -> Data {
        if value <= 23 {
            return Data([UInt8(value)])
        } else if value <= 0xFF {
            return Data([0x18, UInt8(value)])
        } else if value <= 0xFFFF {
            return Data([0x19, UInt8(value >> 8), UInt8(value & 0xFF)])
        } else {
            var d = Data([0x1A])
            d.append(contentsOf: withUnsafeBytes(of: UInt32(value).bigEndian) { Array($0) })
            return d
        }
    }

    private func cborNegInt(_ value: Int64) -> Data {
        let n = UInt64(-1 - value)
        if n <= 23 {
            return Data([0x20 | UInt8(n)])
        } else if n <= 0xFF {
            return Data([0x38, UInt8(n)])
        } else {
            return Data([0x39, UInt8(n >> 8), UInt8(n & 0xFF)])
        }
    }

    private func cborTextString(_ string: String) -> Data {
        let utf8 = [UInt8](string.utf8)
        let count = utf8.count
        var header: [UInt8]
        if count <= 23 {
            header = [0x60 | UInt8(count)]
        } else if count <= 255 {
            header = [0x78, UInt8(count)]
        } else {
            header = [0x79, UInt8(count >> 8), UInt8(count & 0xFF)]
        }
        return Data(header + utf8)
    }

    private func cborByteString(_ bytes: Data) -> Data {
        let count = bytes.count
        var header: [UInt8]
        if count <= 23 {
            header = [0x40 | UInt8(count)]
        } else if count <= 255 {
            header = [0x58, UInt8(count)]
        } else {
            header = [0x59, UInt8(count >> 8), UInt8(count & 0xFF)]
        }
        return Data(header) + bytes
    }

    private func cborMap(_ count: Int) -> Data {
        if count <= 23 {
            return Data([0xA0 | UInt8(count)])
        }
        return Data([0xB8, UInt8(count)])
    }

    private func cborArray(_ count: Int) -> Data {
        if count <= 23 {
            return Data([0x80 | UInt8(count)])
        }
        return Data([0x98, UInt8(count)])
    }

    private func cborNull() -> Data { Data([0xF6]) }

    // MARK: - JUMBF/C2PA Structure Builders

    private func appendBox(to data: inout Data, type: String, data payload: Data) {
        let size = UInt32(8 + payload.count)
        data.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
        data.append(type.data(using: .ascii)!)
        data.append(payload)
    }

    private func buildJUMDPayload(prefix: String, label: String) -> Data {
        var data = Data()
        data.append(contentsOf: [UInt8](prefix.utf8))
        data.append(contentsOf: [0x00, 0x11, 0x00, 0x10, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        data.append(0x03) // toggles
        data.append(contentsOf: [UInt8](label.utf8))
        data.append(0x00)
        return data
    }

    private func buildClaim(generator: String) -> Data {
        // {"claim_generator": generator}
        var cbor = Data()
        cbor.append(cborMap(1))
        cbor.append(cborTextString("claim_generator"))
        cbor.append(cborTextString(generator))
        return cbor
    }

    private func buildClaimV2(name: String, version: String) -> Data {
        // {"claim_generator_info": [{"name": name, "version": version}]}
        var cbor = Data()
        cbor.append(cborMap(1))
        cbor.append(cborTextString("claim_generator_info"))
        cbor.append(cborArray(1))
        cbor.append(cborMap(2))
        cbor.append(cborTextString("name"))
        cbor.append(cborTextString(name))
        cbor.append(cborTextString("version"))
        cbor.append(cborTextString(version))
        return cbor
    }

    private func buildClaimWithAssertionRefs() -> Data {
        var cbor = Data()
        cbor.append(cborMap(2))
        cbor.append(cborTextString("claim_generator"))
        cbor.append(cborTextString("test"))
        cbor.append(cborTextString("created_assertions"))
        cbor.append(cborArray(1))
        // hashed URI map
        cbor.append(cborMap(3))
        cbor.append(cborTextString("url"))
        cbor.append(cborTextString("self#jumbf=/c2pa/test/c2pa.assertions/c2pa.hash.data"))
        cbor.append(cborTextString("alg"))
        cbor.append(cborTextString("sha256"))
        cbor.append(cborTextString("hash"))
        cbor.append(cborByteString(Data(repeating: 0xAB, count: 32)))
        return cbor
    }

    private func buildMinimalSignature() -> Data {
        // COSE_Sign1_Tagged: tag(18) [protected, unprotected, nil, signature]
        var cbor = Data()
        cbor.append(0xD2) // tag 18

        cbor.append(cborArray(4))

        // [0] protected: bstr containing CBOR map {1: -7} (ES256)
        var protectedMap = Data()
        protectedMap.append(cborMap(1))
        protectedMap.append(cborUInt(1)) // key 1 = alg
        protectedMap.append(cborNegInt(-7)) // ES256
        cbor.append(cborByteString(protectedMap))

        // [1] unprotected: empty map
        cbor.append(cborMap(0))

        // [2] payload: null (detached)
        cbor.append(cborNull())

        // [3] signature: byte string
        cbor.append(cborByteString(Data(repeating: 0xFF, count: 64)))

        return cbor
    }

    private func buildManifest(label: String, claimCBOR: Data, assertionBoxes: [Data] = []) -> Data {
        var manifestPayload = Data()

        // jumd for manifest
        let manifestJumd = buildJUMDPayload(prefix: "c2ma", label: label)
        appendBox(to: &manifestPayload, type: "jumd", data: manifestJumd)

        // Claim superbox
        var claimSuperPayload = Data()
        let claimJumd = buildJUMDPayload(prefix: "c2cl", label: "c2pa.claim")
        appendBox(to: &claimSuperPayload, type: "jumd", data: claimJumd)
        appendBox(to: &claimSuperPayload, type: "cbor", data: claimCBOR)
        appendBox(to: &manifestPayload, type: "jumb", data: claimSuperPayload)

        // Signature superbox
        var sigSuperPayload = Data()
        let sigJumd = buildJUMDPayload(prefix: "c2cs", label: "c2pa.signature")
        appendBox(to: &sigSuperPayload, type: "jumd", data: sigJumd)
        appendBox(to: &sigSuperPayload, type: "cbor", data: buildMinimalSignature())
        appendBox(to: &manifestPayload, type: "jumb", data: sigSuperPayload)

        // Assertion store
        if !assertionBoxes.isEmpty {
            var assertionStorePayload = Data()
            let asJumd = buildJUMDPayload(prefix: "c2as", label: "c2pa.assertions")
            appendBox(to: &assertionStorePayload, type: "jumd", data: asJumd)
            for assertionBox in assertionBoxes {
                assertionStorePayload.append(assertionBox)
            }
            appendBox(to: &manifestPayload, type: "jumb", data: assertionStorePayload)
        }

        return manifestPayload
    }

    private func buildAssertionBox(label: String, prefix: String = "c2as", cbor: Data) -> Data {
        var assertionPayload = Data()
        // Use a generic UUID for assertions — the label identifies the type
        let assertionJumd = buildJUMDPayload(prefix: prefix, label: label)
        appendBox(to: &assertionPayload, type: "jumd", data: assertionJumd)
        appendBox(to: &assertionPayload, type: "cbor", data: cbor)
        var box = Data()
        appendBox(to: &box, type: "jumb", data: assertionPayload)
        return box
    }

    private func wrapInManifestStore(_ manifestPayload: Data) -> Data {
        var storePayload = Data()
        let storeJumd = buildJUMDPayload(prefix: "c2pa", label: "c2pa")
        appendBox(to: &storePayload, type: "jumd", data: storeJumd)
        appendBox(to: &storePayload, type: "jumb", data: manifestPayload)

        var jumbfData = Data()
        appendBox(to: &jumbfData, type: "jumb", data: storePayload)
        return jumbfData
    }

    private func buildMinimalJUMBFPayload() -> Data {
        // Just a jumd with c2pa UUID — enough for format extraction tests
        var payload = Data()
        let jumd = buildJUMDPayload(prefix: "c2pa", label: "c2pa")
        appendBox(to: &payload, type: "jumd", data: jumd)
        return payload
    }

    // MARK: - Full Manifest Store Builders

    private func buildMinimalManifestStore(claimGenerator: String = "SwiftExif Test") -> Data {
        let claim = buildClaim(generator: claimGenerator)
        let manifest = buildManifest(label: "urn:c2pa:test-manifest", claimCBOR: claim)
        return wrapInManifestStore(manifest)
    }

    private func buildManifestStoreV2(name: String, version: String) -> Data {
        let claim = buildClaimV2(name: name, version: version)
        let manifest = buildManifest(label: "urn:c2pa:v2-manifest", claimCBOR: claim)
        return wrapInManifestStore(manifest)
    }

    private func buildManifestStoreWithAssertionRefs() -> Data {
        let claim = buildClaimWithAssertionRefs()
        let manifest = buildManifest(label: "urn:c2pa:ref-manifest", claimCBOR: claim)
        return wrapInManifestStore(manifest)
    }

    private func buildManifestStoreWithActions() -> Data {
        // Build actions CBOR: {"actions": [{"action": "c2pa.created"}]}
        var actionsCBOR = Data()
        actionsCBOR.append(cborMap(1))
        actionsCBOR.append(cborTextString("actions"))
        actionsCBOR.append(cborArray(1))
        actionsCBOR.append(cborMap(1))
        actionsCBOR.append(cborTextString("action"))
        actionsCBOR.append(cborTextString("c2pa.created"))

        let assertionBox = buildAssertionBox(label: "c2pa.actions", cbor: actionsCBOR)
        let claim = buildClaim(generator: "test")
        let manifest = buildManifest(label: "urn:c2pa:actions", claimCBOR: claim, assertionBoxes: [assertionBox])
        return wrapInManifestStore(manifest)
    }

    private func buildManifestStoreWithHashData() -> Data {
        // {"alg": "sha256", "hash": bstr(32), "exclusions": [{"start": 100, "length": 200}]}
        var hashCBOR = Data()
        hashCBOR.append(cborMap(3))
        hashCBOR.append(cborTextString("alg"))
        hashCBOR.append(cborTextString("sha256"))
        hashCBOR.append(cborTextString("hash"))
        hashCBOR.append(cborByteString(Data(repeating: 0xCC, count: 32)))
        hashCBOR.append(cborTextString("exclusions"))
        hashCBOR.append(cborArray(1))
        hashCBOR.append(cborMap(2))
        hashCBOR.append(cborTextString("start"))
        hashCBOR.append(cborUInt(100))
        hashCBOR.append(cborTextString("length"))
        hashCBOR.append(cborUInt(200))

        let assertionBox = buildAssertionBox(label: "c2pa.hash.data", cbor: hashCBOR)
        let claim = buildClaim(generator: "test")
        let manifest = buildManifest(label: "urn:c2pa:hash", claimCBOR: claim, assertionBoxes: [assertionBox])
        return wrapInManifestStore(manifest)
    }

    private func buildThumbnailAssertionBox(label: String, bytes: Data) -> Data {
        var assertionPayload = Data()
        let jumd = buildJUMDPayload(prefix: "c2as", label: label)
        appendBox(to: &assertionPayload, type: "jumd", data: jumd)
        appendBox(to: &assertionPayload, type: "bidb", data: bytes)
        var box = Data()
        appendBox(to: &box, type: "jumb", data: assertionPayload)
        return box
    }

    private func buildManifestStoreWithThumbnail(label: String, bytes: Data) -> Data {
        let assertion = buildThumbnailAssertionBox(label: label, bytes: bytes)
        let claim = buildClaim(generator: "test")
        let manifest = buildManifest(label: "urn:c2pa:thumb", claimCBOR: claim, assertionBoxes: [assertion])
        return wrapInManifestStore(manifest)
    }

    private func buildManifestStoreWithIngredient() -> Data {
        var ingredientCBOR = Data()
        ingredientCBOR.append(cborMap(3))
        ingredientCBOR.append(cborTextString("dc:title"))
        ingredientCBOR.append(cborTextString("source.jpg"))
        ingredientCBOR.append(cborTextString("dc:format"))
        ingredientCBOR.append(cborTextString("image/jpeg"))
        ingredientCBOR.append(cborTextString("relationship"))
        ingredientCBOR.append(cborTextString("parentOf"))

        let assertionBox = buildAssertionBox(label: "c2pa.ingredient", cbor: ingredientCBOR)
        let claim = buildClaim(generator: "test")
        let manifest = buildManifest(label: "urn:c2pa:ingredient", claimCBOR: claim, assertionBoxes: [assertionBox])
        return wrapInManifestStore(manifest)
    }
}
