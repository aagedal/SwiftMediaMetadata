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

/// Check if a URL has a supported image, video, or audio extension.
func isSupportedFile(_ url: URL) -> Bool {
    supportedImageExtensions.contains(url.pathExtension.lowercased())
        || supportedVideoExtensions.contains(url.pathExtension.lowercased())
        || supportedAudioExtensions.contains(url.pathExtension.lowercased())
}

let supportedImageExtensions: Set<String> = [
    "jpg", "jpeg", "tif", "tiff", "dng", "cr2", "cr3", "nef", "nrw", "arw",
    "raf", "rw2", "orf", "pef", "srw", "raw",
    "jxl", "png", "avif", "heic", "heif", "webp",
    "gif", "bmp", "dib", "svg", "psd", "pdf",
]

let supportedVideoExtensions: Set<String> = [
    "mp4", "mov", "m4v", "mxf",
    "mkv", "webm", "avi",
    "mpg", "mpeg", "vob",
    "ts", "m2ts", "mts",
    "braw",
]

let supportedAudioExtensions: Set<String> = [
    "mp3", "flac", "m4a", "ogg", "oga", "opus",
]

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

// MARK: - Tag mappings (-tagsFromFile template expansion)

/// A single SRC→DST mapping from the `--map` flag.
struct TagMapping: Sendable, Equatable {
    let src: String
    let dst: String
}

/// Parse `--map` arguments. Accepts either `SRC>DST` (ExifTool-style) or
/// `SRC=DST`. Whitespace around the separator is tolerated. The same key on
/// both sides is allowed and means "copy verbatim".
func parseTagMappings(_ raw: [String]) throws -> [TagMapping] {
    try raw.map { entry in
        let separator: String
        if entry.contains(">") {
            separator = ">"
        } else if entry.contains("=") {
            separator = "="
        } else {
            throw ValidationError("Invalid --map '\(entry)'. Expected 'SRC>DST' or 'SRC=DST'.")
        }
        let parts = entry.components(separatedBy: separator)
        guard parts.count == 2 else {
            throw ValidationError("Invalid --map '\(entry)'. Expected exactly one '\(separator)'.")
        }
        let src = parts[0].trimmingCharacters(in: .whitespaces)
        let dst = parts[1].trimmingCharacters(in: .whitespaces)
        guard !src.isEmpty, !dst.isEmpty else {
            throw ValidationError("Invalid --map '\(entry)'. SRC and DST must both be non-empty.")
        }
        return TagMapping(src: src, dst: dst)
    }
}

// MARK: - Group prefixing (-G)

/// File-system tags that exporters emit bare but belong under the `File` group
/// when ExifTool prints with `-G`. Keeping this list small means anything else
/// bare gets the caller-supplied default group (EXIF for images).
private let fileGroupKeys: Set<String> = [
    "FileFormat", "FileName", "FileSize", "FileType", "FileTypeExtension",
    "FileModifyDate", "FileAccessDate", "FileInodeChangeDate",
    "FilePermissions", "Directory", "MIMEType",
    "ImageWidth", "ImageHeight",
]

/// Return a copy of `dict` with every bare key prefixed by its group
/// (`Make` → `EXIF:Make`). Keys that already carry a colon (`IPTC:Headline`,
/// `Composite:Aperture`) or an `XMP-` prefix are left untouched. The default
/// group lets the caller distinguish the image path (`EXIF`) from video/audio
/// where bare keys come from container parsers, not the EXIF block.
func applyGroupPrefix<V>(to dict: [String: V], defaultGroup: String) -> [String: V] {
    var out: [String: V] = [:]
    out.reserveCapacity(dict.count)
    for (key, value) in dict {
        if key.contains(":") || key.hasPrefix("XMP-") {
            out[key] = value
            continue
        }
        let group = fileGroupKeys.contains(key) ? "File" : defaultGroup
        out["\(group):\(key)"] = value
    }
    return out
}

// MARK: - Date reformatting (-d)

/// Tag-key suffixes whose values should be passed through the `-d` reformatter.
/// Anything containing one of these substrings (case-insensitive) is treated
/// as a date/time string. Mirrors the set of tags ExifTool reformats with `-d`.
private let dateTagKeywords: [String] = [
    "DateTime", "DateCreated", "DateTimeOriginal", "DateTimeDigitized",
    "ModifyDate", "CreateDate", "TimeStamp", "Date", "FileModifyDate",
    "FileAccessDate", "FileInodeChangeDate", "OffsetTime",
    "SubSecCreateDate", "SubSecModifyDate", "SubSecDateTimeOriginal",
    "GPSDateTime", "ExpirationDate", "ReleaseDate", "ReferenceDate",
    "DigitalCreationDate",
]

/// True when `key` looks like a date/time tag eligible for `-d` reformatting.
func isDateTagKey(_ key: String) -> Bool {
    let lower = key.lowercased()
    return dateTagKeywords.contains { lower.contains($0.lowercased()) }
}

