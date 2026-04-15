import ArgumentParser
import Foundation
import SwiftExif

struct SetGPSCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-gps",
        abstract: "Set GPS coordinates on image files."
    )

    @Option(name: .long, help: "Latitude in decimal degrees (positive = North).")
    var lat: Double

    @Option(name: .long, help: "Longitude in decimal degrees (positive = East).")
    var lon: Double

    @Option(name: .long, help: "Altitude in meters above sea level.")
    var alt: Double?

    @Flag(name: .long, help: "Auto-fill IPTC location fields via reverse geocoding.")
    var fillLocation = false

    @Argument(help: "Image files to set GPS on.")
    var files: [String]

    func validate() throws {
        guard lat >= -90 && lat <= 90 else {
            throw ValidationError("Latitude must be between -90 and 90.")
        }
        guard lon >= -180 && lon <= 180 else {
            throw ValidationError("Longitude must be between -180 and 180.")
        }
    }

    func run() throws {
        let urls = try resolveFiles(files)
        var succeeded = 0
        var failed = 0

        for url in urls {
            do {
                var metadata = try ImageMetadata.read(from: url)
                metadata.setGPS(latitude: lat, longitude: lon, altitude: alt)

                if fillLocation {
                    if let location = metadata.fillLocationFromGPS(overwrite: true) {
                        print("  \(url.lastPathComponent): \(String(format: "%.6f", lat)), \(String(format: "%.6f", lon)) — \(location.city), \(location.country)")
                    } else {
                        print("  \(url.lastPathComponent): \(String(format: "%.6f", lat)), \(String(format: "%.6f", lon)) — no city match")
                    }
                } else {
                    print("  \(url.lastPathComponent): \(String(format: "%.6f", lat)), \(String(format: "%.6f", lon))")
                }

                try metadata.write(to: url)
                succeeded += 1
            } catch {
                printError("Error: \(url.lastPathComponent): \(error.localizedDescription)")
                failed += 1
            }
        }

        printSummary(succeeded: succeeded, failed: failed, verb: "Updated")
    }
}
