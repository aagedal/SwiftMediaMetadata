import Foundation
import CryptoKit

/// Compute cryptographic hashes of file data.
/// Provides MD5 and SHA256 digests for file integrity verification and asset management.
public struct FileHasher: Sendable {

    /// Compute the MD5 hash of data, returning a lowercase hex string.
    public static func md5(_ data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Compute the SHA256 hash of data, returning a lowercase hex string.
    public static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Compute the SHA512 hash of data, returning a lowercase hex string.
    public static func sha512(_ data: Data) -> String {
        let digest = SHA512.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
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
