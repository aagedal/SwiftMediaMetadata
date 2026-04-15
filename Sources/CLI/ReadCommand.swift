import ArgumentParser
import Foundation
import SwiftExif

struct ReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read and display metadata from image/video files."
    )

    @Argument(help: "Image or video files to read.")
    var files: [String]

    @Option(name: .long, help: "Output format: table (default), json, csv, xml.")
    var format: OutputFormat = .table

    @Option(name: .long, help: "Filter by metadata group: exif, iptc, xmp, c2pa, icc, makernote, composite.")
    var group: [String] = []

    @Flag(name: .shortAndLong, help: "Show raw numeric values (skip print conversion).")
    var numeric = false

    @Option(name: .long, help: "Only include specific fields (comma-separated).")
    var fields: String?

    @Option(name: .long, help: "Filter condition (e.g. 'Make=Canon', 'ISO>800').")
    var `if`: [String] = []

    @Option(name: .long, help: "Include only tags matching glob pattern (e.g. 'IPTC:*').")
    var tags: [String] = []

    @Option(name: .long, help: "Exclude tags matching glob pattern (e.g. 'MakerNote:*').")
    var excludeTags: [String] = []

    func run() throws {
        let urls = try resolveFiles(files)
        let condition = try parseConditions(self.if)
        let fieldList = fields?.split(separator: ",").map(String.init)
        let groups = Set(group)
        let tagFilter = (!tags.isEmpty || !excludeTags.isEmpty)
            ? TagFilter(tags: tags, excludeTags: excludeTags) : nil

        let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

        var imageDicts: [[String: String]] = []
        var videoDicts: [[String: String]] = []
        var imageNames: [String] = []
        var videoNames: [String] = []

        for url in urls {
            if videoExtensions.contains(url.pathExtension.lowercased()) {
                let vm = try VideoMetadata.read(from: url)
                let dict = VideoMetadataExporter.buildDictionary(vm).mapValues { String(describing: $0) }
                videoDicts.append(dict)
                videoNames.append(url.lastPathComponent)
            } else {
                let metadata = try ImageMetadata.read(from: url)
                if let condition, !condition.matches(metadata) { continue }

                let dict: [String: String]
                if numeric {
                    let raw = MetadataExporter.buildDictionary(metadata)
                    dict = raw.mapValues { value in
                        if let arr = value as? [String] { return arr.joined(separator: ", ") }
                        return String(describing: value)
                    }
                } else {
                    dict = PrintConverter.buildReadableDictionary(metadata)
                }
                var filtered = filterByGroups(dict, groups: groups, fields: fieldList)
                if let tagFilter { filtered = tagFilter.apply(to: filtered).mapValues { String(describing: $0) } }
                imageDicts.append(filtered)
                imageNames.append(url.lastPathComponent)
            }
        }

        let allDicts = imageDicts + videoDicts
        let allNames = imageNames + videoNames

        switch format {
        case .json:
            if let data = try? JSONSerialization.data(withJSONObject: allDicts, options: [.prettyPrinted, .sortedKeys]) {
                print(String(data: data, encoding: .utf8) ?? "[]")
            }
        case .csv:
            printCSV(allDicts)
        case .xml:
            for dict in allDicts {
                printXML(dict)
            }
        case .table:
            for (i, dict) in allDicts.enumerated() {
                if allDicts.count > 1 {
                    printSeparator(allNames[i])
                }
                printTable(dict)
            }
        }
    }

    private func printTable(_ dict: [String: String]) {
        guard !dict.isEmpty else { return }
        let maxKey = dict.keys.map(\.count).max() ?? 20
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            print("\(key.padding(toLength: maxKey + 2, withPad: " ", startingAt: 0)): \(value)")
        }
    }

    private func printCSV(_ dicts: [[String: String]]) {
        guard !dicts.isEmpty else { return }

        var allKeys = Set<String>()
        for dict in dicts { allKeys.formUnion(dict.keys) }
        let columns = allKeys.sorted()

        // Header
        print(columns.joined(separator: ","))

        // Rows
        for dict in dicts {
            let row = columns.map { key -> String in
                let value = dict[key] ?? ""
                if value.contains(",") || value.contains("\"") || value.contains("\n") {
                    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
                }
                return value
            }
            print(row.joined(separator: ","))
        }
    }

    private func printXML(_ dict: [String: String]) {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n"
        xml += "<rdf:Description>\n"
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            let tag = key.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "_")
            let escaped = value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            xml += "  <\(tag)>\(escaped)</\(tag)>\n"
        }
        xml += "</rdf:Description>\n"
        xml += "</rdf:RDF>\n"
        print(xml)
    }

    private func filterByGroups(_ dict: [String: String], groups: Set<String>, fields: [String]?) -> [String: String] {
        if let fields {
            let fieldSet = Set(fields)
            return dict.filter { fieldSet.contains($0.key) }
        }

        guard !groups.isEmpty else { return dict }

        let exifKeys: Set<String> = [
            "Make", "Model", "Software", "DateTime", "DateTimeOriginal", "DateTimeDigitized",
            "Copyright", "Artist", "LensModel", "LensMake", "Orientation", "ISO",
            "ExposureTime", "FNumber", "FocalLength", "FocalLengthIn35mmFilm",
            "ExposureProgram", "MeteringMode", "Flash", "ColorSpace", "WhiteBalance",
            "SceneCaptureType", "ExposureMode", "CustomRendered", "SensingMethod",
            "LightSource", "ResolutionUnit", "Compression", "PixelXDimension",
            "PixelYDimension", "ImageWidth", "ImageHeight",
            "GPSLatitude", "GPSLongitude",
        ]

        return dict.filter { key, _ in
            for g in groups {
                switch g.lowercased() {
                case "exif": if exifKeys.contains(key) { return true }
                case "iptc": if key.hasPrefix("IPTC:") { return true }
                case "xmp": if key.hasPrefix("XMP-") { return true }
                case "icc": if key.hasPrefix("ICCProfile:") { return true }
                case "makernote": if key.hasPrefix("MakerNote:") { return true }
                case "composite": if key.hasPrefix("Composite:") { return true }
                case "c2pa": if key.hasPrefix("C2PA:") { return true }
                default: break
                }
            }
            return false
        }
    }
}

enum OutputFormat: String, ExpressibleByArgument, Sendable {
    case table, json, csv, xml
}
