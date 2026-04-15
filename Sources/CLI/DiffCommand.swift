import ArgumentParser
import Foundation
import SwiftExif

struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Compare metadata between two image files."
    )

    @Argument(help: "First image file.")
    var file1: String

    @Argument(help: "Second image file.")
    var file2: String

    @Flag(name: .long, help: "Output diff as JSON.")
    var json = false

    func run() throws {
        let url1 = URL(fileURLWithPath: file1)
        let url2 = URL(fileURLWithPath: file2)

        let meta1 = try ImageMetadata.read(from: url1)
        let meta2 = try ImageMetadata.read(from: url2)
        let diff = meta1.diff(against: meta2)

        if diff.isEmpty {
            print("Files are identical.")
            return
        }

        if json {
            printDiffJSON(diff, file1: url1.lastPathComponent, file2: url2.lastPathComponent)
        } else {
            printDiffTable(diff, file1: url1.lastPathComponent, file2: url2.lastPathComponent)
        }
    }

    private func printDiffTable(_ diff: ImageMetadata.MetadataDiff, file1: String, file2: String) {
        let keyWidth = diff.changes.map(\.key.count).max().map { max($0, 20) } ?? 20

        if !diff.additions.isEmpty {
            print("--- Added (only in \(file2)) ---")
            for change in diff.additions.sorted(by: { $0.key < $1.key }) {
                let padded = change.key.padding(toLength: keyWidth + 2, withPad: " ", startingAt: 0)
                print("  + \(padded): \(change.newValue ?? "")")
            }
            print()
        }

        if !diff.removals.isEmpty {
            print("--- Removed (only in \(file1)) ---")
            for change in diff.removals.sorted(by: { $0.key < $1.key }) {
                let padded = change.key.padding(toLength: keyWidth + 2, withPad: " ", startingAt: 0)
                print("  - \(padded): \(change.oldValue ?? "")")
            }
            print()
        }

        if !diff.modifications.isEmpty {
            print("--- Modified ---")
            for change in diff.modifications.sorted(by: { $0.key < $1.key }) {
                let padded = change.key.padding(toLength: keyWidth + 2, withPad: " ", startingAt: 0)
                print("  ~ \(padded): \(change.oldValue ?? "") → \(change.newValue ?? "")")
            }
            print()
        }

        print("\(diff.additions.count) added, \(diff.removals.count) removed, \(diff.modifications.count) modified")
    }

    private func printDiffJSON(_ diff: ImageMetadata.MetadataDiff, file1: String, file2: String) {
        var obj: [String: Any] = [
            "file1": file1,
            "file2": file2,
        ]

        var changes: [[String: Any]] = []
        for change in diff.changes {
            var entry: [String: Any] = [
                "key": change.key,
                "type": changeTypeName(change.type),
            ]
            if let old = change.oldValue { entry["oldValue"] = old }
            if let new = change.newValue { entry["newValue"] = new }
            changes.append(entry)
        }
        obj["changes"] = changes

        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    private func changeTypeName(_ type: ImageMetadata.MetadataChange.ChangeType) -> String {
        switch type {
        case .added: return "added"
        case .removed: return "removed"
        case .modified: return "modified"
        }
    }
}
