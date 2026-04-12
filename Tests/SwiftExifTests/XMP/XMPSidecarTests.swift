import XCTest
@testable import SwiftExif

final class XMPSidecarTests: XCTestCase {

    func testSidecarURL() {
        let imageURL = URL(fileURLWithPath: "/photos/IMG_001.cr2")
        let sidecarURL = XMPSidecar.sidecarURL(for: imageURL)
        XCTAssertEqual(sidecarURL.path, "/photos/IMG_001.xmp")
    }

    func testSidecarURLForJPEG() {
        let imageURL = URL(fileURLWithPath: "/photos/DSC_1234.jpg")
        let sidecarURL = XMPSidecar.sidecarURL(for: imageURL)
        XCTAssertEqual(sidecarURL.path, "/photos/DSC_1234.xmp")
    }

    func testWriteAndReadSidecar() throws {
        var xmp = XMPData()
        xmp.headline = "Sidecar Test"
        xmp.city = "Tromsø"
        xmp.subject = ["news", "test"]
        xmp.rights = "© 2026 Photographer"

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID()).xmp")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try XMPSidecar.write(xmp, to: tempURL)

        let readBack = try XMPSidecar.read(from: tempURL)

        XCTAssertEqual(readBack.headline, "Sidecar Test")
        XCTAssertEqual(readBack.city, "Tromsø")
        XCTAssertEqual(readBack.subject, ["news", "test"])
        XCTAssertEqual(readBack.rights, "© 2026 Photographer")
    }

    func testWriteSidecarFromImageMetadata() throws {
        let jpeg = TestFixtures.minimalJPEG()
        var metadata = try ImageMetadata.read(from: jpeg)

        metadata.iptc.headline = "Metadata Sidecar"
        metadata.iptc.city = "Oslo"
        metadata.syncIPTCToXMP()

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID()).xmp")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try metadata.writeSidecar(to: tempURL)

        let readBack = try XMPSidecar.read(from: tempURL)
        XCTAssertEqual(readBack.headline, "Metadata Sidecar")
        XCTAssertEqual(readBack.city, "Oslo")
    }

    func testReadNonExistentSidecarThrows() {
        let url = URL(fileURLWithPath: "/nonexistent/file.xmp")
        XCTAssertThrowsError(try XMPSidecar.read(from: url)) { error in
            guard let metaError = error as? MetadataError,
                  case .fileNotFound = metaError else {
                XCTFail("Expected fileNotFound error")
                return
            }
        }
    }

    func testWriteSidecarWithNoXMPThrows() throws {
        let jpeg = TestFixtures.minimalJPEG()
        let metadata = try ImageMetadata.read(from: jpeg)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID()).xmp")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        XCTAssertThrowsError(try metadata.writeSidecar(to: tempURL)) { error in
            guard let metaError = error as? MetadataError,
                  case .writeNotSupported = metaError else {
                XCTFail("Expected writeNotSupported error")
                return
            }
        }
    }

    func testNordicCharactersInSidecar() throws {
        var xmp = XMPData()
        xmp.headline = "Sterk nordavind i Tromsø"
        xmp.creator = ["Bjørn Ødegård"]
        xmp.description = "Kraftig nordavind førte til store bølger"

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID()).xmp")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try XMPSidecar.write(xmp, to: tempURL)
        let readBack = try XMPSidecar.read(from: tempURL)

        XCTAssertEqual(readBack.headline, "Sterk nordavind i Tromsø")
        XCTAssertEqual(readBack.creator, ["Bjørn Ødegård"])
        XCTAssertEqual(readBack.description, "Kraftig nordavind førte til store bølger")
    }
}
