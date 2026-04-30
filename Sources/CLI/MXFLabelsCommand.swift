import ArgumentParser
import Foundation
import SwiftExif

/// `swift-exif mxf-labels file.mxf [--output labels.txt]`
///
/// Read the SMPTE ST 377-4 Multi-Channel Audio labelling from an MXF file and
/// render it back in bmxtools `--audio-labels` input format. Round-trips
/// labelling between `bmxtranswrap` outputs and inputs.
struct MXFLabelsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mxf-labels",
        abstract: "Export MXF MCA / soundfield labels in bmxtools labels.txt format."
    )

    @Argument(help: "MXF file to read MCA labels from.")
    var file: String

    @Option(name: .shortAndLong, help: "Output labels.txt path (default: stdout).")
    var output: String?

    func run() throws {
        let url = URL(fileURLWithPath: file)
        let metadata = try VideoMetadata.read(from: url)

        guard let labeling = metadata.mcaAudioLabeling, !labeling.isEmpty else {
            printError("No MCA / soundfield labels found in \(url.lastPathComponent).")
            throw ExitCode.failure
        }

        let text = MCALabelsRenderer.render(labeling)

        if let outputPath = output {
            try text.write(toFile: outputPath, atomically: true, encoding: .utf8)
            print("Wrote \(labeling.channels.count) channel labels to \(outputPath)")
        } else {
            // Trim a trailing newline added by the renderer's blank-line
            // separator so stdout doesn't double-blank when piped.
            print(text, terminator: "")
        }
    }
}
