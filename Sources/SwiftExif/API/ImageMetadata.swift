import Foundation

/// Unified metadata access for an image file.
public struct ImageMetadata: Sendable {
    public var container: ImageContainer
    public var format: ImageFormat
    public var iptc: IPTCData
    public var exif: ExifData?
    public var xmp: XMPData?

    public init(container: ImageContainer = .jpeg(JPEGFile()), format: ImageFormat = .jpeg, iptc: IPTCData = IPTCData(), exif: ExifData? = nil, xmp: XMPData? = nil) {
        self.container = container
        self.format = format
        self.iptc = iptc
        self.exif = exif
        self.xmp = xmp
    }

    // MARK: - Reading

    /// Read all metadata from an image file at the given URL.
    public static func read(from url: URL) throws -> ImageMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MetadataError.fileNotFound(url.path)
        }
        let data = try Data(contentsOf: url)

        // Try magic-byte detection first, fall back to extension
        let format = FormatDetector.detect(data)
            ?? FormatDetector.detectFromExtension(url.pathExtension)

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
        case .tiff, .raw:
            return try readTIFF(from: data, format: format)
        case .jpegXL:
            return try readJPEGXL(from: data)
        case .png:
            return try readPNG(from: data)
        case .avif:
            return try readAVIF(from: data)
        }
    }

    // MARK: - Writing

    /// Write all metadata back to a new Data blob (preserving image data).
    /// Currently only supported for JPEG.
    public func writeToData() throws -> Data {
        guard case .jpeg(var file) = container else {
            throw MetadataError.unsupportedFormat
        }

        // Write IPTC
        let existingAPP13 = file.iptcSegment()?.data
        let app13Data = try IPTCWriter.writeToAPP13(iptc, existingAPP13: existingAPP13)
        file.replaceOrAddIPTCSegment(JPEGSegment(marker: .app13, data: app13Data))

        // Write Exif
        if let exif = exif {
            let exifData = ExifWriter.write(exif)
            file.replaceOrAddExifSegment(JPEGSegment(marker: .app1, data: exifData))
        }

        // Write XMP
        if let xmp = xmp {
            let xmpData = XMPWriter.write(xmp)
            file.replaceOrAddXMPSegment(JPEGSegment(marker: .app1, data: xmpData))
        }

        return JPEGWriter.write(file)
    }

    /// Write metadata to a file URL.
    public func write(to url: URL) throws {
        let data = try writeToData()
        try data.write(to: url)
    }

    // MARK: - IPTC ↔ XMP Sync

    /// Synchronize IPTC values to XMP (one-way: IPTC → XMP).
    public mutating func syncIPTCToXMP() {
        if xmp == nil { xmp = XMPData() }

        for (iptcTag, xmpMapping) in XMPNamespace.iimToXMP {
            if iptcTag.isRepeatable {
                let values = iptc.values(for: iptcTag)
                if !values.isEmpty {
                    xmp?.setValue(.array(values), namespace: xmpMapping.namespace, property: xmpMapping.property)
                }
            } else {
                if let value = iptc.value(for: iptcTag) {
                    // dc:title, dc:description, dc:rights use langAlternative
                    if xmpMapping.namespace == XMPNamespace.dc &&
                       (xmpMapping.property == "title" || xmpMapping.property == "description" || xmpMapping.property == "rights") {
                        xmp?.setValue(.langAlternative(value), namespace: xmpMapping.namespace, property: xmpMapping.property)
                    } else {
                        xmp?.setValue(.simple(value), namespace: xmpMapping.namespace, property: xmpMapping.property)
                    }
                }
            }
        }
    }

    /// Synchronize XMP values to IPTC (one-way: XMP → IPTC).
    public mutating func syncXMPToIPTC() {
        guard let xmp = xmp else { return }

        for (iptcTag, xmpMapping) in XMPNamespace.iimToXMP {
            if iptcTag.isRepeatable {
                let values = xmp.arrayValue(namespace: xmpMapping.namespace, property: xmpMapping.property)
                if !values.isEmpty {
                    iptc.setValues(values, for: iptcTag)
                }
            } else {
                if let value = xmp.simpleValue(namespace: xmpMapping.namespace, property: xmpMapping.property) {
                    iptc.setValue(value, for: iptcTag)
                }
            }
        }
    }

    // MARK: - Format-Specific Reading

    private static func readJPEG(from data: Data) throws -> ImageMetadata {
        let jpegFile = try JPEGParser.parse(data)

        var iptc = IPTCData()
        if let iptcSegment = jpegFile.iptcSegment() {
            iptc = try IPTCReader.readFromAPP13(iptcSegment.data)
        }

        var exif: ExifData?
        if let exifSegment = jpegFile.exifSegment() {
            exif = try ExifReader.read(from: exifSegment.data)
        }

        var xmp: XMPData?
        if let xmpSegment = jpegFile.xmpSegment() {
            xmp = try XMPReader.read(from: xmpSegment.data)
        }

        return ImageMetadata(container: .jpeg(jpegFile), format: .jpeg, iptc: iptc, exif: exif, xmp: xmp)
    }

    private static func readTIFF(from data: Data, format: ImageFormat) throws -> ImageMetadata {
        let tiffFile = try TIFFFileParser.parse(data)

        var iptc = IPTCData()
        var exif: ExifData?
        var xmp: XMPData?

        // Build ExifData from the parsed IFDs
        exif = try TIFFFileParser.extractExif(from: tiffFile, data: data)

        // Extract IPTC (from tag 0x8649 Photoshop IRB, or tag 0x83BB raw IPTC-NAA)
        iptc = try TIFFFileParser.extractIPTC(from: tiffFile)

        // Extract XMP (from tag 0x02BC)
        xmp = try TIFFFileParser.extractXMP(from: tiffFile)

        return ImageMetadata(container: .tiff(tiffFile), format: format, iptc: iptc, exif: exif, xmp: xmp)
    }

    private static func readJPEGXL(from data: Data) throws -> ImageMetadata {
        let jxlFile = try JXLParser.parse(data)

        var exif: ExifData?
        var xmp: XMPData?

        // Exif box
        if let exifBox = jxlFile.findBox("Exif") {
            exif = try JXLParser.extractExif(from: exifBox)
        }

        // XMP box (type "xml ")
        if let xmpBox = jxlFile.findBox("xml ") {
            xmp = try XMPReader.readFromXML(xmpBox.data)
        }

        return ImageMetadata(container: .jpegXL(jxlFile), format: .jpegXL, iptc: IPTCData(), exif: exif, xmp: xmp)
    }

    private static func readPNG(from data: Data) throws -> ImageMetadata {
        let pngFile = try PNGParser.parse(data)

        var exif: ExifData?
        var xmp: XMPData?

        // eXIf chunk
        if let exifChunk = pngFile.findChunk("eXIf") {
            exif = try ExifReader.readFromTIFF(data: exifChunk.data)
        }

        // XMP in iTXt chunk with keyword "XML:com.adobe.xmp"
        xmp = try PNGParser.extractXMP(from: pngFile)

        return ImageMetadata(container: .png(pngFile), format: .png, iptc: IPTCData(), exif: exif, xmp: xmp)
    }

    private static func readAVIF(from data: Data) throws -> ImageMetadata {
        let avifFile = try AVIFParser.parse(data)

        let exif = try AVIFParser.extractExif(from: avifFile)
        let xmp = try AVIFParser.extractXMP(from: avifFile)

        return ImageMetadata(container: .avif(avifFile), format: .avif, iptc: IPTCData(), exif: exif, xmp: xmp)
    }
}
