import Foundation

/// Result of a batch processing operation.
public struct BatchResult: Sendable {
    public let succeeded: Int
    public let failed: [(url: URL, error: any Error)]
    public let totalTime: TimeInterval

    public init(succeeded: Int, failed: [(url: URL, error: any Error)], totalTime: TimeInterval) {
        self.succeeded = succeeded
        self.failed = failed
        self.totalTime = totalTime
    }

    public var totalProcessed: Int { succeeded + failed.count }
}

/// Process metadata across many files efficiently.
public struct BatchProcessor: Sendable {
    public typealias MetadataTransform = @Sendable (inout ImageMetadata) throws -> Void

    /// Apply a transformation to a single file.
    public static func process(file url: URL, transform: MetadataTransform) throws {
        var metadata = try ImageMetadata.read(from: url)
        try transform(&metadata)
        try metadata.write(to: url)
    }

    /// Apply a transformation to all JPEG files in a directory.
    public static func processDirectory(
        at url: URL,
        recursive: Bool = false,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        transform: @escaping MetadataTransform
    ) throws -> BatchResult {
        let fm = FileManager.default

        var urls: [URL] = []

        if recursive {
            if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in enumerator {
                    if isSupportedFormat(fileURL) {
                        urls.append(fileURL)
                    }
                }
            }
        } else {
            let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            urls = contents.filter { isSupportedFormat($0) }
        }

        return try processFiles(urls, concurrency: concurrency, transform: transform)
    }

    /// Apply a transformation to a list of files.
    public static func processFiles(
        _ urls: [URL],
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        transform: @escaping MetadataTransform
    ) throws -> BatchResult {
        let start = Date()
        let accumulator = Accumulator()

        let semaphore = DispatchSemaphore(value: max(1, concurrency))
        let group = DispatchGroup()

        for url in urls {
            group.enter()
            semaphore.wait()

            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    semaphore.signal()
                    group.leave()
                }

                do {
                    try process(file: url, transform: transform)
                    accumulator.recordSuccess()
                } catch {
                    accumulator.recordFailure(url: url, error: error)
                }
            }
        }

        group.wait()

        let elapsed = Date().timeIntervalSince(start)
        return BatchResult(succeeded: accumulator.succeeded, failed: accumulator.failed, totalTime: elapsed)
    }

    // MARK: - Private

    private final class Accumulator: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var succeeded = 0
        private(set) var failed: [(url: URL, error: any Error)] = []

        func recordSuccess() {
            lock.lock()
            succeeded += 1
            lock.unlock()
        }

        func recordFailure(url: URL, error: any Error) {
            lock.lock()
            failed.append((url: url, error: error))
            lock.unlock()
        }
    }

    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg",
        "tif", "tiff",
        "dng", "cr2", "nef", "arw",
        "jxl",
        "png",
        "avif",
        "heic", "heif",
    ]

    private static func isSupportedFormat(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

}
