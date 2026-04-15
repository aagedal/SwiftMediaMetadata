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

    @Flag(name: .shortAndLong, help: "Recursively search directories for images.")
    var recursive = false

    func run() throws {
        var urls: [URL] = []

        let fm = FileManager.default
        for path in files {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if recursive {
                    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                        for case let fileURL as URL in enumerator {
                            if isSupportedFile(fileURL) { urls.append(fileURL) }
                        }
                    }
                } else {
                    if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        urls.append(contentsOf: contents.filter { isSupportedFile($0) })
                    }
                }
            } else {
                urls.append(url)
            }
        }

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
