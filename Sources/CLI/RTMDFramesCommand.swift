import ArgumentParser
import Foundation
import SwiftExif

/// `swift-exif rtmd-frames file.mp4 [--stream attributes|gyroscope|accelerometer] [--output frames.csv]`
///
/// Walk every sample in a Sony Real-Time Metadata (`rtmd`) track and emit
/// CSV. One stream per invocation — the per-frame attribute stream runs at
/// video frame rate (50 Hz on the Alpha sample), while the IMU streams
/// expand to ~2 kHz (40 IMU samples per video frame).
struct RTMDFramesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rtmd-frames",
        abstract: "Export Sony RTMD per-frame metadata or IMU samples as CSV."
    )

    enum Stream: String, ExpressibleByArgument, CaseIterable {
        case attributes
        case gyroscope
        case accelerometer
    }

    @Argument(help: "MP4/MOV file containing a Sony RTMD track.")
    var file: String

    @Option(
        name: .shortAndLong,
        help: ArgumentHelp(
            "Stream to export.",
            discussion: """
                attributes  — one row per video frame: ISO, shutter angle/time,
                              focal length, focus distance, iris F, white-balance K,
                              gamma, camera tilt/roll (default).
                gyroscope   — IMU pitch/roll/yaw samples in raw signed-integer
                              counts (per-camera scale; ~2 kHz on Sony Alpha).
                accelerometer — IMU x/y/z samples in raw signed-integer counts
                              (gravity observable on the up-axis ≈ 8000+).
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
            let frames = try RTMDReader.readAttributes(from: url)
            guard !frames.isEmpty else {
                printError("No RTMD samples found in \(url.lastPathComponent).")
                throw ExitCode.failure
            }
            csv = renderAttributesCSV(frames)
        case .gyroscope, .accelerometer:
            let s: RTMDStream = (stream == .gyroscope) ? .gyroscope : .accelerometer
            let samples = try RTMDReader.readMotionSamples(from: url, stream: s)
            guard !samples.isEmpty else {
                printError("No \(stream.rawValue) samples found in \(url.lastPathComponent).")
                throw ExitCode.failure
            }
            csv = renderMotionCSV(samples, stream: stream)
        }

        if let outputPath = output {
            try csv.write(toFile: outputPath, atomically: true, encoding: .utf8)
            print("Wrote \(stream.rawValue) CSV to \(outputPath)")
        } else {
            print(csv, terminator: "")
        }
    }

    // MARK: - Renderers

    private func renderAttributesCSV(_ frames: [RTMDFrameAttribute]) -> String {
        var lines: [String] = []
        lines.append("frame_index,timestamp_s,iso,exposure_time_s,f_number,focal_length_mm,white_balance,frame_rate,gps_lat,gps_lon,date_time,serial_number")
        for f in frames {
            let cells: [String] = [
                "\(f.frameIndex)",
                formatTimestamp(f.timestampSeconds),
                f.iso.map(String.init) ?? "",
                f.exposureTimeSeconds.map { String(format: "%.6f", $0) } ?? "",
                f.fNumber.map { formatDouble($0) } ?? "",
                f.focalLengthMm.map { formatDouble($0) } ?? "",
                f.whiteBalance ?? "",
                f.frameRate.map { formatDouble($0) } ?? "",
                f.gpsLatitude.map { String(format: "%.6f", $0) } ?? "",
                f.gpsLongitude.map { String(format: "%.6f", $0) } ?? "",
                f.dateTime ?? "",
                f.serialNumber ?? "",
            ]
            lines.append(cells.map(CSVExporter.escapeCSV).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func renderMotionCSV(_ samples: [RTMDMotionSample], stream: Stream) -> String {
        var lines: [String] = []
        // Pitch/roll/yaw vs x/y/z naming reflects how Sony / ExifTool label
        // the gyroscope vs accelerometer arrays.
        switch stream {
        case .gyroscope:
            lines.append("timestamp_s,pitch,roll,yaw")
        case .accelerometer:
            lines.append("timestamp_s,x,y,z")
        case .attributes:
            break
        }
        for s in samples {
            let row = [
                formatTimestamp(s.timestampSeconds),
                String(s.x),
                String(s.y),
                String(s.z),
            ]
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Cell formatting

    private func formatTimestamp(_ v: Double) -> String {
        return String(format: "%.6f", v)
    }

    private func formatDouble(_ v: Double) -> String {
        return String(format: "%.4f", v)
    }
}
