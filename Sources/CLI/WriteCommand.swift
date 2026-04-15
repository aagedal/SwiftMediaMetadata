import ArgumentParser
import Foundation
import SwiftExif

struct WriteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write",
        abstract: "Set metadata tags on image files."
    )

    @Argument(help: "Image files to modify.")
    var files: [String]

    @Option(name: .shortAndLong, help: "Tag to set (format: Key=Value). Can be repeated.")
    var tag: [String] = []

    @Option(name: .long, help: "Filter condition (e.g. 'Make=Canon').")
    var `if`: [String] = []

    @Flag(name: .long, help: "Sync IPTC fields to XMP after writing.")
    var syncXMP = false

    func validate() throws {
        guard !tag.isEmpty else {
            throw ValidationError("At least one --tag is required.")
        }
    }

    func run() throws {
        let urls = try resolveFiles(files)
        let condition = try parseConditions(self.if)
        let tags = try parseTags(tag)

        var succeeded = 0
        var failed = 0

        for url in urls {
            do {
                var metadata = try ImageMetadata.read(from: url)
                if let condition, !condition.matches(metadata) { continue }

                applyTags(tags, to: &metadata)

                if syncXMP {
                    metadata.syncIPTCToXMP()
                }

                try metadata.write(to: url)
                succeeded += 1
            } catch {
                printError("Error writing \(url.lastPathComponent): \(error.localizedDescription)")
                failed += 1
            }
        }

        printSummary(succeeded: succeeded, failed: failed, verb: "Updated")
    }
}

func parseTags(_ tags: [String]) throws -> [(key: String, value: String)] {
    try tags.map { tag in
        guard let eqIndex = tag.firstIndex(of: "=") else {
            throw ValidationError("Invalid tag format '\(tag)'. Expected Key=Value.")
        }
        let key = String(tag[tag.startIndex..<eqIndex])
        let value = String(tag[tag.index(after: eqIndex)...])
        return (key: key, value: value)
    }
}

func applyTags(_ tags: [(key: String, value: String)], to metadata: inout ImageMetadata) {
    for (key, value) in tags {
        // IPTC tags
        switch key {
        case "IPTC:Headline", "Headline":
            metadata.iptc.headline = value
        case "IPTC:Caption-Abstract", "Caption", "Caption-Abstract":
            metadata.iptc.caption = value
        case "IPTC:By-line", "By-line", "Byline":
            metadata.iptc.byline = value
        case "IPTC:Credit", "Credit":
            metadata.iptc.credit = value
        case "IPTC:Source", "Source":
            metadata.iptc.source = value
        case "IPTC:CopyrightNotice", "CopyrightNotice":
            metadata.iptc.copyright = value
        case "IPTC:City", "City":
            metadata.iptc.city = value
        case "IPTC:Sub-location", "Sub-location", "Sublocation":
            metadata.iptc.sublocation = value
        case "IPTC:Province-State", "Province-State", "State":
            metadata.iptc.provinceState = value
        case "IPTC:Country-PrimaryLocationCode", "CountryCode":
            metadata.iptc.countryCode = value
        case "IPTC:Country-PrimaryLocationName", "Country":
            metadata.iptc.countryName = value
        case "IPTC:DateCreated", "DateCreated":
            metadata.iptc.dateCreated = value
        case "IPTC:TimeCreated", "TimeCreated":
            metadata.iptc.timeCreated = value
        case "IPTC:SpecialInstructions", "SpecialInstructions":
            metadata.iptc.specialInstructions = value
        case "IPTC:ObjectName", "ObjectName", "Title":
            metadata.iptc.objectName = value
        case "IPTC:Writer-Editor", "Writer-Editor", "Writer":
            metadata.iptc.writerEditor = value
        case "IPTC:OriginalTransmissionReference", "JobId", "TransmissionReference":
            metadata.iptc.jobId = value
        case "IPTC:Keywords", "Keywords":
            metadata.iptc.keywords = value.split(separator: ";").map { String($0.trimmingCharacters(in: .whitespaces)) }

        // XMP tags (namespace:property format)
        default:
            if key.hasPrefix("XMP:") || key.hasPrefix("XMP-") {
                applyXMPTag(key: key, value: value, to: &metadata)
            } else {
                printError("Warning: Unknown tag '\(key)' — skipping.")
            }
        }
    }
}

private func applyXMPTag(key: String, value: String, to metadata: inout ImageMetadata) {
    if metadata.xmp == nil {
        metadata.xmp = XMPData()
    }

    // Parse XMP-prefix:Property or XMP:namespace:Property
    let stripped: String
    if key.hasPrefix("XMP-") {
        stripped = String(key.dropFirst(4))
    } else {
        stripped = String(key.dropFirst(4)) // XMP:
    }

    // Try to resolve namespace from prefix
    let parts = stripped.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else {
        printError("Warning: Invalid XMP tag format '\(key)'. Expected XMP-prefix:Property.")
        return
    }

    let prefix = String(parts[0])
    let property = String(parts[1])

    // Look up namespace from prefix
    let namespace = XMPNamespace.prefixes.first(where: { $0.value == prefix })?.key
        ?? "http://\(prefix.lowercased())/"

    if value.contains(";") {
        let items = value.split(separator: ";").map { String($0.trimmingCharacters(in: .whitespaces)) }
        metadata.xmp?.setValue(.array(items), namespace: namespace, property: property)
    } else {
        metadata.xmp?.setValue(.simple(value), namespace: namespace, property: property)
    }
}
