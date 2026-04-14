import Foundation

/// Reconstructs a TIFF file from parsed components with updated metadata.
public struct TIFFWriter: Sendable {

    /// Metadata tag IDs that we manage (replaced during write).
    private static let metadataTagIDs: Set<UInt16> = [
        ExifTag.xmpTag,          // 0x02BC — XMP
        ExifTag.iccProfile,      // 0x8773 — ICC color profile
        ExifTag.iptcNAA,         // 0x83BB — raw IPTC-NAA
        ExifTag.photoshopIRB,    // 0x8649 — Photoshop IRB (IPTC container)
        ExifTag.exifIFDPointer,  // 0x8769 — Exif sub-IFD pointer
        ExifTag.gpsIFDPointer,   // 0x8825 — GPS sub-IFD pointer
    ]

    /// Reconstruct a TIFF file with updated metadata.
    /// Preserves all non-metadata IFD entries and their data.
    public static func write(_ tiffFile: TIFFFile, exif: ExifData?, iptc: IPTCData?, xmp: XMPData?, iccProfile: ICCProfile? = nil) throws -> Data {
        let endian = tiffFile.header.byteOrder
        var writer = BinaryWriter(capacity: tiffFile.rawData.count + 4096)

        // TIFF header
        let header = TIFFHeader(byteOrder: endian)
        header.write(to: &writer)

        // Rebuild IFD chain
        for (ifdIndex, ifd) in tiffFile.ifds.enumerated() {
            if ifdIndex == 0 {
                // IFD0: merge in metadata entries
                let updatedEntries = try buildIFD0Entries(
                    existing: ifd.entries,
                    endian: endian,
                    exif: exif,
                    iptc: iptc,
                    xmp: xmp,
                    iccProfile: iccProfile,
                    writerOffset: writer.count
                )
                writeIFD(&writer, entries: updatedEntries, endian: endian, nextIFDOffset: tiffFile.ifds.count > 1 ? 0xFFFFFFFF : 0)
            } else {
                // Subsequent IFDs: preserve as-is
                let isLast = ifdIndex == tiffFile.ifds.count - 1
                writeIFD(&writer, entries: ifd.entries, endian: endian, nextIFDOffset: isLast ? 0 : 0xFFFFFFFF)
            }
        }

        // If no IFDs existed, create IFD0 from scratch
        if tiffFile.ifds.isEmpty {
            let entries = try buildIFD0Entries(
                existing: [],
                endian: endian,
                exif: exif,
                iptc: iptc,
                xmp: xmp,
                iccProfile: iccProfile,
                writerOffset: writer.count
            )
            writeIFD(&writer, entries: entries, endian: endian, nextIFDOffset: 0)
        }

        // Now patch IFD chain offsets (we used placeholder 0xFFFFFFFF above)
        patchIFDOffsets(&writer, endian: endian, ifdCount: max(tiffFile.ifds.count, 1))

        return writer.data
    }

    // MARK: - Private

    private static func buildIFD0Entries(
        existing: [IFDEntry],
        endian: ByteOrder,
        exif: ExifData?,
        iptc: IPTCData?,
        xmp: XMPData?,
        iccProfile: ICCProfile?,
        writerOffset: Int
    ) throws -> [IFDEntry] {
        // Start with existing non-metadata entries
        var entries = existing.filter { !metadataTagIDs.contains($0.tag) }

        // Add XMP tag (0x02BC)
        if let xmp = xmp {
            let xmlData = Data(XMPWriter.generateXML(xmp).utf8)
            entries.append(IFDEntry(
                tag: ExifTag.xmpTag,
                type: .undefined,
                count: UInt32(xmlData.count),
                valueData: xmlData
            ))
        }

        // Add Photoshop IRB with IPTC (0x8649)
        if let iptc = iptc, !iptc.datasets.isEmpty {
            let iptcBinary = try IPTCWriter.write(iptc)
            let irbData = PhotoshopIRB.write(blocks: [
                IRBBlock(resourceID: PhotoshopIRB.iptcResourceID, data: iptcBinary)
            ])
            entries.append(IFDEntry(
                tag: ExifTag.photoshopIRB,
                type: .undefined,
                count: UInt32(irbData.count),
                valueData: irbData
            ))
        }

        // Add ICC profile (0x8773)
        if let icc = iccProfile {
            entries.append(IFDEntry(
                tag: ExifTag.iccProfile,
                type: .undefined,
                count: UInt32(icc.data.count),
                valueData: icc.data
            ))
        }

        // Sort by tag ID (TIFF spec requirement)
        entries.sort { $0.tag < $1.tag }

        return entries
    }

