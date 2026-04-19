import XCTest
@testable import SwiftExif

/// Tests for video-container coverage required by the Aagedal Media Converter swap:
///   - C2PA in MP4/MOV
///   - Sony NonRealTimeMeta XML (embedded + sidecar)
///   - MXF container sniffing + KLV payload extraction
///   - Negative cases (plain files return nil, no false positives)
final class VideoContainerTests: XCTestCase {

    // MARK: - C2PA in MP4/MOV

    func testMP4WithC2PAUUIDBox() throws {
        let jumbf = buildMinimalManifestStore()
        let data = buildMP4WithC2PAUUIDBox(jumbf: jumbf, brand: "mp42")
        let metadata = try VideoMetadata.read(from: data)

        XCTAssertNotNil(metadata.c2pa, "C2PA should be extracted from uuid box in MP4")
        XCTAssertEqual(metadata.c2pa?.manifests.count, 1)
        XCTAssertEqual(metadata.c2pa?.activeManifest?.claim.claimGenerator, "SwiftExif Test")
    }

    func testMP4WithC2PATopLevelJumb() throws {
        let jumbf = buildMinimalManifestStore()
        let data = buildMP4WithTopLevelJumb(jumbf: jumbf)
        let metadata = try VideoMetadata.read(from: data)

        XCTAssertNotNil(metadata.c2pa)
    }

    func testMOVWithC2PAUUIDBox() throws {
        let jumbf = buildMinimalManifestStore()
        let data = buildMP4WithC2PAUUIDBox(jumbf: jumbf, brand: "qt  ")
        let metadata = try VideoMetadata.read(from: data)

        XCTAssertEqual(metadata.format, .mov)
        XCTAssertNotNil(metadata.c2pa)
    }

    func testPlainMP4HasNoC2PA() throws {
        let data = buildMinimalValidMP4(brand: "isom")
        let metadata = try VideoMetadata.read(from: data)

        XCTAssertNil(metadata.c2pa, "Plain MP4 must not surface C2PA")
        XCTAssertTrue(metadata.warnings.isEmpty)
    }

    // MARK: - Sony NRT XML (parser)

