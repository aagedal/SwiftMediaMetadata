import Foundation

/// Serialize ExifData back to APP1 segment payload.
public struct ExifWriter {

    /// Serialize ExifData to APP1 segment payload (including "Exif\0\0" prefix).
    public static func write(_ exifData: ExifData) -> Data {
        var writer = BinaryWriter(capacity: 4096)

        // Exif identifier
        writer.writeBytes([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])

        // Append raw TIFF data
        writer.writeBytes(writeTIFF(exifData))

        return writer.data
    }

    /// Serialize ExifData to raw TIFF bytes (no "Exif\0\0" prefix).
    /// Used by PNG (eXIf chunk), JPEG XL (Exif box), AVIF (Exif property box), and TIFF files.
    public static func writeTIFF(_ exifData: ExifData) -> Data {
        let endian = exifData.byteOrder
        var writer = BinaryWriter(capacity: 4096)

        let tiffStart = writer.count

        // TIFF header (will patch IFD offset)
        let header = TIFFHeader(byteOrder: endian)
        header.write(to: &writer)

        // Collect all IFDs and their data
        var ifd0Entries = exifData.ifd0?.entries ?? []
        let exifIFDEntries = exifData.exifIFD?.entries ?? []
        let gpsIFDEntries = exifData.gpsIFD?.entries ?? []

        // Remove existing sub-IFD pointers (we'll recalculate)
        ifd0Entries.removeAll { $0.tag == ExifTag.exifIFDPointer || $0.tag == ExifTag.gpsIFDPointer }

        // Phase 1: Calculate sizes to determine offsets

        // IFD0 size
        let hasExifIFD = !exifIFDEntries.isEmpty
        let hasGPSIFD = !gpsIFDEntries.isEmpty

        var totalIFD0Entries = ifd0Entries.count
        if hasExifIFD { totalIFD0Entries += 1 }
        if hasGPSIFD { totalIFD0Entries += 1 }

        let ifd0Size = 2 + totalIFD0Entries * 12 + 4 // count + entries + next offset

        // IFD0 data starts after IFD0 directory
        let ifd0DataStart = 8 + ifd0Size // 8 = TIFF header size

        // Calculate IFD0 external data size
        var ifd0ExternalSize = 0
        for entry in ifd0Entries {
            if entry.totalValueSize > 4 {
                ifd0ExternalSize += entry.totalValueSize
                // Align to word boundary
                if ifd0ExternalSize % 2 != 0 { ifd0ExternalSize += 1 }
            }
        }

        // Exif IFD offset (after IFD0 + IFD0 data)
        let exifIFDOffset = ifd0DataStart + ifd0ExternalSize

        // Exif IFD size
        let exifIFDSize = hasExifIFD ? (2 + exifIFDEntries.count * 12 + 4) : 0

        // Exif IFD external data
        var exifExternalSize = 0
        if hasExifIFD {
            for entry in exifIFDEntries {
                if entry.totalValueSize > 4 {
                    exifExternalSize += entry.totalValueSize
                    if exifExternalSize % 2 != 0 { exifExternalSize += 1 }
                }
            }
        }

        // GPS IFD offset
        let gpsIFDOffset = exifIFDOffset + exifIFDSize + exifExternalSize

        // GPS IFD size (used for offset calculation above)
        _ = hasGPSIFD ? (2 + gpsIFDEntries.count * 12 + 4) : 0

        var gpsExternalSize = 0
        if hasGPSIFD {
            for entry in gpsIFDEntries {
                if entry.totalValueSize > 4 {
                    gpsExternalSize += entry.totalValueSize
                    if gpsExternalSize % 2 != 0 { gpsExternalSize += 1 }
                }
            }
        }

        // Phase 2: Write IFD0
        // Add sub-IFD pointer entries
        var allIFD0Entries = ifd0Entries
        if hasExifIFD {
            var exifOffsetData = BinaryWriter(capacity: 4)
            exifOffsetData.writeUInt32(UInt32(exifIFDOffset), endian: endian)
            allIFD0Entries.append(IFDEntry(tag: ExifTag.exifIFDPointer, type: .long, count: 1, valueData: exifOffsetData.data))
        }
        if hasGPSIFD {
            var gpsOffsetData = BinaryWriter(capacity: 4)
            gpsOffsetData.writeUInt32(UInt32(gpsIFDOffset), endian: endian)
            allIFD0Entries.append(IFDEntry(tag: ExifTag.gpsIFDPointer, type: .long, count: 1, valueData: gpsOffsetData.data))
        }

        // Sort by tag ID (TIFF spec requires this)
        allIFD0Entries.sort { $0.tag < $1.tag }

        writeIFD(&writer, entries: allIFD0Entries, endian: endian, dataOffset: ifd0DataStart, nextIFDOffset: 0, tiffStart: tiffStart)

        // Write Exif IFD
        if hasExifIFD {
            let exifDataStart = exifIFDOffset + 2 + exifIFDEntries.count * 12 + 4
            let sortedExifEntries = exifIFDEntries.sorted { $0.tag < $1.tag }
            writeIFD(&writer, entries: sortedExifEntries, endian: endian, dataOffset: exifDataStart, nextIFDOffset: 0, tiffStart: tiffStart)
        }

        // Write GPS IFD
        if hasGPSIFD {
            let gpsDataStart = gpsIFDOffset + 2 + gpsIFDEntries.count * 12 + 4
            let sortedGPSEntries = gpsIFDEntries.sorted { $0.tag < $1.tag }
            writeIFD(&writer, entries: sortedGPSEntries, endian: endian, dataOffset: gpsDataStart, nextIFDOffset: 0, tiffStart: tiffStart)
        }

        return writer.data
    }

    // MARK: - Private

    private static func writeIFD(_ writer: inout BinaryWriter, entries: [IFDEntry], endian: ByteOrder, dataOffset: Int, nextIFDOffset: UInt32, tiffStart: Int) {
        writer.writeUInt16(UInt16(entries.count), endian: endian)

        // Track where external data will go
        var currentDataOffset = dataOffset

        // First pass: write directory entries
        for entry in entries {
            writer.writeUInt16(entry.tag, endian: endian)
            writer.writeUInt16(entry.type.rawValue, endian: endian)
            writer.writeUInt32(entry.count, endian: endian)

            if entry.totalValueSize <= 4 {
                // Inline value (pad to 4 bytes)
                var padded = entry.valueData
                while padded.count < 4 { padded.append(0x00) }
                writer.writeBytes(padded.prefix(4))
            } else {
                // Write offset
                writer.writeUInt32(UInt32(currentDataOffset), endian: endian)
                currentDataOffset += entry.totalValueSize
                if currentDataOffset % 2 != 0 { currentDataOffset += 1 }
            }
        }

        // Next IFD offset
        writer.writeUInt32(nextIFDOffset, endian: endian)

        // Second pass: write external data
        for entry in entries {
            if entry.totalValueSize > 4 {
                writer.writeBytes(entry.valueData)
                if entry.valueData.count % 2 != 0 {
                    writer.writeUInt8(0x00)
                }
            }
        }
    }
}
