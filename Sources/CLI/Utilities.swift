import ArgumentParser
import Foundation
import SwiftExif

/// Resolve file arguments to URLs, expanding directories and applying filters.
func resolveFiles(_ paths: [String], filter: FileFilterOptions = FileFilterOptions()) throws -> [URL] {
    var urls: [URL] = []
    let fm = FileManager.default
    let extFilter = Set(filter.ext.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
    let ignoreDirs = Set(filter.ignore)

    for path in paths {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false

        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                if filter.recursive {
                    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                        for case let fileURL as URL in enumerator {
                            if let isSubDir = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isSubDir {
                                if ignoreDirs.contains(fileURL.lastPathComponent) {
                                    enumerator.skipDescendants()
                                }
                                continue
                            }
                            if isMatchingFile(fileURL, extFilter: extFilter) {
                                urls.append(fileURL)
                            }
                        }
                    }
                } else {
                    if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        urls.append(contentsOf: contents.filter { isMatchingFile($0, extFilter: extFilter) })
                    }
                }
            } else {
                urls.append(url)
            }
        } else {
            printError("File not found: \(path)")
        }
    }

    return urls
}

/// Check if a file matches the extension filter (or all supported if no filter).
private func isMatchingFile(_ url: URL, extFilter: Set<String>) -> Bool {
    guard isSupportedFile(url) else { return false }
    if extFilter.isEmpty { return true }
    return extFilter.contains(url.pathExtension.lowercased())
}

/// Check if a URL has a supported image or video extension.
func isSupportedFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    let supported: Set<String> = [
        "jpg", "jpeg", "tif", "tiff", "dng", "cr2", "cr3", "nef", "arw",
        "raf", "rw2", "orf", "pef",
        "jxl", "png", "avif", "heic", "heif", "webp",
        "gif", "bmp", "dib", "svg",
        "mp4", "mov", "m4v",
        "mp3", "flac", "m4a",
    ]
    return supported.contains(ext)
}

/// Print an error message to stderr.
func printError(_ message: String) {
    let stderr = FileHandle.standardError
    stderr.write(Data((message + "\n").utf8))
}

extension FileHandle: @retroactive TextOutputStream {
    public func write(_ string: String) {
        let data = Data(string.utf8)
        self.write(data)
    }
}

/// Print a file separator header.
func printSeparator(_ filename: String) {
    print("======== \(filename) ========")
}

/// Print a success/failure summary line.
func printSummary(succeeded: Int, failed: Int, verb: String) {
    if failed == 0 {
        print("\(verb) \(succeeded) file(s).")
    } else {
        print("\(verb) \(succeeded) file(s), \(failed) failed.")
    }
}

// MARK: - Condition Parsing

/// Parse CLI condition strings into MetadataCondition.
/// Supports: Field=Value, Field!=Value, Field~Substring, Field>N, Field<N, Field>=N, Field<=N, Field?
func parseConditions(_ conditions: [String]) throws -> MetadataCondition? {
    guard !conditions.isEmpty else { return nil }

    let parsed = try conditions.map { try parseOneCondition($0) }

    if parsed.count == 1 {
        return parsed[0]
    }
    return .and(parsed)
}

private func parseOneCondition(_ str: String) throws -> MetadataCondition {
    // Field? (exists)
    if str.hasSuffix("?") {
        let field = String(str.dropLast())
        return .exists(field: field)
    }

    // Field!=Value
    if let range = str.range(of: "!=") {
        let field = String(str[str.startIndex..<range.lowerBound])
        let value = String(str[range.upperBound...])
        return .notEquals(field: field, value: value)
    }

    // Field>=N
    if let range = str.range(of: ">=") {
        let field = String(str[str.startIndex..<range.lowerBound])
        let value = String(str[range.upperBound...])
        guard let num = Double(value) else {
            throw ValidationError("Invalid numeric value in condition: \(str)")
        }
        return .greaterThanOrEqual(field: field, value: num)
    }

    // Field<=N
    if let range = str.range(of: "<=") {
        let field = String(str[str.startIndex..<range.lowerBound])
        let value = String(str[range.upperBound...])
        guard let num = Double(value) else {
            throw ValidationError("Invalid numeric value in condition: \(str)")
        }
        return .lessThanOrEqual(field: field, value: num)
    }

    // Field>N
    if let range = str.range(of: ">") {
        let field = String(str[str.startIndex..<range.lowerBound])
        let value = String(str[range.upperBound...])
        guard let num = Double(value) else {
            throw ValidationError("Invalid numeric value in condition: \(str)")
        }
        return .greaterThan(field: field, value: num)
    }

    // Field<N
    if let range = str.range(of: "<") {
        let field = String(str[str.startIndex..<range.lowerBound])
        let value = String(str[range.upperBound...])
        guard let num = Double(value) else {
            throw ValidationError("Invalid numeric value in condition: \(str)")
        }
        return .lessThan(field: field, value: num)
    }

    // Field~Substring (contains)
    if let range = str.range(of: "~") {
        let field = String(str[str.startIndex..<range.lowerBound])
        let value = String(str[range.upperBound...])
        return .contains(field: field, substring: value)
    }

    // Field=Value (equals)
    if let range = str.range(of: "=") {
        let field = String(str[str.startIndex..<range.lowerBound])
        let value = String(str[range.upperBound...])
        return .equals(field: field, value: value)
    }

    throw ValidationError("Cannot parse condition: '\(str)'. Use Field=Value, Field>N, Field~Substring, or Field?")
}
