import Foundation

/// Reconstructs a TIFF file from parsed components with updated metadata.
///
/// The writer rebuilds the IFD chain from scratch and **relocates every block
/// an IFD entry points at** — strip/tile pixel data, the old-style JPEG
/// thumbnail, and the Exif/GPS sub-IFDs — copying the bytes into the output and
/// rewriting the offsets. This keeps the raster (and any compressed payload)
/// valid; a TIFF round-tripped through SwiftExif decodes identically.
public struct TIFFWriter: Sendable {

    // Offset-bearing tags whose values are file offsets that must be rewritten.
    private static let stripOffsets: UInt16 = 0x0111
    private static let stripByteCounts: UInt16 = 0x0117
    private static let tileOffsets: UInt16 = 0x0144
    private static let tileByteCounts: UInt16 = 0x0145
    private static let jpegInterchangeFormat: UInt16 = 0x0201        // old-style JPEG thumbnail
    private static let jpegInterchangeFormatLength: UInt16 = 0x0202

    /// Pointer tags whose value is the offset of a child IFD. A pointer is only
    /// written when we have the child IFD to relocate; otherwise it is dropped
    /// so the output never carries a dangling offset.
    private static let exifPointer: UInt16 = 0x8769
    private static let gpsPointer: UInt16 = 0x8825
    private static let pointerTags: Set<UInt16> = [
        0x8769, 0x8825, 0xA005, 0x014A, // Exif, GPS, Interoperability, SubIFDs
    ]

    /// Metadata tag IDs that we manage (replaced during write).
    private static let metadataTagIDs: Set<UInt16> = [
        ExifTag.xmpTag,          // 0x02BC — XMP
        ExifTag.iccProfile,      // 0x8773 — ICC color profile
        ExifTag.iptcNAA,         // 0x83BB — raw IPTC-NAA
        ExifTag.photoshopIRB,    // 0x8649 — Photoshop IRB (IPTC container)
        ExifTag.exifIFDPointer,  // 0x8769 — Exif sub-IFD pointer
        ExifTag.gpsIFDPointer,   // 0x8825 — GPS sub-IFD pointer
    ]

    /// IFD0 tags that describe the *pixel data itself* (layout, strips, tiles,
    /// resolution, colour). They are always taken from the destination file and
    /// never copied out of an assigned `exif`, whose IFD0 may come from a
    /// differently-sized source image — copying e.g. StripOffsets would point
    /// at the wrong bytes and corrupt the raster. Descriptive IFD0 tags
    /// (Make, Model, Software, DateTime, Artist, …) are copied from `exif`.
    private static let structuralIFD0Tags: Set<UInt16> = [
        0x00FE, 0x00FF,                                  // NewSubfileType, SubfileType
        0x0100, 0x0101, 0x0102, 0x0103, 0x0106, 0x0107,  // dimensions / compression / photometric
        0x0108, 0x0109, 0x010A,                          // cell sizes, fill order
        0x0111, 0x0115, 0x0116, 0x0117,                  // strip offsets / samples / rows / counts
        0x011A, 0x011B, 0x011C,                          // x/y resolution, planar config
        0x0122, 0x0123, 0x0128,                          // gray response, resolution unit
        0x0112,                                          // orientation (tied to the dest pixels)
        0x013D, 0x0140,                                  // predictor, color map
        0x0142, 0x0143, 0x0144, 0x0145,                  // tile width / length / offsets / counts
        0x014A, 0x0153, 0x0154, 0x0155,                  // sub-IFDs, sample format, min/max
        0x0201, 0x0202,                                  // JPEG thumbnail offset/length
    ]

    /// Reconstruct a TIFF file with updated metadata, preserving the raster.
    public static func write(_ tiffFile: TIFFFile, exif: ExifData?, iptc: IPTCData?, xmp: XMPData?, iccProfile: ICCProfile? = nil) throws -> Data {
        let endian = tiffFile.header.byteOrder
        let raw = tiffFile.rawData
        var writer = BinaryWriter(capacity: raw.count + 8192)

        // TIFF header — IFD0 immediately follows at offset 8.
        TIFFHeader(byteOrder: endian).write(to: &writer)

        // Build the top-level IFD entry lists: IFD0 gets the metadata merge,
        // later IFDs (e.g. the IFD1 thumbnail) pass through structurally.
        var topIFDs: [[IFDEntry]]
        if tiffFile.ifds.isEmpty {
            topIFDs = [try buildIFD0Entries(existing: [], exif: exif, iptc: iptc, xmp: xmp, iccProfile: iccProfile)]
        } else {
            topIFDs = tiffFile.ifds.map { $0.entries }
            topIFDs[0] = try buildIFD0Entries(existing: tiffFile.ifds[0].entries, exif: exif, iptc: iptc, xmp: xmp, iccProfile: iccProfile)
        }

        // Sub-IFDs to relocate under IFD0 come from the assigned exif model.
        var ifd0SubIFDs: [UInt16: [IFDEntry]] = [:]
        if let exifIFD = exif?.exifIFD { ifd0SubIFDs[exifPointer] = exifIFD.entries }
        if let gpsIFD = exif?.gpsIFD { ifd0SubIFDs[gpsPointer] = gpsIFD.entries }

        var prevNextField: Int? = nil
        for (index, entries) in topIFDs.enumerated() {
            if writer.count % 2 != 0 { writer.writeUInt8(0) } // word-align each IFD
            let ifdStart = writer.count
            if let p = prevNextField {
                try writer.patchUInt32(UInt32(ifdStart), at: p, endian: endian)
            }
            let subIFDs = index == 0 ? ifd0SubIFDs : [:]
            prevNextField = try writeIFD(&writer, entries: entries, endian: endian, raw: raw, subIFDs: subIFDs)
        }
        // The final IFD's next-offset field was written as 0 — leave it.

        return writer.data
    }

