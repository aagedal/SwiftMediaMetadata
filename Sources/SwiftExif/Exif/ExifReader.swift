import Foundation

/// Parse Exif data from an APP1 segment.
public struct ExifReader {

    /// Parse Exif data from APP1 segment payload (including "Exif\0\0" identifier).
    public static func read(from data: Data) throws -> ExifData {
        var reader = BinaryReader(data: data)

        // Skip Exif identifier: "Exif\0\0" (6 bytes)
        try reader.expect([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])

        let tiffStart = reader.offset

        // Parse TIFF header
        let header = try TIFFHeader.parse(from: &reader)
        let endian = header.byteOrder

        var exifData = ExifData(byteOrder: endian)

        // Parse IFD0
        try reader.seek(to: tiffStart + Int(header.ifdOffset))
        let (ifd0, nextOffset) = try parseIFD(data: data, tiffStart: tiffStart, offset: reader.offset, endian: endian)
        exifData.ifd0 = ifd0

        // Check for Exif sub-IFD
        if let exifPointer = ifd0.entry(for: ExifTag.exifIFDPointer),
           let exifOffset = exifPointer.uint32Value(endian: endian) {
            let (exifIFD, _) = try parseIFD(data: data, tiffStart: tiffStart, offset: tiffStart + Int(exifOffset), endian: endian)
            exifData.exifIFD = exifIFD
        }

        // Check for GPS sub-IFD
        if let gpsPointer = ifd0.entry(for: ExifTag.gpsIFDPointer),
           let gpsOffset = gpsPointer.uint32Value(endian: endian) {
            let (gpsIFD, _) = try parseIFD(data: data, tiffStart: tiffStart, offset: tiffStart + Int(gpsOffset), endian: endian)
            exifData.gpsIFD = gpsIFD
        }

        // Check for IFD1 (thumbnail)
        if nextOffset > 0 {
            let (ifd1, _) = try parseIFD(data: data, tiffStart: tiffStart, offset: tiffStart + Int(nextOffset), endian: endian)
            exifData.ifd1 = ifd1
        }

        return exifData
    }

    // MARK: - Private

    private static func parseIFD(data: Data, tiffStart: Int, offset: Int, endian: ByteOrder) throws -> (IFD, UInt32) {
        var reader = BinaryReader(data: data)
        try reader.seek(to: offset)

        let count = try reader.readUInt16(endian: endian)
        var entries: [IFDEntry] = []

        for _ in 0..<count {
            let tag = try reader.readUInt16(endian: endian)
            let typeRaw = try reader.readUInt16(endian: endian)
            let valueCount = try reader.readUInt32(endian: endian)
            let valueOrOffset = try reader.readBytes(4)

            guard let type = TIFFDataType(rawValue: typeRaw) else {
                // Skip unknown types
                continue
            }

            let totalSize = Int(valueCount) * type.unitSize
            let valueData: Data

            if totalSize <= 4 {
                // Value is inline (in the 4-byte field)
                valueData = Data(valueOrOffset.prefix(totalSize))
            } else {
                // Value is at an offset
                var offsetReader = BinaryReader(data: valueOrOffset)
                let dataOffset = try offsetReader.readUInt32(endian: endian)
                valueData = try reader.slice(from: tiffStart + Int(dataOffset), count: totalSize)
            }

            entries.append(IFDEntry(tag: tag, type: type, count: valueCount, valueData: valueData))
        }

        let nextIFDOffset = try reader.readUInt32(endian: endian)

        return (IFD(entries: entries, nextIFDOffset: nextIFDOffset), nextIFDOffset)
    }
}
