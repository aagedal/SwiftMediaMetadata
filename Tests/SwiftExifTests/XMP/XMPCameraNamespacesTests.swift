import XCTest
@testable import SwiftExif

/// Round-trip coverage for the exif / tiff / aux / exifEX namespaces added in Phase B.
/// The primary interop target is Lightroom / Capture One sidecars, which store camera and
/// lens identity in these namespaces. When EXIF is stripped from the file, exif: in XMP
/// is the only camera metadata that survives.
final class XMPCameraNamespacesTests: XCTestCase {

    private func makeXMPData(xml: String) -> Data {
        var data = Data(JPEGSegment.xmpIdentifier)
        data.append(Data(xml.utf8))
        return data
    }

    // MARK: - exif:

    func testExifAccessorsRoundTrip() throws {
        var xmp = XMPData()
        xmp.exifDateTimeOriginal = "2026-04-18T12:34:56+02:00"
        xmp.exifDateTimeDigitized = "2026-04-18T12:34:56+02:00"
        xmp.exifExposureTime = "1/125"
        xmp.exifFNumber = "56/10"
        xmp.exifISOSpeedRatings = ["400"]
        xmp.exifFocalLength = "35/1"
        xmp.exifFocalLengthIn35mmFilm = "35"
        xmp.exifGPSLatitude = "69,39.0N"
        xmp.exifGPSLongitude = "18,57.0E"
        xmp.exifGPSAltitude = "12/1"
        xmp.exifGPSTimeStamp = "2026-04-18T10:34:56Z"

        let data = XMPWriter.write(xmp)
        let decoded = try XMPReader.read(from: data)

        XCTAssertEqual(decoded.exifDateTimeOriginal, "2026-04-18T12:34:56+02:00")
        XCTAssertEqual(decoded.exifDateTimeDigitized, "2026-04-18T12:34:56+02:00")
        XCTAssertEqual(decoded.exifExposureTime, "1/125")
        XCTAssertEqual(decoded.exifFNumber, "56/10")
        XCTAssertEqual(decoded.exifISOSpeedRatings, ["400"])
        XCTAssertEqual(decoded.exifFocalLength, "35/1")
        XCTAssertEqual(decoded.exifFocalLengthIn35mmFilm, "35")
        XCTAssertEqual(decoded.exifGPSLatitude, "69,39.0N")
        XCTAssertEqual(decoded.exifGPSLongitude, "18,57.0E")
        XCTAssertEqual(decoded.exifGPSAltitude, "12/1")
        XCTAssertEqual(decoded.exifGPSTimeStamp, "2026-04-18T10:34:56Z")
    }

    // MARK: - tiff:

    func testTiffAccessorsRoundTrip() throws {
        var xmp = XMPData()
        xmp.tiffMake = "Canon"
        xmp.tiffModel = "EOS R5"
        xmp.tiffOrientation = "1"
        xmp.tiffSoftware = "Lightroom Classic 13.2"
        xmp.tiffImageWidth = "8192"
        xmp.tiffImageLength = "5464"
        xmp.tiffDateTime = "2026-04-18T13:00:00+02:00"
        xmp.tiffXResolution = "300/1"
        xmp.tiffYResolution = "300/1"
        xmp.tiffBitsPerSample = ["8", "8", "8"]

        let data = XMPWriter.write(xmp)
        let decoded = try XMPReader.read(from: data)

        XCTAssertEqual(decoded.tiffMake, "Canon")
        XCTAssertEqual(decoded.tiffModel, "EOS R5")
        XCTAssertEqual(decoded.tiffOrientation, "1")
        XCTAssertEqual(decoded.tiffSoftware, "Lightroom Classic 13.2")
        XCTAssertEqual(decoded.tiffImageWidth, "8192")
        XCTAssertEqual(decoded.tiffImageLength, "5464")
        XCTAssertEqual(decoded.tiffDateTime, "2026-04-18T13:00:00+02:00")
        XCTAssertEqual(decoded.tiffXResolution, "300/1")
        XCTAssertEqual(decoded.tiffYResolution, "300/1")
        XCTAssertEqual(decoded.tiffBitsPerSample, ["8", "8", "8"])
    }

    // MARK: - aux:

