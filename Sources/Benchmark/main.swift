import Foundation
import SwiftExif

// MARK: - Configuration

let fileCount = 100
let exiftoolPath = "/opt/homebrew/bin/exiftool"

// Metadata to write (identical for both tools)
let headline = "Sterk nordavind i Tromsø"
let byline = "Bjørn Ødegård"
let city = "Tromsø"
let country = "Norge"
let copyright = "© NTB / Bjørn Ødegård 2026"
let credit = "NTB Scanpix"
let keywords = ["vær", "storm", "Tromsø", "nordavind"]
let caption = "Kraftig nordavind i Tromsø førte til store bølger i havna."

// MARK: - Helpers

func findSourceJPEG() -> URL? {
    let candidates = [
        "TestImages/S01E13 The Parting of Ways-0003.jpg",
        "TestImages/DEI_8158_edit.jpg",
        "TestImages/Vixen 2026 05.jpg",
    ]
    for path in candidates {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
    }
    return nil
}

func createTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftexif_bench_\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func copyFiles(source: URL, to dir: URL, prefix: String, count: Int) -> [URL] {
    var urls: [URL] = []
    for i in 0..<count {
        let dest = dir.appendingPathComponent("\(prefix)_\(String(format: "%04d", i)).jpg")
        try? FileManager.default.copyItem(at: source, to: dest)
        urls.append(dest)
    }
    return urls
}

func cleanup(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

func measureTime(_ label: String, block: () throws -> Void) rethrows -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    try block()
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    return elapsed
}

// MARK: - Benchmarks

func benchmarkExiftool(files: [URL]) -> Double {
    // exiftool can process multiple files in a single invocation
    let paths = files.map { $0.path }

    let elapsed = measureTime("exiftool") {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        process.arguments = [
            "-overwrite_original",
            "-IPTC:Headline=\(headline)",
            "-IPTC:By-line=\(byline)",
            "-IPTC:City=\(city)",
            "-IPTC:Country-PrimaryLocationName=\(country)",
            "-IPTC:CopyrightNotice=\(copyright)",
            "-IPTC:Credit=\(credit)",
            "-IPTC:Caption-Abstract=\(caption)",
        ] + keywords.map { "-IPTC:Keywords=\($0)" }
          + [
            "-XMP:Headline=\(headline)",
            "-XMP:Creator=\(byline)",
            "-XMP:City=\(city)",
            "-XMP:Country=\(country)",
            "-XMP:Rights=\(copyright)",
            "-XMP:Credit=\(credit)",
            "-XMP:Description=\(caption)",
        ] + keywords.map { "-XMP:Subject=\($0)" }
          + paths

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try? process.run()
        process.waitUntilExit()
    }

    return elapsed
}

func benchmarkExiftoolOneByOne(files: [URL]) -> Double {
    let elapsed = measureTime("exiftool-sequential") {
        for file in files {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exiftoolPath)
            process.arguments = [
                "-overwrite_original",
                "-IPTC:Headline=\(headline)",
                "-IPTC:By-line=\(byline)",
                "-IPTC:City=\(city)",
                "-IPTC:Country-PrimaryLocationName=\(country)",
                "-IPTC:CopyrightNotice=\(copyright)",
                "-IPTC:Credit=\(credit)",
                "-IPTC:Caption-Abstract=\(caption)",
                "-XMP:Headline=\(headline)",
                "-XMP:Creator=\(byline)",
                "-XMP:City=\(city)",
                "-XMP:Country=\(country)",
                "-XMP:Rights=\(copyright)",
                "-XMP:Credit=\(credit)",
                "-XMP:Description=\(caption)",
            ] + keywords.map { "-IPTC:Keywords=\($0)" }
              + keywords.map { "-XMP:Subject=\($0)" }
              + [file.path]

            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            try? process.run()
            process.waitUntilExit()
        }
    }

    return elapsed
}

func benchmarkSwiftExif(files: [URL]) -> Double {
    let elapsed = measureTime("SwiftExif") {
        for file in files {
            do {
                var metadata = try ImageMetadata.read(from: file)

                metadata.iptc.headline = headline
                metadata.iptc.byline = byline
                metadata.iptc.city = city
                metadata.iptc.countryName = country
                metadata.iptc.copyright = copyright
                metadata.iptc.credit = credit
                metadata.iptc.caption = caption
                metadata.iptc.keywords = keywords

                metadata.syncIPTCToXMP()

                try metadata.write(to: file)
            } catch {
                print("  Error: \(error)")
            }
        }
    }

    return elapsed
}

func benchmarkSwiftExifBatch(files: [URL]) -> Double {
    let elapsed = measureTime("SwiftExif-batch") {
        let result = try? BatchProcessor.processFiles(files) { metadata in
            metadata.iptc.headline = headline
            metadata.iptc.byline = byline
            metadata.iptc.city = city
            metadata.iptc.countryName = country
            metadata.iptc.copyright = copyright
            metadata.iptc.credit = credit
            metadata.iptc.caption = caption
            metadata.iptc.keywords = keywords

            metadata.syncIPTCToXMP()
        }
        if let r = result, !r.failed.isEmpty {
            print("  \(r.failed.count) failures")
        }
    }

    return elapsed
}

