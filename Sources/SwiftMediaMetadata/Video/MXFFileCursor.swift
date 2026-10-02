import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The MXF walk uses the same parser for caller-owned Data and files.
/// Offsets are relative to the input extent, including nonzero-index Data slices.
protocol MXFByteCursor {
    var offset: Int { get }
    var count: Int { get }
    var remainingCount: Int { get }
    mutating func readUInt8() throws -> UInt8
    mutating func readBytes(_ count: Int) throws -> Data
    func slice(from start: Int, count: Int) throws -> Data
    mutating func seek(to offset: Int) throws
}

extension BinaryReader: MXFByteCursor {}

/// No mapping, read-ahead, or essence cache. POSIX reads directly into the
/// bounded Data buffer, avoiding autoreleased FileHandle/NSData temporaries.
/// A captured extent constrains all arithmetic; truncation or growth observed
/// at completion is an error. Same-size concurrent writes are not detected.
final class MXFFileCursor: MXFByteCursor {
    private let handle: FileHandle
    let count: Int
    private(set) var offset = 0
    var remainingCount: Int { count - offset }

    // Internal instrumentation for focused tests; reports actual read requests.
    var onRead: ((Int, Int) -> Void)?

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        do {
            var status = stat()
            guard fstat(handle.fileDescriptor, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard status.st_size >= 0, UInt64(status.st_size) <= UInt64(Int.max) else {
                throw MetadataError.invalidVideo("MXF file extent exceeds supported range")
            }
            self.count = Int(status.st_size)
            self.handle = handle
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit { try? handle.close() }

    func validateExtent() throws {
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_size == count else {
            throw MetadataError.invalidVideo("MXF file extent changed during metadata read")
        }
    }

    func readUInt8() throws -> UInt8 {
        let value = try readBytes(1)
        return value[value.startIndex]
    }

    func readBytes(_ count: Int) throws -> Data {
        let value = try slice(from: offset, count: count)
        offset += count
        return value
    }

    func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= count else {
            throw MetadataError.unexpectedEndOfData
        }
        offset = newOffset
    }

    func slice(from start: Int, count length: Int) throws -> Data {
        guard start >= 0, length >= 0, start <= count, length <= count - start else {
            throw MetadataError.unexpectedEndOfData
        }
        guard length > 0 else { return Data() }
        var result = Data(count: length)
        try result.withUnsafeMutableBytes { bytes in
            var completed = 0
            while completed < length {
                onRead?(start + completed, length - completed)
                let received = pread(handle.fileDescriptor,
                                     bytes.baseAddress!.advanced(by: completed),
                                     length - completed, off_t(start + completed))
                if received < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard received > 0 else {
                    throw MetadataError.unexpectedEndOfData
                }
                completed += received
            }
        }
        return result
    }
}
