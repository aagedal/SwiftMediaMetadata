import ArgumentParser
import Foundation
import SwiftExif

struct WriteVideoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write-video",
        abstract: "Set metadata tags on video files (MP4, MOV, M4V)."
    )

    @Argument(help: "Video files to modify.")
    var files: [String]

    @Option(name: .long, help: "Set the title.")
    var title: String?

    @Option(name: .long, help: "Set the artist/creator.")
    var artist: String?

    @Option(name: .long, help: "Set a comment.")
    var comment: String?

    @Option(name: .long, help: "Set GPS latitude (decimal degrees, e.g. 59.9139).")
    var latitude: Double?

    @Option(name: .long, help: "Set GPS longitude (decimal degrees, e.g. 10.7522).")
    var longitude: Double?

    @Option(name: .long, help: "Set GPS altitude (meters).")
    var altitude: Double?

    @Flag(name: .long, help: "Strip all user metadata.")
    var strip = false

    @Flag(name: .long, help: "Strip GPS data only.")
    var stripGPS = false

    @Flag(name: .long, help: "Create backup of original file.")
    var backup = false

    func validate() throws {
        let hasWrite = title != nil || artist != nil || comment != nil || latitude != nil || longitude != nil
        guard hasWrite || strip || stripGPS else {
            throw ValidationError("Provide at least one metadata option (--title, --artist, --comment, --latitude/--longitude) or --strip/--strip-gps.")
        }
        if (latitude != nil) != (longitude != nil) {
            throw ValidationError("Both --latitude and --longitude must be provided together.")
        }
    }

    func run() throws {
        let urls = try resolveFiles(files)
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
        var succeeded = 0
        var failed = 0

        for url in urls {
            guard videoExtensions.contains(url.pathExtension.lowercased()) else {
                printError("Skipping non-video file: \(url.lastPathComponent)")
                continue
            }

            do {
                var metadata = try VideoMetadata.read(from: url)

                if strip {
                    metadata.stripMetadata()
                }
                if stripGPS {
                    metadata.stripGPS()
                }

                if let t = title { metadata.title = t }
                if let a = artist { metadata.artist = a }
                if let c = comment { metadata.comment = c }
                if let lat = latitude, let lon = longitude {
                    metadata.gpsLatitude = lat
                    metadata.gpsLongitude = lon
                    metadata.gpsAltitude = altitude
                }

                let options = ImageMetadata.WriteOptions(atomic: true, createBackup: backup)
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