    func testParseSonyNRTXML() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta">
          <Device manufacturer="Sony" modelName="PXW-FX9" serialNo="123456"/>
          <LensUnitMetadata>
            <LensModelName>Sony FE 24-70mm F2.8 GM</LensModelName>
          </LensUnitMetadata>
          <CreationDate value="2024-01-15T10:30:00+02:00"/>
          <TimeZone>+02:00</TimeZone>
          <RecordingMode type="normal"/>
          <VideoFormat>
            <VideoFrame captureFps="23.98p" formatFps="23.98p"/>
          </VideoFormat>
          <AcquisitionRecord>
            <Group name="CameraUnitMetadataSet">
              <Item name="CaptureGammaEquation" value="SLog3"/>
            </Group>
          </AcquisitionRecord>
          <UserDescriptiveMetadata>
            <Meta name="Creator" content="Jane Doe"/>
            <Meta name="Project" content="Documentary A"/>
          </UserDescriptiveMetadata>
        </NonRealTimeMeta>
        """
        let cam = try NRTXMLParser.parse(Data(xml.utf8))

        XCTAssertEqual(cam.deviceManufacturer, "Sony")
        XCTAssertEqual(cam.deviceModelName, "PXW-FX9")
        XCTAssertEqual(cam.deviceSerialNumber, "123456")
        XCTAssertEqual(cam.lensModelName, "Sony FE 24-70mm F2.8 GM")
        XCTAssertEqual(cam.timeZone, "+02:00")
        XCTAssertEqual(cam.captureGammaEquation, "SLog3")
        XCTAssertEqual(cam.recordingModeType, "normal")
        XCTAssertEqual(cam.captureFps!, 23.98, accuracy: 0.001)
        XCTAssertEqual(cam.userMetaNames, ["Creator", "Project"])
        XCTAssertEqual(cam.userMetaContents, ["Jane Doe", "Documentary A"])
        XCTAssertNotNil(cam.creationDate)
    }

    func testParseSonyNRTWithNamespacePrefix() throws {
        // Some Sony writers namespace-prefix all elements.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ns:NonRealTimeMeta xmlns:ns="urn:schemas-professionalDisc:nonRealTimeMeta">
          <ns:Device manufacturer="Sony" modelName="ILCE-7M4" serialNo="ABC"/>
          <ns:VideoFormat><ns:VideoFrame captureFps="29.97p"/></ns:VideoFormat>
        </ns:NonRealTimeMeta>
        """
        let cam = try NRTXMLParser.parse(Data(xml.utf8))
        XCTAssertEqual(cam.deviceManufacturer, "Sony")
        XCTAssertEqual(cam.deviceModelName, "ILCE-7M4")
        XCTAssertEqual(cam.captureFps!, 29.97, accuracy: 0.001)
    }

    func testParseNRTFrameRateFraction() throws {
        let xml = """
        <NonRealTimeMeta>
          <VideoFormat><VideoFrame captureFps="30000/1001"/></VideoFormat>
        </NonRealTimeMeta>
        """
        let cam = try NRTXMLParser.parse(Data(xml.utf8))
        XCTAssertEqual(cam.captureFps!, 30000.0 / 1001.0, accuracy: 0.0001)
    }

    func testNRTParserRejectsMalformed() {
        let bogus = Data("<<not xml".utf8)
        XCTAssertThrowsError(try NRTXMLParser.parse(bogus))
    }

    func testNRTCameraMetadataIsEmptyForBlankXML() throws {
        let xml = "<NonRealTimeMeta></NonRealTimeMeta>"
        let cam = try NRTXMLParser.parse(Data(xml.utf8))
        XCTAssertTrue(cam.isEmpty)
    }

    // MARK: - Embedded NRT in MP4

    func testEmbeddedNRTInMP4UUIDBox() throws {
        let xml = """
        <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta">
          <Device manufacturer="Sony" modelName="ILCE-1" serialNo="S-1"/>
        </NonRealTimeMeta>
        """
        // Use a non-XMP uuid + XML payload — the parser sniffs content.
        let uuidUserType = Data([
            0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77
        ])
        let payload = uuidUserType + Data(xml.utf8)
        let data = buildMP4WithUUIDBox(uuidPayload: payload)

        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.camera?.deviceManufacturer, "Sony")
        XCTAssertEqual(metadata.camera?.deviceModelName, "ILCE-1")
    }

    // MARK: - MXF

    func testMXFMagicDetected() {
        let mxfHead: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
            0x0D, 0x01, 0x02, 0x01, 0x01, 0x02, 0x04, 0x00,
        ]
        let data = Data(mxfHead) + Data(repeating: 0, count: 100)
        XCTAssertTrue(MXFReader.isMXF(data))
        XCTAssertEqual(FormatDetector.detectVideo(data), .mxf)
    }

    func testMXFWithEmbeddedNRT() throws {
        let xml = """
        <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta">
          <Device manufacturer="Sony" modelName="PMW-F55" serialNo="X-1"/>
          <VideoFormat><VideoFrame captureFps="24p"/></VideoFormat>
        </NonRealTimeMeta>
        """
        let data = buildMinimalMXF(withNRTXML: Data(xml.utf8))

        let metadata = try VideoMetadata.read(from: data)
        XCTAssertEqual(metadata.format, .mxf)
        XCTAssertEqual(metadata.camera?.deviceManufacturer, "Sony")
        XCTAssertEqual(metadata.camera?.deviceModelName, "PMW-F55")
        let fps = try XCTUnwrap(metadata.camera?.captureFps)
        XCTAssertEqual(fps, 24.0, accuracy: 0.01)
    }

    func testBERLengthShortForm() throws {
        var reader = BinaryReader(data: Data([0x42]))
        XCTAssertEqual(try MXFReader.readBERLength(&reader), 0x42)
    }

    func testBERLengthLongForm() throws {
        // 0x83 = long form, 3 bytes of length follow
        var reader = BinaryReader(data: Data([0x83, 0x01, 0x02, 0x03]))
        XCTAssertEqual(try MXFReader.readBERLength(&reader), 0x010203)
    }

    // MARK: - Sidecar XML discovery

    func testSidecarDiscoveryFindsXMLNextToMXF() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftexif_sidecar_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mxfURL = tmp.appendingPathComponent("CLIP.MXF")
        let xmlURL = tmp.appendingPathComponent("CLIP.XML")

        // Write a minimal (unparseable-as-MXF) dummy but with valid MXF prefix so
        // read() goes through MXFReader and then the sidecar probe fires.
        let mxfPrefix: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
            0x0D, 0x01, 0x02, 0x01, 0x01, 0x02, 0x04, 0x00,
        ]
        try Data(mxfPrefix).write(to: mxfURL)

        let xml = """
        <NonRealTimeMeta>
          <Device manufacturer="Sony" modelName="SIDECAR-1" serialNo="S1"/>
        </NonRealTimeMeta>
        """
        try Data(xml.utf8).write(to: xmlURL)

        let metadata = try VideoMetadata.read(from: mxfURL)
        XCTAssertEqual(metadata.camera?.deviceModelName, "SIDECAR-1")
    }

    func testSidecarURLLookupMissingReturnsNil() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).mp4")
        XCTAssertNil(NRTXMLParser.sidecarURL(for: url))
    }

    func testSidecarCandidatesCoverCaseVariants() {
        let url = URL(fileURLWithPath: "/tmp/CLIP.MP4")
        let candidates = NRTXMLParser.sidecarCandidates(for: url).map(\.lastPathComponent)
        XCTAssertTrue(candidates.contains("CLIP.XML"))
        XCTAssertTrue(candidates.contains("CLIP.xml"))
    }

    // MARK: - Public API

    func testAsyncReadVideoC2PAMetadataReturnsNilForPlainMP4() async throws {
        let data = buildMinimalValidMP4(brand: "isom")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftexif_plain_\(UUID().uuidString).mp4")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let c2pa = try await readVideoC2PAMetadata(from: tmp)
        XCTAssertNil(c2pa)
    }

    func testAsyncReadVideoC2PAMetadataPopulatesForSignedMP4() async throws {
        let jumbf = buildMinimalManifestStore()
        let data = buildMP4WithC2PAUUIDBox(jumbf: jumbf, brand: "mp42")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftexif_c2pa_\(UUID().uuidString).mp4")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let c2pa = try await readVideoC2PAMetadata(from: tmp)
        XCTAssertNotNil(c2pa)
        XCTAssertEqual(c2pa?.activeManifest?.claim.claimGenerator, "SwiftExif Test")
    }

    func testAsyncReadVideoCameraMetadataUsesSidecar() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftexif_cam_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mp4URL = tmp.appendingPathComponent("CLIP.MP4")
        let xmlURL = tmp.appendingPathComponent("CLIP.XML")
        try buildMinimalValidMP4(brand: "mp42").write(to: mp4URL)
        let xml = """
        <NonRealTimeMeta>
          <Device manufacturer="Sony" modelName="FX30" serialNo="S2"/>
        </NonRealTimeMeta>
        """
        try Data(xml.utf8).write(to: xmlURL)

        let cam = try await readVideoCameraMetadata(from: mp4URL)
        XCTAssertEqual(cam?.deviceModelName, "FX30")
    }

    func testAsyncReadVideoCameraMetadataReturnsNilForPlainMOV() async throws {
        let data = buildMinimalValidMP4(brand: "qt  ")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftexif_plain_\(UUID().uuidString).mov")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cam = try await readVideoCameraMetadata(from: tmp)
        XCTAssertNil(cam)
    }

    func testFilesWithBothC2PAAndCameraXMLPopulateIndependently() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftexif_both_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mp4URL = tmp.appendingPathComponent("CLIP.MP4")
        let xmlURL = tmp.appendingPathComponent("CLIP.XML")

        let jumbf = buildMinimalManifestStore()
        try buildMP4WithC2PAUUIDBox(jumbf: jumbf, brand: "mp42").write(to: mp4URL)
        let xml = """
        <NonRealTimeMeta>
          <Device manufacturer="Sony" modelName="FX3" serialNo="S3"/>
        </NonRealTimeMeta>
        """
        try Data(xml.utf8).write(to: xmlURL)

        let metadata = try await readVideoMetadata(from: mp4URL)
        XCTAssertNotNil(metadata.c2pa)
        XCTAssertEqual(metadata.camera?.deviceModelName, "FX3")
    }

    // MARK: - Fixture builders

    private func buildMinimalValidMP4(brand: String) -> Data {
        // ftyp + minimal moov (with empty mvhd so MP4Parser does not throw)
        var data = Data()
        data.append(writeBoxRaw("ftyp", payload: Data(brand.utf8) + Data([0, 0, 0, 0])))

        var mvhd = Data([0, 0, 0, 0]) // version + flags
        mvhd.append(Data(repeating: 0, count: 96)) // minimal mvhd body
        let mvhdBox = writeBoxRaw("mvhd", payload: mvhd)
        let moovBox = writeBoxRaw("moov", payload: mvhdBox)
        data.append(moovBox)
        return data
    }

    private func buildMP4WithC2PAUUIDBox(jumbf: Data, brand: String) -> Data {
        var data = buildMinimalValidMP4(brand: brand)

        let c2paUUID = Data([
            0xD8, 0xFE, 0xC3, 0xD6, 0x1B, 0x0E, 0x48, 0x3C,
            0x92, 0x97, 0x58, 0x28, 0x87, 0x7E, 0xC4, 0x81,
        ])
        let uuidPayload = c2paUUID + jumbf
        data.append(writeBoxRaw("uuid", payload: uuidPayload))
        return data
    }

    private func buildMP4WithTopLevelJumb(jumbf: Data) -> Data {
        // `jumbf` starts with an outer "jumb" box; re-serialize its inner payload.
        // Extract the inner payload of the outer jumb and append it as a top-level box.
        var reader = BinaryReader(data: jumbf)
        _ = try? reader.readUInt32BigEndian() // size
        _ = try? reader.readBytes(4) // "jumb"
        let inner = (try? reader.readBytes(reader.remainingCount)) ?? Data()

        var data = buildMinimalValidMP4(brand: "mp42")
        data.append(writeBoxRaw("jumb", payload: inner))
        return data
    }

    private func buildMP4WithUUIDBox(uuidPayload: Data) -> Data {
        var data = buildMinimalValidMP4(brand: "mp42")
        data.append(writeBoxRaw("uuid", payload: uuidPayload))
        return data
    }

    private func buildMinimalMXF(withNRTXML xml: Data) -> Data {
        // Partition Pack key (first 16 bytes).
        let partitionPackKey: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
            0x0D, 0x01, 0x02, 0x01, 0x01, 0x02, 0x04, 0x00,
        ]
        // Body: 16 bytes of dummy Partition Pack content.
        let partitionBody = Data(repeating: 0x00, count: 16)

        // Second KLV carrying the NRT XML. Key is a generic 16-byte label.
        let xmlKey = Data(repeating: 0xAA, count: 16)

        var out = Data()
        out.append(contentsOf: partitionPackKey)
        out.append(berLength(partitionBody.count))
        out.append(partitionBody)
        out.append(xmlKey)
        out.append(berLength(xml.count))
        out.append(xml)
        return out
    }

    private func berLength(_ length: Int) -> Data {
        if length <= 0x7F {
            return Data([UInt8(length)])
        }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private func writeBoxRaw(_ type: String, payload: Data) -> Data {
        var out = Data()
        let size = UInt32(8 + payload.count)
        out.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
        out.append(type.data(using: .ascii)!)
        out.append(payload)
        return out
    }

    // MARK: - C2PA manifest store builders (copied minimal subset from C2PAReaderTests)

    private func buildMinimalManifestStore() -> Data {
        let claim = buildClaim(generator: "SwiftExif Test")
        let manifest = buildManifest(label: "urn:c2pa:test-manifest", claimCBOR: claim)
        return wrapInManifestStore(manifest)
    }

    private func buildClaim(generator: String) -> Data {
        var cbor = Data()
        cbor.append(cborMap(1))
        cbor.append(cborTextString("claim_generator"))
        cbor.append(cborTextString(generator))
        return cbor
    }

    private func buildMinimalSignature() -> Data {
        var cbor = Data()
        cbor.append(0xD2) // tag 18
        cbor.append(cborArray(4))
        var protectedMap = Data()
        protectedMap.append(cborMap(1))
        protectedMap.append(cborUInt(1))
        protectedMap.append(cborNegInt(-7))
        cbor.append(cborByteString(protectedMap))
        cbor.append(cborMap(0))
        cbor.append(Data([0xF6]))
        cbor.append(cborByteString(Data(repeating: 0xFF, count: 64)))
        return cbor
    }

    private func buildManifest(label: String, claimCBOR: Data) -> Data {
        var manifestPayload = Data()
        appendBox(to: &manifestPayload, type: "jumd", data: buildJUMD(prefix: "c2ma", label: label))

        var claimSuper = Data()
        appendBox(to: &claimSuper, type: "jumd", data: buildJUMD(prefix: "c2cl", label: "c2pa.claim"))
        appendBox(to: &claimSuper, type: "cbor", data: claimCBOR)
        appendBox(to: &manifestPayload, type: "jumb", data: claimSuper)

        var sigSuper = Data()
        appendBox(to: &sigSuper, type: "jumd", data: buildJUMD(prefix: "c2cs", label: "c2pa.signature"))
        appendBox(to: &sigSuper, type: "cbor", data: buildMinimalSignature())
        appendBox(to: &manifestPayload, type: "jumb", data: sigSuper)

        return manifestPayload
    }

    private func wrapInManifestStore(_ manifestPayload: Data) -> Data {
        var storePayload = Data()
        appendBox(to: &storePayload, type: "jumd", data: buildJUMD(prefix: "c2pa", label: "c2pa"))
        appendBox(to: &storePayload, type: "jumb", data: manifestPayload)

        var out = Data()
        appendBox(to: &out, type: "jumb", data: storePayload)
        return out
    }

    private func buildJUMD(prefix: String, label: String) -> Data {
        var d = Data()
        d.append(contentsOf: [UInt8](prefix.utf8))
        d.append(contentsOf: [0x00, 0x11, 0x00, 0x10, 0x80, 0x00, 0x00, 0xAA,
                              0x00, 0x38, 0x9B, 0x71])
        d.append(0x03)
        d.append(contentsOf: [UInt8](label.utf8))
        d.append(0x00)
        return d
    }

    private func appendBox(to data: inout Data, type: String, data payload: Data) {
        let size = UInt32(8 + payload.count)
        data.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
        data.append(type.data(using: .ascii)!)
        data.append(payload)
    }

    private func cborUInt(_ value: UInt64) -> Data {
        if value <= 23 { return Data([UInt8(value)]) }
        if value <= 0xFF { return Data([0x18, UInt8(value)]) }
        if value <= 0xFFFF { return Data([0x19, UInt8(value >> 8), UInt8(value & 0xFF)]) }
        var d = Data([0x1A])
        d.append(contentsOf: withUnsafeBytes(of: UInt32(value).bigEndian) { Array($0) })
        return d
    }

    private func cborNegInt(_ value: Int64) -> Data {
        let n = UInt64(-1 - value)
        if n <= 23 { return Data([0x20 | UInt8(n)]) }
        return Data([0x38, UInt8(n)])
    }

    private func cborTextString(_ s: String) -> Data {
        let utf8 = [UInt8](s.utf8)
        let count = utf8.count
        var header: [UInt8]
        if count <= 23 { header = [0x60 | UInt8(count)] }
        else if count <= 255 { header = [0x78, UInt8(count)] }
        else { header = [0x79, UInt8(count >> 8), UInt8(count & 0xFF)] }
        return Data(header + utf8)
    }

    private func cborByteString(_ bytes: Data) -> Data {
        let count = bytes.count
        var header: [UInt8]
        if count <= 23 { header = [0x40 | UInt8(count)] }
        else if count <= 255 { header = [0x58, UInt8(count)] }
        else { header = [0x59, UInt8(count >> 8), UInt8(count & 0xFF)] }
        return Data(header) + bytes
    }

    private func cborMap(_ count: Int) -> Data {
        if count <= 23 { return Data([0xA0 | UInt8(count)]) }
        return Data([0xB8, UInt8(count)])
    }

    private func cborArray(_ count: Int) -> Data {
        if count <= 23 { return Data([0x80 | UInt8(count)]) }
        return Data([0x98, UInt8(count)])
    }
}
