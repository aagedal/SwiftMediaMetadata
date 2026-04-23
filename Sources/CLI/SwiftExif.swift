import ArgumentParser
import Foundation

@main
struct SwiftExifCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-exif",
        abstract: "Read, write, and manipulate image/video metadata.",
        version: "1.3.0",
        subcommands: [
            ReadCommand.self,
            WriteCommand.self,
            WriteVideoCommand.self,
            WriteAudioCommand.self,
            StripCommand.self,
            CopyCommand.self,
            DiffCommand.self,
            RenameCommand.self,
            GeotagCommand.self,
            ShiftDatesCommand.self,
            ThumbnailCommand.self,
            SidecarCommand.self,
            ValidateCommand.self,
            SetGPSCommand.self,
            GeocodeCommand.self,
            GPXExportCommand.self,
            ImportCommand.self,
            DeleteOriginalCommand.self,
        ],
        defaultSubcommand: ReadCommand.self
    )

    static func main() {
        let rawArgs = Array(CommandLine.arguments.dropFirst())

        // Check for -stay_open batch mode before ArgumentParser takes over.
        if let stayOpenIndex = rawArgs.firstIndex(of: "-stay_open"),
           stayOpenIndex + 1 < rawArgs.count
        {
            let value = rawArgs[stayOpenIndex + 1].lowercased()
            if value == "true" || value == "1" {
                var server = StayOpenServer()
                server.run()
                return
            }
        }

        do {
            let expandedArgs = try expandArgfiles(rawArgs)
            Self.main(expandedArgs)
        } catch {
            printError("\(error)")
            _exit(1)
        }
    }
}
