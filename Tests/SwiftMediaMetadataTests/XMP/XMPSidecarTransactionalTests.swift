import Foundation
import XCTest
import SwiftMediaMetadata

final class XMPSidecarTransactionalTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmp-transaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testRevisionUsesExactContentAndSnapshotMatchesParsedBytes() throws {
        let url = sidecarURL()
        XCTAssertEqual(try XMPSidecar.revision(of: url), .missing)

        var xmp = XMPData()
        xmp.headline = "First"
        try XMPSidecar.write(xmp, to: url)

        let snapshot = try XMPSidecar.readSnapshot(from: url)
        XCTAssertEqual(snapshot.xmpData.headline, "First")
        XCTAssertEqual(snapshot.revision, try XMPSidecar.revision(of: url))

        let preservedDate = Date(timeIntervalSince1970: 1_577_930_645)
        try FileManager.default.setAttributes(
            [.modificationDate: preservedDate],
            ofItemAtPath: url.path
        )
        let firstRevision = snapshot.revision

        xmp.headline = "Second"
        try XMPSidecar.write(
            xmp,
            to: url,
            options: .init(fileModificationDate: .preserveExisting)
        )

        XCTAssertNotEqual(try XMPSidecar.revision(of: url), firstRevision)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let writtenDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertEqual(
            writtenDate.timeIntervalSince1970,
            preservedDate.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testUpdateCreatesFromMissingRevisionAndReadsBackInstalledState() throws {
        let url = sidecarURL()

        let result = try XMPSidecar.update(
            at: url,
            expectedRevision: .missing
        ) { xmp in
            xmp.headline = "Created transactionally"
        }

        XCTAssertEqual(result.output, url)
        XCTAssertEqual(result.xmpData.headline, "Created transactionally")
        XCTAssertEqual(result.revision, try XMPSidecar.revision(of: url))
        XCTAssertEqual(result.attempts, 1)
        XCTAssertEqual(result.warnings, [])
    }

    func testStaleBaseRevisionNeverOverwritesNewerWriter() throws {
        let url = sidecarURL()
        var original = XMPData()
        original.headline = "Original"
        try XMPSidecar.write(original, to: url)
        let firstWriter = try XMPSidecar.readSnapshot(from: url)

        _ = try XMPSidecar.update(
            at: url,
            expectedRevision: firstWriter.revision
        ) { xmp in
            xmp.headline = "Newer writer"
        }

        XCTAssertThrowsError(
            try XMPSidecar.update(
                at: url,
                expectedRevision: firstWriter.revision
            ) { xmp in
                xmp.headline = "Stale writer"
            }
        ) { error in
            guard case XMPSidecarUpdateError.staleRevision(
                expected: firstWriter.revision,
                actual: let actual
            ) = error else {
                return XCTFail("Expected staleRevision, got \(error)")
            }
            XCTAssertNotEqual(actual, firstWriter.revision)
        }

        XCTAssertEqual(try XMPSidecar.read(from: url).headline, "Newer writer")
    }

    func testConcurrentWritersRetryAndPreserveBothMutations() throws {
        let url = sidecarURL()
        var original = XMPData()
        original.setValue(
            .simple("retained"),
            namespace: "https://example.com/vendor/1.0/",
            property: "PrivateField"
        )
        try XMPSidecar.write(original, to: url)
        let baseRevision = try XMPSidecar.revision(of: url)

        let firstReady = DispatchSemaphore(value: 0)
        let secondReady = DispatchSemaphore(value: 0)
        let results = LockedBox<[Result<XMPSidecarUpdateResult, Error>]>([])
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "XMPSidecarTransactionalTests.writers",
            attributes: .concurrent
        )

        group.enter()
        queue.async {
            defer { group.leave() }
            var firstInvocation = true
            let result = Result {
                try XMPSidecar.update(
                    at: url,
                    expectedRevision: baseRevision,
                    maximumRetries: 1
                ) { xmp in
                    if firstInvocation {
                        firstInvocation = false
                        firstReady.signal()
                        guard secondReady.wait(timeout: .now() + 5) == .success else {
                            throw TestFailure.timedOut
                        }
                    }
                    xmp.headline = "Writer one"
                }
            }
            results.withValue { $0.append(result) }
        }

        group.enter()
        queue.async {
            defer { group.leave() }
            var firstInvocation = true
            let result = Result {
                try XMPSidecar.update(
                    at: url,
                    expectedRevision: baseRevision,
                    maximumRetries: 1
                ) { xmp in
                    if firstInvocation {
                        firstInvocation = false
                        secondReady.signal()
                        guard firstReady.wait(timeout: .now() + 5) == .success else {
                            throw TestFailure.timedOut
                        }
                    }
                    xmp.city = "Writer two"
                }
            }
            results.withValue { $0.append(result) }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        let outcomes = results.value
        XCTAssertEqual(outcomes.count, 2)
        let updates = try outcomes.map { try $0.get() }
        XCTAssertEqual(updates.map(\.attempts).sorted(), [1, 2])

        let installed = try XMPSidecar.read(from: url)
        XCTAssertEqual(installed.headline, "Writer one")
        XCTAssertEqual(installed.city, "Writer two")
        XCTAssertEqual(
            installed.simpleValue(
                namespace: "https://example.com/vendor/1.0/",
                property: "PrivateField"
            ),
            "retained"
        )
    }

    func testRetryLimitExhaustionLeavesLastCompetingRevisionInstalled() throws {
        let url = sidecarURL()
        var original = XMPData()
        original.headline = "Original"
        try XMPSidecar.write(original, to: url)
        let competingWrites = LockedBox(0)

        XCTAssertThrowsError(
            try XMPSidecar.update(at: url, maximumRetries: 2) { candidate in
                let number = competingWrites.withValue { value -> Int in
                    value += 1
                    return value
                }
                var competitor = candidate
                competitor.city = "Competitor \(number)"
                try XMPSidecar.write(competitor, to: url)
                candidate.headline = "Never installed"
            }
        ) { error in
            guard case XMPSidecarUpdateError.retryLimitExceeded(
                attempts: 3,
                lastObserved: let revision
            ) = error else {
                return XCTFail("Expected retryLimitExceeded, got \(error)")
            }
            XCTAssertEqual(revision, try? XMPSidecar.revision(of: url))
        }

        let installed = try XMPSidecar.read(from: url)
        XCTAssertEqual(installed.headline, "Original")
        XCTAssertEqual(installed.city, "Competitor 3")
    }

    func testMutationFailureAndInvalidPacketLeaveOriginalRevisionUntouched() throws {
        let url = sidecarURL()
        var original = XMPData()
        original.headline = "Original"
        try XMPSidecar.write(original, to: url)
        let originalRevision = try XMPSidecar.revision(of: url)

        XCTAssertThrowsError(try XMPSidecar.update(at: url) { _ in
            throw TestFailure.mutationFailed
        }) { error in
            XCTAssertEqual(error as? TestFailure, .mutationFailed)
        }
        XCTAssertEqual(try XMPSidecar.revision(of: url), originalRevision)

        XCTAssertThrowsError(try XMPSidecar.update(at: url) { xmp in
            xmp.headline = String(UnicodeScalar(0xFFFE)!)
        }) { error in
            guard case XMPSidecarUpdateError.invalidSerializedPacket = error else {
                return XCTFail("Expected invalidSerializedPacket, got \(error)")
            }
        }
        XCTAssertEqual(try XMPSidecar.revision(of: url), originalRevision)
        XCTAssertEqual(try XMPSidecar.read(from: url).headline, "Original")
    }

    func testUpdateForwardsBackupAndTimestampOptionsForAtomicAndDirectWrites() throws {
        for atomic in [true, false] {
            let url = sidecarURL(name: atomic ? "atomic" : "direct")
            var xmp = XMPData()
            xmp.headline = "Original"
            try XMPSidecar.write(xmp, to: url)

            let originalDate = Date(timeIntervalSince1970: 1_577_930_645.25)
            try FileManager.default.setAttributes(
                [.modificationDate: originalDate],
                ofItemAtPath: url.path
            )
            let options = ImageMetadata.WriteOptions(
                atomic: atomic,
                createBackup: true,
                backupSuffix: ".bak",
                fileModificationDate: .preserveExisting
            )

            _ = try XMPSidecar.update(at: url, options: options) { updated in
                updated.headline = "Updated"
            }

            let backupURL = ImageMetadata.backupURL(for: url, suffix: ".bak")
            XCTAssertEqual(try XMPSidecar.read(from: backupURL).headline, "Original")
            XCTAssertEqual(try XMPSidecar.read(from: url).headline, "Updated")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let writtenDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
            XCTAssertEqual(
                writtenDate.timeIntervalSince1970,
                originalDate.timeIntervalSince1970,
                accuracy: 0.001
            )
        }
    }

    func testFailedCommitDoesNotLeaveAtomicStagingFiles() throws {
        #if os(macOS) || os(Linux)
        let url = sidecarURL()
        var xmp = XMPData()
        xmp.headline = "Original"
        try XMPSidecar.write(xmp, to: url)
        let originalRevision = try XMPSidecar.revision(of: url)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: temporaryDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: temporaryDirectory.path
            )
        }

        XCTAssertThrowsError(try XMPSidecar.update(at: url) { updated in
            updated.headline = "Must not install"
        })
        XCTAssertEqual(try XMPSidecar.revision(of: url), originalRevision)

        let names = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".swiftmediametadata_tmp_") })
        #endif
    }

    private func sidecarURL(name: String = "metadata") -> URL {
        temporaryDirectory.appendingPathComponent(name).appendingPathExtension("xmp")
    }
}

private enum TestFailure: Error, Equatable {
    case mutationFailed
    case timedOut
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func withValue<Result>(_ operation: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try operation(&storage) }
    }
}
