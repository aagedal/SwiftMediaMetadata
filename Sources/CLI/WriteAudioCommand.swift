import ArgumentParser
import Foundation
import SwiftExif

struct WriteAudioCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write-audio",
        abstract: "Set metadata tags on audio files (MP3, FLAC, M4A)."
    )

    @Argument(help: "Audio files to modify.")
    var files: [String]

    @Option(name: .long, help: "Set the title.")
    var title: String?

    @Option(name: .long, help: "Set the artist.")
    var artist: String?

    @Option(name: .long, help: "Set the album.")
    var album: String?

    @Option(name: .long, help: "Set the track number.")
    var track: Int?

    @Option(name: .long, help: "Set the genre.")
    var genre: String?

    @Option(name: .long, help: "Set a comment.")
    var comment: String?

    @Option(name: .long, help: "Set the year.")
    var year: String?

    @Option(name: .long, help: "Set the album artist.")
    var albumArtist: String?

    @Option(name: .long, help: "Set the composer.")
    var composer: String?

    @Flag(name: .long, help: "Strip all metadata tags.")
    var strip = false

    @Flag(name: .long, help: "Create backup of original file.")
    var backup = false

    func validate() throws {
        let hasWrite = title != nil || artist != nil || album != nil || track != nil ||
                       genre != nil || comment != nil || year != nil || albumArtist != nil || composer != nil
        guard hasWrite || strip else {
            throw ValidationError("Provide at least one metadata option or --strip.")
        }
    }

    func run() throws {
        let audioExtensions: Set<String> = ["mp3", "flac", "m4a"]
        let urls = try resolveFiles(files)
        var succeeded = 0
        var failed = 0

        for url in urls {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else {
                printError("Skipping non-audio file: \(url.lastPathComponent)")
                continue
            }

            do {
                var metadata = try AudioMetadata.read(from: url)

                if strip { metadata.stripMetadata() }

                if let t = title { metadata.title = t }
                if let a = artist { metadata.artist = a }
                if let al = album { metadata.album = al }
                if let tr = track { metadata.trackNumber = tr }
                if let g = genre { metadata.genre = g }
                if let c = comment { metadata.comment = c }
                if let y = year { metadata.year = y }
                if let aa = albumArtist { metadata.albumArtist = aa }
                if let co = composer { metadata.composer = co }

                if backup {
                    let backupURL = ImageMetadata.backupURL(for: url)
                    let fm = FileManager.default
                    try? fm.removeItem(at: backupURL)
                    try fm.copyItem(at: url, to: backupURL)
                }

                try metadata.write(to: url)
                succeeded += 1
            } catch {
                printError("Error writing \(url.lastPathComponent): \(error.localizedDescription)")
                failed += 1
            }
        }

        printSummary(succeeded: succeeded, failed: failed, verb: "Updated")
    }
}
