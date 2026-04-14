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

// MARK: - Read Benchmarks

func benchmarkExiftoolRead(files: [URL]) -> Double {
    let paths = files.map { $0.path }

    let elapsed = measureTime("exiftool-read") {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        process.arguments = ["-json", "-IPTC:All", "-XMP:All", "-EXIF:All"] + paths
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    return elapsed
}

func benchmarkSwiftExifRead(files: [URL]) -> Double {
    let elapsed = measureTime("SwiftExif-read") {
        for file in files {
            let _ = try? ImageMetadata.read(from: file)
        }
    }

    return elapsed
}

func benchmarkSwiftExifReadBatch(files: [URL]) -> Double {
    let elapsed = measureTime("SwiftExif-read-batch") {
        let _ = try? BatchProcessor.processFiles(files) { _ in }
    }

    return elapsed
}

// MARK: - C2PA Benchmark Helpers

func buildBenchmarkCBORMap(_ pairs: [(String, Data)]) -> Data {
    var cbor = Data()
    let count = pairs.count
    if count <= 23 {
        cbor.append(0xA0 | UInt8(count))
    } else {
        cbor.append(contentsOf: [0xB8, UInt8(count)])
    }
    for (key, value) in pairs {
        let utf8 = [UInt8](key.utf8)
        if utf8.count <= 23 {
            cbor.append(0x60 | UInt8(utf8.count))
        } else {
            cbor.append(contentsOf: [0x78, UInt8(utf8.count)])
        }
        cbor.append(contentsOf: utf8)
        cbor.append(value)
    }
    return cbor
}

func buildBenchmarkCBORText(_ s: String) -> Data {
    let utf8 = [UInt8](s.utf8)
    var header: [UInt8]
    if utf8.count <= 23 {
        header = [0x60 | UInt8(utf8.count)]
    } else if utf8.count <= 255 {
        header = [0x78, UInt8(utf8.count)]
    } else {
        header = [0x79, UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)]
    }
    return Data(header + utf8)
}

func buildBenchmarkCBORBytes(_ bytes: Data) -> Data {
    let count = bytes.count
    var header: [UInt8]
    if count <= 23 {
        header = [0x40 | UInt8(count)]
    } else if count <= 255 {
        header = [0x58, UInt8(count)]
    } else {
        header = [0x59, UInt8(count >> 8), UInt8(count & 0xFF)]
    }
    return Data(header) + bytes
}

func buildBenchmarkBox(type: String, payload: Data) -> Data {
    let size = UInt32(8 + payload.count)
    var data = Data(capacity: Int(size))
    data.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
    data.append(type.data(using: .ascii)!)
    data.append(payload)
    return data
}

