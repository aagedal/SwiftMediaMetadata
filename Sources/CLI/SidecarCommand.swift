import ArgumentParser
import Foundation
import SwiftExif

struct SidecarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sidecar",
        abstract: "Read, write, sync, and manage XMP sidecar files.",
        subcommands: [SidecarRead.self, SidecarWrite.self, SidecarEmbed.self, SidecarSync.self, SidecarCleanup.self]
    )
}

struct SidecarRead: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read and display XMP sidecar data for an image."
    )

    @Argument(help: "Image file (reads the .xmp sidecar alongside it) or .xmp file directly.")
    var file: String

    func run() throws {
        let url = URL(fileURLWithPath: file)

        let xmp: XMPData
        if url.pathExtension.lowercased() == "xmp" {
            xmp = try readXMPSidecar(from: url)
        } else {
            xmp = try readXMPSidecar(for: url)
        }

        // Display XMP fields
        let keys = xmp.allKeys.sorted()
        if keys.isEmpty {
            print("No XMP data found in sidecar.")
            return
        }

        let maxKey = keys.map(\.count).max() ?? 30
        for key in keys {
            guard let value = xmp.value(namespace: extractNamespace(from: key), property: extractProperty(from: key)) else {
                continue
            }
            let display: String
            switch value {
            case .simple(let s): display = s
            case .array(let items): display = items.joined(separator: "; ")
            case .langAlternative(let s): display = s
            case .structure(let fields):
                display = XMPData.flatten(fields).values.sorted().joined(separator: "; ")
            case .structuredArray(let items):
                display = items.map { XMPData.flatten($0).values.sorted().joined(separator: ", ") }.joined(separator: "; ")
            }
            let shortKey = shortenXMPKey(key)
            print("\(shortKey.padding(toLength: maxKey + 2, withPad: " ", startingAt: 0)): \(display)")
        }
    }

    private func extractNamespace(from key: String) -> String {
        for ns in XMPNamespace.prefixes.keys.sorted(by: { $0.count > $1.count }) {
            if key.hasPrefix(ns) { return ns }
        }
        return ""
    }

    private func extractProperty(from key: String) -> String {
        for ns in XMPNamespace.prefixes.keys.sorted(by: { $0.count > $1.count }) {
            if key.hasPrefix(ns) { return String(key.dropFirst(ns.count)) }
        }
        return key
    }

    private func shortenXMPKey(_ key: String) -> String {
        for (ns, prefix) in XMPNamespace.prefixes.sorted(by: { $0.key.count > $1.key.count }) {
            if key.hasPrefix(ns) {
                let prop = String(key.dropFirst(ns.count))
                return "XMP-\(prefix):\(prop)"
            }
        }
        return key
    }
}

struct SidecarWrite: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write",
        abstract: "Write XMP metadata from an image as a sidecar file."
    )

    @Argument(help: "Image file to extract XMP from.")
    var file: String

    @Option(name: .shortAndLong, help: "Output .xmp file path (default: alongside image).")
    var output: String?

    func run() throws {
        let url = URL(fileURLWithPath: file)
        let metadata = try ImageMetadata.read(from: url)

        if let output {
            try metadata.writeSidecar(to: URL(fileURLWithPath: output))
            print("Sidecar written: \(output)")
        } else {
            try metadata.writeSidecar(for: url)
            let sidecarName = url.deletingPathExtension().lastPathComponent + ".xmp"
            print("Sidecar written: \(sidecarName)")
        }
    }
}

struct SidecarEmbed: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "embed",
        abstract: "Embed XMP from sidecar files into images."
    )

    @Argument(help: "Image files whose sidecars should be embedded.")
    var files: [String]

    @OptionGroup var fileFilter: FileFilterOptions

    func run() throws {
        let urls = try resolveFiles(files, filter: fileFilter)
        var succeeded = 0
        var failed = 0

        for url in urls {
            do {
                let sidecarURL = XMPSidecar.sidecarURL(for: url)
                guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
                    printError("No sidecar found for \(url.lastPathComponent)")
                    failed += 1
                    continue
                }
                var metadata = try ImageMetadata.read(from: url)
                try metadata.embedSidecar(from: sidecarURL)
                try metadata.write(to: url)
                succeeded += 1
            } catch {
                printError("Error embedding \(url.lastPathComponent): \(error)")
                failed += 1
            }
        }

        printSummary(succeeded: succeeded, failed: failed, verb: "Embedded")
    }
}

struct SidecarSync: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Compare and synchronize sidecar vs embedded XMP."
    )

    @Argument(help: "Image files to sync.")
    var files: [String]

    @OptionGroup var fileFilter: FileFilterOptions

    @Option(name: .long, help: "Sync direction: sidecar (sidecar wins) or image (embedded wins). Omit to just compare.")
    var direction: String?

    func run() throws {
        let urls = try resolveFiles(files, filter: fileFilter)

        for url in urls {
            let sidecarURL = XMPSidecar.sidecarURL(for: url)
            guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
                printError("No sidecar for \(url.lastPathComponent)")
                continue
            }

            var metadata = try ImageMetadata.read(from: url)
            let report = try metadata.compareSidecar(at: sidecarURL)

            print("=== \(url.lastPathComponent) ===")
            if !report.hasDifferences {
                print("  In sync (\(report.matching) matching properties)")
                continue
            }

            if !report.sidecarOnly.isEmpty {
                print("  Sidecar only: \(report.sidecarOnly.joined(separator: ", "))")
            }
            if !report.embeddedOnly.isEmpty {
                print("  Embedded only: \(report.embeddedOnly.joined(separator: ", "))")
            }
            for conflict in report.conflicts {
                print("  Conflict: \(conflict.key)")
                print("    Sidecar:  \(conflict.sidecarValue)")
                print("    Embedded: \(conflict.embeddedValue)")
            }

            if let dir = direction {
                let syncDir: ImageMetadata.SyncDirection = dir == "sidecar" ? .sidecarToImage : .imageToSidecar
                try metadata.syncWithSidecar(at: sidecarURL, direction: syncDir)
                if syncDir == .sidecarToImage {
                    try metadata.write(to: url)
                }
                print("  Synced (\(dir) wins)")
            }
        }
    }
}

struct SidecarCleanup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Find and remove orphan .xmp sidecar files."
    )

    @Argument(help: "Directory to scan.")
    var directory: String

    @Flag(name: .long, help: "Recursively scan subdirectories.")
    var recursive = false

    @Flag(name: .long, help: "Actually delete orphan files (default is dry run).")
    var delete = false

    func run() throws {
        let dirURL = URL(fileURLWithPath: directory)
        let orphans = try XMPSidecarSync.findOrphans(in: dirURL, recursive: recursive)

        if orphans.isEmpty {
            print("No orphan sidecar files found.")
            return
        }

        for url in orphans {
            print("Orphan: \(url.lastPathComponent)")
        }

        if delete {
            let removed = try XMPSidecarSync.cleanupOrphans(in: dirURL, recursive: recursive, dryRun: false)
            print("Removed \(removed.count) orphan sidecar file(s).")
        } else {
            print("\(orphans.count) orphan(s) found. Use --delete to remove.")
        }
    }
}
