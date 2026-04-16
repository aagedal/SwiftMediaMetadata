import Foundation

enum ArgfileError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case readError(String, Error)

    var description: String {
        switch self {
        case .fileNotFound(let path):
            return "Error: Argfile not found: \(path)"
        case .readError(let path, let underlying):
            return "Error: Cannot read argfile '\(path)': \(underlying.localizedDescription)"
        }
    }
}

/// Expands `-@ ARGFILE` pairs in an argument array by reading arguments from the file.
/// Matches ExifTool behavior: one argument per line, `#` comments, blank lines ignored.
func expandArgfiles(_ arguments: [String]) throws -> [String] {
    var result: [String] = []
    var i = 0

    while i < arguments.count {
        if arguments[i] == "-@" {
            guard i + 1 < arguments.count else {
                result.append(arguments[i])
                i += 1
                continue
            }

            let source = arguments[i + 1]
            let lines = try readArgfile(source)
            result.append(contentsOf: lines)
            i += 2
        } else {
            result.append(arguments[i])
            i += 1
        }
    }

    return result
}

private func readArgfile(_ path: String) throws -> [String] {
    let content: String

    if path == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        content = String(data: data, encoding: .utf8) ?? ""
    } else {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ArgfileError.fileNotFound(path)
        }
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ArgfileError.readError(path, error)
        }
    }

    return parseArgfileContent(content)
}

func parseArgfileContent(_ content: String) -> [String] {
    content
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}
