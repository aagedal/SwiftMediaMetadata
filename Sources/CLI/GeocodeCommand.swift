import ArgumentParser
import Foundation
import SwiftExif

struct GeocodeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "geocode",
        abstract: "Reverse-geocode GPS coordinates or geotagged images."
    )

    @Option(name: .long, help: "Latitude in decimal degrees.")
    var lat: Double?

    @Option(name: .long, help: "Longitude in decimal degrees.")
    var lon: Double?

    @Option(name: .shortAndLong, help: "Number of nearest results to show (default: 1).")
    var count: Int = 1

    @Argument(help: "Image files to read GPS from (if --lat/--lon not given).")
    var files: [String] = []

    @OptionGroup var fileFilter: FileFilterOptions

    func validate() throws {
        if lat != nil || lon != nil {
            guard lat != nil && lon != nil else {
                throw ValidationError("Both --lat and --lon are required together.")
            }
        } else if files.isEmpty {
            throw ValidationError("Provide --lat/--lon or image files to read GPS from.")
        }
    }

    func run() throws {
        let geocoder = ReverseGeocoder.shared

        if let lat, let lon {
            // Direct coordinate lookup
            let results = geocoder.nearest(latitude: lat, longitude: lon, count: count)
            if results.isEmpty {
                print("No city found near \(String(format: "%.6f", lat)), \(String(format: "%.6f", lon))")
            } else {
                for loc in results {
                    print("\(loc.city), \(loc.region), \(loc.country) (\(loc.countryCode)) — \(loc.timezone) — \(String(format: "%.1f", loc.distance)) km")
                }
            }
        } else {
            // Read GPS from image files
            let urls = try resolveFiles(files, filter: fileFilter)
            for url in urls {
                do {
                    let metadata = try ImageMetadata.read(from: url)
                    guard let lat = metadata.exif?.gpsLatitude,
                          let lon = metadata.exif?.gpsLongitude else {
                        print("\(url.lastPathComponent): no GPS data")
                        continue
                    }

                    let results = geocoder.nearest(latitude: lat, longitude: lon, count: count)
                    if results.isEmpty {
                        print("\(url.lastPathComponent): \(String(format: "%.6f", lat)), \(String(format: "%.6f", lon)) — no city match")
                    } else {
                        let loc = results[0]
                        print("\(url.lastPathComponent): \(loc.city), \(loc.region), \(loc.country) (\(loc.countryCode)) — \(String(format: "%.1f", loc.distance)) km")
                        for loc in results.dropFirst() {
                            print("  also: \(loc.city), \(loc.region), \(loc.country) — \(String(format: "%.1f", loc.distance)) km")
                        }
                    }
                } catch {
                    printError("Error: \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }
}
