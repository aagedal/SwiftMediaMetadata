import XCTest
@testable import SwiftExif

final class XMPSidecarSyncTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Embed Sidecar

    func testEmbedSidecarIntoImage() throws {
        // Create sidecar with XMP data
        var sidecarXMP = XMPData()
        sidecarXMP.title = "From Sidecar"
        sidecarXMP.setValue(.simple("Stockholm"), namespace: XMPNamespace.photoshop, property: "City")

        let sidecarURL = tempDir.appendingPathComponent("photo.xmp")
        try XMPSidecar.write(sidecarXMP, to: sidecarURL)

        // Create image with no XMP
        let jpeg = TestFixtures.minimalJPEG()
        var metadata = try ImageMetadata.read(from: jpeg)
        XCTAssertNil(metadata.xmp)

        // Embed
        try metadata.embedSidecar(from: sidecarURL)

        XCTAssertNotNil(metadata.xmp)
        XCTAssertEqual(metadata.xmp?.title, "From Sidecar")
    }

    func testEmbedSidecarOverwritesConflicts() throws {
        var sidecarXMP = XMPData()
        sidecarXMP.title = "Sidecar Title"

        let sidecarURL = tempDir.appendingPathComponent("photo.xmp")
        try XMPSidecar.write(sidecarXMP, to: sidecarURL)

        let jpeg = TestFixtures.minimalJPEG()
        var metadata = try ImageMetadata.read(from: jpeg)
        metadata.xmp = XMPData()
        metadata.xmp?.title = "Embedded Title"

        try metadata.embedSidecar(from: sidecarURL)

        XCTAssertEqual(metadata.xmp?.title, "Sidecar Title") // Sidecar wins
    }

    // MARK: - Compare Sidecar

    func testCompareSidecarIdentical() throws {
        var xmp = XMPData()
        xmp.title = "Same"

        let sidecarURL = tempDir.appendingPathComponent("photo.xmp")
        try XMPSidecar.write(xmp, to: sidecarURL)

        let jpeg = TestFixtures.minimalJPEG()
        var metadata = try ImageMetadata.read(from: jpeg)
        metadata.xmp = xmp

        let report = try metadata.compareSidecar(at: sidecarURL)

        XCTAssertFalse(report.hasDifferences)
        XCTAssertGreaterThan(report.matching, 0)
    }

    func testCompareSidecarWithDifferences() throws {
        var sidecarXMP = XMPData()
        sidecarXMP.title = "Sidecar"

        let sidecarURL = tempDir.appendingPathComponent("photo.xmp")
        try XMPSidecar.write(sidecarXMP, to: sidecarURL)

        var embeddedXMP = XMPData()
        embeddedXMP.title = "Embedded"

        let jpeg = TestFixtures.minimalJPEG()
        var metadata = try ImageMetadata.read(from: jpeg)
        metadata.xmp = embeddedXMP

        let report = try metadata.compareSidecar(at: sidecarURL)

        XCTAssertTrue(report.hasDifferences)
        XCTAssertFalse(report.conflicts.isEmpty)
    }

    func testCompareSidecarOnlyKeys() throws {
        var sidecarXMP = XMPData()
        sidecarXMP.title = "Title"
        sidecarXMP.setValue(.simple("Oslo"), namespace: XMPNamespace.photoshop, property: "City")

        let sidecarURL = tempDir.appendingPathComponent("photo.xmp")
        try XMPSidecar.write(sidecarXMP, to: sidecarURL)

        let jpeg = TestFixtures.minimalJPEG()
        var metadata = try ImageMetadata.read(from: jpeg)
        metadata.xmp = XMPData()
        metadata.xmp?.title = "Title" // Same

        let report = try metadata.compareSidecar(at: sidecarURL)

        XCTAssertTrue(report.hasDifferences)
        XCTAssertFalse(report.sidecarOnly.isEmpty) // City only in sidecar
    }

    // MARK: - Sync

    func testSyncSidecarToImage() throws {
        var sidecarXMP = XMPData()
        sidecarXMP.title = "Synced"

        let sidecarURL = tempDir.appendingPathComponent("photo.xmp")
        try XMPSidecar.write(sidecarXMP, to: sidecarURL)

        let jpeg = TestFixtures.minimalJPEG()
        var metadata = try ImageMetadata.read(from: jpeg)

        try metadata.syncWithSidecar(at: sidecarURL, direction: .sidecarToImage)

        XCTAssertEqual(metadata.xmp?.title, "Synced")
    }

    func testSyncImageToSidecar() throws {
        let sidecarURL = tempDir.appendingPathComponent("photo.xmp")
        // Write empty sidecar first
        try XMPSidecar.write(XMPData(), to: sidecarURL)

        let jpeg = TestFixtures.minimalJPEG()
        var metadata = try ImageMetadata.read(from: jpeg)
        metadata.xmp = XMPData()
        metadata.xmp?.title = "From Image"

        try metadata.syncWithSidecar(at: sidecarURL, direction: .imageToSidecar)

        // Read back sidecar
        let readBack = try XMPSidecar.read(from: sidecarURL)
        XCTAssertEqual(readBack.title, "From Image")
    }

    // MARK: - Orphan Detection

    func testFindOrphans() throws {
        // Create image + sidecar pair
        let imageURL = tempDir.appendingPathComponent("photo.jpg")
        try TestFixtures.minimalJPEG().write(to: imageURL)
        let validSidecar = tempDir.appendingPathComponent("photo.xmp")
        try XMPSidecar.write(XMPData(), to: validSidecar)

        // Create orphan sidecar (no matching image)
        let orphanSidecar = tempDir.appendingPathComponent("deleted.xmp")
        try XMPSidecar.write(XMPData(), to: orphanSidecar)

        let orphans = try XMPSidecarSync.findOrphans(in: tempDir)

        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.lastPathComponent, "deleted.xmp")
    }

    func testNoOrphans() throws {
        let imageURL = tempDir.appendingPathComponent("photo.jpg")
        try TestFixtures.minimalJPEG().write(to: imageURL)
        let sidecar = tempDir.appendingPathComponent("photo.xmp")
        try XMPSidecar.write(XMPData(), to: sidecar)

        let orphans = try XMPSidecarSync.findOrphans(in: tempDir)
        XCTAssertTrue(orphans.isEmpty)
    }

    func testCleanupOrphansDryRun() throws {
        let orphanSidecar = tempDir.appendingPathComponent("orphan.xmp")
        try XMPSidecar.write(XMPData(), to: orphanSidecar)

        let result = try XMPSidecarSync.cleanupOrphans(in: tempDir, dryRun: true)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanSidecar.path)) // Not deleted
    }

    func testCleanupOrphansDelete() throws {
        let orphanSidecar = tempDir.appendingPathComponent("orphan.xmp")
        try XMPSidecar.write(XMPData(), to: orphanSidecar)

        let result = try XMPSidecarSync.cleanupOrphans(in: tempDir, dryRun: false)
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanSidecar.path)) // Deleted
    }
}
