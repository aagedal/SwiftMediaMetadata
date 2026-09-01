import Foundation

/// Shared filesystem transaction used by all public media writers.
///
/// Metadata serialization intentionally remains in the format-specific writers;
/// this type only owns committing the resulting bytes to disk.
enum FileCommitter {
    static func write(
        _ data: Data,
        to url: URL,
        options: ImageMetadata.WriteOptions
    ) throws {
        let fm = FileManager.default

        do {
            let modificationDate = try resolvedModificationDate(
                for: url,
                policy: options.fileModificationDate,
                fileManager: fm
            )

            if options.createBackup && fm.fileExists(atPath: url.path) {
                let backupURL = ImageMetadata.backupURL(for: url, suffix: options.backupSuffix)
                try? fm.removeItem(at: backupURL)
                try fm.copyItem(at: url, to: backupURL)
            }

            if options.atomic {
                try atomicWrite(
                    data,
                    to: url,
                    modificationDate: modificationDate,
                    fileManager: fm
                )
            } else {
                try data.write(to: url)
                if let modificationDate {
                    try fm.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
                }
            }
        } catch let error as MetadataError {
            throw error
        } catch {
            throw MetadataError.fileWriteError(error.localizedDescription)
        }
    }

    private static func resolvedModificationDate(
        for url: URL,
        policy: ImageMetadata.WriteOptions.FileModificationDatePolicy,
        fileManager fm: FileManager
    ) throws -> Date? {
        switch policy {
        case .update:
            return nil
        case .preserveExisting:
            guard fm.fileExists(atPath: url.path) else { return nil }
            return try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        case .set(let date):
            return date
        }
    }

    private static func atomicWrite(
        _ data: Data,
        to url: URL,
        modificationDate: Date?,
        fileManager fm: FileManager
    ) throws {
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".swiftexif_tmp_\(UUID().uuidString)")

        do {
            try data.write(to: tempURL)
            if let modificationDate {
                try fm.setAttributes([.modificationDate: modificationDate], ofItemAtPath: tempURL.path)
            }

            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
    }
}
