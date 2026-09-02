import XCTest
import SwiftMediaMetadata

final class MetadataSemanticComparisonTests: XCTestCase {
    func testCapabilitiesDescribeDirectOpaqueAndSidecarSupport() {
        XCTAssertEqual(ImageFormat.jpeg.metadataCapabilities[.iptcIIM].write, .directlyWritable)
        XCTAssertEqual(ImageFormat.jpeg.metadataCapabilities[.c2pa].read, .readable)
        XCTAssertEqual(ImageFormat.jpeg.metadataCapabilities[.c2pa].preservation, .preservedOpaquely)

        XCTAssertEqual(ImageFormat.raw(.dng).metadataCapabilities[.xmp].write, .directlyWritable)
        XCTAssertEqual(ImageFormat.raw(.arw).metadataCapabilities[.xmp].write, .sidecarOnly)
        XCTAssertEqual(ImageFormat.raw(.arw).metadataCapabilities[.cameraRaw].write, .sidecarOnly)
        XCTAssertEqual(ImageFormat.raw(.arw).metadataCapabilities[.icc].preservation, .preservedOpaquely)

        XCTAssertEqual(ImageFormat.avif.metadataCapabilities[.icc].read, .readable)
        XCTAssertEqual(ImageFormat.avif.metadataCapabilities[.icc].write, .unsupported)
        XCTAssertEqual(ImageFormat.avif.metadataCapabilities[.icc].preservation, .preservedOpaquely)

        XCTAssertEqual(ImageFormat.bmp.metadataCapabilities[.xmp], .unsupported)
        XCTAssertEqual(ImageFormat.svg.metadataCapabilities[.xmp], .semanticReadWrite)
    }

    func testEveryAdvertisedFormatHasEveryDomainCapability() {
        let formats: [ImageFormat] = [
            .jpeg, .tiff, .jpegXL, .png, .avif, .heif, .webp, .pdf, .psd, .gif, .bmp, .svg,
        ] + ImageFormat.RawFormat.allCases.map(ImageFormat.raw)

        for format in formats {
            let capabilities = format.metadataCapabilities
            XCTAssertEqual(capabilities.domains.count, MetadataDomain.allCases.count)
            for domain in MetadataDomain.allCases {
                XCTAssertNotNil(capabilities.domains[domain], "Missing \(domain) for \(format)")
            }
        }
    }

    func testExifByteOrderAndLayoutOffsetsAreNotSemanticChanges() {
        let big = ExifData.fixture(
            byteOrder: .bigEndian,
            orientationBytes: Data([0x00, 0x06]),
            sourceOffset: 42
        )
        let little = ExifData.fixture(
            byteOrder: .littleEndian,
            orientationBytes: Data([0x06, 0x00]),
            sourceOffset: 9_999
        )
        let source = ImageMetadata(format: .jpeg, exif: big)
        let output = ImageMetadata(format: .tiff, exif: little)

        let report = source.preservationReport(comparedTo: output)
        XCTAssertTrue(report.isSemanticallyLossless)
        XCTAssertTrue(report.changed.isEmpty)
    }

    func testXMPOrderingGPSAndDateSpellingsAreSemanticallyEquivalent() {
        var first = XMPData()
        first.setValue(.array(["news", "oslo"]), namespace: XMPNamespace.dc, property: "subject")
        first.setValue(.simple("59,54.000N"), namespace: XMPNamespace.exif, property: "GPSLatitude")
        first.setValue(.simple("2026-09-01T12:00:00+02:00"), namespace: XMPNamespace.photoshop, property: "DateCreated")
        first.setValue(.languageAlternative([
            .init(language: "nb-NO", value: "Tittel"),
            .init(language: "x-default", value: "Title"),
        ]), namespace: XMPNamespace.dc, property: "title")

        var second = XMPData()
        second.setValue(.languageAlternative([
            .init(language: "x-default", value: "Title"),
            .init(language: "NB-no", value: "Tittel"),
        ]), namespace: XMPNamespace.dc, property: "title")
        second.setValue(.simple("2026-09-01T10:00:00Z"), namespace: XMPNamespace.photoshop, property: "DateCreated")
        second.setValue(.simple("59.9 N"), namespace: XMPNamespace.exif, property: "GPSLatitude")
        second.setValue(.array(["oslo", "news"]), namespace: XMPNamespace.dc, property: "subject")

        let source = ImageMetadata(format: .jpeg, xmp: first)
        let output = ImageMetadata(format: .png, xmp: second)
        XCTAssertTrue(source.preservationReport(comparedTo: output).isSemanticallyLossless)
    }

