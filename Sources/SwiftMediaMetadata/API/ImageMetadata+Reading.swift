import Foundation

extension ImageMetadata {
    // MARK: - Reading

    /// Read all metadata from an image file at the given URL.
    public static func read(from url: URL) throws -> ImageMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MetadataError.fileNotFound(url.path)
        }
        // Use `.alwaysMapped` rather than `.mappedIfSafe` — the latter declines
        // to map external volumes and silently loads the whole file into RAM,
        // which is wasteful for large raws/HEIFs where metadata lives in the
        // first few KB. (Same rationale as VideoMetadata.readMappedData.)
        let data = try Data(contentsOf: url, options: .alwaysMapped)

        // Try magic-byte detection first, fall back to extension
        var format = FormatDetector.detect(data)
            ?? FormatDetector.detectFromExtension(url.pathExtension)

        // GPR is DNG-structured, so content detection may report generic DNG. The
        // .gpr extension disambiguates it (content detection already upgrades files
        // with a GoPro Make on its own).
        if format == .raw(.dng), url.pathExtension.lowercased() == "gpr" {
            format = .raw(.gpr)
        }

        guard let format else {
            throw MetadataError.unsupportedFormat
        }

        return try read(from: data, format: format)
    }

    /// Read all metadata from image data in memory.
    /// Automatically detects the format from magic bytes.
    public static func read(from data: Data) throws -> ImageMetadata {
        guard let format = FormatDetector.detect(data) else {
            throw MetadataError.unsupportedFormat
        }
        return try read(from: data, format: format)
    }

    /// Read metadata from image data with a known format.
    public static func read(from data: Data, format: ImageFormat) throws -> ImageMetadata {
        switch format {
        case .jpeg:
            return try readJPEG(from: data)
        case .raw(.cr3):
            return try readCR3(from: data)
        case .raw(.raf), .raw(.rw2), .raw(.iiq), .raw(.x3f), .raw(.mrw):
            return try readRAW(from: data, format: format)
        case .tiff, .raw:
            return try readTIFF(from: data, format: format)
        case .jpegXL:
            return try readJPEGXL(from: data)
        case .png:
            return try readPNG(from: data)
        case .avif:
            return try readAVIF(from: data)
        case .heif:
            return try readHEIF(from: data)
        case .webp:
            return try readWebP(from: data)
        case .pdf:
            return try readPDF(from: data)
        case .psd:
            return try readPSD(from: data)
        case .gif:
            return try readGIF(from: data)
        case .bmp:
            return try readBMP(from: data)
        case .svg:
            return try readSVG(from: data)
        }
    }
}
