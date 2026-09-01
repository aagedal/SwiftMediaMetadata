import XCTest
@testable import SwiftMediaMetadata

final class MetadataWriteResultTests: XCTestCase {
    func testImageSerializationMatchesCompatibilityAPIsAndCarriesWarnings() throws {
        var iptc = IPTCData()
        iptc.byline = "Alessandro Bremec / ipa-agency.net"
        let metadata = try ImageMetadata.read(from: TestFixtures.jpegWithIPTC(datasets: iptc.datasets))

        let result = try metadata.serialized()
        let legacy = try metadata.writeToDataWithWarnings()

        XCTAssertEqual(result.output, legacy.data)
        XCTAssertEqual(result.warnings, legacy.warnings)
        XCTAssertTrue(result.warnings.contains { $0.contains("By-line") })
    }

    func testImageWriteResultReportsDestinationAndWarnings() throws {
        var iptc = IPTCData()
        iptc.byline = "Alessandro Bremec / ipa-agency.net"
        let metadata = try ImageMetadata.read(from: TestFixtures.jpegWithIPTC(datasets: iptc.datasets))
        let destination = temporaryURL(extension: "jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        let result = try metadata.writeResult(to: destination)

        XCTAssertEqual(result.output, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(result.warnings.contains { $0.contains("By-line") })
    }

    func testXMPSidecarUsesSameSerializationAndWriteResultShape() throws {
        var xmp = XMPData()
        xmp.headline = "Unified result"
        let destination = temporaryURL(extension: "xmp")
        defer { try? FileManager.default.removeItem(at: destination) }

        let serialized = try XMPSidecar.serialized(xmp)
        let written = try XMPSidecar.writeResult(xmp, to: destination)

        XCTAssertFalse(serialized.output.isEmpty)
        XCTAssertTrue(serialized.warnings.isEmpty)
        XCTAssertEqual(written.output, destination)
        XCTAssertTrue(written.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), serialized.output)
    }

    func testImageSidecarAndBatchReturnWriteResults() throws {
        var metadata = try ImageMetadata.read(from: TestFixtures.minimalJPEG())
        metadata.xmp = XMPData()
        metadata.xmp?.headline = "Sidecar result"
        let sidecarURL = temporaryURL(extension: "xmp")
        defer { try? FileManager.default.removeItem(at: sidecarURL) }

        let sidecarResult = try metadata.writeSidecarResult(to: sidecarURL)
        XCTAssertEqual(sidecarResult.output, sidecarURL)

        let imageURL = temporaryURL(extension: "jpg")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        try TestFixtures.minimalJPEG().write(to: imageURL)
        let batchResult = try BatchProcessor.processResult(file: imageURL) {
            $0.iptc.headline = "Batch result"
        }

        XCTAssertEqual(batchResult.output, imageURL)
        XCTAssertEqual(try ImageMetadata.read(from: imageURL).iptc.headline, "Batch result")
    }

    func testAudioAndVideoExposeTheCommonSerializationContract() {
        XCTAssertThrowsError(try AudioMetadata(format: .mp3).serialized())
        XCTAssertThrowsError(try VideoMetadata(format: .mp4).serialized())
    }

    private func temporaryURL(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-write-result-\(UUID())")
            .appendingPathExtension(pathExtension)
    }
}
