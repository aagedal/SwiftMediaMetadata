import ArgumentParser
import Foundation
import SwiftExif

struct GPXExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gpx-export",
        abstract: "Generate a GPX track file from geotagged images."
    )

    @Argument(help: "Image files or directories to read GPS data from.")
    var files: [String]

    @Option(name: .shortAndLong, help: "Output GPX file path (default: stdout).")
    var output: String?

    @Option(name: .long, help: "Track name in the GPX file.")
    var name: String?

    @OptionGroup var fileFilter: FileFilterOptions

    func run() throws {
        let urls = try resolveFiles(files, filter: fileFilter)

        guard !urls.isEmpty else {
            printError("No files found.")
            throw ExitCode.failure
        }

        let gpx = try GPXTrackGenerator.generate(from: urls, name: name)

        if let outputPath = output {
            try gpx.write(toFile: outputPath, atomically: true, encoding: .utf8)
            print("Wrote GPX track to \(outputPath)")
        } else {
            print(gpx)
        }
    }
}
