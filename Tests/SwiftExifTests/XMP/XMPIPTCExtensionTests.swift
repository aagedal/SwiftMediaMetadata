import XCTest
@testable import SwiftExif

final class XMPIPTCExtensionTests: XCTestCase {

    private func makeXMPData(xml: String) -> Data {
        var data = Data(JPEGSegment.xmpIdentifier)
        data.append(Data(xml.utf8))
        return data
    }

    // MARK: - DigitalSourceType

    func testReadDigitalSourceTypeAsAttribute() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/">
         <rdf:Description rdf:about=""
            Iptc4xmpExt:DigitalSourceType="http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        XCTAssertEqual(xmp.digitalSourceType, "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture")
    }

    func testReadDigitalSourceTypeAsElement() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/">
         <rdf:Description rdf:about="">
          <Iptc4xmpExt:DigitalSourceType>http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia</Iptc4xmpExt:DigitalSourceType>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        XCTAssertEqual(xmp.digitalSourceType, "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia")
    }

    func testDigitalSourceTypeRoundTrip() throws {
        var xmp = XMPData()
        xmp.digitalSourceType = "http://cv.iptc.org/newscodes/digitalsourcetype/algorithmicMedia"

        let xml = XMPWriter.generateXML(xmp)
        let readBack = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertEqual(readBack.digitalSourceType, "http://cv.iptc.org/newscodes/digitalsourcetype/algorithmicMedia")
    }

    // MARK: - Print Conversion: Digital Source Type

    func testDigitalSourceTypePrintConversion() {
        let base = "http://cv.iptc.org/newscodes/digitalsourcetype/"

        XCTAssertEqual(PrintConverter.digitalSourceType(base + "digitalCapture"),
                       "Digital capture of a real life scene")
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "negativeFilm"),
                       "Digitised from a negative on film")
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "positiveFilm"),
                       "Digitised from a positive on film")
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "print"),
                       "Digitised from a print on non-transparent medium")
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "minorHumanEdits"),
                       "Minor human edits")
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "compositeWithTrainedAlgorithmicMedia"),
                       "Composite with trained algorithmic media")
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "algorithmicMedia"),
                       "Pure algorithmic media (AI-generated)")
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "trainedAlgorithmicMedia"),
                       "Trained algorithmic media")
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "compositeSynthetic"),
                       "Composite including synthetic elements")
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "algorithmicallyEnhanced"),
                       "Algorithmically enhanced")
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "dataDrivenMedia"),
                       "Data-driven media")
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "digitalArt"),
                       "Digital art")
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "virtualRecording"),
                       "Virtual recording")
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "compositeCapture"),
                       "Composite of multiple captures")
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "softwareImage"),
                       "Created by software")
        // Unknown code returns original URI
        XCTAssertEqual(PrintConverter.digitalSourceType(base + "unknownFuture"),
                       base + "unknownFuture")
        // Non-IPTC URI returned as-is
        XCTAssertEqual(PrintConverter.digitalSourceType("https://example.com/custom"),
                       "https://example.com/custom")
    }

    // MARK: - Print Conversion: Release Status

    func testModelReleaseStatusPrintConversion() {
        let base = "http://ns.useplus.org/ldf/vocab/"
        XCTAssertEqual(PrintConverter.modelReleaseStatus(base + "MR-UMR"), "Unlimited Model Releases")
        XCTAssertEqual(PrintConverter.modelReleaseStatus(base + "MR-LMR"), "Limited or Incomplete Model Releases")
    }

    func testPropertyReleaseStatusPrintConversion() {
        let base = "http://ns.useplus.org/ldf/vocab/"
        XCTAssertEqual(PrintConverter.propertyReleaseStatus(base + "PR-UPR"), "Unlimited Property Releases")
        XCTAssertEqual(PrintConverter.propertyReleaseStatus(base + "PR-NON"), "None")
    }

    // MARK: - Simple/Array IPTC Core Properties

    func testIntellectualGenre() {
        var xmp = XMPData()
        XCTAssertNil(xmp.intellectualGenre)

        xmp.intellectualGenre = "Current"
        XCTAssertEqual(xmp.intellectualGenre, "Current")

        xmp.intellectualGenre = nil
        XCTAssertNil(xmp.intellectualGenre)
    }

    func testScene() {
        var xmp = XMPData()
        XCTAssertTrue(xmp.scene.isEmpty)

        xmp.scene = ["010100", "011100"]
        XCTAssertEqual(xmp.scene, ["010100", "011100"])
    }

    func testSubjectCode() {
        var xmp = XMPData()
        XCTAssertTrue(xmp.subjectCode.isEmpty)

        xmp.subjectCode = ["15000000", "04000000"]
        XCTAssertEqual(xmp.subjectCode, ["15000000", "04000000"])
    }

    func testSceneRoundTrip() throws {
        var xmp = XMPData()
        xmp.scene = ["010100", "011100"]

        let xml = XMPWriter.generateXML(xmp)
        let readBack = try XMPReader.readFromXML(Data(xml.utf8))
        XCTAssertEqual(readBack.scene, ["010100", "011100"])
    }

    // MARK: - IPTC Extension Simple Properties

    func testEvent() throws {
        var xmp = XMPData()
        xmp.event = "Olympic Games 2024"

        let xml = XMPWriter.generateXML(xmp)
        let readBack = try XMPReader.readFromXML(Data(xml.utf8))
        XCTAssertEqual(readBack.event, "Olympic Games 2024")
    }

    func testOrganisationInImage() {
        var xmp = XMPData()
        xmp.organisationInImageCode = ["AAPL", "MSFT"]
        xmp.organisationInImageName = ["Apple Inc.", "Microsoft Corp."]

        XCTAssertEqual(xmp.organisationInImageCode, ["AAPL", "MSFT"])
        XCTAssertEqual(xmp.organisationInImageName, ["Apple Inc.", "Microsoft Corp."])
    }

    func testMaxAvailDimensions() {
        var xmp = XMPData()
        xmp.maxAvailHeight = "4000"
        xmp.maxAvailWidth = "6000"

        XCTAssertEqual(xmp.maxAvailHeight, "4000")
        XCTAssertEqual(xmp.maxAvailWidth, "6000")
    }

    func testModelReleaseFields() {
        var xmp = XMPData()
        xmp.modelReleaseStatus = "http://ns.useplus.org/ldf/vocab/MR-UMR"
        xmp.modelReleaseDocument = ["MR-001", "MR-002"]

        XCTAssertEqual(xmp.modelReleaseStatus, "http://ns.useplus.org/ldf/vocab/MR-UMR")
        XCTAssertEqual(xmp.modelReleaseDocument, ["MR-001", "MR-002"])
    }

    func testPropertyReleaseFields() {
        var xmp = XMPData()
        xmp.propertyReleaseStatus = "http://ns.useplus.org/ldf/vocab/PR-UPR"
        xmp.propertyReleaseDocument = ["PR-001"]

        XCTAssertEqual(xmp.propertyReleaseStatus, "http://ns.useplus.org/ldf/vocab/PR-UPR")
        XCTAssertEqual(xmp.propertyReleaseDocument, ["PR-001"])
    }

    func testDigitalImageGUID() {
        var xmp = XMPData()
        xmp.digitalImageGUID = "urn:uuid:12345678-1234-1234-1234-123456789012"
        XCTAssertEqual(xmp.digitalImageGUID, "urn:uuid:12345678-1234-1234-1234-123456789012")
    }

    func testImageSupplierImageID() {
        var xmp = XMPData()
        xmp.imageSupplierImageID = "SUPPLIER-IMG-42"
        XCTAssertEqual(xmp.imageSupplierImageID, "SUPPLIER-IMG-42")
    }

    func testAdditionalModelInformation() {
        var xmp = XMPData()
        xmp.additionalModelInformation = "Professional model, Caucasian ethnicity"
        XCTAssertEqual(xmp.additionalModelInformation, "Professional model, Caucasian ethnicity")
    }

    // MARK: - PLUS Namespace Properties

    func testPLUSProperties() throws {
        var xmp = XMPData()
        xmp.minorModelAgeDisclosure = "http://ns.useplus.org/ldf/vocab/AG-A25"
        xmp.plusModelReleaseID = ["MR-ID-001"]
        xmp.plusPropertyReleaseID = ["PR-ID-001", "PR-ID-002"]

        let xml = XMPWriter.generateXML(xmp)
        XCTAssertTrue(xml.contains("plus:MinorModelAgeDisclosure"))

        let readBack = try XMPReader.readFromXML(Data(xml.utf8))
        XCTAssertEqual(readBack.minorModelAgeDisclosure, "http://ns.useplus.org/ldf/vocab/AG-A25")
        XCTAssertEqual(readBack.plusModelReleaseID, ["MR-ID-001"])
        XCTAssertEqual(readBack.plusPropertyReleaseID, ["PR-ID-001", "PR-ID-002"])
    }

    // MARK: - Structure Parsing: CreatorContactInfo

    func testCreatorContactInfoAttributeForm() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/">
         <rdf:Description rdf:about="">
          <Iptc4xmpCore:CreatorContactInfo>
           <rdf:Description
              Iptc4xmpCore:CiAdrCity="Oslo"
              Iptc4xmpCore:CiAdrCtry="Norway"
              Iptc4xmpCore:CiEmailWork="photo@example.com"
              Iptc4xmpCore:CiTelWork="+47-12345678"/>
          </Iptc4xmpCore:CreatorContactInfo>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        let contact = xmp.creatorContactInfo
        XCTAssertNotNil(contact)
        XCTAssertEqual(contact?.city, "Oslo")
        XCTAssertEqual(contact?.country, "Norway")
        XCTAssertEqual(contact?.emailWork, "photo@example.com")
        XCTAssertEqual(contact?.phoneWork, "+47-12345678")
    }

    func testCreatorContactInfoParseTypeResource() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/">
         <rdf:Description rdf:about="">
          <Iptc4xmpCore:CreatorContactInfo rdf:parseType="Resource">
           <Iptc4xmpCore:CiAdrCity>Stockholm</Iptc4xmpCore:CiAdrCity>
           <Iptc4xmpCore:CiAdrCtry>Sweden</Iptc4xmpCore:CiAdrCtry>
           <Iptc4xmpCore:CiEmailWork>foto@example.se</Iptc4xmpCore:CiEmailWork>
          </Iptc4xmpCore:CreatorContactInfo>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        let contact = xmp.creatorContactInfo
        XCTAssertNotNil(contact)
        XCTAssertEqual(contact?.city, "Stockholm")
        XCTAssertEqual(contact?.country, "Sweden")
        XCTAssertEqual(contact?.emailWork, "foto@example.se")
    }

    func testCreatorContactInfoRoundTrip() throws {
        var xmp = XMPData()
        xmp.creatorContactInfo = IPTCCreatorContactInfo(
            city: "Copenhagen",
            country: "Denmark",
            address: "Nyhavn 1",
            postalCode: "1051",
            region: "Capital Region",
            emailWork: "foto@example.dk",
            phoneWork: "+45-12345678",
            webUrl: "https://example.dk"
        )

        let xml = XMPWriter.generateXML(xmp)
        let readBack = try XMPReader.readFromXML(Data(xml.utf8))

        let contact = readBack.creatorContactInfo
        XCTAssertNotNil(contact)
        XCTAssertEqual(contact?.city, "Copenhagen")
        XCTAssertEqual(contact?.country, "Denmark")
        XCTAssertEqual(contact?.address, "Nyhavn 1")
        XCTAssertEqual(contact?.postalCode, "1051")
        XCTAssertEqual(contact?.region, "Capital Region")
        XCTAssertEqual(contact?.emailWork, "foto@example.dk")
        XCTAssertEqual(contact?.phoneWork, "+45-12345678")
        XCTAssertEqual(contact?.webUrl, "https://example.dk")
    }

    // MARK: - Structured Array Parsing: LocationCreated

    func testLocationCreatedParsing() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/">
         <rdf:Description rdf:about="">
          <Iptc4xmpExt:LocationCreated>
           <rdf:Bag>
            <rdf:li>
             <rdf:Description
                Iptc4xmpExt:City="Oslo"
                Iptc4xmpExt:CountryCode="NOR"
                Iptc4xmpExt:CountryName="Norway"
                Iptc4xmpExt:WorldRegion="Europe"/>
            </rdf:li>
           </rdf:Bag>
          </Iptc4xmpExt:LocationCreated>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        let locations = xmp.locationCreated
        XCTAssertEqual(locations.count, 1)
        XCTAssertEqual(locations.first?.city, "Oslo")
        XCTAssertEqual(locations.first?.countryCode, "NOR")
        XCTAssertEqual(locations.first?.countryName, "Norway")
        XCTAssertEqual(locations.first?.worldRegion, "Europe")
    }

    func testLocationCreatedRoundTrip() throws {
        var xmp = XMPData()
        xmp.locationCreated = [
            IPTCLocation(city: "Oslo", countryCode: "NOR", countryName: "Norway", worldRegion: "Europe"),
            IPTCLocation(city: "Stockholm", countryCode: "SWE", countryName: "Sweden", worldRegion: "Europe"),
        ]

        let xml = XMPWriter.generateXML(xmp)
        let readBack = try XMPReader.readFromXML(Data(xml.utf8))

        let locations = readBack.locationCreated
        XCTAssertEqual(locations.count, 2)
        XCTAssertEqual(locations[0].city, "Oslo")
        XCTAssertEqual(locations[0].countryCode, "NOR")
        XCTAssertEqual(locations[1].city, "Stockholm")
        XCTAssertEqual(locations[1].countryCode, "SWE")
    }

    func testLocationShownRoundTrip() throws {
        var xmp = XMPData()
        xmp.locationShown = [
            IPTCLocation(city: "Helsinki", countryCode: "FIN", sublocation: "Senate Square"),
        ]

        let xml = XMPWriter.generateXML(xmp)
        let readBack = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertEqual(readBack.locationShown.count, 1)
        XCTAssertEqual(readBack.locationShown[0].city, "Helsinki")
        XCTAssertEqual(readBack.locationShown[0].sublocation, "Senate Square")
    }

    // MARK: - Structured Array Parsing: RegistryId

    func testRegistryIdParsing() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/">
         <rdf:Description rdf:about="">
          <Iptc4xmpExt:RegistryId>
           <rdf:Bag>
            <rdf:li>
             <rdf:Description
                Iptc4xmpExt:RegItemId="12345"
                Iptc4xmpExt:RegOrgId="ISNI:0000000121032683"/>
            </rdf:li>
            <rdf:li>
             <rdf:Description
                Iptc4xmpExt:RegItemId="67890"
                Iptc4xmpExt:RegOrgId="DOI"/>
            </rdf:li>
           </rdf:Bag>
          </Iptc4xmpExt:RegistryId>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))
        let entries = xmp.registryId
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].regItemId, "12345")
        XCTAssertEqual(entries[0].regOrgId, "ISNI:0000000121032683")
        XCTAssertEqual(entries[1].regItemId, "67890")
        XCTAssertEqual(entries[1].regOrgId, "DOI")
    }

    func testRegistryIdRoundTrip() throws {
        var xmp = XMPData()
        xmp.registryId = [
            IPTCRegistryEntry(regItemId: "ABC-123", regOrgId: "NTB"),
        ]

        let xml = XMPWriter.generateXML(xmp)
        let readBack = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertEqual(readBack.registryId.count, 1)
        XCTAssertEqual(readBack.registryId[0].regItemId, "ABC-123")
        XCTAssertEqual(readBack.registryId[0].regOrgId, "NTB")
    }

    // MARK: - ArtworkOrObject

    func testArtworkOrObjectRoundTrip() throws {
        var xmp = XMPData()
        xmp.artworkOrObject = [
            IPTCArtworkOrObject(title: "Mona Lisa", creator: "Leonardo da Vinci", source: "Louvre Museum"),
        ]

        let xml = XMPWriter.generateXML(xmp)
        let readBack = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertEqual(readBack.artworkOrObject.count, 1)
        XCTAssertEqual(readBack.artworkOrObject[0].title, "Mona Lisa")
        XCTAssertEqual(readBack.artworkOrObject[0].creator, "Leonardo da Vinci")
        XCTAssertEqual(readBack.artworkOrObject[0].source, "Louvre Museum")
    }

    // MARK: - Typed Struct Tests

    func testIPTCCreatorContactInfoToFields() {
        let contact = IPTCCreatorContactInfo(
            city: "Oslo", country: "Norway", emailWork: "test@test.no"
        )
        let fields = contact.toFields()
        XCTAssertEqual(fields[XMPNamespace.iptcCore + "CiAdrCity"], "Oslo")
        XCTAssertEqual(fields[XMPNamespace.iptcCore + "CiAdrCtry"], "Norway")
        XCTAssertEqual(fields[XMPNamespace.iptcCore + "CiEmailWork"], "test@test.no")
        XCTAssertNil(fields[XMPNamespace.iptcCore + "CiAdrPcode"])
    }

    func testIPTCLocationFromFields() {
        let ns = XMPNamespace.iptcExt
        let fields = [
            ns + "City": "Bergen",
            ns + "CountryCode": "NOR",
            ns + "ProvinceState": "Vestland",
        ]
        let location = IPTCLocation(fields: fields)
        XCTAssertEqual(location.city, "Bergen")
        XCTAssertEqual(location.countryCode, "NOR")
        XCTAssertEqual(location.provinceState, "Vestland")
        XCTAssertNil(location.sublocation)
    }

    func testIPTCRegistryEntryRoundTrip() {
        let entry = IPTCRegistryEntry(regItemId: "ID-42", regOrgId: "ORG-99")
        let fields = entry.toFields()
        let restored = IPTCRegistryEntry(fields: fields)
        XCTAssertEqual(entry, restored)
    }

    func testIPTCArtworkOrObjectRoundTrip() {
        let artwork = IPTCArtworkOrObject(
            title: "The Scream",
            creator: "Edvard Munch",
            dateCreated: "1893",
            source: "National Gallery, Oslo",
            copyrightNotice: "Public Domain"
        )
        let fields = artwork.toFields()
        let restored = IPTCArtworkOrObject(fields: fields)
        XCTAssertEqual(artwork, restored)
    }

    // MARK: - IPTC Extension 1.4+ Structures (Phase D)

    func testImageCreatorRoundTrip() throws {
        var xmp = XMPData()
        xmp.imageCreator = [
            IPTCImageCreator(creatorID: "urn:example:creator:42", creatorName: "Truls Aagedal"),
        ]

        let xml = XMPWriter.generateXML(xmp)
        let readBack = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertEqual(readBack.imageCreator.count, 1)
        XCTAssertEqual(readBack.imageCreator[0].creatorID, "urn:example:creator:42")
        XCTAssertEqual(readBack.imageCreator[0].creatorName, "Truls Aagedal")
    }

    func testCopyrightOwnerRoundTrip() throws {
        var xmp = XMPData()
        xmp.copyrightOwner = [
            IPTCCopyrightOwner(copyrightOwnerID: "owner:1", copyrightOwnerName: "NTB"),
            IPTCCopyrightOwner(copyrightOwnerName: "Associated Press"),
        ]

        let xml = XMPWriter.generateXML(xmp)
        let readBack = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertEqual(readBack.copyrightOwner.count, 2)
        let names = Set(readBack.copyrightOwner.compactMap(\.copyrightOwnerName))
        XCTAssertEqual(names, Set(["NTB", "Associated Press"]))
    }

    func testLicensorRoundTrip() throws {
        var xmp = XMPData()
        xmp.licensor = [
            IPTCLicensor(
                licensorID: "urn:licensor:ntb",
                licensorName: "NTB",
                licensorCity: "Oslo",
                licensorCountry: "Norway",
                licensorEmail: "licensing@ntb.no",
                licensorURL: "https://ntb.no"
            ),
        ]

        let xml = XMPWriter.generateXML(xmp)
        let readBack = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertEqual(readBack.licensor.count, 1)
        let lic = readBack.licensor[0]
        XCTAssertEqual(lic.licensorID, "urn:licensor:ntb")
        XCTAssertEqual(lic.licensorName, "NTB")
        XCTAssertEqual(lic.licensorCity, "Oslo")
        XCTAssertEqual(lic.licensorCountry, "Norway")
        XCTAssertEqual(lic.licensorEmail, "licensing@ntb.no")
        XCTAssertEqual(lic.licensorURL, "https://ntb.no")
    }

    func testGenresRoundTrip() throws {
        var xmp = XMPData()
        xmp.genres = ["News Photo", "Feature", "Portrait"]

        let xml = XMPWriter.generateXML(xmp)
        let readBack = try XMPReader.readFromXML(Data(xml.utf8))
        XCTAssertEqual(readBack.genres, ["News Photo", "Feature", "Portrait"])
    }

    func testImageCreatorStructureSelfRoundTrip() {
        let original = IPTCImageCreator(creatorID: "A", creatorName: "B")
        let restored = IPTCImageCreator(fields: original.toFields())
        XCTAssertEqual(original, restored)
    }

    func testLicensorStructureSelfRoundTrip() {
        let original = IPTCLicensor(
            licensorID: "id", licensorName: "n",
            licensorStreetAddress: "street", licensorExtendedAddress: "apt 2",
            licensorCity: "Oslo", licensorRegion: "Oslo",
            licensorPostalCode: "0123", licensorCountry: "Norway",
            licensorTelephone1: "+47 1", licensorTelephone2: "+47 2",
            licensorEmail: "a@b.no", licensorURL: "https://b.no"
        )
        let restored = IPTCLicensor(fields: original.toFields())
        XCTAssertEqual(original, restored)
    }

    // MARK: - Template Tests

    func testAIGeneratedTemplate() throws {
        var metadata = ImageMetadata(format: .jpeg)
        metadata.xmp = XMPData()

        try MetadataTemplate.aiGenerated.apply(to: &metadata)

        XCTAssertEqual(metadata.xmp?.digitalSourceType,
                       "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia")
        XCTAssertEqual(metadata.xmp?.usageTerms, "AI-generated content")
    }

    // MARK: - Validator Tests

    func testDigitalSourceTypeValidation() {
        var metadata = ImageMetadata(format: .jpeg)
        metadata.xmp = XMPData()
        metadata.xmp?.digitalSourceType = "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture"

        let result = MetadataValidator.stockPhoto.validate(metadata)
        // Valid DST URI should not produce a DST warning
        let dstWarnings = result.warnings.filter { $0.field == "XMP-Iptc4xmpExt:DigitalSourceType" && $0.message.contains("IPTC controlled vocabulary") }
        XCTAssertTrue(dstWarnings.isEmpty)
    }

    func testInvalidDigitalSourceTypeValidation() {
        var metadata = ImageMetadata(format: .jpeg)
        metadata.xmp = XMPData()
        metadata.xmp?.digitalSourceType = "https://example.com/custom-type"

        let result = MetadataValidator.stockPhoto.validate(metadata)
        let dstWarnings = result.warnings.filter { $0.field == "XMP-Iptc4xmpExt:DigitalSourceType" }
        XCTAssertEqual(dstWarnings.count, 1)
    }

    // MARK: - Combined Properties Round-Trip

    func testFullIPTCExtensionRoundTrip() throws {
        var xmp = XMPData()

        // Set all simple/array IPTC Extension properties
        xmp.digitalSourceType = "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture"
        xmp.event = "Press Conference"
        xmp.personInImage = ["Jane Doe", "John Smith"]
        xmp.organisationInImageCode = ["ORG001"]
        xmp.organisationInImageName = ["Example Corp"]
        xmp.maxAvailHeight = "5000"
        xmp.maxAvailWidth = "7500"
        xmp.additionalModelInformation = "Model information"
        xmp.modelReleaseStatus = "http://ns.useplus.org/ldf/vocab/MR-UMR"
        xmp.propertyReleaseStatus = "http://ns.useplus.org/ldf/vocab/PR-UPR"
        xmp.modelReleaseDocument = ["MR-001"]
        xmp.propertyReleaseDocument = ["PR-001"]
        xmp.digitalImageGUID = "urn:uuid:test-guid"
        xmp.imageSupplierImageID = "SUPP-123"

        // IPTC Core
        xmp.intellectualGenre = "Feature"
        xmp.scene = ["010100"]
        xmp.subjectCode = ["15000000"]

        // PLUS
        xmp.minorModelAgeDisclosure = "http://ns.useplus.org/ldf/vocab/AG-A25"
        xmp.plusModelReleaseID = ["PLUS-MR-1"]
        xmp.plusPropertyReleaseID = ["PLUS-PR-1"]

        let xml = XMPWriter.generateXML(xmp)
        let readBack = try XMPReader.readFromXML(Data(xml.utf8))

        XCTAssertEqual(readBack.digitalSourceType, xmp.digitalSourceType)
        XCTAssertEqual(readBack.event, xmp.event)
        XCTAssertEqual(readBack.personInImage, xmp.personInImage)
        XCTAssertEqual(readBack.organisationInImageCode, xmp.organisationInImageCode)
        XCTAssertEqual(readBack.organisationInImageName, xmp.organisationInImageName)
        XCTAssertEqual(readBack.maxAvailHeight, xmp.maxAvailHeight)
        XCTAssertEqual(readBack.maxAvailWidth, xmp.maxAvailWidth)
        XCTAssertEqual(readBack.additionalModelInformation, xmp.additionalModelInformation)
        XCTAssertEqual(readBack.modelReleaseStatus, xmp.modelReleaseStatus)
        XCTAssertEqual(readBack.propertyReleaseStatus, xmp.propertyReleaseStatus)
        XCTAssertEqual(readBack.modelReleaseDocument, xmp.modelReleaseDocument)
        XCTAssertEqual(readBack.propertyReleaseDocument, xmp.propertyReleaseDocument)
        XCTAssertEqual(readBack.digitalImageGUID, xmp.digitalImageGUID)
        XCTAssertEqual(readBack.imageSupplierImageID, xmp.imageSupplierImageID)
        XCTAssertEqual(readBack.intellectualGenre, xmp.intellectualGenre)
        XCTAssertEqual(readBack.scene, xmp.scene)
        XCTAssertEqual(readBack.subjectCode, xmp.subjectCode)
        XCTAssertEqual(readBack.minorModelAgeDisclosure, xmp.minorModelAgeDisclosure)
        XCTAssertEqual(readBack.plusModelReleaseID, xmp.plusModelReleaseID)
        XCTAssertEqual(readBack.plusPropertyReleaseID, xmp.plusPropertyReleaseID)
    }
}
