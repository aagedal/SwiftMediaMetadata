import Foundation

/// Reconstructs a JPEG XL container file from parsed components.
public struct JXLWriter {

    /// Reconstruct a JPEG XL container file from its boxes.
    /// Only supported for container format; bare codestream files cannot carry metadata.
    public static func write(_ file: JXLFile) throws -> Data {
        guard file.isContainer else {
            throw MetadataError.writeNotSupported("Cannot write metadata to bare JPEG XL codestream; container format required")
        }

        var writer = BinaryWriter(capacity: estimateSize(file))

        // JXL file type box (12-byte signature)
        writer.writeBytes(JXLParser.containerSignature)

        // Write all boxes
        ISOBMFFBoxWriter.writeBoxes(&writer, boxes: file.boxes)

        return writer.data
    }

    private static func estimateSize(_ file: JXLFile) -> Int {
        var size = 12 // JXL signature
        for box in file.boxes {
            size += 8 + box.data.count
        }
        return size
    }
}
