import XCTest
@testable import SwiftMediaMetadata

final class XMPLanguageAlternativeTests: XCTestCase {
    private let expected = [
        XMPLanguageAlternative(language: "x-default", value: "Default title"),
        XMPLanguageAlternative(language: "nb-NO", value: "Norsk tittel"),
        XMPLanguageAlternative(language: "nb-NO", value: "Alternativ norsk tittel"),
        XMPLanguageAlternative(language: "nn", value: ""),
    ]

    func testLocalizedTitlePacketRoundTripPreservesOrderLanguagesDuplicatesAndEmptyItems() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/" rdf:about="">
           <dc:title><rdf:Alt>
            <rdf:li xml:lang="x-default">Default title</rdf:li>
            <rdf:li xml:lang="nb-NO">Norsk tittel</rdf:li>
            <rdf:li xml:lang="nb-NO">Alternativ norsk tittel</rdf:li>
            <rdf:li xml:lang="nn"></rdf:li>
           </rdf:Alt></dc:title>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """

        let parsed = try XMPReader.readFromXML(Data(xml.utf8))
        XCTAssertEqual(
            parsed.languageAlternativeValue(namespace: XMPNamespace.dc, property: "title"),
            expected
        )
        XCTAssertEqual(parsed.title, "Default title")

        let rewritten = try XMPReader.readFromXML(Data(XMPWriter.generateXML(parsed).utf8))
        XCTAssertEqual(
            rewritten.languageAlternativeValue(namespace: XMPNamespace.dc, property: "title"),
            expected
        )
    }

    func testSingleDefaultAlternativeRetainsLegacyScalarCarrier() throws {
        var xmp = XMPData()
        xmp.title = "Legacy title"

        let reparsed = try XMPReader.readFromXML(Data(XMPWriter.generateXML(xmp).utf8))
        guard case .langAlternative(let title)? = reparsed.value(
            namespace: XMPNamespace.dc,
            property: "title"
        ) else {
            return XCTFail("Expected the legacy scalar carrier")
        }
        XCTAssertEqual(title, "Legacy title")
        XCTAssertEqual(
            reparsed.languageAlternativeValue(namespace: XMPNamespace.dc, property: "title"),
            [XMPLanguageAlternative(language: "x-default", value: "Legacy title")]
        )
    }

    func testLanguageAlternativesRoundTripInsideNestedStructure() throws {
        let fieldKey = XMPNamespace.dc + "title"
        var xmp = XMPData()
        xmp.setValue(
            .structure([fieldKey: .languageAlternative(expected)]),
            namespace: "https://example.com/ns/",
            property: "localized"
        )

        let reparsed = try XMPReader.readFromXML(Data(XMPWriter.generateXML(xmp).utf8))
        guard case .structure(let fields)? = reparsed.value(
            namespace: "https://example.com/ns/",
            property: "localized"
        ) else {
            return XCTFail("Expected the enclosing structure")
        }
        XCTAssertEqual(fields[fieldKey], .languageAlternative(expected))
    }

    func testLocalizedTitlesRoundTripThroughEmbeddedJPEGXMP() throws {
        var metadata = try ImageMetadata.read(from: TestFixtures.minimalJPEG())
        metadata.xmp = XMPData()
        metadata.xmp?.setValue(
            .languageAlternative(expected),
            namespace: XMPNamespace.dc,
            property: "title"
        )

        let written = try metadata.serialized().output
        var reparsed = try ImageMetadata.read(from: written)
        XCTAssertEqual(
            reparsed.xmp?.languageAlternativeValue(namespace: XMPNamespace.dc, property: "title"),
            expected
        )

        reparsed.xmp?.headline = "Updated headline"
        let updated = try ImageMetadata.read(from: reparsed.serialized().output)
        XCTAssertEqual(updated.xmp?.headline, "Updated headline")
        XCTAssertEqual(
            updated.xmp?.languageAlternativeValue(namespace: XMPNamespace.dc, property: "title"),
            expected
        )
    }

    func testMetadataExporterRetainsLanguageTags() {
        var metadata = ImageMetadata()
        metadata.xmp = XMPData()
        metadata.xmp?.setValue(
            .languageAlternative(expected),
            namespace: XMPNamespace.dc,
            property: "title"
        )

        let exported = MetadataExporter.buildDictionary(metadata)
        let items = exported["XMP-dc:Title"] as? [[String: String]]
        XCTAssertEqual(items?.map { $0["language"] }, expected.map(\.language))
        XCTAssertEqual(items?.map { $0["value"] }, expected.map(\.value))
    }
}
