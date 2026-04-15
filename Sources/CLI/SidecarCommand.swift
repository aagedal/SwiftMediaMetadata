import ArgumentParser
import Foundation
import SwiftExif

struct SidecarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sidecar",
        abstract: "Read or write XMP sidecar files.",
        subcommands: [SidecarRead.self, SidecarWrite.self]
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
