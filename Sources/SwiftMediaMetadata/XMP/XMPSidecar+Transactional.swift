import Foundation

/// A content-based revision of an XMP sidecar.
///
/// Revisions use the exact installed bytes rather than filesystem timestamps,
/// which can have coarse precision or be deliberately preserved by write
/// options. Identical bytes intentionally have the same revision even when a
/// file has been atomically replaced.
public enum XMPSidecarRevision: Equatable, Hashable, Sendable {
    /// No sidecar exists at the requested URL.
    case missing

    /// The SHA-256 digest and byte count of an installed sidecar packet.
    case content(sha256: String, byteCount: Int)
}

/// XMP data and the exact disk revision from which it was parsed.
public struct XMPSidecarSnapshot: Equatable, Sendable {
    public let xmpData: XMPData
    public let revision: XMPSidecarRevision

    public init(xmpData: XMPData, revision: XMPSidecarRevision) {
        self.xmpData = xmpData
        self.revision = revision
    }
}

/// The installed state returned by a transactional sidecar update.
public struct XMPSidecarUpdateResult: Equatable, Sendable {
    public let output: URL
    public let xmpData: XMPData
    public let revision: XMPSidecarRevision
    public let warnings: [String]

    /// Number of read/mutate/compare attempts. A value greater than one means
    /// the mutation was reapplied to a newer sidecar after a revision race.
    public let attempts: Int

    public init(
        output: URL,
        xmpData: XMPData,
        revision: XMPSidecarRevision,
        warnings: [String] = [],
        attempts: Int
    ) {
        self.output = output
        self.xmpData = xmpData
        self.revision = revision
        self.warnings = warnings
        self.attempts = attempts
    }
}

/// Transaction-specific failures from `XMPSidecar.update`.
public enum XMPSidecarUpdateError: Error, Equatable, Sendable, LocalizedError {
    /// The caller's base revision was no longer installed before mutation began,
    /// or another writer won a race when retries were disabled.
    case staleRevision(expected: XMPSidecarRevision, actual: XMPSidecarRevision)

    /// Another writer won every compare-and-commit race in the retry budget.
    case retryLimitExceeded(attempts: Int, lastObserved: XMPSidecarRevision)

    /// Retry counts must be nonnegative and leave room for the initial attempt.
    case invalidRetryLimit(Int)

    /// The packet generated from the mutation was not valid XMP XML.
    case invalidSerializedPacket(String)

    public var errorDescription: String? {
        switch self {
        case .staleRevision(let expected, let actual):
            return "The XMP sidecar revision is stale (expected \(expected), found \(actual))"
        case .retryLimitExceeded(let attempts, let lastObserved):
            return "The XMP sidecar changed during all \(attempts) update attempts (last revision: \(lastObserved))"
        case .invalidRetryLimit(let count):
            return "The XMP sidecar retry limit must be between zero and Int.max - 1 (received \(count))"
        case .invalidSerializedPacket(let detail):
            return "The updated XMP sidecar packet is invalid: \(detail)"
        }
    }
}

public extension XMPSidecar {
    /// Return a content revision for the current sidecar, or `.missing` when no
    /// file exists. This does not parse the packet.
    static func revision(of url: URL) throws -> XMPSidecarRevision {
        try loadDiskState(from: url, parseXMP: false).revision
    }

    /// Read XMP together with the content revision of the exact bytes parsed.
    static func readSnapshot(from url: URL) throws -> XMPSidecarSnapshot {
        let state = try loadDiskState(from: url, parseXMP: true)
        guard let xmpData = state.xmpData else {
            throw MetadataError.fileNotFound(url.path)
        }
        return XMPSidecarSnapshot(xmpData: xmpData, revision: state.revision)
    }

