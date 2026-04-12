import Foundation

/// Parsed representation of a JPEG XL file.
public struct JXLFile: Sendable {
    /// Whether this is a container format (true) or bare codestream (false).
    public let isContainer: Bool
    /// Top-level boxes (only present in container format).
    public var boxes: [ISOBMFFBox]

    public init(isContainer: Bool, boxes: [ISOBMFFBox] = []) {
        self.isContainer = isContainer
        self.boxes = boxes
    }

    /// Find the first box of the given type.
    public func findBox(_ type: String) -> ISOBMFFBox? {
        boxes.first { $0.type == type }
    }
}