    // MARK: - IFD0 metadata merge

    private static func buildIFD0Entries(
        existing: [IFDEntry],
        exif: ExifData?,
        iptc: IPTCData?,
        xmp: XMPData?,
        iccProfile: ICCProfile?
    ) throws -> [IFDEntry] {
        // Keep existing non-metadata entries (this retains structural and raster
        // tags such as StripOffsets/StripByteCounts).
        var entries = existing.filter { !metadataTagIDs.contains($0.tag) }

        // Merge descriptive IFD0 tags (Make, Model, Software, DateTime, …) from
        // the assigned exif, overriding the destination's same-tag entries.
        // Structural/raster tags and sub-IFD pointers are excluded — structural
        // layout stays with the destination, and Exif/GPS sub-IFDs are written
        // separately from `exif.exifIFD` / `exif.gpsIFD`.
        if let ifd0 = exif?.ifd0 {
            let descriptive = ifd0.entries.filter {
                !structuralIFD0Tags.contains($0.tag) && !metadataTagIDs.contains($0.tag) && !pointerTags.contains($0.tag)
            }
            let overrideTags = Set(descriptive.map { $0.tag })
            entries.removeAll { overrideTags.contains($0.tag) }
            entries.append(contentsOf: descriptive)
        }

        if let xmp = xmp {
            let xmlData = Data(XMPWriter.generateXML(xmp).utf8)
            entries.append(IFDEntry(tag: ExifTag.xmpTag, type: .undefined, count: UInt32(xmlData.count), valueData: xmlData))
        }

        if let iptc = iptc, !iptc.datasets.isEmpty {
            let iptcBinary = try IPTCWriter.write(iptc)
            let irbData = PhotoshopIRB.write(blocks: [IRBBlock(resourceID: PhotoshopIRB.iptcResourceID, data: iptcBinary)])
            entries.append(IFDEntry(tag: ExifTag.photoshopIRB, type: .undefined, count: UInt32(irbData.count), valueData: irbData))
        }

        if let icc = iccProfile {
            entries.append(IFDEntry(tag: ExifTag.iccProfile, type: .undefined, count: UInt32(icc.data.count), valueData: icc.data))
        }

        return entries.sorted { $0.tag < $1.tag }
    }

    // MARK: - IFD serialization (with block relocation)

