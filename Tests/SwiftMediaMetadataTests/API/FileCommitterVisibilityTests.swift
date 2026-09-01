import XCTest
@testable import SwiftMediaMetadata

final class FileCommitterVisibilityTests: XCTestCase {
    func testAtomicImageRewritePreservesDestinationVisibility() throws {
        let url = temporaryURL(extension: "jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestFixtures.minimalJPEG().write(to: url)
        let metadata = try ImageMetadata.read(from: url)

        try setHidden(false, at: url)
        _ = try metadata.write(to: url)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isHiddenKey]).isHidden, false)

        try setHidden(true, at: url)
        _ = try metadata.write(to: url)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)
    }

    func testAtomicCommitPreservesVisibleDestination() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("original".utf8).write(to: url)
        try setHidden(false, at: url)

        try FileCommitter.commit(Data("updated".utf8), to: url, options: .default)

        XCTAssertEqual(try url.resourceValues(forKeys: [.isHiddenKey]).isHidden, false)
    }

    func testAtomicCommitPreservesHiddenDestination() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("original".utf8).write(to: url)
        try setHidden(true, at: url)

        try FileCommitter.commit(Data("updated".utf8), to: url, options: .default)

        XCTAssertEqual(try url.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)
    }

    func testAtomicCommitCreatesVisibleNonDotDestination() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try FileCommitter.commit(Data("new".utf8), to: url, options: .default)

        XCTAssertEqual(try url.resourceValues(forKeys: [.isHiddenKey]).isHidden, false)
    }

    private func temporaryURL(extension pathExtension: String = "dat") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-visibility-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    private func setHidden(_ isHidden: Bool, at url: URL) throws {
        var values = URLResourceValues()
        values.isHidden = isHidden
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}
