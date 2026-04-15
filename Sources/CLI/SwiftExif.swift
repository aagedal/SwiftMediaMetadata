import ArgumentParser

@main
struct SwiftExifCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-exif",
        abstract: "Read, write, and manipulate image/video metadata.",
        version: "1.0.0",
        subcommands: [
            ReadCommand.self,
            WriteCommand.self,
            StripCommand.self,
            CopyCommand.self,
            DiffCommand.self,
            RenameCommand.self,
            GeotagCommand.self,
            ShiftDatesCommand.self,
            ThumbnailCommand.self,
            SidecarCommand.self,
        ],
        defaultSubcommand: ReadCommand.self
    )
}
