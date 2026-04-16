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

    @OptionGroup var fileFilter: FileFilterOptions

    @Option(name: .shortAndLong, help: "Tag to set (Key=Value), append (Key+=Value), or remove (Key-=Value). Can be repeated.")
    var tag: [String] = []

    @Option(name: .long, help: "Filter condition (e.g. 'Make=Canon').")
    var `if`: [String] = []

    @Flag(name: .long, help: "Sync IPTC fields to XMP after writing.")
    var syncXMP = false

    @Flag(name: .long, help: "Create backup of original file before writing.")
    var backup = false

    @Flag(name: .long, help: "Overwrite original without backup (default behavior, for ExifTool compatibility).")
    var overwriteOriginal = false

    func validate() throws {
        guard !tag.isEmpty else {
            throw ValidationError("At least one --tag is required.")
        }
    }

    func run() throws {
        let urls = try resolveFiles(files, filter: fileFilter)
        let condition = try parseConditions(self.if)
        let tags = try parseTags(tag)
        let options = ImageMetadata.WriteOptions(atomic: true, createBackup: backup && !overwriteOriginal)

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

                try metadata.write(to: url, options: options)
                succeeded += 1
            } catch {
                printError("Error writing \(url.lastPathComponent): \(error.localizedDescription)")
                failed += 1
            }
        }

        printSummary(succeeded: succeeded, failed: failed, verb: "Updated")
    }
}

/// The operation to perform when applying a tag value.
enum TagOperation: Sendable {
    case set      // Key=Value  — replace the value
    case append   // Key+=Value — add to list without replacing
    case remove   // Key-=Value — remove from list
}

/// A parsed tag assignment with its operation.
struct ParsedTag: Sendable {
    let key: String
    let value: String
    let operation: TagOperation
}

func parseTags(_ tags: [String]) throws -> [ParsedTag] {
    try tags.map { tag in
        // Check for += (append) first, then -= (remove), then = (set)
        if let range = tag.range(of: "+=") {
            let key = String(tag[tag.startIndex..<range.lowerBound])
            let value = String(tag[range.upperBound...])
            return ParsedTag(key: key, value: value, operation: .append)
        }
        if let range = tag.range(of: "-=") {
            let key = String(tag[tag.startIndex..<range.lowerBound])
            let value = String(tag[range.upperBound...])
            return ParsedTag(key: key, value: value, operation: .remove)
        }
        guard let eqIndex = tag.firstIndex(of: "=") else {
            throw ValidationError("Invalid tag format '\(tag)'. Expected Key=Value, Key+=Value, or Key-=Value.")
        }
        let key = String(tag[tag.startIndex..<eqIndex])
        let value = String(tag[tag.index(after: eqIndex)...])
        return ParsedTag(key: key, value: value, operation: .set)
    }
}

func applyTags(_ tags: [ParsedTag], to metadata: inout ImageMetadata) {
    for tag in tags {
        let key = tag.key
        let value = tag.value
        let op = tag.operation

        // For += and -= on IPTC repeatable tags, resolve the IPTC tag type
        if let iptcListTag = iptcRepeatableTag(for: key) {
            let items = value.split(separator: ";").map { String($0.trimmingCharacters(in: .whitespaces)) }
            switch op {
            case .set:
                try? metadata.iptc.setValues(items, for: iptcListTag)
            case .append:
                for item in items {
                    try? metadata.iptc.addValue(item, for: iptcListTag)
                }
            case .remove:
                let existing = metadata.iptc.values(for: iptcListTag)
                let filtered = existing.filter { current in
                    !items.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame })
                }
                try? metadata.iptc.setValues(filtered, for: iptcListTag)
            }
            continue
        }

        // For += and -= on XMP tags, handle array manipulation
        if key.hasPrefix("XMP:") || key.hasPrefix("XMP-") {
            applyXMPTag(key: key, value: value, operation: op, to: &metadata)
            continue
        }

        // Non-list tags: += and -= fall back to set (with warning for -=)
        if op == .remove {
            printError("Warning: -= not supported for non-list tag '\(key)' — use tag removal instead.")
            continue
        }

        // IPTC single-value tags (set or append→set)
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
        default:
            printError("Warning: Unknown tag '\(key)' — skipping.")
        }
    }
}

/// Map tag key names to IPTC repeatable tag types.
private func iptcRepeatableTag(for key: String) -> IPTCTag? {
    switch key {
    case "IPTC:Keywords", "Keywords": return .keywords
    case "IPTC:SupplementalCategories", "SupplementalCategories": return .supplementalCategories
    case "IPTC:Contact", "Contact": return .contact
    case "IPTC:SubjectReference", "SubjectReference": return .subjectReference
    default: return nil
    }
}

private func applyXMPTag(key: String, value: String, operation: TagOperation, to metadata: inout ImageMetadata) {
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

    let items = value.split(separator: ";").map { String($0.trimmingCharacters(in: .whitespaces)) }

    switch operation {
    case .set:
        if items.count > 1 {
            metadata.xmp?.setValue(.array(items), namespace: namespace, property: property)
        } else {
            metadata.xmp?.setValue(.simple(value), namespace: namespace, property: property)
        }

    case .append:
        // Get existing array (or start empty), append new items
        var existing = metadata.xmp?.arrayValue(namespace: namespace, property: property) ?? []
        // If it was a simple value, promote to array
        if existing.isEmpty, let simple = metadata.xmp?.simpleValue(namespace: namespace, property: property) {
            existing = [simple]
        }
        existing.append(contentsOf: items)
        metadata.xmp?.setValue(.array(existing), namespace: namespace, property: property)

    case .remove:
        var existing = metadata.xmp?.arrayValue(namespace: namespace, property: property) ?? []
        existing.removeAll { current in
            items.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame })
        }
        if existing.isEmpty {
            metadata.xmp?.removeValue(namespace: namespace, property: property)
        } else {
            metadata.xmp?.setValue(.array(existing), namespace: namespace, property: property)
        }
    }
}
