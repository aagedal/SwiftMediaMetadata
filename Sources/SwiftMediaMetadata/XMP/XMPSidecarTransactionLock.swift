import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Serializes sidecar compare-and-commit sections across cooperating processes.
///
/// Locking the containing directory avoids a lock-file lifecycle race: removing
/// a lock file while another process is waiting on its old inode can otherwise
/// let a third process enter through a newly-created inode. The directory inode
/// remains stable while sidecar files are atomically replaced.
enum XMPSidecarTransactionLock {
    static func withLock<Result>(
        for sidecarURL: URL,
        _ operation: () throws -> Result
    ) throws -> Result {
        #if canImport(Darwin) || canImport(Glibc)
        let directoryPath = sidecarURL.deletingLastPathComponent().path
        let descriptor = open(directoryPath, O_RDONLY)
        guard descriptor >= 0 else {
            throw MetadataError.fileWriteError(
                "Unable to open sidecar directory for locking: \(systemErrorDescription())"
            )
        }
        defer { _ = close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw MetadataError.fileWriteError(
                "Unable to lock sidecar directory: \(systemErrorDescription())"
            )
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        return try operation()
        #else
        // Supported package platforms provide flock. Keep a fallback so the
        // pure-Swift library remains compilable on unusual Foundation ports.
        return try operation()
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    private static func systemErrorDescription() -> String {
        String(cString: strerror(errno))
    }
    #endif
}
