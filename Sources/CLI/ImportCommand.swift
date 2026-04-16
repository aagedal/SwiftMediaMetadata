import ArgumentParser
import Foundation
import SwiftExif

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import metadata from a JSON or CSV file onto images."
    )

    @Argument(help: "JSON or CSV file containing metadata.")
    var source: String

    @Argument(help: "Image files to apply metadata to.")
    var files: [String]

    @Option(name: .long, help: "Match mode: filename (default) or sequential.")
    var match: String = "filename"

    @Option(name: .long, help: "Column name for filename matching (default: SourceFile).")
    var fileColumn: String = "SourceFile"

    @Option(name: .long, help: "Only import tags matching glob pattern.")
    var tags: [String] = []

    @Option(name: .long, help: "Exclude tags matching glob pattern.")
    var excludeTags: [String] = []

    @Flag(name: .long, help: "Create backup of original file before writing.")
    var backup = false

    @Flag(name: .long, help: "Overwrite original without backup (default behavior, for ExifTool compatibility).")
    var overwriteOriginal = false

    func run() throws {
        let sourceURL = URL(fileURLWithPath: source)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ValidationError("Source file not found: \(source)")
        }

        let destURLs = try resolveFiles(files)
        let ext = sourceURL.pathExtension.lowercased()

        let records: [[String: String]]
        if ext == "json" {
            let data = try Data(contentsOf: sourceURL)
            records = try MetadataImporter.parseJSON(data)
        } else if ext == "csv" {
            let string = try String(contentsOf: sourceURL, encoding: .utf8)
            records = try MetadataImporter.parseCSV(string)
        } else {
            throw ValidationError("Unsupported import format. Use .json or .csv.")
        }

        let matching: MetadataImporter.FileMatching
        if match == "sequential" {
            matching = .sequential
        } else {
            matching = .byFilename(column: fileColumn)
        }

        let filter: TagFilter? = (!tags.isEmpty || !excludeTags.isEmpty)
            ? TagFilter(tags: tags, excludeTags: excludeTags) : nil

        let writeOpts = ImageMetadata.WriteOptions(atomic: true, createBackup: backup && !overwriteOriginal)
        let result = try MetadataImporter.importToFiles(
            records: records, files: destURLs, matching: matching, filter: filter, writeOptions: writeOpts
        )

        printSummary(succeeded: result.succeeded, failed: result.failed, verb: "Imported")
    }
}
