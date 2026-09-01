import Foundation

/// Shared filesystem transaction used by all public media writers.
///
/// Metadata serialization intentionally remains in the format-specific writers;
/// this type only owns committing the resulting bytes to disk.
enum FileCommitter {
    /// Commit already-serialized bytes and return the destination that was written.
    @discardableResult
    static func commit(
        _ data: Data,
        to url: URL,
        options: ImageMetadata.WriteOptions
    ) throws -> URL {
        let fm = FileManager.default

        do {
            let isHidden = try resolvedHiddenState(for: url, fileManager: fm)
            let modificationDate = try resolvedModificationDate(
                for: url,
                policy: options.fileModificationDate,
                fileManager: fm
            )
            let creationDate = try resolvedCreationDate(
                for: url,
                policy: options.fileCreationDate,
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
                    isHidden: isHidden,
                    modificationDate: modificationDate,
                    creationDate: creationDate,
                    fileManager: fm
                )
            } else {
                try data.write(to: url)
                try restoreFileDates(
                    modificationDate: modificationDate,
                    creationDate: creationDate,
                    at: url,
                    fileManager: fm
                )
            }
            return url
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

    private static func resolvedCreationDate(
        for url: URL,
        policy: ImageMetadata.WriteOptions.FileCreationDatePolicy,
        fileManager fm: FileManager
    ) throws -> Date? {
        switch policy {
        case .update:
            return nil
        case .preserveExisting:
            guard fm.fileExists(atPath: url.path) else { return nil }
            return try fm.attributesOfItem(atPath: url.path)[.creationDate] as? Date
        case .set(let date):
            return date
        }
    }

    /// Capture filesystem visibility before creating a dot-prefixed staging file.
    /// Some file providers can otherwise transfer that staging file's hidden flag
    /// to the installed destination during replacement.
    private static func resolvedHiddenState(
        for url: URL,
        fileManager fm: FileManager
    ) throws -> Bool {
        #if canImport(Darwin)
        guard fm.fileExists(atPath: url.path) else {
            return url.lastPathComponent.hasPrefix(".")
        }
        return try url.resourceValues(forKeys: [.isHiddenKey]).isHidden
            ?? url.lastPathComponent.hasPrefix(".")
        #else
        return url.lastPathComponent.hasPrefix(".")
        #endif
    }

    private static func atomicWrite(
        _ data: Data,
        to url: URL,
        isHidden: Bool,
        modificationDate: Date?,
        creationDate: Date?,
        fileManager fm: FileManager
    ) throws {
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".swiftmediametadata_tmp_\(UUID().uuidString)")

        do {
            try data.write(to: tempURL)
            try restoreFileDates(
                modificationDate: modificationDate,
                creationDate: creationDate,
                at: tempURL,
                fileManager: fm
            )

            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: url)
            }

            try restoreHiddenState(isHidden, at: url)
            try restoreFileDates(
                modificationDate: modificationDate,
                creationDate: creationDate,
                at: url,
                fileManager: fm
            )
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
    }

    private static func restoreHiddenState(_ isHidden: Bool, at url: URL) throws {
        #if canImport(Darwin)
        var visibility = URLResourceValues()
        visibility.isHidden = isHidden
        var installedURL = url
        try installedURL.setResourceValues(visibility)
        #endif
    }

    private static func restoreFileDates(
        modificationDate: Date?,
        creationDate: Date?,
        at url: URL,
        fileManager fm: FileManager
    ) throws {
        var attributes: [FileAttributeKey: Any] = [:]
        if let modificationDate { attributes[.modificationDate] = modificationDate }
        if let creationDate { attributes[.creationDate] = creationDate }
        if !attributes.isEmpty {
            try fm.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }
}