    func testCameraRawUsesItsOwnSemanticDomainWhileRetainingUnknownFields() {
        var xmp = XMPData()
        xmp.setValue(.simple("1.25"), namespace: XMPNamespace.crs, property: "Exposure2012")
        xmp.setValue(.structure([
            "https://vendor.example/schema/Private": .simple("kept"),
        ]), namespace: XMPNamespace.crs, property: "VendorSettings")

        let metadata = ImageMetadata(format: .jpeg, xmp: xmp)
        let entries = metadata.semanticMetadata.keys.filter { $0.domain == .cameraRaw }
        XCTAssertEqual(entries.count, 2)
        XCTAssertFalse(metadata.semanticMetadata.keys.contains { $0.domain == .xmp && $0.path.contains("Exposure2012") })
    }

    func testIPTCRepeatOrderingDoesNotCreateAConflict() throws {
        let a = try IPTCDataSet(tag: .keywords, stringValue: "alpha")
        let b = try IPTCDataSet(tag: .keywords, stringValue: "beta")
        let source = ImageMetadata(format: .jpeg, iptc: IPTCData(datasets: [a, b]))
        let output = ImageMetadata(format: .tiff, iptc: IPTCData(datasets: [b, a]))

        XCTAssertTrue(source.preservationReport(comparedTo: output).isSemanticallyLossless)
    }

    func testC2PAMapAndAssertionReferenceOrderingAreCanonical() {
        let first = c2pa(
            raw: .map([
                .init(key: .textString("title"), value: .textString("Oslo")),
                .init(key: .textString("version"), value: .unsignedInt(2)),
            ]),
            references: [reference("b", byte: 2), reference("a", byte: 1)]
        )
        let second = c2pa(
            raw: .map([
                .init(key: .textString("version"), value: .unsignedInt(2)),
                .init(key: .textString("title"), value: .textString("Oslo")),
            ]),
            references: [reference("a", byte: 1), reference("b", byte: 2)]
        )

        let source = ImageMetadata(format: .jpeg, c2pa: first)
        let output = ImageMetadata(format: .png, c2pa: second)
        let report = source.preservationReport(comparedTo: output)
        XCTAssertTrue(report.isSemanticallyLossless)
        XCTAssertEqual(report.opaquePreserved.count, source.semanticMetadata.keys.filter { $0.domain == .c2pa }.count)
    }

    func testReportSeparatesChangedUnrepresentableAndOpaquePreservedValues() throws {
        let headline = try IPTCDataSet(tag: .headline, stringValue: "Source")
        let profile = ICCProfile(data: Data(repeating: 0, count: 128))!
        let source = ImageMetadata(
            format: .jpeg,
            iptc: IPTCData(datasets: [headline]),
            exif: .fixture(byteOrder: .bigEndian, orientationBytes: Data([0, 1])),
            iccProfile: profile
        )
        let output = ImageMetadata(
            format: .avif,
            exif: .fixture(byteOrder: .bigEndian, orientationBytes: Data([0, 8])),
            iccProfile: profile
        )

        let report = source.preservationReport(comparedTo: output)
        XCTAssertEqual(report.changed.map(\.identity.domain), [.exif])
        XCTAssertEqual(report.unrepresentable.map(\.identity.domain), [.iptcIIM])
        XCTAssertEqual(report.opaquePreserved.map(\.identity.domain), [.icc])
        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertFalse(report.isSemanticallyLossless)
    }

    private func reference(_ name: String, byte: UInt8) -> C2PAHashedURI {
        C2PAHashedURI(url: "self#\(name)", algorithm: "sha256", hash: Data(repeating: byte, count: 32))
    }

    private func c2pa(raw: CBORValue, references: [C2PAHashedURI]) -> C2PAData {
        let claim = C2PAClaim(
            claimGenerator: "tests",
            assertionReferences: references,
            raw: raw,
            rawCBORBytes: Data()
        )
        let signature = C2PASignature(signatureBytes: Data([1, 2, 3]))
        return C2PAData(manifests: [
            C2PAManifest(label: "urn:c2pa:test", claim: claim, signature: signature, assertions: []),
        ])
    }
}

private extension ExifData {
    static func fixture(
        byteOrder: ByteOrder,
        orientationBytes: Data,
        sourceOffset: Int? = nil
    ) -> ExifData {
        var exif = ExifData(byteOrder: byteOrder)
        exif.ifd0 = IFD(entries: [
            IFDEntry(
                tag: ExifTag.orientation,
                type: .short,
                count: 1,
                valueData: orientationBytes,
                sourceOffset: sourceOffset
            ),
            // Deliberately different carrier offsets are excluded from semantics.
            IFDEntry(tag: 0x0111, type: .long, count: 1, valueData: Data([0, 0, 0, 4])),
        ], nextIFDOffset: UInt32(sourceOffset ?? 0))
        return exif
    }
}
