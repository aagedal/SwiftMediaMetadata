import ArgumentParser
import Foundation
import SwiftExif

struct StripCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strip",
        abstract: "Remove metadata from image files."
    )

    @Argument(help: "Image files to strip metadata from.")
    var files: [String]

    @Flag(name: .long, help: "Strip all metadata.")
    var all = false

    @Flag(name: .long, help: "Strip EXIF data.")
    var exif = false

    @Flag(name: .long, help: "Strip IPTC data.")
    var iptc = false

    @Flag(name: .long, help: "Strip XMP data.")
    var xmp = false

    @Flag(name: .long, help: "Strip GPS data only.")
    var gps = false

    @Flag(name: .long, help: "Strip C2PA provenance data.")
    var c2pa = false

    @Flag(name: .long, help: "Strip ICC color profile.")
    var icc = false

    @Option(name: .long, help: "Filter condition.")
    var `if`: [String] = []

    func validate() throws {
        guard all || exif || iptc || xmp || gps || c2pa || icc else {
            throw ValidationError("Specify at least one of: --all, --exif, --iptc, --xmp, --gps, --c2pa, --icc")
        }
    }

    func run() throws {
        let urls = try resolveFiles(files)
        let condition = try parseConditions(self.if)

        var succeeded = 0
        var failed = 0

        for url in urls {
            do {
                var metadata = try ImageMetadata.read(from: url)
                if let condition, !condition.matches(metadata) { continue }

                if all {
                    metadata.stripAllMetadata()
                } else {
                    if exif { metadata.stripExif() }
                    if iptc { metadata.stripIPTC() }
                    if xmp { metadata.stripXMP() }
                    if gps { metadata.stripGPS() }
                    if c2pa { metadata.stripC2PA() }
                    if icc { metadata.stripICCProfile() }
                }

                try metadata.write(to: url)
                succeeded += 1
            } catch {
                printError("Error stripping \(url.lastPathComponent): \(error.localizedDescription)")
                failed += 1
            }
        }

        printSummary(succeeded: succeeded, failed: failed, verb: "Stripped")
    }
}
