import ArgumentParser
import Foundation
import SwiftExif

struct CopyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy",
        abstract: "Copy metadata from one image to others."
    )

    @Option(name: .long, help: "Source image to copy metadata from.")
    var from: String

    @Argument(help: "Destination image files.")
    var files: [String]

    @OptionGroup var fileFilter: FileFilterOptions

    @Option(name: .long, help: "Metadata groups to copy (comma-separated): exif, iptc, xmp, c2pa, icc. Default: all.")
    var groups: String?

    @Option(name: .long, help: "Only copy tags matching glob pattern (e.g. 'IPTC:*').")
    var tags: [String] = []

    @Option(name: .long, help: "Exclude tags matching glob pattern.")
    var excludeTags: [String] = []

    @Option(name: .long,
            help: "Remap a source tag to a different destination tag. Repeatable. Format: 'SRC>DST' or 'SRC=DST' (e.g. 'IPTC:Caption-Abstract>XMP-dc:description'). Mirrors ExifTool's '-tagsFromFile @ -SRC>DST' template syntax.")
    var map: [String] = []

    @Flag(name: .long, help: "Create backup of original file before writing.")
    var backup = false

    @Flag(name: .long, help: "Overwrite original without backup (default behavior, for ExifTool compatibility).")
    var overwriteOriginal = false

    func run() throws {
        let sourceURL = URL(fileURLWithPath: from)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ValidationError("Source file not found: \(from)")
        }

        let source = try ImageMetadata.read(from: sourceURL)
        let destURLs = try resolveFiles(files, filter: fileFilter)

        let groupSet: Set<ImageMetadata.MetadataGroup>?
        if let groups {
            groupSet = Set(groups.split(separator: ",").compactMap { name -> ImageMetadata.MetadataGroup? in
                switch name.trimmingCharacters(in: .whitespaces).lowercased() {
                case "exif": return .exif
                case "iptc": return .iptc
                case "xmp": return .xmp
                case "c2pa": return .c2pa
                case "icc", "iccprofile": return .iccProfile
                default:
                    printError("Warning: Unknown group '\(name)'")
                    return nil
                }
            })
        } else {
            groupSet = nil
        }

        let options = ImageMetadata.WriteOptions(atomic: true, createBackup: backup && !overwriteOriginal)
        let mappings = try parseTagMappings(map)
        // Pre-build a flat read of the source dict; -map looks up SRC keys
        // here and applies their values via the same write path -tag uses.
        let sourceDict = mappings.isEmpty
            ? [:]
            : MetadataExporter.buildDictionary(source).mapValues { value -> String in
                if let arr = value as? [String] { return arr.joined(separator: "; ") }
                return String(describing: value)
            }
        var succeeded = 0
        var failed = 0

        for url in destURLs {
            do {
                var dest = try ImageMetadata.read(from: url)
                if !tags.isEmpty || !excludeTags.isEmpty {
                    let filter = TagFilter(tags: tags, excludeTags: excludeTags)
                    dest.copyMetadata(from: source, filter: filter)
                } else if let groupSet {
                    dest.copyMetadata(from: source, groups: groupSet)
                } else if mappings.isEmpty {
                    dest.copyMetadata(from: source)
                }
                // Remap stage runs after the bulk copy so that `--map` can
                // override or supplement -group/-tags selections, matching
                // ExifTool's "later assignment wins" semantics.
                if !mappings.isEmpty {
                    let synthesized = mappings.compactMap { m -> ParsedTag? in
                        guard let value = sourceDict[m.src], !value.isEmpty else { return nil }
                        return ParsedTag(key: m.dst, value: value, operation: .set)
                    }
                    applyTags(synthesized, to: &dest)
                }
                try dest.write(to: url, options: options)
                succeeded += 1
            } catch {
                printError("Error copying to \(url.lastPathComponent): \(error.localizedDescription)")
                failed += 1
            }
        }

        printSummary(succeeded: succeeded, failed: failed, verb: "Copied")
    }
}
