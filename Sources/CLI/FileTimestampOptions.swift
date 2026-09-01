import ArgumentParser
import SwiftMediaMetadata

/// Filesystem timestamp policy shared by commands that rewrite media or sidecars.
struct FileTimestampOptions: ParsableArguments {
    @Flag(
        name: [.customShort("P"), .customLong("preserve-file-modification-date")],
        help: "Preserve the existing destination file's modification date."
    )
    var preserveFileModificationDate = false

    func applying(to options: ImageMetadata.WriteOptions) -> ImageMetadata.WriteOptions {
        var result = options
        if preserveFileModificationDate {
            result.fileModificationDate = .preserveExisting
        }
        return result
    }
}
