import ArgumentParser
import Foundation
import SwiftExif

struct ShiftDatesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shift-dates",
        abstract: "Shift all date/time fields by a given offset."
    )

    @Argument(help: "Image files to adjust.")
    var files: [String]

    @Option(name: .long, help: "Time offset in seconds (positive = forward, negative = backward).")
    var by: Double?

    @Option(name: .long, help: "Time offset in hours (alternative to --by).")
    var hours: Double?

    @Option(name: .long, help: "Filter condition.")
    var `if`: [String] = []

    @Flag(name: .long, help: "Create backup of original file before writing.")
    var backup = false

    @Flag(name: .long, help: "Overwrite original without backup (default behavior, for ExifTool compatibility).")
    var overwriteOriginal = false

    func validate() throws {
        guard by != nil || hours != nil else {
            throw ValidationError("Specify either --by (seconds) or --hours.")
        }
    }

    func run() throws {
        let urls = try resolveFiles(files)
        let condition = try parseConditions(self.if)
        let offset = by ?? (hours! * 3600)

        var succeeded = 0
        var failed = 0

        for url in urls {
            do {
                var metadata = try ImageMetadata.read(from: url)
                if let condition, !condition.matches(metadata) { continue }

                metadata.shiftDates(by: offset)
                let options = ImageMetadata.WriteOptions(atomic: true, createBackup: backup && !overwriteOriginal)
                try metadata.write(to: url, options: options)
                succeeded += 1
            } catch {
                printError("Error processing \(url.lastPathComponent): \(error.localizedDescription)")
                failed += 1
            }
        }

        let direction = offset >= 0 ? "forward" : "backward"
        let absOffset = abs(offset)
        let desc: String
        if absOffset >= 3600 {
            desc = String(format: "%.1f hours", absOffset / 3600)
        } else if absOffset >= 60 {
            desc = String(format: "%.0f minutes", absOffset / 60)
        } else {
            desc = String(format: "%.0f seconds", absOffset)
        }

        print("Shifted \(desc) \(direction)")
        printSummary(succeeded: succeeded, failed: failed, verb: "Shifted")
    }
}
