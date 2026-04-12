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
public struct BatchProcessor {
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
                    if isJPEG(fileURL) {
                        urls.append(fileURL)
                    }
                }
            }
        } else {
            let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            urls = contents.filter { isJPEG($0) }
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
        var succeeded = 0
        var failed: [(url: URL, error: any Error)] = []

        // Use a serial queue for thread-safe result collection
        let lock = NSLock()

        // Process with concurrency limiting via DispatchSemaphore
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
                    lock.lock()
                    succeeded += 1
                    lock.unlock()
                } catch {
                    lock.lock()
                    failed.append((url: url, error: error))
                    lock.unlock()
                }
            }
        }

        group.wait()

        let elapsed = Date().timeIntervalSince(start)
        return BatchResult(succeeded: succeeded, failed: failed, totalTime: elapsed)
    }

    // MARK: - Private

    private static func isJPEG(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "jpg" || ext == "jpeg"
    }
}
