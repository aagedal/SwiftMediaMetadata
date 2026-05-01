import XCTest
import CryptoKit
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

    // MARK: - Phase A: Format Extraction Parity

    func testExtractJUMBFFromTIFF() throws {
        let jumbfData = buildMinimalManifestStore()
        let entry = IFDEntry(tag: C2PAReader.tiffC2PATag, type: .undefined,
                             count: UInt32(jumbfData.count), valueData: jumbfData)
        let ifd0 = IFD(entries: [entry], nextIFDOffset: 0)
        let header = TIFFHeader(byteOrder: .littleEndian)
        let tiffFile = TIFFFile(rawData: Data(), header: header, ifds: [ifd0])

        let result = C2PAReader.extractJUMBFFromTIFF(tiffFile)
        XCTAssertEqual(result, jumbfData)

        // End-to-end: parsing the extracted JUMBF round-trips into a manifest.
        let parsed = try C2PAReader.parseManifestStore(from: result!)
        XCTAssertEqual(parsed?.activeManifest?.label, "urn:c2pa:test-manifest")
    }

    func testExtractJUMBFFromTIFFMissingTagReturnsNil() {
        let header = TIFFHeader(byteOrder: .littleEndian)
        let tiffFile = TIFFFile(rawData: Data(), header: header,
                                ifds: [IFD(entries: [], nextIFDOffset: 0)])
        XCTAssertNil(C2PAReader.extractJUMBFFromTIFF(tiffFile))
    }

    func testExtractJUMBFFromWebP() throws {
        let jumbfData = buildMinimalManifestStore()
        let webPFile = WebPFile(chunks: [WebPChunk(fourCC: "C2PA", data: jumbfData)])

        let result = C2PAReader.extractJUMBFFromWebP(webPFile)
        XCTAssertEqual(result, jumbfData)

        let parsed = try C2PAReader.parseManifestStore(from: result!)
        XCTAssertNotNil(parsed?.activeManifest)
    }

    func testExtractJUMBFFromWebPMissingChunkReturnsNil() {
        let webPFile = WebPFile(chunks: [WebPChunk(fourCC: "EXIF", data: Data([0xCA]))])
        XCTAssertNil(C2PAReader.extractJUMBFFromWebP(webPFile))
    }

    func testExtractJUMBFFromGIF() throws {
        let jumbfData = buildMinimalManifestStore()
        let block = GIFBlock(type: .applicationExtension(
            identifier: "C2PA_GIF",
            authCode: Data([0x00, 0x00, 0x00]),
            data: jumbfData
        ))
        let gifFile = GIFFile(blocks: [block])

        let result = C2PAReader.extractJUMBFFromGIF(gifFile)
        XCTAssertEqual(result, jumbfData)

        let parsed = try C2PAReader.parseManifestStore(from: result!)
        XCTAssertNotNil(parsed?.activeManifest)
    }

    func testExtractJUMBFFromGIFIgnoresOtherIdentifiers() {
        let xmpBlock = GIFBlock(type: .applicationExtension(
            identifier: "XMP Data",
            authCode: Data([0x00, 0x00, 0x00]),
            data: Data("<x:xmpmeta/>".utf8)
        ))
        let gifFile = GIFFile(blocks: [xmpBlock])
        XCTAssertNil(C2PAReader.extractJUMBFFromGIF(gifFile))
    }

    func testExtractJUMBFFromPDF() throws {
        let jumbfData = buildMinimalManifestStore()
        let pdfBytes = buildMinimalPDFWithC2PA(streamData: jumbfData)
        let pdfFile = PDFFile(rawData: pdfBytes)

        let result = C2PAReader.extractJUMBFFromPDF(pdfFile)
        XCTAssertEqual(result, jumbfData)

        let parsed = try C2PAReader.parseManifestStore(from: result!)
        XCTAssertNotNil(parsed?.activeManifest)
    }

    func testExtractJUMBFFromPDFNoMatchReturnsNil() {
        let pdfBytes = Data(
            "%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n%%EOF".utf8
        )
        let pdfFile = PDFFile(rawData: pdfBytes)
        XCTAssertNil(C2PAReader.extractJUMBFFromPDF(pdfFile))
    }

    func testExtractJUMBFFromRIFFWAV() throws {
        let jumbfData = buildMinimalManifestStore()
        let riff = buildMinimalRIFF_WAVE(c2paChunk: jumbfData)

        let result = C2PAReader.extractJUMBFFromRIFF(riff)
        XCTAssertEqual(result, jumbfData)

        let parsed = try C2PAReader.parseManifestStore(from: result!)
        XCTAssertNotNil(parsed?.activeManifest)
    }

    func testExtractJUMBFFromRIFFRejectsNonRIFF() {
        let bogus = Data("MTHD\u{00}\u{00}\u{00}\u{06}".utf8)  // MIDI header
        XCTAssertNil(C2PAReader.extractJUMBFFromRIFF(bogus))
    }

    func testReadSidecarC2PA() throws {
        let jumbfData = buildMinimalManifestStore()
        let parsed = try C2PAData.readSidecar(from: jumbfData)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.activeManifest?.label, "urn:c2pa:test-manifest")
    }

    func testReadSidecarRejectsNonJUMBF() throws {
        let garbage = Data(repeating: 0xAB, count: 64)
        XCTAssertNil(try C2PAData.readSidecar(from: garbage))
    }

    // MARK: - Phase B: Typed Assertion Parsing

    func testParseStdsIPTCAssertion() throws {
        // {"dc:creator": ["Jane Doe"], "dc:rights": "© Jane Doe", "Iptc4xmpExt:DigitalSourceType": "trainedAlgorithmicMedia"}
        var cbor = Data()
        cbor.append(cborMap(3))
        cbor.append(cborTextString("dc:creator"))
        cbor.append(cborArray(1))
        cbor.append(cborTextString("Jane Doe"))
        cbor.append(cborTextString("dc:rights"))
        cbor.append(cborTextString("\u{00A9} Jane Doe"))
        cbor.append(cborTextString("Iptc4xmpExt:DigitalSourceType"))
        cbor.append(cborTextString("trainedAlgorithmicMedia"))

        let manifest = buildManifestStoreWithCustomAssertion(label: "stds.iptc", cbor: cbor)
        let parsed = try C2PAReader.parseManifestStore(from: manifest)
        let assertion = parsed?.activeManifest?.assertions.first(where: { $0.label == "stds.iptc" })
        guard case .iptc(let iptc) = assertion?.content else {
            XCTFail("Expected typed IPTC assertion")
            return
        }
        XCTAssertEqual(iptc.creators, ["Jane Doe"])
        XCTAssertEqual(iptc.rights, "\u{00A9} Jane Doe")
        XCTAssertEqual(iptc.digitalSourceType, "trainedAlgorithmicMedia")
    }

    func testParseStdsExifAssertion() throws {
        // {"tiff:Make": "Canon", "tiff:Model": "EOS R5", "exif:DateTimeOriginal": "2026-04-30T12:00:00Z"}
        var cbor = Data()
        cbor.append(cborMap(3))
        cbor.append(cborTextString("tiff:Make"))
        cbor.append(cborTextString("Canon"))
        cbor.append(cborTextString("tiff:Model"))
        cbor.append(cborTextString("EOS R5"))
        cbor.append(cborTextString("exif:DateTimeOriginal"))
        cbor.append(cborTextString("2026-04-30T12:00:00Z"))

        let manifest = buildManifestStoreWithCustomAssertion(label: "stds.exif", cbor: cbor)
        let parsed = try C2PAReader.parseManifestStore(from: manifest)
        let assertion = parsed?.activeManifest?.assertions.first(where: { $0.label == "stds.exif" })
        guard case .exif(let exif) = assertion?.content else {
            XCTFail("Expected typed Exif assertion")
            return
        }
        XCTAssertEqual(exif.make, "Canon")
        XCTAssertEqual(exif.model, "EOS R5")
        XCTAssertEqual(exif.dateTimeOriginal, "2026-04-30T12:00:00Z")
    }

    func testParseSchemaOrgCreativeWorkAssertion() throws {
        // {"@context": "https://schema.org", "copyrightHolder": {"@type":"Person","name":"Jane"}, "license": "https://creativecommons.org/licenses/by/4.0/"}
        var cbor = Data()
        cbor.append(cborMap(3))
        cbor.append(cborTextString("@context"))
        cbor.append(cborTextString("https://schema.org"))
        cbor.append(cborTextString("copyrightHolder"))
        cbor.append(cborMap(2))
        cbor.append(cborTextString("@type"))
        cbor.append(cborTextString("Person"))
        cbor.append(cborTextString("name"))
        cbor.append(cborTextString("Jane"))
        cbor.append(cborTextString("license"))
        cbor.append(cborTextString("https://creativecommons.org/licenses/by/4.0/"))

        let manifest = buildManifestStoreWithCustomAssertion(label: "stds.schema-org.CreativeWork", cbor: cbor)
        let parsed = try C2PAReader.parseManifestStore(from: manifest)
        let assertion = parsed?.activeManifest?.assertions.first(where: { $0.label == "stds.schema-org.CreativeWork" })
        guard case .schemaOrgCreativeWork(let work) = assertion?.content else {
            XCTFail("Expected typed schema.org assertion")
            return
        }
        XCTAssertEqual(work.copyrightHolder, "Jane")
        XCTAssertEqual(work.license, "https://creativecommons.org/licenses/by/4.0/")
    }

    func testParseTrainingMiningAssertion() throws {
        // {"entries": { "c2pa.ai_generative_training": {"use": "notAllowed"}, "c2pa.ai_inference": {"use": "allowed"} }}
        var cbor = Data()
        cbor.append(cborMap(1))
        cbor.append(cborTextString("entries"))
        cbor.append(cborMap(2))
        cbor.append(cborTextString("c2pa.ai_generative_training"))
        cbor.append(cborMap(1))
        cbor.append(cborTextString("use"))
        cbor.append(cborTextString("notAllowed"))
        cbor.append(cborTextString("c2pa.ai_inference"))
        cbor.append(cborMap(1))
        cbor.append(cborTextString("use"))
        cbor.append(cborTextString("allowed"))

        let manifest = buildManifestStoreWithCustomAssertion(label: "c2pa.training-mining", cbor: cbor)
        let parsed = try C2PAReader.parseManifestStore(from: manifest)
        let assertion = parsed?.activeManifest?.assertions.first(where: { $0.label == "c2pa.training-mining" })
        guard case .trainingMining(let tm) = assertion?.content else {
            XCTFail("Expected typed training-mining assertion")
            return
        }
        XCTAssertEqual(tm.entries.count, 2)
        let genTraining = tm.entries.first { $0.category == "c2pa.ai_generative_training" }
        XCTAssertEqual(genTraining?.use, "notAllowed")
        let inference = tm.entries.first { $0.category == "c2pa.ai_inference" }
        XCTAssertEqual(inference?.use, "allowed")
    }

    func testParseRedactionsAssertion() throws {
        // {"redactions": ["self#jumbf=/c2pa/m1/c2pa.assertions/secret"]}
        var cbor = Data()
        cbor.append(cborMap(1))
        cbor.append(cborTextString("redactions"))
        cbor.append(cborArray(1))
        cbor.append(cborTextString("self#jumbf=/c2pa/m1/c2pa.assertions/secret"))

        let manifest = buildManifestStoreWithCustomAssertion(label: "c2pa.redactions", cbor: cbor)
        let parsed = try C2PAReader.parseManifestStore(from: manifest)
        let assertion = parsed?.activeManifest?.assertions.first(where: { $0.label == "c2pa.redactions" })
        guard case .redactions(let redactions) = assertion?.content else {
            XCTFail("Expected typed redactions assertion")
            return
        }
        XCTAssertEqual(redactions.redactions, ["self#jumbf=/c2pa/m1/c2pa.assertions/secret"])
    }

    func testParseIdentityAssertionEnvelope() throws {
        // {"signer_payload": {"sig_type": "x509"}, "signature": bstr(64)}
        var cbor = Data()
        cbor.append(cborMap(2))
        cbor.append(cborTextString("signer_payload"))
        cbor.append(cborMap(1))
        cbor.append(cborTextString("sig_type"))
        cbor.append(cborTextString("x509"))
        cbor.append(cborTextString("signature"))
        cbor.append(cborByteString(Data(repeating: 0xEE, count: 64)))

        let manifest = buildManifestStoreWithCustomAssertion(label: "c2pa.identity.assertion", cbor: cbor)
        let parsed = try C2PAReader.parseManifestStore(from: manifest)
        let assertion = parsed?.activeManifest?.assertions.first(where: { $0.label == "c2pa.identity.assertion" })
        guard case .identityAssertion(let identity) = assertion?.content else {
            XCTFail("Expected typed identity assertion")
            return
        }
        XCTAssertEqual(identity.signature, Data(repeating: 0xEE, count: 64))
        XCTAssertEqual(identity.signerPayload["sig_type"]?.textStringValue, "x509")
    }

    // MARK: - Phase C.1: Hard-Binding Assertions & Verifier

    func testParseHashBoxesAssertion() throws {
        // {"alg": "sha256", "boxes": [ {"names": ["ftyp"], "hash": h'AA*32'} ]}
        let entryHash = Data(repeating: 0xAA, count: 32)
        var cbor = Data()
        cbor.append(cborMap(2))
        cbor.append(cborTextString("alg"))
        cbor.append(cborTextString("sha256"))
        cbor.append(cborTextString("boxes"))
        cbor.append(cborArray(1))
        cbor.append(cborMap(2))
        cbor.append(cborTextString("names"))
        cbor.append(cborArray(1))
        cbor.append(cborTextString("ftyp"))
        cbor.append(cborTextString("hash"))
        cbor.append(cborByteString(entryHash))

        let manifest = buildManifestStoreWithCustomAssertion(label: "c2pa.hash.boxes", cbor: cbor)
        let parsed = try C2PAReader.parseManifestStore(from: manifest)
        let assertion = parsed?.activeManifest?.assertions.first(where: { $0.label == "c2pa.hash.boxes" })
        guard case .hashBoxes(let hb) = assertion?.content else {
            XCTFail("Expected hashBoxes assertion content")
            return
        }
        XCTAssertEqual(hb.algorithm, "sha256")
        XCTAssertEqual(hb.boxes.count, 1)
        XCTAssertEqual(hb.boxes.first?.names, ["ftyp"])
        XCTAssertEqual(hb.boxes.first?.hash, entryHash)
    }

    func testParseHashCollectionAssertion() throws {
        // {"alg": "sha256", "uris": [ {"uri": "asset.jpg", "hash": h'BB*32', "size": 12345} ]}
        let h = Data(repeating: 0xBB, count: 32)
        var cbor = Data()
        cbor.append(cborMap(2))
        cbor.append(cborTextString("alg"))
        cbor.append(cborTextString("sha256"))
        cbor.append(cborTextString("uris"))
        cbor.append(cborArray(1))
        cbor.append(cborMap(3))
        cbor.append(cborTextString("uri"))
        cbor.append(cborTextString("asset.jpg"))
        cbor.append(cborTextString("hash"))
        cbor.append(cborByteString(h))
        cbor.append(cborTextString("size"))
        cbor.append(cborUInt(12345))

        let manifest = buildManifestStoreWithCustomAssertion(label: "c2pa.hash.collection.data", cbor: cbor)
        let parsed = try C2PAReader.parseManifestStore(from: manifest)
        let assertion = parsed?.activeManifest?.assertions.first(where: { $0.label == "c2pa.hash.collection.data" })
        guard case .hashCollection(let hc) = assertion?.content else {
            XCTFail("Expected hashCollection assertion content")
            return
        }
        XCTAssertEqual(hc.uris.first?.uri, "asset.jpg")
        XCTAssertEqual(hc.uris.first?.hash, h)
        XCTAssertEqual(hc.uris.first?.size, 12345)
    }

    func testVerifyHashDataValid() {
        // 256 bytes of pseudo-asset; embedded "manifest" range is excluded.
        var asset = Data((0..<256).map { UInt8($0 & 0xFF) })
        let exclusion = C2PAExclusion(start: 100, length: 32)
        // Compute the expected SHA-256 of the asset with the exclusion zeroed.
        var blanked = asset
        blanked.replaceSubrange(100..<132, with: Data(repeating: 0, count: 32))
        let expected = C2PAHashVerifier.digest(of: blanked, algorithm: "sha256")!
        let assertion = C2PAHashData(algorithm: "sha256", hash: expected, exclusions: [exclusion])

        // Mutate bytes inside the exclusion — should still validate.
        asset.replaceSubrange(110..<120, with: Data(repeating: 0xFF, count: 10))

        XCTAssertEqual(C2PAHashVerifier.verifyHashData(assertion, against: asset), .valid)
    }

    func testVerifyHashDataInvalidWhenAssetMutatedOutsideExclusion() {
        var asset = Data((0..<256).map { UInt8($0 & 0xFF) })
        let exclusion = C2PAExclusion(start: 100, length: 32)
        var blanked = asset
        blanked.replaceSubrange(100..<132, with: Data(repeating: 0, count: 32))
        let expected = C2PAHashVerifier.digest(of: blanked, algorithm: "sha256")!
        let assertion = C2PAHashData(algorithm: "sha256", hash: expected, exclusions: [exclusion])

        // Mutate a byte outside the exclusion — must fail.
        asset[10] = 0xFF

        if case .invalid = C2PAHashVerifier.verifyHashData(assertion, against: asset) {
            // Expected
        } else {
            XCTFail("Expected invalid result for mutation outside exclusion")
        }
    }

    func testVerifyHashDataUnsupportedAlgorithm() {
        let assertion = C2PAHashData(algorithm: "blake2b", hash: Data(), exclusions: [])
        if case .unsupported = C2PAHashVerifier.verifyHashData(assertion, against: Data()) {
            // Expected
        } else {
            XCTFail("Expected unsupported result for blake2b")
        }
    }

    func testVerifyHashBoxesValid() {
        // Two ISOBMFF boxes; hash covers just the first one.
        let ftypBox = ISOBMFFBox(type: "ftyp", data: Data([0x61, 0x76, 0x69, 0x66]))
        let mdatBox = ISOBMFFBox(type: "mdat", data: Data([0x01, 0x02, 0x03]))

        let ftypBytes = C2PAHashVerifier.reconstructBoxBytes(ftypBox)
        let expected = C2PAHashVerifier.digest(of: ftypBytes, algorithm: "sha256")!

        let assertion = C2PAHashBoxes(algorithm: "sha256", boxes: [
            C2PAHashBoxEntry(names: ["ftyp"], algorithm: nil, hash: expected, pad: nil)
        ])
        XCTAssertEqual(
            C2PAHashVerifier.verifyHashBoxes(assertion, against: [ftypBox, mdatBox]),
            .valid
        )
    }

    func testVerifyHashBoxesMissingBox() {
        let assertion = C2PAHashBoxes(algorithm: "sha256", boxes: [
            C2PAHashBoxEntry(names: ["moov"], algorithm: nil, hash: Data(repeating: 0, count: 32), pad: nil)
        ])
        let status = C2PAHashVerifier.verifyHashBoxes(assertion, against: [
            ISOBMFFBox(type: "ftyp", data: Data())
        ])
        if case .invalid = status {
            // Expected
        } else {
            XCTFail("Expected invalid status when named box missing")
        }
    }

    func testManifestVerifyHardBindingValid() throws {
        let asset = Data((0..<128).map { UInt8($0) })
        let expected = C2PAHashVerifier.digest(of: asset, algorithm: "sha256")!

        // Build a manifest carrying a c2pa.hash.data assertion that matches.
        var hashCBOR = Data()
        hashCBOR.append(cborMap(2))
        hashCBOR.append(cborTextString("alg"))
        hashCBOR.append(cborTextString("sha256"))
        hashCBOR.append(cborTextString("hash"))
        hashCBOR.append(cborByteString(expected))

        let manifest = buildManifestStoreWithCustomAssertion(label: "c2pa.hash.data", cbor: hashCBOR)
        let parsed = try C2PAReader.parseManifestStore(from: manifest)!
        XCTAssertEqual(parsed.activeManifest?.verifyHardBinding(against: asset), .valid)
    }

    // MARK: - Phase C.2: X.509 + COSE_Sign1 Verification

    func testX509ParserExtractsBasicFields() {
        let priv = P256.Signing.PrivateKey()
        let cert = buildMinimalX509Cert(
            subjectCN: "Acme Test Signer",
            issuerCN: "Acme Test CA",
            publicKey: priv.publicKey,
            notBefore: "260101000000Z",
            notAfter: "270101000000Z"
        )

        let parsed = X509Parser.parse(cert)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.subjectCommonName, "Acme Test Signer")
        XCTAssertEqual(parsed?.issuerCommonName, "Acme Test CA")
        XCTAssertEqual(parsed?.publicKeyAlgorithmOID, X509OID.ecPublicKey)
        XCTAssertEqual(parsed?.publicKeyCurveOID, X509OID.p256Curve)
        XCTAssertEqual(parsed?.subjectPublicKeyBytes, priv.publicKey.x963Representation)
    }

    func testVerifySignatureES256ValidAndTampered() throws {
        let priv = P256.Signing.PrivateKey()
        let cert = buildMinimalX509Cert(
            subjectCN: "Test Signer",
            issuerCN: "Test CA",
            publicKey: priv.publicKey,
            notBefore: "260101000000Z",
            notAfter: "270101000000Z"
        )

        let claimBytes = Data("c2pa fake claim payload".utf8)
        let protectedHeader = buildCOSEProtectedHeader(certs: [cert])
        let sigStructure = C2PASignatureVerifier.encodeSigStructure(
            bodyProtected: protectedHeader,
            externalAAD: Data(),
            payload: claimBytes
        )
        let digest = SHA256.hash(data: sigStructure)
        let signed = try priv.signature(for: digest)
        let sigBytes = signed.rawRepresentation

        let cose: CBORValue = .tagged(18, .array([
            .byteString(protectedHeader),
            .map([]),
            .null,
            .byteString(sigBytes),
        ]))
        let c2paSig = C2PASignature(
            algorithm: .es256,
            certificateChain: [cert],
            timestamp: nil,
            signatureBytes: sigBytes,
            raw: cose
        )

        // Verify with a reference time inside the cert's validity window so
        // a generated test doesn't bounce on the wall clock.
        let referenceTime = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!

        let result = C2PASignatureVerifier.verify(c2paSig, claimBytes: claimBytes, referenceTime: referenceTime)
        if case .signatureValid(let signer) = result {
            XCTAssertEqual(signer?.subjectCommonName, "Test Signer")
        } else {
            XCTFail("Expected signatureValid, got \(result)")
        }

        // Tampered claim → signatureInvalid
        let tampered = Data("different payload".utf8)
        let tamperedResult = C2PASignatureVerifier.verify(c2paSig, claimBytes: tampered, referenceTime: referenceTime)
        if case .signatureInvalid = tamperedResult {} else {
            XCTFail("Expected signatureInvalid for tampered claim, got \(tamperedResult)")
        }
    }

    func testVerifySignatureExpiredCertificate() throws {
        let priv = P256.Signing.PrivateKey()
        let cert = buildMinimalX509Cert(
            subjectCN: "Expired Signer",
            issuerCN: "Test CA",
            publicKey: priv.publicKey,
            notBefore: "200101000000Z",   // 2020
            notAfter:  "210101000000Z"   // 2021
        )

        let claimBytes = Data("payload".utf8)
        let protectedHeader = buildCOSEProtectedHeader(certs: [cert])
        let sigStructure = C2PASignatureVerifier.encodeSigStructure(
            bodyProtected: protectedHeader,
            externalAAD: Data(),
            payload: claimBytes
        )
        let signed = try priv.signature(for: SHA256.hash(data: sigStructure))

        let cose: CBORValue = .tagged(18, .array([
            .byteString(protectedHeader),
            .map([]),
            .null,
            .byteString(signed.rawRepresentation),
        ]))
        let c2paSig = C2PASignature(
            algorithm: .es256,
            certificateChain: [cert],
            timestamp: nil,
            signatureBytes: signed.rawRepresentation,
            raw: cose
        )

        // Reference time well after cert expiry.
        let result = C2PASignatureVerifier.verify(c2paSig, claimBytes: claimBytes,
                                                   referenceTime: Date(timeIntervalSince1970: 1_750_000_000))
        if case .certificateExpired = result {} else {
            XCTFail("Expected certificateExpired, got \(result)")
        }
    }

    func testVerifySignatureUnsupportedAlgorithm() {
        let cert = buildMinimalX509Cert(
            subjectCN: "PSS Signer",
            issuerCN: "PSS CA",
            publicKey: P256.Signing.PrivateKey().publicKey,
            notBefore: "260101000000Z",
            notAfter:  "270101000000Z"
        )
        let c2paSig = C2PASignature(
            algorithm: .ps256,
            certificateChain: [cert],
            timestamp: nil,
            signatureBytes: Data(repeating: 0xAA, count: 256),
            raw: .tagged(18, .array([.byteString(Data()), .map([]), .null, .byteString(Data())]))
        )
        let result = C2PASignatureVerifier.verify(c2paSig, claimBytes: Data(),
                                                   referenceTime: ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!)
        if case .unsupportedAlgorithm = result {} else {
            XCTFail("Expected unsupportedAlgorithm, got \(result)")
        }
    }

    // MARK: - Phase C.2 Test Helpers (DER encoders)

    /// Build a minimal X.509 v1 certificate (DER) wrapping the given P-256
    /// public key. Self-signed in structure but the signature value is a
    /// placeholder — `X509Parser` doesn't verify the cert's own signature.
    private func buildMinimalX509Cert(
        subjectCN: String,
        issuerCN: String,
        publicKey: P256.Signing.PublicKey,
        notBefore: String,
        notAfter: String
    ) -> Data {
        // OIDs as raw DER (06 LEN ...).
        let oidEcPublicKey = derEncode(0x06, Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]))
        let oidP256       = derEncode(0x06, Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]))
        let oidEcdsaSha256 = derEncode(0x06, Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        let oidCN          = derEncode(0x06, Data([0x55, 0x04, 0x03]))

        // tbsCertificate fields
        let serial = derEncode(0x02, Data([0x01]))                          // INTEGER 1
        let tbsSigAlg = derEncode(0x30, oidEcdsaSha256)                      // SEQUENCE { OID }
        let issuerName = encodeName(commonName: issuerCN, oidCN: oidCN)
        let validity = derEncode(0x30,
            derEncode(0x17, Data(notBefore.utf8))                            // UTCTime
            + derEncode(0x17, Data(notAfter.utf8))
        )
        let subjectName = encodeName(commonName: subjectCN, oidCN: oidCN)
        let spkiAlg = derEncode(0x30, oidEcPublicKey + oidP256)
        // BIT STRING: 1-byte unused-bits (0x00) + key bytes
        let spkiBitString = derEncode(0x03, Data([0x00]) + publicKey.x963Representation)
        let spki = derEncode(0x30, spkiAlg + spkiBitString)

        let tbs = derEncode(0x30, serial + tbsSigAlg + issuerName + validity + subjectName + spki)
        let outerSigAlg = derEncode(0x30, oidEcdsaSha256)
        // Placeholder signature value — verification doesn't read it.
        let sigValue = derEncode(0x03, Data([0x00]) + Data(repeating: 0xCC, count: 64))

        return derEncode(0x30, tbs + outerSigAlg + sigValue)
    }

    /// Encode a Name with a single CN attribute.
    private func encodeName(commonName: String, oidCN: Data) -> Data {
        let cnString = derEncode(0x0C, Data(commonName.utf8))    // UTF8String
        let atv = derEncode(0x30, oidCN + cnString)              // SEQUENCE { OID, value }
        let rdn = derEncode(0x31, atv)                           // SET OF ATV
        return derEncode(0x30, rdn)                              // SEQUENCE OF RDN
    }

    /// Encode a COSE protected header: {1: -7 (ES256), 33: x5chain}.
    private func buildCOSEProtectedHeader(certs: [Data]) -> Data {
        var inner = Data()
        inner.append(cborMap(2))
        inner.append(cborUInt(1))
        inner.append(cborNegInt(-7))
        inner.append(cborUInt(33))
        if certs.count == 1 {
            inner.append(cborByteString(certs[0]))
        } else {
            inner.append(cborArray(certs.count))
            for cert in certs { inner.append(cborByteString(cert)) }
        }
        return inner
    }

    private func derEncode(_ tag: UInt8, _ value: Data) -> Data {
        var data = Data([tag])
        let n = value.count
        if n < 0x80 {
            data.append(UInt8(n))
        } else if n < 0x100 {
            data.append(0x81)
            data.append(UInt8(n))
        } else {
            data.append(0x82)
            data.append(UInt8(n >> 8))
            data.append(UInt8(n & 0xFF))
        }
        data.append(value)
        return data
    }

    private func buildManifestStoreWithCustomAssertion(label: String, cbor: Data) -> Data {
        let assertionBox = buildAssertionBox(label: label, cbor: cbor)
        let claim = buildClaim(generator: "test")
        let manifest = buildManifest(label: "urn:c2pa:custom-\(label)", claimCBOR: claim, assertionBoxes: [assertionBox])
        return wrapInManifestStore(manifest)
    }

    // MARK: - Phase A Format Builders

    /// Build a minimal PDF byte stream containing a C2PA-typed embedded file
    /// stream. The PDF is intentionally not a fully valid document (no xref) —
    /// `extractC2PAJUMBF` only needs to find the `/Subtype /application#2Fc2pa`
    /// needle and read the surrounding stream object.
    private func buildMinimalPDFWithC2PA(streamData: Data) -> Data {
        var pdf = Data()
        pdf.append(Data("%PDF-1.7\n".utf8))
        let header = "5 0 obj\n<< /Length \(streamData.count) /Type /EmbeddedFile /Subtype /application#2Fc2pa >>\nstream\n"
        pdf.append(Data(header.utf8))
        pdf.append(streamData)
        pdf.append(Data("\nendstream\nendobj\n%%EOF\n".utf8))
        return pdf
    }

    /// Build a minimal RIFF/WAVE byte stream with a "C2PA" chunk.
    private func buildMinimalRIFF_WAVE(c2paChunk jumbf: Data) -> Data {
        var data = Data()
        // Body: "WAVE" form id + C2PA chunk header + payload
        var body = Data("WAVE".utf8)
        body.append(Data("C2PA".utf8))
        body.append(uint32LE(UInt32(jumbf.count)))
        body.append(jumbf)
        // Pad to even length per RIFF rules.
        if jumbf.count & 1 != 0 { body.append(0x00) }

        data.append(Data("RIFF".utf8))
        data.append(uint32LE(UInt32(body.count)))
        data.append(body)
        return data
    }

    private func uint32LE(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
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