func buildBenchmarkJUMD(prefix: String, label: String) -> Data {
    var data = Data()
    data.append(contentsOf: [UInt8](prefix.utf8))
    data.append(contentsOf: [0x00, 0x11, 0x00, 0x10, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
    data.append(0x03)
    data.append(contentsOf: [UInt8](label.utf8))
    data.append(0x00)
    return data
}

func buildBenchmarkManifestStore(manifestCount: Int, assertionsPerManifest: Int) -> Data {
    var storePayload = Data()
    storePayload.append(buildBenchmarkBox(type: "jumd", payload: buildBenchmarkJUMD(prefix: "c2pa", label: "c2pa")))

    for m in 0..<manifestCount {
        var manifestPayload = Data()
        manifestPayload.append(buildBenchmarkBox(type: "jumd", payload: buildBenchmarkJUMD(prefix: "c2ma", label: "urn:c2pa:bench-\(m)")))

        // Claim
        let claimCBOR = buildBenchmarkCBORMap([
            ("claim_generator_info", Data([0x81]) + buildBenchmarkCBORMap([
                ("name", buildBenchmarkCBORText("BenchTool")),
                ("version", buildBenchmarkCBORText("1.0")),
            ])),
            ("instanceID", buildBenchmarkCBORText("xmp:iid:\(UUID().uuidString)")),
            ("dc:format", buildBenchmarkCBORText("image/jpeg")),
            ("dc:title", buildBenchmarkCBORText("Benchmark Asset \(m)")),
            ("alg", buildBenchmarkCBORText("sha256")),
        ])
        var claimSuper = Data()
        claimSuper.append(buildBenchmarkBox(type: "jumd", payload: buildBenchmarkJUMD(prefix: "c2cl", label: "c2pa.claim")))
        claimSuper.append(buildBenchmarkBox(type: "cbor", payload: claimCBOR))
        manifestPayload.append(buildBenchmarkBox(type: "jumb", payload: claimSuper))

        // Signature (COSE Sign1)
        var sigCBOR = Data()
        sigCBOR.append(0xD2) // tag 18
        sigCBOR.append(Data([0x84])) // array(4)
        var protectedMap = Data([0xA1]) // map(1)
        protectedMap.append(Data([0x01])) // key 1
        protectedMap.append(Data([0x26])) // -7 (ES256)
        sigCBOR.append(buildBenchmarkCBORBytes(protectedMap))
        sigCBOR.append(Data([0xA0])) // empty map
        sigCBOR.append(Data([0xF6])) // null
        sigCBOR.append(buildBenchmarkCBORBytes(Data(repeating: 0xFF, count: 64)))

        var sigSuper = Data()
        sigSuper.append(buildBenchmarkBox(type: "jumd", payload: buildBenchmarkJUMD(prefix: "c2cs", label: "c2pa.signature")))
        sigSuper.append(buildBenchmarkBox(type: "cbor", payload: sigCBOR))
        manifestPayload.append(buildBenchmarkBox(type: "jumb", payload: sigSuper))

        // Assertion store
        var assertionStorePayload = Data()
        assertionStorePayload.append(buildBenchmarkBox(type: "jumd", payload: buildBenchmarkJUMD(prefix: "c2as", label: "c2pa.assertions")))

        for a in 0..<assertionsPerManifest {
            let actionsCBOR = buildBenchmarkCBORMap([
                ("actions", Data([0x82]) + // array(2)
                    buildBenchmarkCBORMap([
                        ("action", buildBenchmarkCBORText("c2pa.created")),
                        ("softwareAgent", buildBenchmarkCBORText("BenchTool 1.0")),
                    ]) +
                    buildBenchmarkCBORMap([
                        ("action", buildBenchmarkCBORText("c2pa.edited")),
                        ("softwareAgent", buildBenchmarkCBORText("BenchEditor 2.0")),
                        ("description", buildBenchmarkCBORText("Benchmark edit operation \(a)")),
                    ])
                ),
            ])

            var assertionPayload = Data()
            assertionPayload.append(buildBenchmarkBox(type: "jumd", payload: buildBenchmarkJUMD(prefix: "c2as", label: "c2pa.actions")))
            assertionPayload.append(buildBenchmarkBox(type: "cbor", payload: actionsCBOR))
            assertionStorePayload.append(buildBenchmarkBox(type: "jumb", payload: assertionPayload))
        }

        // Add a hash.data assertion
        let hashCBOR = buildBenchmarkCBORMap([
            ("alg", buildBenchmarkCBORText("sha256")),
            ("hash", buildBenchmarkCBORBytes(Data(repeating: 0xAA, count: 32))),
            ("exclusions", Data([0x81]) + buildBenchmarkCBORMap([
                ("start", Data([0x19, 0x03, 0xE8])), // uint 1000
                ("length", Data([0x19, 0x07, 0xD0])), // uint 2000
            ])),
        ])
        var hashPayload = Data()
        hashPayload.append(buildBenchmarkBox(type: "jumd", payload: buildBenchmarkJUMD(prefix: "c2as", label: "c2pa.hash.data")))
        hashPayload.append(buildBenchmarkBox(type: "cbor", payload: hashCBOR))
        assertionStorePayload.append(buildBenchmarkBox(type: "jumb", payload: hashPayload))

        // Add an ingredient assertion
        let ingredientCBOR = buildBenchmarkCBORMap([
            ("dc:title", buildBenchmarkCBORText("source_\(m).jpg")),
            ("dc:format", buildBenchmarkCBORText("image/jpeg")),
            ("instanceID", buildBenchmarkCBORText("xmp:iid:\(UUID().uuidString)")),
            ("relationship", buildBenchmarkCBORText("parentOf")),
        ])
        var ingredientPayload = Data()
        ingredientPayload.append(buildBenchmarkBox(type: "jumd", payload: buildBenchmarkJUMD(prefix: "c2as", label: "c2pa.ingredient")))
        ingredientPayload.append(buildBenchmarkBox(type: "cbor", payload: ingredientCBOR))
        assertionStorePayload.append(buildBenchmarkBox(type: "jumb", payload: ingredientPayload))

        manifestPayload.append(buildBenchmarkBox(type: "jumb", payload: assertionStorePayload))
        storePayload.append(buildBenchmarkBox(type: "jumb", payload: manifestPayload))
    }

    var jumbfData = Data()
    jumbfData.append(buildBenchmarkBox(type: "jumb", payload: storePayload))
    return jumbfData
}

func benchmarkC2PAParsing(iterations: Int, manifestCount: Int, assertionsPerManifest: Int) -> (time: Double, dataSize: Int) {
    let data = buildBenchmarkManifestStore(manifestCount: manifestCount, assertionsPerManifest: assertionsPerManifest)

    let elapsed = measureTime("C2PA-parse") {
        for _ in 0..<iterations {
            let _ = try? C2PAReader.parseManifestStore(from: data)
        }
    }

    return (elapsed, data.count)
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

// --- Write Summary ---
print("┌──────────────────────────────────────────────────────────┐")
print("│  Write Results                                           │")
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

// ==========================================================================
// READ BENCHMARKS
// ==========================================================================
print()
print("╔══════════════════════════════════════════════════════════╗")
print("║       SwiftExif vs exiftool — Read Benchmark            ║")
print("╚══════════════════════════════════════════════════════════╝")
print()

// --- exiftool read (batch JSON) ---
print("5) exiftool — read batch (single invocation, \(fileCount) files)")
let exifReadFiles = copyFiles(source: sourceJPEG, to: tempDir, prefix: "exif_read", count: fileCount)
let exifReadTime = benchmarkExiftoolRead(files: exifReadFiles)
print(String(format: "   %.3f s  (%.1f ms/file)\n", exifReadTime, exifReadTime / Double(fileCount) * 1000))

// --- SwiftExif read sequential ---
print("6) SwiftExif — read sequential")
let swiftReadSeqFiles = copyFiles(source: sourceJPEG, to: tempDir, prefix: "swift_read_seq", count: fileCount)
let swiftReadSeqTime = benchmarkSwiftExifRead(files: swiftReadSeqFiles)
print(String(format: "   %.3f s  (%.1f ms/file)\n", swiftReadSeqTime, swiftReadSeqTime / Double(fileCount) * 1000))

// --- SwiftExif read batch (concurrent) ---
print("7) SwiftExif — read batch (concurrent, \(ProcessInfo.processInfo.activeProcessorCount) cores)")
let swiftReadBatchFiles = copyFiles(source: sourceJPEG, to: tempDir, prefix: "swift_read_batch", count: fileCount)
let swiftReadBatchTime = benchmarkSwiftExifReadBatch(files: swiftReadBatchFiles)
print(String(format: "   %.3f s  (%.1f ms/file)\n", swiftReadBatchTime, swiftReadBatchTime / Double(fileCount) * 1000))

// --- Read Summary ---
print("┌──────────────────────────────────────────────────────────┐")
print("│  Read Results                                            │")
print("├──────────────────────────────────────────────────────────┤")
print(String(format: "│  exiftool batch:        %7.3f s  (%5.1f ms/file)       │", exifReadTime, exifReadTime / Double(fileCount) * 1000))
print(String(format: "│  SwiftExif sequential:  %7.3f s  (%5.1f ms/file)       │", swiftReadSeqTime, swiftReadSeqTime / Double(fileCount) * 1000))
print(String(format: "│  SwiftExif batch:       %7.3f s  (%5.1f ms/file)       │", swiftReadBatchTime, swiftReadBatchTime / Double(fileCount) * 1000))
print("├──────────────────────────────────────────────────────────┤")

let readFastest = min(swiftReadSeqTime, swiftReadBatchTime)
let readSpeedup = exifReadTime / readFastest
print(String(format: "│  SwiftExif is %.0fx faster than exiftool (read)          │", readSpeedup))
print("└──────────────────────────────────────────────────────────┘")

// ==========================================================================
// C2PA PARSING BENCHMARK
// ==========================================================================
print()
print("╔══════════════════════════════════════════════════════════╗")
print("║       C2PA Manifest Store Parsing Benchmark             ║")
print("╚══════════════════════════════════════════════════════════╝")
print()

let c2paIterations = 1000

// Small: 1 manifest, 2 assertions
print("8) C2PA parse — small (1 manifest, 2 action assertions + hash + ingredient)")
let c2paSmall = benchmarkC2PAParsing(iterations: c2paIterations, manifestCount: 1, assertionsPerManifest: 2)
print(String(format: "   %d iterations, %.1f KB payload", c2paIterations, Double(c2paSmall.dataSize) / 1024))
print(String(format: "   %.3f s  (%.1f µs/parse)\n", c2paSmall.time, c2paSmall.time / Double(c2paIterations) * 1_000_000))

// Medium: 3 manifests, 5 assertions each
print("9) C2PA parse — medium (3 manifests, 5 action assertions + hash + ingredient each)")
let c2paMedium = benchmarkC2PAParsing(iterations: c2paIterations, manifestCount: 3, assertionsPerManifest: 5)
print(String(format: "   %d iterations, %.1f KB payload", c2paIterations, Double(c2paMedium.dataSize) / 1024))
print(String(format: "   %.3f s  (%.1f µs/parse)\n", c2paMedium.time, c2paMedium.time / Double(c2paIterations) * 1_000_000))

// Large: 10 manifests, 10 assertions each
print("10) C2PA parse — large (10 manifests, 10 action assertions + hash + ingredient each)")
let c2paLarge = benchmarkC2PAParsing(iterations: c2paIterations, manifestCount: 10, assertionsPerManifest: 10)
print(String(format: "   %d iterations, %.1f KB payload", c2paIterations, Double(c2paLarge.dataSize) / 1024))
print(String(format: "   %.3f s  (%.1f µs/parse)\n", c2paLarge.time, c2paLarge.time / Double(c2paIterations) * 1_000_000))

// --- C2PA Summary ---
print("┌──────────────────────────────────────────────────────────┐")
print("│  C2PA Parsing Results (per parse)                        │")
print("├──────────────────────────────────────────────────────────┤")
print(String(format: "│  Small  (%.1f KB):  %7.1f µs                           │", Double(c2paSmall.dataSize) / 1024, c2paSmall.time / Double(c2paIterations) * 1_000_000))
print(String(format: "│  Medium (%.1f KB):  %7.1f µs                           │", Double(c2paMedium.dataSize) / 1024, c2paMedium.time / Double(c2paIterations) * 1_000_000))
print(String(format: "│  Large  (%.1f KB): %7.1f µs                           │", Double(c2paLarge.dataSize) / 1024, c2paLarge.time / Double(c2paIterations) * 1_000_000))
print("└──────────────────────────────────────────────────────────┘")
