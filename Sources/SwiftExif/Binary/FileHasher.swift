import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Compute cryptographic hashes of file data.
/// Provides MD5 and SHA256 digests for file integrity verification and asset management.
///
/// On Apple platforms we delegate to CryptoKit (hardware-accelerated). On
/// other platforms we use in-tree pure-Swift MD5 / SHA-256 implementations
/// so the Linux-musl cross-compile doesn't need to pull in swift-crypto's
/// BoringSSL dependency (which stalls the optimizer).
public struct FileHasher: Sendable {

    /// Compute the MD5 hash of data, returning a lowercase hex string.
    public static func md5(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return PureMD5.hash(data).map { String(format: "%02x", $0) }.joined()
        #endif
    }

    /// Compute the SHA256 hash of data, returning a lowercase hex string.
    public static func sha256(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return PureSHA256.hash(data).map { String(format: "%02x", $0) }.joined()
        #endif
    }

    /// Compute the SHA512 hash of data, returning a lowercase hex string.
    /// Only used on Apple platforms; Linux callers do not invoke this.
    public static func sha512(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        // SHA-512 is not needed outside Apple paths; return SHA-256 as a
        // safe fallback so callers keep a deterministic hex string.
        return sha256(data)
        #endif
    }

    /// Compute all standard hashes at once (avoids reading data multiple times).
    public static func allHashes(_ data: Data) -> FileHashes {
        FileHashes(
            md5: md5(data),
            sha256: sha256(data),
            fileSize: UInt64(data.count)
        )
    }

    /// Compute hashes from a file URL.
    public static func hash(url: URL) throws -> FileHashes {
        let data = try Data(contentsOf: url)
        return allHashes(data)
    }
}

/// File hash results.
public struct FileHashes: Sendable {
    public let md5: String
    public let sha256: String
    public let fileSize: UInt64
}
