import Foundation

extension ImageMetadata {
    // MARK: - Preview Extraction

    /// Extract the embedded JPEG preview image (larger than thumbnail).
    /// For CR3 files, this returns the PRVW image (typically 1620x1080).
    /// Falls back to `extractThumbnail()` if no dedicated preview is found.
    public func extractPreview() -> Data? {
        switch container {
        case .cr3(let file):
            return file.previewData ?? file.thumbnailData
        default:
            // For other formats, fall back to thumbnail (future: SubIFD preview for TIFF-based RAW)
            return extractThumbnail()
        }
    }

    // MARK: - Thumbnail Extraction

    /// Extract every thumbnail asserted in any C2PA manifest (claim or ingredient).
    /// Returns the JUMBF `bidb` payloads as `C2PAThumbnail` values, in manifest/assertion order.
    /// Filter by `label` (e.g. has-prefix `"c2pa.thumbnail.claim."`) to narrow to a specific kind.
    public func extractC2PAThumbnails() -> [C2PAThumbnail] {
        guard let manifests = c2pa?.manifests else { return [] }
        var out: [C2PAThumbnail] = []
        for manifest in manifests {
            for assertion in manifest.assertions {
                guard case .thumbnail(let data, let format) = assertion.content,
                      !data.isEmpty else { continue }
                out.append(C2PAThumbnail(label: assertion.label, data: data, format: format))
            }
        }
        return out
    }

    /// Extract the embedded JPEG thumbnail from Exif IFD1, if present.
    /// Returns the raw JPEG data of the thumbnail image.
    public func extractThumbnail() -> Data? {
        // CR3 stores its thumbnail in the Canon `THMB` box, extracted at parse
        // time — there is no Exif IFD1 to consult.
        if case .cr3(let file) = container {
            return file.thumbnailData
        }

        guard let exif = exif,
              let ifd1 = exif.ifd1 else { return nil }

        let endian = exif.byteOrder

        // Check compression is JPEG (value 6)
        if let compression = ifd1.entry(for: ExifTag.compression)?.uint16Value(endian: endian),
           compression != 6 {
            return nil
        }

        // Get the thumbnail data directly from IFD1 entries
        // The thumbnail JPEG data was already resolved by the IFD parser into valueData
        guard let offsetEntry = ifd1.entry(for: ExifTag.jpegIFOffset),
              let lengthEntry = ifd1.entry(for: ExifTag.jpegIFByteCount),
              let length = lengthEntry.uint32Value(endian: endian) else { return nil }

        // The offset entry points to the thumbnail data within the original Exif blob.
        // Since IFDParser resolves offset-based values, if the data was large enough
        // it would be at the offset. But thumbnail offset/length are metadata about
        // where to find the thumbnail in the original TIFF data — they aren't the
        // thumbnail data itself. We need to extract from the container.
        guard let offset = offsetEntry.uint32Value(endian: endian) else { return nil }

        return extractThumbnailFromContainer(offset: Int(offset), length: Int(length))
    }

    private func extractThumbnailFromContainer(offset: Int, length: Int) -> Data? {
        switch container {
        case .jpeg(let file):
            // Thumbnail offset is relative to TIFF start within the Exif APP1 segment
            guard let exifSegment = file.exifSegment() else { return nil }
            let tiffStart = 6 // Skip "Exif\0\0"
            let absOffset = tiffStart + offset
            let data = exifSegment.data
            guard absOffset >= 0, absOffset + length <= data.count else { return nil }
            return data[data.startIndex + absOffset ..< data.startIndex + absOffset + length]

        case .tiff(let file):
            // Offset is relative to file start (tiffStart = 0)
            guard offset >= 0, offset + length <= file.rawData.count else { return nil }
            return file.rawData[file.rawData.startIndex + offset ..< file.rawData.startIndex + offset + length]

        case .png(let file):
            guard let chunk = file.findChunk("eXIf") else { return nil }
            // eXIf chunk is raw TIFF data, offset is relative to start of chunk data
            guard offset >= 0, offset + length <= chunk.data.count else { return nil }
            return chunk.data[chunk.data.startIndex + offset ..< chunk.data.startIndex + offset + length]

        case .jpegXL(let file):
            guard let box = file.findBox("Exif") else { return nil }
            // Exif box has 4-byte offset prefix before TIFF data
            let prefixSize = 4
            let absOffset = prefixSize + offset
            guard absOffset >= 0, absOffset + length <= box.data.count else { return nil }
            return box.data[box.data.startIndex + absOffset ..< box.data.startIndex + absOffset + length]

        case .avif(let file):
            return extractThumbnailFromISOBMFF(boxes: file.boxes, offset: offset, length: length)

        case .heif(let file):
            return extractThumbnailFromISOBMFF(boxes: file.boxes, offset: offset, length: length)

        case .webp(let file):
            guard let chunk = file.findChunk("EXIF") else { return nil }
            guard offset >= 0, offset + length <= chunk.data.count else { return nil }
            return chunk.data[chunk.data.startIndex + offset ..< chunk.data.startIndex + offset + length]

        case .cr3(let file):
            // CR3 thumbnails are in THMB box (already extracted during parsing)
            return file.thumbnailData

        case .pdf:
            return nil // PDFs don't have EXIF thumbnails

        case .psd:
            return nil // PSD thumbnails are in IRB resource 0x0409, not EXIF

        case .gif:
            return nil // GIF doesn't have standard Exif embedding
        case .bmp:
            return nil // BMP doesn't support embedded thumbnails
        case .svg:
            return nil // SVG doesn't support embedded thumbnails
        }
    }

    private func extractThumbnailFromISOBMFF(boxes: [ISOBMFFBox], offset: Int, length: Int) -> Data? {
        guard let exifBox = ISOBMFFMetadata.findBox(type: "Exif", in: boxes) else { return nil }
        let prefixSize = 4
        let absOffset = prefixSize + offset
        guard absOffset >= 0, absOffset + length <= exifBox.data.count else { return nil }
        return exifBox.data[exifBox.data.startIndex + absOffset ..< exifBox.data.startIndex + absOffset + length]
    }
}