    private static func writeIFD(_ writer: inout BinaryWriter, entries: [IFDEntry], endian: ByteOrder, nextIFDOffset: UInt32) {
        // Record the start of this IFD for offset patching
        let ifdStart = writer.count

        writer.writeUInt16(UInt16(entries.count), endian: endian)

        // Calculate where external data starts (after all entries + next offset)
        let dataStart = ifdStart + 2 + entries.count * 12 + 4
        var currentDataOffset = dataStart

        // First pass: write directory entries
        for entry in entries {
            writer.writeUInt16(entry.tag, endian: endian)
            writer.writeUInt16(entry.type.rawValue, endian: endian)
            writer.writeUInt32(entry.count, endian: endian)

            if entry.totalValueSize <= 4 {
                var padded = entry.valueData
                while padded.count < 4 { padded.append(0x00) }
                writer.writeBytes(padded.prefix(4))
            } else {
                writer.writeUInt32(UInt32(currentDataOffset), endian: endian)
                currentDataOffset += entry.totalValueSize
                if currentDataOffset % 2 != 0 { currentDataOffset += 1 }
            }
        }

        // Next IFD offset (may be patched later)
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

    /// Walk through the written data and patch IFD chain offsets.
    /// IFDs with nextIFDOffset == 0xFFFFFFFF get patched to point to the next IFD.
    private static func patchIFDOffsets(_ writer: inout BinaryWriter, endian: ByteOrder, ifdCount: Int) {
        // First IFD is at offset 8 (right after TIFF header)
        // We need to walk each IFD to find where the next one starts
        var ifdOffset = 8
        let data = writer.data

        for i in 0..<ifdCount {
            guard ifdOffset + 2 <= data.count else { break }

            // Read entry count
            var reader = BinaryReader(data: data)
            guard (try? reader.seek(to: ifdOffset)) != nil else { break }
            guard let count = try? reader.readUInt16(endian: endian) else { break }

            // Skip entries to find the next-IFD-offset field
            let nextOffsetPosition = ifdOffset + 2 + Int(count) * 12

            // Calculate external data size to find end of this IFD's data
            guard (try? reader.seek(to: ifdOffset + 2)) != nil else { break }
            var externalDataSize = 0
            for _ in 0..<count {
                guard let _ = try? reader.readUInt16(endian: endian), // tag
                      let typeRaw = try? reader.readUInt16(endian: endian), // type
                      let valueCount = try? reader.readUInt32(endian: endian) else { break } // count
                _ = try? reader.readBytes(4) // value/offset

                if let dataType = TIFFDataType(rawValue: typeRaw) {
                    let totalSize = Int(valueCount) * dataType.unitSize
                    if totalSize > 4 {
                        externalDataSize += totalSize
                        if externalDataSize % 2 != 0 { externalDataSize += 1 }
                    }
                }
            }

            let nextIFDStart = nextOffsetPosition + 4 + externalDataSize

            // Check if this needs patching (sentinel value 0xFFFFFFFF)
            if i < ifdCount - 1 && nextOffsetPosition + 4 <= data.count {
                var offsetReader = BinaryReader(data: data)
                _ = try? offsetReader.seek(to: nextOffsetPosition)
                if let currentValue = try? offsetReader.readUInt32(endian: endian), currentValue == 0xFFFFFFFF {
                    try? writer.patchUInt32(UInt32(nextIFDStart), at: nextOffsetPosition, endian: endian)
                }
            }

            ifdOffset = nextIFDStart
        }
    }
}
