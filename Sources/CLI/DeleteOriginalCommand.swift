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

    @OptionGroup var fileFilter: FileFilterOptions

    @Flag(name: .long, help: "Preview which files would be deleted without actually deleting.")
    var dryRun = false

    func run() throws {
        let fm = FileManager.default
        var deleted = 0
        var totalSize: UInt64 = 0

        let urls = try resolveFiles(files, filter: fileFilter)

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
