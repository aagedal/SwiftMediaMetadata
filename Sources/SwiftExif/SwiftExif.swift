import Foundation

/// Read all metadata from a JPEG file at the given URL.
public func readMetadata(from url: URL) throws -> ImageMetadata {
    try ImageMetadata.read(from: url)
}

/// Read all metadata from JPEG data in memory.
public func readMetadata(from data: Data) throws -> ImageMetadata {
    try ImageMetadata.read(from: data)
}