    func testAuxAccessorsRoundTrip() throws {
        var xmp = XMPData()
        xmp.auxLens = "RF 24-70mm F2.8 L IS USM"
        xmp.auxLensInfo = "24/1 70/1 28/10 28/10"
        xmp.auxLensID = "248"
        xmp.auxLensSerialNumber = "LNS-0001"
        xmp.auxSerialNumber = "BODY-0001"
        xmp.auxOwnerName = "Truls Aagedal"
        xmp.auxFirmware = "1.8.1"
        xmp.auxFlashCompensation = "-1/3"

        let data = XMPWriter.write(xmp)
        let decoded = try XMPReader.read(from: data)

        XCTAssertEqual(decoded.auxLens, "RF 24-70mm F2.8 L IS USM")
        XCTAssertEqual(decoded.auxLensInfo, "24/1 70/1 28/10 28/10")
        XCTAssertEqual(decoded.auxLensID, "248")
        XCTAssertEqual(decoded.auxLensSerialNumber, "LNS-0001")
        XCTAssertEqual(decoded.auxSerialNumber, "BODY-0001")
        XCTAssertEqual(decoded.auxOwnerName, "Truls Aagedal")
        XCTAssertEqual(decoded.auxFirmware, "1.8.1")
        XCTAssertEqual(decoded.auxFlashCompensation, "-1/3")
    }

    // MARK: - exifEX:

    func testExifEXAccessorsRoundTrip() throws {
        var xmp = XMPData()
        xmp.exifExLensModel = "EF 24-70mm f/2.8L II USM"
        xmp.exifExLensSerialNumber = "CANON-LNS-0002"
        xmp.exifExBodySerialNumber = "CANON-BODY-0002"
        xmp.exifExCameraOwnerName = "Staff"

        let data = XMPWriter.write(xmp)
        let decoded = try XMPReader.read(from: data)

        XCTAssertEqual(decoded.exifExLensModel, "EF 24-70mm f/2.8L II USM")
        XCTAssertEqual(decoded.exifExLensSerialNumber, "CANON-LNS-0002")
        XCTAssertEqual(decoded.exifExBodySerialNumber, "CANON-BODY-0002")
        XCTAssertEqual(decoded.exifExCameraOwnerName, "Staff")
    }

    // MARK: - Realistic Lightroom-style attribute-form sidecar

    /// Simulates a Lightroom sidecar: mixed namespaces, attribute-form properties, no pretty
    /// line breaks inside rdf:Description. Verifies end-to-end that the parser fix (A1) plus
    /// the new prefix registrations (B1) let us round-trip a realistic document.
    func testLightroomStyleAttributeFormParsing() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
                 xmlns:exif="http://ns.adobe.com/exif/1.0/"
                 xmlns:aux="http://ns.adobe.com/exif/1.0/aux/"
                 xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                 xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
         <rdf:Description rdf:about=""
                          tiff:Make="Canon"
                          tiff:Model="EOS R5"
                          tiff:Orientation="1"
                          exif:ExposureTime="1/125"
                          exif:FNumber="56/10"
                          exif:FocalLength="50/1"
                          aux:Lens="RF 50mm F1.2 L USM"
                          aux:LensID="301"
                          aux:SerialNumber="ABC123"
                          xmp:Rating="5"
                          xmp:CreatorTool="Adobe Lightroom Classic"
                          photoshop:Headline="Breaking"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmp = try XMPReader.read(from: makeXMPData(xml: xml))

        XCTAssertEqual(xmp.tiffMake, "Canon")
        XCTAssertEqual(xmp.tiffModel, "EOS R5")
        XCTAssertEqual(xmp.tiffOrientation, "1")
        XCTAssertEqual(xmp.exifExposureTime, "1/125")
        XCTAssertEqual(xmp.exifFNumber, "56/10")
        XCTAssertEqual(xmp.exifFocalLength, "50/1")
        XCTAssertEqual(xmp.auxLens, "RF 50mm F1.2 L USM")
        XCTAssertEqual(xmp.auxLensID, "301")
        XCTAssertEqual(xmp.auxSerialNumber, "ABC123")
        XCTAssertEqual(xmp.rating, 5)
        XCTAssertEqual(xmp.creatorTool, "Adobe Lightroom Classic")
        XCTAssertEqual(xmp.headline, "Breaking")
    }

    /// MetadataImporter dotted-notation should now accept all four new namespaces without
    /// code changes (the prefix is registered in XMPNamespace.prefixes).
    func testImporterResolvesNewPrefixes() {
        XCTAssertEqual(XMPNamespace.namespace(for: "exif"), XMPNamespace.exif)
        XCTAssertEqual(XMPNamespace.namespace(for: "tiff"), XMPNamespace.tiff)
        XCTAssertEqual(XMPNamespace.namespace(for: "aux"), XMPNamespace.aux)
        XCTAssertEqual(XMPNamespace.namespace(for: "exifEX"), XMPNamespace.exifEX)
    }
}
