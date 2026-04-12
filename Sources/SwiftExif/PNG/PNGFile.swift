import Foundation

/// Parsed representation of a PNG file.
public struct PNGFile: Sendable {
    /// All chunks in order.
    public var chunks: [PNGChunk]

    public init(chunks: [PNGChunk] = []) {
        self.chunks = chunks
    }

    /// Find the first chunk of the given type.
    public func findChunk(_ type: String) -> PNGChunk? {
        chunks.first { $0.type == type }
    }

    /// Find all chunks of the given type.
    public func findChunks(_ type: String) -> [PNGChunk] {
        chunks.filter { $0.type == type }
    }
}