/// Reformat a date string using a strftime-style pattern.
/// Falls back to the original string if parsing fails — the spec is forgiving:
/// inputs that aren't dates pass through unchanged.
func reformatDateString(_ input: String, pattern: String) -> String {
    guard let date = parseFlexibleDate(input) else { return input }
    return strftimeFormat(date, pattern: pattern) ?? input
}

/// Apply `-d` reformatting in-place to a `[String: String]` dictionary.
func applyDateFormat(to dict: inout [String: String], pattern: String?) {
    guard let pattern = pattern else { return }
    for (key, value) in dict where isDateTagKey(key) {
        dict[key] = reformatDateString(value, pattern: pattern)
    }
}

/// Parse a date string in any of the formats EXIF/IPTC/XMP commonly emit:
///   "2024:03:15 12:30:45"   (EXIF)
///   "2024:03:15 12:30:45+02:00"
///   "2024-03-15T12:30:45Z"  (ISO 8601 / XMP)
///   "20240315"              (IPTC date-only)
///   "12:30:45"              (IPTC time-only — uses today's date)
private func parseFlexibleDate(_ input: String) -> Date? {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    let formats = [
        "yyyy:MM:dd HH:mm:ss",
        "yyyy:MM:dd HH:mm:ssXXX",
        "yyyy:MM:dd HH:mm:ssZZZZZ",
        "yyyy-MM-dd'T'HH:mm:ssXXX",
        "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyyMMdd",
        "yyyy:MM:dd",
        "yyyy-MM-dd",
    ]
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    for fmt in formats {
        f.dateFormat = fmt
        if let d = f.date(from: trimmed) { return d }
    }
    return nil
}

/// Format `date` using a strftime-style pattern. Supports the directives
/// most commonly used by ExifTool's `-d` flag: %Y %m %d %H %M %S %F %T %j %A %a %B %b %p %z %Z %s %%.
private func strftimeFormat(_ date: Date, pattern: String) -> String? {
    let cal = Calendar(identifier: .gregorian)
    var calUTC = cal
    calUTC.timeZone = TimeZone(identifier: "UTC")!
    let comps = calUTC.dateComponents(
        [.year, .month, .day, .hour, .minute, .second, .weekday],
        from: date)
    let year = comps.year ?? 0
    let month = comps.month ?? 0
    let day = comps.day ?? 0
    let hour = comps.hour ?? 0
    let minute = comps.minute ?? 0
    let second = comps.second ?? 0
    let weekday = comps.weekday ?? 1
    // Day-of-year is `dayOfYear` on macOS 15+, but stays available as the
    // .dayOfYear ordinality query on older targets.
    let dayOfYear = calUTC.ordinality(of: .day, in: .year, for: date) ?? 0

    let weekdayLong = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    let weekdayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    let monthLong = ["January", "February", "March", "April", "May", "June",
                     "July", "August", "September", "October", "November", "December"]
    let monthShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    var out = ""
    var i = pattern.startIndex
    while i < pattern.endIndex {
        let c = pattern[i]
        if c == "%", let next = pattern.index(i, offsetBy: 1, limitedBy: pattern.endIndex), next < pattern.endIndex {
            let directive = pattern[next]
            switch directive {
            case "Y": out += String(format: "%04d", year)
            case "y": out += String(format: "%02d", year % 100)
            case "m": out += String(format: "%02d", month)
            case "d": out += String(format: "%02d", day)
            case "e": out += String(format: "%2d", day)
            case "H": out += String(format: "%02d", hour)
            case "I":
                let h12 = ((hour + 11) % 12) + 1
                out += String(format: "%02d", h12)
            case "M": out += String(format: "%02d", minute)
            case "S": out += String(format: "%02d", second)
            case "F": out += String(format: "%04d-%02d-%02d", year, month, day)
            case "T": out += String(format: "%02d:%02d:%02d", hour, minute, second)
            case "j": out += String(format: "%03d", dayOfYear)
            case "A": out += weekdayLong[max(0, min(6, weekday - 1))]
            case "a": out += weekdayShort[max(0, min(6, weekday - 1))]
            case "B": out += monthLong[max(0, min(11, month - 1))]
            case "b", "h": out += monthShort[max(0, min(11, month - 1))]
            case "p": out += hour < 12 ? "AM" : "PM"
            case "s":
                let epoch = Int(date.timeIntervalSince1970)
                out += String(epoch)
            case "z": out += "+0000"
            case "Z": out += "UTC"
            case "%": out += "%"
            case "n": out += "\n"
            case "t": out += "\t"
            default:
                out += "%"
                out.append(directive)
            }
            i = pattern.index(after: next)
        } else {
            out.append(c)
            i = pattern.index(after: i)
        }
    }
    return out
}