// MARK: - Verification

func verify(files: [URL]) {
    guard let first = files.first else { return }
    do {
        let m = try ImageMetadata.read(from: first)
        let ok = m.iptc.headline == headline
            && m.iptc.byline == byline
            && m.iptc.city == city
            && m.iptc.keywords == keywords
            && m.xmp?.headline == headline
        print(ok ? "  ✓ Metadata verified" : "  ✗ Metadata mismatch!")
    } catch {
        print("  ✗ Verification error: \(error)")
    }
}

// MARK: - Main

guard let sourceJPEG = findSourceJPEG() else {
    print("No test JPEG found in TestImages/. Place a JPEG file there and retry.")
    exit(1)
}

let sourceSize = (try? FileManager.default.attributesOfItem(atPath: sourceJPEG.path)[.size] as? Int) ?? 0

print("╔══════════════════════════════════════════════════════════╗")
print("║       SwiftExif vs exiftool — Write Benchmark           ║")
print("╠══════════════════════════════════════════════════════════╣")
print("║  Source:  \(sourceJPEG.lastPathComponent)")
print("║  Size:    \(String(format: "%.1f", Double(sourceSize) / 1024))  KB")
print("║  Files:   \(fileCount)")
print("║  Fields:  IPTC (8 fields) + XMP sync (8 fields)")
print("╚══════════════════════════════════════════════════════════╝")
print()

let tempDir = createTempDir()
defer { cleanup(tempDir) }

// --- exiftool batch ---
print("1) exiftool — batch mode (single invocation, \(fileCount) files)")
let exifBatchFiles = copyFiles(source: sourceJPEG, to: tempDir, prefix: "exif_batch", count: fileCount)
let exifBatchTime = benchmarkExiftool(files: exifBatchFiles)
verify(files: exifBatchFiles)
print(String(format: "   %.3f s  (%.1f ms/file)\n", exifBatchTime, exifBatchTime / Double(fileCount) * 1000))

// --- exiftool one-by-one ---
print("2) exiftool — sequential (one invocation per file)")
let exifSeqFiles = copyFiles(source: sourceJPEG, to: tempDir, prefix: "exif_seq", count: fileCount)
let exifSeqTime = benchmarkExiftoolOneByOne(files: exifSeqFiles)
verify(files: exifSeqFiles)
print(String(format: "   %.3f s  (%.1f ms/file)\n", exifSeqTime, exifSeqTime / Double(fileCount) * 1000))

// --- SwiftExif sequential ---
print("3) SwiftExif — sequential")
let swiftSeqFiles = copyFiles(source: sourceJPEG, to: tempDir, prefix: "swift_seq", count: fileCount)
let swiftSeqTime = benchmarkSwiftExif(files: swiftSeqFiles)
verify(files: swiftSeqFiles)
print(String(format: "   %.3f s  (%.1f ms/file)\n", swiftSeqTime, swiftSeqTime / Double(fileCount) * 1000))

// --- SwiftExif batch (concurrent) ---
print("4) SwiftExif — batch (concurrent, \(ProcessInfo.processInfo.activeProcessorCount) cores)")
let swiftBatchFiles = copyFiles(source: sourceJPEG, to: tempDir, prefix: "swift_batch", count: fileCount)
let swiftBatchTime = benchmarkSwiftExifBatch(files: swiftBatchFiles)
verify(files: swiftBatchFiles)
print(String(format: "   %.3f s  (%.1f ms/file)\n", swiftBatchTime, swiftBatchTime / Double(fileCount) * 1000))

// --- Summary ---
print("┌──────────────────────────────────────────────────────────┐")
print("│  Results                                                 │")
print("├──────────────────────────────────────────────────────────┤")
print(String(format: "│  exiftool batch:        %7.3f s  (%5.1f ms/file)       │", exifBatchTime, exifBatchTime / Double(fileCount) * 1000))
print(String(format: "│  exiftool sequential:   %7.3f s  (%5.1f ms/file)       │", exifSeqTime, exifSeqTime / Double(fileCount) * 1000))
print(String(format: "│  SwiftExif sequential:  %7.3f s  (%5.1f ms/file)       │", swiftSeqTime, swiftSeqTime / Double(fileCount) * 1000))
print(String(format: "│  SwiftExif batch:       %7.3f s  (%5.1f ms/file)       │", swiftBatchTime, swiftBatchTime / Double(fileCount) * 1000))
print("├──────────────────────────────────────────────────────────┤")

let fastest = min(swiftSeqTime, swiftBatchTime)
let slowest = max(exifBatchTime, exifSeqTime)
let speedup = slowest / fastest

print(String(format: "│  SwiftExif is %.0fx faster than exiftool (best vs worst) │", speedup))

let fairSpeedup = exifSeqTime / swiftSeqTime
print(String(format: "│  Sequential comparison: %.0fx faster                      │", fairSpeedup))
print("└──────────────────────────────────────────────────────────┘")
