import Foundation

/// The outcome of serializing metadata or committing it to a file.
///
/// Metadata writers use the same result shape whether their output is in-memory
/// `Data` or a destination `URL`. Non-fatal format limitations are reported in
/// `warnings`; a successful result always contains the requested output.
public struct MetadataWriteResult<Output: Sendable>: Sendable {
    public let output: Output
    public let warnings: [String]

    public init(output: Output, warnings: [String] = []) {
        self.output = output
        self.warnings = warnings
    }
}

extension MetadataWriteResult: Equatable where Output: Equatable {}
