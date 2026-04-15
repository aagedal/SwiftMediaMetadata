import ArgumentParser
import Foundation
import SwiftExif

struct ThumbnailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thumbnail",
        abstract: "Extract embedded thumbnail from an image file."
    )

    @Argument(help: "Image file to extract thumbnail from.")
    var file: String

    @Option(name: .shortAndLong, help: "Output file path (default: <filename>_thumb.jpg).")
    var output: String?

    func run() throws {
        let url = URL(fileURLWithPath: file)
        let metadata = try ImageMetadata.read(from: url)

        guard let thumbnailData = metadata.extractThumbnail() else {
            printError("No embedded thumbnail found in \(url.lastPathComponent).")
            throw ExitCode.failure
        }

        let outputURL: URL
        if let output {
            outputURL = URL(fileURLWithPath: output)
        } else {
            let stem = url.deletingPathExtension().lastPathComponent
            let dir = url.deletingLastPathComponent()
            outputURL = dir.appendingPathComponent("\(stem)_thumb.jpg")
        }

        try thumbnailData.write(to: outputURL)
        print("Thumbnail extracted: \(outputURL.lastPathComponent) (\(thumbnailData.count) bytes)")
    }
}
