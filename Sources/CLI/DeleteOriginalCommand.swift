import ArgumentParser
import Foundation
import SwiftExif

struct DeleteOriginalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-original",
        abstract: "Delete backup (_original) files created during metadata editing."
    )

    @Argument(help: "Files or directories to clean up backup files for.")
    var files: [String]

    @Flag(name: .shortAndLong, help: "Recurse into subdirectories.")
    var recursive = false

    @Flag(name: .long, help: "Preview which files would be deleted without actually deleting.")
    var dryRun = false

    func run() throws {
        let fm = FileManager.default
        var deleted = 0
        var totalSize: UInt64 = 0

        let urls = try resolveFilesForCleanup(files, recursive: recursive)

        for url in urls {
            let backupURL = ImageMetadata.backupURL(for: url)
            guard fm.fileExists(atPath: backupURL.path) else { continue }

            if let attrs = try? fm.attributesOfItem(atPath: backupURL.path),
               let size = attrs[.size] as? UInt64 {
                totalSize += size
            }

            if dryRun {
                print("  Would delete: \(backupURL.lastPathComponent)")
            } else {
                do {
                    try fm.removeItem(at: backupURL)
                    print("  Deleted: \(backupURL.lastPathComponent)")
                } catch {
                    printError("Error deleting \(backupURL.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
            }
            deleted += 1
        }

        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
        if dryRun {
            print("\(deleted) backup file(s) would be deleted (\(sizeStr))")
        } else {
            print("\(deleted) backup file(s) deleted (\(sizeStr))")
        }
    }
}

/// Resolve paths for cleanup, finding image files (with possible _original backups).
private func resolveFilesForCleanup(_ paths: [String], recursive: Bool) throws -> [URL] {
    var urls: [URL] = []
    let fm = FileManager.default

    for path in paths {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false

        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                if recursive {
                    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                        for case let fileURL as URL in enumerator where isSupportedFile(fileURL) {
                            urls.append(fileURL)
                        }
                    }
                } else if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    urls.append(contentsOf: contents.filter { isSupportedFile($0) })
                }
            } else {
                urls.append(url)
            }
        }
    }

    return urls
}
