import ArgumentParser
import Foundation
import SwiftExif

struct ValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate metadata against photojournalism profiles."
    )

    @Argument(help: "Image files or directories to validate.")
    var files: [String]

    @OptionGroup var fileFilter: FileFilterOptions

    @Option(name: .long, help: "Validation profile: news (default), stock, editorial.")
    var profile: ProfileName = .news

    @Flag(name: .long, help: "Output as CSV instead of table.")
    var csv = false

    @Flag(name: .shortAndLong, help: "Show warnings in addition to errors.")
    var verbose = false

    func run() throws {
        let urls = try resolveFiles(files, filter: fileFilter)
        guard !urls.isEmpty else {
            printError("No files found.")
            throw ExitCode.failure
        }

        let validator = profile.validator

        if csv {
            let report = try BatchProcessor.validateFiles(urls, validator: validator)
            print(report.toCSV())
        } else {
            var passCount = 0
            var failCount = 0

            for url in urls {
                do {
                    let metadata = try ImageMetadata.read(from: url)
                    let result = validator.validate(metadata)

                    let filename = url.lastPathComponent
                    if result.isValid {
                        passCount += 1
                        if verbose && !result.warnings.isEmpty {
                            print("PASS  \(filename)")
                            for issue in result.warnings {
                                print("      ⚠ \(issue.field): \(issue.message)")
                            }
                        } else {
                            print("PASS  \(filename)")
                        }
                    } else {
                        failCount += 1
                        print("FAIL  \(filename)")
                        for issue in result.errors {
                            print("      \(issue.field): \(issue.message)")
                        }
                        if verbose {
                            for issue in result.warnings {
                                print("      \(issue.field): \(issue.message)")
                            }
                        }
                    }
                } catch {
                    failCount += 1
                    print("ERROR \(url.lastPathComponent): \(error)")
                }
            }

            print("")
            print("\(passCount) passed, \(failCount) failed (\(profile.rawValue) profile)")
        }
    }
}

enum ProfileName: String, ExpressibleByArgument, Sendable, CaseIterable {
    case news
    case stock
    case editorial

    var validator: MetadataValidator {
        switch self {
        case .news: return .newsWire
        case .stock: return .stockPhoto
        case .editorial: return .editorial
        }
    }
}
