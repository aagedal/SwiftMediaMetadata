#if os(macOS)
import Foundation
import XCTest

/// Shared harness for black-box CLI tests. Every test case should inherit
/// from `CLITestCase` so that tests are automatically skipped when the
/// `SWIFT_EXIF_RUN_CLI_TESTS` opt-in env var is unset. That keeps the regular
/// `swift test` run fast and focused on library code.
enum CLITestHarness {
    static let optInEnvVar = "SWIFT_EXIF_RUN_CLI_TESTS"
    static let binaryOverrideEnvVar = "SWIFT_EXIF_CLI_BINARY"

    static var enabled: Bool {
        let value = ProcessInfo.processInfo.environment[optInEnvVar]?.lowercased() ?? ""
        return value == "1" || value == "true" || value == "yes"
    }

    /// Locate the built `swift-exif` executable. Honors `SWIFT_EXIF_CLI_BINARY`
    /// as an override; otherwise walks up from this source file to the package
    /// root and tries `.build/debug/swift-exif` then `.build/release/swift-exif`.
    static func binaryURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment[binaryOverrideEnvVar],
           !override.isEmpty
        {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
            throw HarnessError.binaryNotExecutable(url.path)
        }

        // #filePath → Tests/SwiftExifCLITests/CLITestHarness.swift
        // Package root is two directories up.
        let thisFile = URL(fileURLWithPath: #filePath)
        let packageRoot = thisFile
            .deletingLastPathComponent() // SwiftExifCLITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // package root

        let candidates = [
            packageRoot.appendingPathComponent(".build/debug/swift-exif"),
            packageRoot.appendingPathComponent(".build/release/swift-exif"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        throw HarnessError.binaryNotFound(candidates.map(\.path))
    }

    // MARK: - Subprocess runner

    struct Result {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    /// Run the CLI binary with the given arguments. Captures stdout/stderr.
    /// If `stdin` is provided, it is piped into the process.
    @discardableResult
    static func run(
        _ args: [String],
        stdin: String? = nil,
        cwd: URL? = nil,
        timeout: TimeInterval = 30
    ) throws -> Result {
        let binary = try binaryURL()
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe = Pipe()
        if stdin != nil {
            process.standardInput = stdinPipe
        }

        try process.run()

        if let stdin {
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }

        // Poll for completion with a timeout so a hung subprocess can't freeze CI.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw HarnessError.timeout(timeout)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    // MARK: - Fixtures

    /// A pre-built minimal JPEG (SOI + APP0 + DQT + SOF0 + DHT + SOS + EOI).
    /// Mirrors `TestFixtures.minimalJPEG()` but constructed in a non-@testable
    /// target so we don't need access to internal binary writers.
    static let minimalJPEG: Data = {
        var d = Data()
        // SOI
        d.append(contentsOf: [0xFF, 0xD8])
        // APP0 JFIF segment
        d.append(contentsOf: [0xFF, 0xE0, 0x00, 0x10])
        d.append(contentsOf: [
            0x4A, 0x46, 0x49, 0x46, 0x00, // "JFIF\0"
            0x01, 0x01,                   // version 1.1
            0x00,                         // units
            0x00, 0x01, 0x00, 0x01,       // x/y density 1
            0x00, 0x00,                   // thumb 0x0
        ])
        // DQT
        d.append(contentsOf: [0xFF, 0xDB, 0x00, 0x43, 0x00])
        d.append(contentsOf: [UInt8](repeating: 0x01, count: 64))
        // SOF0 (1x1 grayscale)
        d.append(contentsOf: [0xFF, 0xC0, 0x00, 0x0B,
                              0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00])
        // DHT
        d.append(contentsOf: [0xFF, 0xC4, 0x00, 0x14, 0x00])
        d.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        d.append(0x00)
        // SOS
        d.append(contentsOf: [0xFF, 0xDA, 0x00, 0x08,
                              0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
        // Scan data + EOI
        d.append(contentsOf: [0x7F, 0xFF, 0xD9])
        return d
    }()

    enum HarnessError: Error, CustomStringConvertible {
        case binaryNotFound([String])
        case binaryNotExecutable(String)
        case timeout(TimeInterval)

        var description: String {
            switch self {
            case .binaryNotFound(let paths):
                return "swift-exif binary not found. Tried: \(paths.joined(separator: ", "))"
            case .binaryNotExecutable(let path):
                return "SWIFT_EXIF_CLI_BINARY points to a non-executable: \(path)"
            case .timeout(let t):
                return "CLI subprocess timed out after \(t)s"
            }
        }
    }
}

/// Base class that skips every test when opt-in env var is not set.
class CLITestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            CLITestHarness.enabled,
            "CLI tests are opt-in. Set \(CLITestHarness.optInEnvVar)=1 to run them " +
            "(or use Scripts/run-cli-tests.sh)."
        )
    }

    /// Create a temporary directory for a single test. Auto-deleted in tearDown.
    func makeTempDir(function: String = #function) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("swift-exif-cli-tests", isDirectory: true)
            .appendingPathComponent("\(function)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempDirs.append(base)
        return base
    }

    /// Write a minimal JPEG fixture into `dir` under `name` and return the URL.
    func writeMinimalJPEG(in dir: URL, name: String = "fixture.jpg") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try CLITestHarness.minimalJPEG.write(to: url)
        return url
    }

    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        try super.tearDownWithError()
    }
}
#endif
