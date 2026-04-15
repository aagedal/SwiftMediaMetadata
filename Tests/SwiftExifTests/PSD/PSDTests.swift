import XCTest
@testable import SwiftExif

final class PSDTests: XCTestCase {

    // MARK: - Format Detection

    func testDetectPSDMagicBytes() {
        let psd = buildMinimalPSD()
        XCTAssertEqual(FormatDetector.detect(psd), .psd)
    }

    func testDetectPSDExtension() {
        XCTAssertEqual(FormatDetector.detectFromExtension("psd"), .psd)
        XCTAssertEqual(FormatDetector.detectFromExtension("psb"), .psd)
    }

    func testNotPSD() {
        let jpeg = TestFixtures.minimalJPEG()
        XCTAssertNotEqual(FormatDetector.detect(jpeg), .psd)
    }

    // MARK: - Parsing

    func testParseMinimalPSD() throws {
        let psd = buildMinimalPSD()
        let file = try PSDParser.parse(psd)

        XCTAssertEqual(file.version, 1)
        XCTAssertEqual(file.width, 1)
        XCTAssertEqual(file.height, 1)
        XCTAssertEqual(file.depth, 8)
        XCTAssertEqual(file.colorMode, 1) // Grayscale
    }

    func testParsePSDWithIPTC() throws {
        let psd = buildMinimalPSD(headline: "Test Headline")
        let metadata = try ImageMetadata.read(from: psd)

        XCTAssertEqual(metadata.format, .psd)
        XCTAssertEqual(metadata.iptc.value(for: .headline), "Test Headline")
    }

    func testParsePSDWithXMP() throws {
        let xmpXml = """
        <?xpacket begin="\u{feff}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="\(XMPNamespace.rdf)"
           xmlns:dc="\(XMPNamespace.dc)">
         <rdf:Description rdf:about="">
          <dc:title><rdf:Alt><rdf:li xml:lang="x-default">PSD Title</rdf:li></rdf:Alt></dc:title>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let psd = buildMinimalPSD(xmpXml: xmpXml)
        let metadata = try ImageMetadata.read(from: psd)

        XCTAssertEqual(metadata.xmp?.title, "PSD Title")
    }

    // MARK: - Writing

    func testPSDRoundTrip() throws {
        let psd = buildMinimalPSD(headline: "Original")
        var metadata = try ImageMetadata.read(from: psd)

        try metadata.iptc.setValue("Modified", for: .headline)
        let written = try metadata.writeToData()
        let reread = try ImageMetadata.read(from: written)

        XCTAssertEqual(reread.format, .psd)
        XCTAssertEqual(reread.iptc.value(for: .headline), "Modified")
    }

    func testPSDAddXMP() throws {
        let psd = buildMinimalPSD()
        var metadata = try ImageMetadata.read(from: psd)
        XCTAssertNil(metadata.xmp)

        metadata.xmp = XMPData()
        metadata.xmp?.title = "New Title"
        let written = try metadata.writeToData()
        let reread = try ImageMetadata.read(from: written)

        XCTAssertEqual(reread.xmp?.title, "New Title")
    }

    func testPSDExport() throws {
        let psd = buildMinimalPSD(headline: "Export Test")
        let metadata = try ImageMetadata.read(from: psd)
        let dict = MetadataExporter.buildDictionary(metadata)

        XCTAssertEqual(dict["FileFormat"] as? String, "PSD")
        XCTAssertEqual(dict["IPTC:Headline"] as? String, "Export Test")
    }

    // MARK: - Helpers

    /// Build a minimal valid PSD file with optional metadata.
    private func buildMinimalPSD(headline: String? = nil, xmpXml: String? = nil) -> Data {
        var writer = BinaryWriter(capacity: 512)

        // Header (26 bytes)
        writer.writeBytes([0x38, 0x42, 0x50, 0x53]) // "8BPS"
        writer.writeUInt16BigEndian(1) // Version 1 (PSD)
        writer.writeBytes([0, 0, 0, 0, 0, 0]) // Reserved
        writer.writeUInt16BigEndian(1) // 1 channel
        writer.writeUInt32BigEndian(1) // Height: 1
        writer.writeUInt32BigEndian(1) // Width: 1
        writer.writeUInt16BigEndian(8) // 8-bit depth
        writer.writeUInt16BigEndian(1) // Grayscale

        // Color mode data section (empty)
        writer.writeUInt32BigEndian(0)

        // Image resources section
        var irbBlocks: [IRBBlock] = []

        if let headline {
            // Build IPTC data with headline
            var iptcWriter = BinaryWriter(capacity: 64)
            // Record 2, DataSet 105 (Headline)
            iptcWriter.writeUInt8(0x1C) // Marker
            iptcWriter.writeUInt8(0x02) // Record 2
            iptcWriter.writeUInt8(0x69) // DataSet 105 = Headline
            let headlineBytes = Data(headline.utf8)
            iptcWriter.writeUInt16BigEndian(UInt16(headlineBytes.count))
            iptcWriter.writeBytes(headlineBytes)
            irbBlocks.append(IRBBlock(resourceID: 0x0404, data: iptcWriter.data))
        }

        if let xmpXml {
            let xmpData = Data(xmpXml.utf8)
            irbBlocks.append(IRBBlock(resourceID: 0x0424, data: xmpData))
        }

        let resourcesData = PhotoshopIRB.writeRaw(blocks: irbBlocks)
        writer.writeUInt32BigEndian(UInt32(resourcesData.count))
        writer.writeBytes(resourcesData)

        // Layer and mask data section (empty)
        writer.writeUInt32BigEndian(0)

        // Image data: compression type (raw = 0) + 1 byte pixel data
        writer.writeUInt16BigEndian(0) // Raw
        writer.writeUInt8(0x80) // Single gray pixel

        return writer.data
    }
}
