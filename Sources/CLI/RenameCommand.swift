import ArgumentParser
import Foundation
import SwiftExif

struct RenameCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename files based on metadata using a template.",
        discussion: """
        Template tokens:
          %{FieldName}              — metadata value (e.g. %{Make}, %{IPTC:City})
          %{FieldName:dateformat}   — format a date (e.g. %{DateTimeOriginal:yyyy-MM-dd})
          %c                        — sequence counter for uniqueness

        Example: swift-exif rename --template '%{DateTimeOriginal:yyyy-MM-dd}_%{Make}_%c' *.jpg
        """
    )

    @Option(name: .shortAndLong, help: "Template string for the new filename.")
    var template: String

    @Argument(help: "Image files to rename.")
    var files: [String]

    @Flag(name: .long, help: "Preview renames without moving files.")
    var dryRun = false

    @Option(name: .long, help: "Number of digits for counter (default: 3).")
    var counterDigits: Int = 3

    func run() throws {
        let urls = try resolveFiles(files)
        let renamer = MetadataRenamer(template: template, counterDigits: counterDigits)

        if dryRun {
            let previews = renamer.dryRun(files: urls)
            if previews.isEmpty {
                print("No renames needed.")
            } else {
                for (from, to) in previews {
                    print("\(from.lastPathComponent) → \(to.lastPathComponent)")
                }
                print("\n\(previews.count) file(s) would be renamed.")
            }
        } else {
            let result = renamer.rename(files: urls)

            for (from, to) in result.renamed {
                print("\(from.lastPathComponent) → \(to.lastPathComponent)")
            }

            if !result.failed.isEmpty {
                for (url, error) in result.failed {
                    printError("Error renaming \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            print("\n\(result.renamed.count) renamed, \(result.skipped.count) skipped, \(result.failed.count) failed")
        }
    }
}
