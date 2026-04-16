import ArgumentParser
import Foundation

/// Implements ExifTool-compatible `-stay_open` batch mode.
///
/// Protocol:
/// - Process stays alive, reading commands from stdin line-by-line
/// - Each command is a sequence of arguments (one per line), terminated by `-execute` or `-executeNUM`
/// - After processing, outputs results followed by `{ready}` or `{readyNUM}` on stdout
/// - `-common_args` sets arguments appended to every subsequent command
/// - `-stay_open False` or `-stay_open 0` shuts down the server
/// - EOF on stdin also shuts down
///
/// Used by Lightroom, darktable, digiKam, and other apps that integrate ExifTool
/// to avoid paying process startup cost on every operation.
struct StayOpenServer {
    private var commonArgs: [String] = []

    mutating func run() {
        // Unbuffer stdout so sentinels are flushed immediately.
        setbuf(stdout, nil)

        var currentArgs: [String] = []

        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip blank lines and comments (argfile convention).
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Check for -execute or -executeNUM sentinel.
            if let tag = parseExecuteSentinel(trimmed) {
                executeCommand(currentArgs, tag: tag)
                currentArgs = []
                continue
            }

            // Handle -stay_open False/0 to shut down.
            if trimmed.lowercased() == "-stay_open" {
                // The value is on the next line.
                if let valueLine = readLine(strippingNewline: true) {
                    let value = valueLine.trimmingCharacters(in: .whitespaces).lowercased()
                    if value == "false" || value == "0" {
                        return
                    }
                }
                continue
            }

            // Handle -common_args: everything after this until -execute becomes
            // the new common args, replacing any previous ones.
            if trimmed == "-common_args" {
                // Flush current args into commonArgs collection mode.
                commonArgs = []
                // Read lines until -execute, storing them as common args.
                while let argLine = readLine(strippingNewline: true) {
                    let argTrimmed = argLine.trimmingCharacters(in: .whitespaces)
                    if argTrimmed.isEmpty || argTrimmed.hasPrefix("#") {
                        continue
                    }
                    if let tag = parseExecuteSentinel(argTrimmed) {
                        // Common args are set; emit ready.
                        emitReady(tag: tag)
                        break
                    }
                    commonArgs.append(argTrimmed)
                }
                continue
            }

            currentArgs.append(trimmed)
        }

        // EOF reached — shut down gracefully.
    }

    // MARK: - Command Execution

    private func executeCommand(_ args: [String], tag: String) {
        let fullArgs = args + commonArgs

        guard !fullArgs.isEmpty else {
            emitReady(tag: tag)
            return
        }

        do {
            let expandedArgs = try expandArgfiles(fullArgs)
            // Parse and run through ArgumentParser.
            // We catch the exit to prevent the process from terminating.
            var command = try SwiftExifCLI.parseAsRoot(expandedArgs)
            try command.run()
        } catch {
            // ArgumentParser throws CleanExit for --help/--version.
            if case let cleanExit as CleanExit = error {
                let message = SwiftExifCLI.message(for: cleanExit)
                if !message.isEmpty {
                    print(message)
                }
            } else {
                let message = SwiftExifCLI.fullMessage(for: error)
                printError(message)
            }
        }

        emitReady(tag: tag)
    }

    // MARK: - Sentinel Parsing

    /// Parses `-execute` or `-executeNUM` and returns the tag (empty string or NUM).
    private func parseExecuteSentinel(_ str: String) -> String? {
        guard str.hasPrefix("-execute") else { return nil }

        let rest = str.dropFirst("-execute".count)

        // Plain `-execute` → empty tag.
        if rest.isEmpty {
            return ""
        }

        // `-executeNUM` where NUM is digits only.
        if rest.allSatisfy(\.isNumber) {
            return String(rest)
        }

        // Not a valid execute sentinel (e.g. `-executeFoo`).
        return nil
    }

    /// Writes the `{ready}` or `{readyNUM}` sentinel to stdout.
    private func emitReady(tag: String) {
        if tag.isEmpty {
            print("{ready}")
        } else {
            print("{ready\(tag)}")
        }
        fflush(stdout)
    }
}
