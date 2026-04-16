import ArgumentParser
import Foundation

/// Shared options for file filtering, recursion, and directory ignoring.
/// Include in any command that processes files via @OptionGroup.
struct FileFilterOptions: ParsableArguments {
    @Option(name: .long, help: "Process only files with these extensions (can be repeated).")
    var ext: [String] = []

    @Option(name: .shortAndLong, help: "Ignore directories matching this name during traversal.")
    var ignore: [String] = []

    @Flag(name: .shortAndLong, help: "Recurse into subdirectories.")
    var recursive: Bool = false
}