    /// Transactionally mutate the latest XMP sidecar state.
    ///
    /// When `expectedRevision` is supplied, the first disk read must match it;
    /// use `.missing` to create a sidecar only when none exists. If another
    /// cooperating writer commits after a mutation begins, the mutation is
    /// reapplied to the newer state up to `maximumRetries` times. The mutation
    /// closure must therefore be safe to invoke more than once. No bytes are
    /// committed when the closure throws or packet validation fails.
    ///
    /// The final compare, filesystem commit, and read-back occur under the same
    /// cross-process directory lock. Existing `XMPSidecar.write` calls use that
    /// lock as well; writers outside this API cannot be made cooperative.
    static func update(
        at url: URL,
        expectedRevision: XMPSidecarRevision? = nil,
        maximumRetries: Int = 0,
        options: ImageMetadata.WriteOptions = .default,
        mutation: (inout XMPData) throws -> Void
    ) throws -> XMPSidecarUpdateResult {
        guard maximumRetries >= 0, maximumRetries < Int.max else {
            throw XMPSidecarUpdateError.invalidRetryLimit(maximumRetries)
        }

        let maximumAttempts = maximumRetries + 1
        for attempt in 1...maximumAttempts {
            let base = try loadDiskState(from: url, parseXMP: true)

            if attempt == 1, let expectedRevision, base.revision != expectedRevision {
                throw XMPSidecarUpdateError.staleRevision(
                    expected: expectedRevision,
                    actual: base.revision
                )
            }

            var updatedXMP = base.xmpData ?? XMPData()
            try mutation(&updatedXMP)

            let serializedResult = try serialized(updatedXMP)
            try validateSerializedPacket(serializedResult.output)

            var observedRevision = base.revision
            let committed: XMPSidecarUpdateResult? = try XMPSidecarTransactionLock.withLock(for: url) {
                let currentRevision = try loadDiskState(from: url, parseXMP: false).revision
                guard currentRevision == base.revision else {
                    observedRevision = currentRevision
                    return nil
                }

                let output = try FileCommitter.commit(
                    serializedResult.output,
                    to: url,
                    options: options
                )

                // Read back while still holding the transaction lock so the
                // result describes the exact revision installed by this call.
                let installed = try loadDiskState(from: url, parseXMP: true)
                guard let installedXMP = installed.xmpData else {
                    throw XMPSidecarUpdateError.invalidSerializedPacket(
                        "the committed file could not be read back"
                    )
                }
                return XMPSidecarUpdateResult(
                    output: output,
                    xmpData: installedXMP,
                    revision: installed.revision,
                    warnings: serializedResult.warnings,
                    attempts: attempt
                )
            }

            if let committed { return committed }

            if attempt == maximumAttempts {
                if maximumRetries == 0 {
                    throw XMPSidecarUpdateError.staleRevision(
                        expected: base.revision,
                        actual: observedRevision
                    )
                }
                throw XMPSidecarUpdateError.retryLimitExceeded(
                    attempts: maximumAttempts,
                    lastObserved: observedRevision
                )
            }
        }

        // The non-empty closed range above always returns or throws.
        throw XMPSidecarUpdateError.retryLimitExceeded(
            attempts: maximumAttempts,
            lastObserved: .missing
        )
    }
}

private extension XMPSidecar {
    struct DiskState {
        let revision: XMPSidecarRevision
        let xmpData: XMPData?
    }

    static func loadDiskState(from url: URL, parseXMP: Bool) throws -> DiskState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DiskState(revision: .missing, xmpData: nil)
        }

        let data = try Data(contentsOf: url)
        let revision = XMPSidecarRevision.content(
            sha256: FileHasher.sha256(data),
            byteCount: data.count
        )
        let xmpData = parseXMP ? try XMPReader.readFromXML(data) : nil
        return DiskState(revision: revision, xmpData: xmpData)
    }

    static func validateSerializedPacket(_ data: Data) throws {
        guard let xml = String(data: data, encoding: .utf8) else {
            throw XMPSidecarUpdateError.invalidSerializedPacket("packet is not UTF-8")
        }

        // XML 1.0 permits tab, LF, CR, and the scalar ranges below. The pure
        // tokenizer intentionally accepts a broad input language, so enforce
        // this wire-level constraint before relying on a parse round trip.
        if let invalid = xml.unicodeScalars.first(where: { scalar in
            let value = scalar.value
            return value != 0x09 && value != 0x0A && value != 0x0D
                && !(0x20...0xD7FF).contains(value)
                && !(0xE000...0xFFFD).contains(value)
                && !(0x10000...0x10FFFF).contains(value)
        }) {
            throw XMPSidecarUpdateError.invalidSerializedPacket(
                "disallowed XML scalar U+\(String(invalid.value, radix: 16, uppercase: true))"
            )
        }

        do {
            _ = try XMPReader.readFromXML(data)
        } catch {
            throw XMPSidecarUpdateError.invalidSerializedPacket(error.localizedDescription)
        }
    }
}
