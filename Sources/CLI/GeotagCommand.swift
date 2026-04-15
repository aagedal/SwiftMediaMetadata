import ArgumentParser
import Foundation
import SwiftExif

struct GeotagCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "geotag",
        abstract: "Apply GPS coordinates from a GPX track to images."
    )

    @Option(name: .long, help: "GPX file to load GPS track from.")
    var gpx: String

    @Argument(help: "Image files to geotag.")
    var files: [String]

    @Option(name: .long, help: "Maximum time offset in seconds for matching (default: 60).")
    var maxOffset: Double = 60

    @Option(name: .long, help: "Timezone offset in hours (e.g. +2, -5) to adjust camera time to UTC.")
    var tzOffset: Double = 0

    @Flag(name: .long, help: "Auto-fill IPTC location fields via reverse geocoding after geotagging.")
    var fillLocation = false

    func run() throws {
        let gpxURL = URL(fileURLWithPath: gpx)
        let track = try GPXParser.parse(from: gpxURL)
        let urls = try resolveFiles(files)

        print("Loaded GPX track: \(track.trackpoints.count) trackpoints")
        if let range = track.timeRange {
            let fmt = ISO8601DateFormatter()
            print("Time range: \(fmt.string(from: range.lowerBound)) — \(fmt.string(from: range.upperBound))")
        }
        print()

        var tagged = 0
        var skipped = 0
        var failed = 0

        for url in urls {
            do {
                var metadata = try ImageMetadata.read(from: url)
                let applied = metadata.applyGPX(track, maxOffset: maxOffset, timeZoneOffset: tzOffset * 3600)

                if applied {
                    if fillLocation {
                        metadata.fillLocationFromGPS(overwrite: true)
                    }
                    try metadata.write(to: url)
                    if let lat = metadata.exif?.gpsLatitude, let lon = metadata.exif?.gpsLongitude {
                        var line = "  \(url.lastPathComponent): \(String(format: "%.6f", lat)), \(String(format: "%.6f", lon))"
                        if fillLocation, let city = metadata.iptc.city, let country = metadata.iptc.countryName {
                            line += " — \(city), \(country)"
                        }
                        print(line)
                    }
                    tagged += 1
                } else {
                    print("  \(url.lastPathComponent): no GPS match")
                    skipped += 1
                }
            } catch {
                printError("Error processing \(url.lastPathComponent): \(error.localizedDescription)")
                failed += 1
            }
        }

        print("\n\(tagged) geotagged, \(skipped) skipped, \(failed) failed")
    }
}