    /// Write one IFD plus all data it points at (strip/tile/JPEG rasters and the
    /// Exif/GPS sub-IFDs), rewriting every offset. Returns the file position of
    /// this IFD's 4-byte next-IFD-offset field (initialized to 0) so the caller
    /// can chain it.
    private static func writeIFD(_ writer: inout BinaryWriter, entries rawEntries: [IFDEntry], endian: ByteOrder,
                                 raw: Data, subIFDs: [UInt16: [IFDEntry]]) throws -> Int {
        // Drop pointer entries we cannot relocate (avoids dangling offsets),
        // keeping only pointers whose child IFD we will write.
        var entries = rawEntries.filter { !pointerTags.contains($0.tag) || subIFDs[$0.tag] != nil }
        // Inject a placeholder pointer entry for each sub-IFD we will write.
        for tag in subIFDs.keys where !entries.contains(where: { $0.tag == tag }) {
            entries.append(IFDEntry(tag: tag, type: .long, count: 1, valueData: Data([0, 0, 0, 0])))
        }
        entries.sort { $0.tag < $1.tag }

        // Directory type per entry: offset arrays are written as LONG so a
        // relocated offset always fits even if the source used SHORT.
        func dirType(_ e: IFDEntry) -> TIFFDataType {
            (e.tag == stripOffsets || e.tag == tileOffsets) ? .long : e.type
        }
        func dirCount(_ e: IFDEntry) -> UInt32 {
            (e.tag == stripOffsets || e.tag == tileOffsets) ? UInt32(parseOffsets(e, endian: endian).count) : e.count
        }

        // --- Directory pass: write entries; inline small values, leave a
        // placeholder for everything that needs out-of-line data. ---
        writer.writeUInt16(UInt16(entries.count), endian: endian)
        var slotPositions: [Int] = []
        for e in entries {
            let type = dirType(e)
            let count = dirCount(e)
            writer.writeUInt16(e.tag, endian: endian)
            writer.writeUInt16(type.rawValue, endian: endian)
            writer.writeUInt32(count, endian: endian)
            let managed = pointerTags.contains(e.tag) || e.tag == stripOffsets || e.tag == tileOffsets || e.tag == jpegInterchangeFormat
            let valueSize = Int(count) * type.unitSize
            slotPositions.append(writer.count)
            if !managed && valueSize <= 4 {
                var padded = e.valueData.prefix(4)
                while padded.count < 4 { padded.append(0x00) }
                writer.writeBytes(Data(padded))
            } else {
                writer.writeUInt32(0, endian: endian) // placeholder; filled below
            }
        }
        let nextOffsetPos = writer.count
        writer.writeUInt32(0, endian: endian) // next-IFD offset (chained by caller)

        // --- Data pass: append out-of-line data and patch the slots. ---
        for (idx, e) in entries.enumerated() {
            let pos = slotPositions[idx]

            if e.tag == stripOffsets || e.tag == tileOffsets {
                let byteCountTag = e.tag == stripOffsets ? stripByteCounts : tileByteCounts
                let lengths = entries.first { $0.tag == byteCountTag }.map { parseOffsets($0, endian: endian) } ?? []
                let srcOffsets = parseOffsets(e, endian: endian)
                var newOffsets: [UInt64] = []
                for (k, srcOff) in srcOffsets.enumerated() {
                    let len = k < lengths.count ? Int(lengths[k]) : 0
                    align(&writer)
                    newOffsets.append(UInt64(writer.count))
                    writer.writeBytes(copyBlock(raw, offset: Int(srcOff), length: len))
                }
                writeOffsetArray(&writer, newOffsets, into: pos, endian: endian)

            } else if e.tag == jpegInterchangeFormat {
                let len = entries.first { $0.tag == jpegInterchangeFormatLength }
                    .flatMap { parseOffsets($0, endian: endian).first }.map(Int.init) ?? 0
                let srcOff = parseOffsets(e, endian: endian).first.map(Int.init) ?? 0
                align(&writer)
                let newOff = writer.count
                writer.writeBytes(copyBlock(raw, offset: srcOff, length: len))
                try writer.patchUInt32(UInt32(newOff), at: pos, endian: endian)

            } else if pointerTags.contains(e.tag), let childEntries = subIFDs[e.tag] {
                align(&writer)
                let childPos = writer.count
                // Child IFDs have no further sub-IFDs we relocate; pointer tags
                // inside them are dropped to avoid dangling offsets.
                _ = try writeIFD(&writer, entries: childEntries, endian: endian, raw: raw, subIFDs: [:])
                try writer.patchUInt32(UInt32(childPos), at: pos, endian: endian)

            } else if Int(e.count) * e.type.unitSize > 4 {
                align(&writer)
                let off = writer.count
                writer.writeBytes(e.valueData)
                try writer.patchUInt32(UInt32(off), at: pos, endian: endian)
            }
            // else: inline value already written in the directory pass.
        }

        return nextOffsetPos
    }

    // MARK: - Helpers

    /// Parse an entry's value as an array of unsigned integers (SHORT or LONG).
    private static func parseOffsets(_ entry: IFDEntry, endian: ByteOrder) -> [UInt64] {
        var reader = BinaryReader(data: entry.valueData)
        var values: [UInt64] = []
        for _ in 0..<entry.count {
            switch entry.type {
            case .short:
                guard let v = try? reader.readUInt16(endian: endian) else { return values }
                values.append(UInt64(v))
            case .long:
                guard let v = try? reader.readUInt32(endian: endian) else { return values }
                values.append(UInt64(v))
            default:
                return values
            }
        }
        return values
    }

    /// Copy `length` bytes at `offset` from the source file, clamped to bounds.
    private static func copyBlock(_ raw: Data, offset: Int, length: Int) -> Data {
        guard offset >= 0, length > 0, offset < raw.count else { return Data() }
        let end = min(offset + length, raw.count)
        return raw.subdata(in: (raw.startIndex + offset) ..< (raw.startIndex + end))
    }

    /// Write a relocated offset array (LONG) into a directory slot: inline when
    /// a single value fits, otherwise appended out-of-line and referenced.
    private static func writeOffsetArray(_ writer: inout BinaryWriter, _ offsets: [UInt64], into pos: Int, endian: ByteOrder) {
        if offsets.count <= 1 {
            try? writer.patchUInt32(UInt32(offsets.first ?? 0), at: pos, endian: endian)
        } else {
            align(&writer)
            let arrayOffset = writer.count
            for v in offsets { writer.writeUInt32(UInt32(truncatingIfNeeded: v), endian: endian) }
            try? writer.patchUInt32(UInt32(arrayOffset), at: pos, endian: endian)
        }
    }

    private static func align(_ writer: inout BinaryWriter) {
        if writer.count % 2 != 0 { writer.writeUInt8(0) }
    }
}
