import ArgumentParser
import Foundation
import SwiftExif

/// `swift-exif braw-frames file.braw [--stream attributes|gyroscope|accelerometer] [--output frames.csv]`
///
/// Walk every frame's `bmdf` interpretation header (or every IMU sample
/// in a BRAW `mebx` motion-data track) and emit CSV. One stream per
/// invocation — mixing 24 fps attributes with 1 kHz IMU data in a single
/// file would produce ragged columns; consumers can merge with pandas /
/// duckdb if that's actually wanted.
///
/// Defaults to attributes (the small per-frame stream) on stdout. Use
/// `-o` to write a file instead.
struct BRAWFramesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "braw-frames",
        abstract: "Export BRAW per-frame metadata or IMU samples as CSV."
    )

    enum Stream: String, ExpressibleByArgument, CaseIterable {
        case attributes
        case gyroscope
        case accelerometer
    }

    @Argument(help: "BRAW file to read.")
    var file: String

    @Option(
        name: .shortAndLong,
        help: ArgumentHelp(
            "Stream to export.",
            discussion: """
                attributes  — one row per video frame: shutter angle, aperture,
                              focal length, focus distance, ISO, white-balance
                              Kelvin / tint (default).
                gyroscope   — IMU samples (rad/s, ~1 kHz).
                accelerometer — IMU samples (m/s²; gravity observable on the
                              up-axis at record-start).
                """
        )
    )
    var stream: Stream = .attributes

    @Option(name: .shortAndLong, help: "Output CSV path (default: stdout).")
    var output: String?

    func run() throws {
        let url = URL(fileURLWithPath: file)
        let csv: String
        switch stream {
        case .attributes:
            let frames = try BRAWFrameReader.readAttributes(from: url)
            guard !frames.isEmpty else {
                printError("No BRAW video frames found in \(url.lastPathComponent).")
                throw ExitCode.failure
            }
            csv = renderAttributesCSV(frames)
        case .gyroscope, .accelerometer:
            let braw: BRAWMotionStream = (stream == .gyroscope) ? .gyroscope : .accelerometer
            let samples = try BRAWFrameReader.readMotionSamples(from: url, stream: braw)
            guard !samples.isEmpty else {
                printError("No \(stream.rawValue) samples found in \(url.lastPathComponent).")
                throw ExitCode.failure
            }
            csv = renderMotionCSV(samples)
        }

        if let outputPath = output {
            try csv.write(toFile: outputPath, atomically: true, encoding: .utf8)
            print("Wrote \(stream.rawValue) CSV to \(outputPath)")
        } else {
            // CSV already ends with a newline — no extra terminator.
            print(csv, terminator: "")
        }
    }

    // MARK: - Renderers

    /// Attributes CSV: numeric columns where possible (suffixes like `°`,
    /// `f`, `mm` stripped), so graphing tools render directly without a
    /// preprocess step. Empty cell on parse fail or when the field was nil.
    private func renderAttributesCSV(_ frames: [BRAWFrameAttribute]) -> String {
        var lines: [String] = []
        lines.append("frame_index,timestamp_s,shutter_angle_deg,aperture_f,focal_length_mm,focus_distance_mm,iso,wb_kelvin,wb_tint")
        for f in frames {
            let cells: [String] = [
                "\(f.frameIndex)",
                formatTimestamp(f.timestampSeconds),
                stripIntSuffix(f.shutterAngle, suffix: "°"),
                stripDoublePrefix(f.aperture, prefix: "f"),
                stripIntSuffix(f.focalLength, suffix: "mm"),
                stripIntSuffix(f.focusDistance, suffix: "mm"),
                f.iso.map(String.init) ?? "",
                f.whiteBalanceKelvin.map(String.init) ?? "",
                f.whiteBalanceTint.map(String.init) ?? "",
            ]
            lines.append(cells.map(CSVExporter.escapeCSV).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func renderMotionCSV(_ samples: [BRAWMotionSample]) -> String {
        var lines: [String] = []
        lines.append("timestamp_s,x,y,z")
        for s in samples {
            let row = [
                formatTimestamp(s.timestampSeconds),
                formatFloat(s.x),
                formatFloat(s.y),
                formatFloat(s.z),
            ]
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Cell formatting

    /// Strip a fixed trailing string from a slate value and parse the
    /// remainder as Int. Returns the empty string when input is nil or
    /// the parse fails — keeps CSV columns numeric without dragging
    /// non-numeric cells along.
    private func stripIntSuffix(_ s: String?, suffix: String) -> String {
        guard let s, s.hasSuffix(suffix) else { return s ?? "" }
        let trimmed = String(s.dropLast(suffix.count))
        return Int(trimmed).map(String.init) ?? ""
    }

    private func stripDoublePrefix(_ s: String?, prefix: String) -> String {
        guard let s, s.hasPrefix(prefix) else { return s ?? "" }
        let trimmed = String(s.dropFirst(prefix.count))
        // Format with up to 6 significant digits — typical aperture
        // resolution is one decimal but BMD writes whatever the lens
        // reports.
        return Double(trimmed).map { "\($0)" } ?? ""
    }

    /// Six decimals on the timestamp keeps μs-resolution timestamps
    /// without gratuitous trailing zeros (the IMU stream is ~1 kHz, so
    /// six decimals leaves three digits of headroom).
    private func formatTimestamp(_ v: Double) -> String {
        return String(format: "%.6f", v)
    }

    private func formatFloat(_ v: Float) -> String {
        return String(format: "%.6f", v)
    }
}
