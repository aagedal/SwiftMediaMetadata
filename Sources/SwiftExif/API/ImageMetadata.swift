import Foundation

/// Unified metadata access for a JPEG file.
public struct ImageMetadata: Sendable {
    public var jpegFile: JPEGFile
    public var iptc: IPTCData
    public var exif: ExifData?
    public var xmp: XMPData?

    public init(jpegFile: JPEGFile = JPEGFile(), iptc: IPTCData = IPTCData(), exif: ExifData? = nil, xmp: XMPData? = nil) {
        self.jpegFile = jpegFile
        self.iptc = iptc
        self.exif = exif
        self.xmp = xmp
    }

    // MARK: - Reading

    /// Read all metadata from a JPEG file at the given URL.
    public static func read(from url: URL) throws -> ImageMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MetadataError.fileNotFound(url.path)
        }
        let data = try Data(contentsOf: url)
        return try read(from: data)
    }

    /// Read all metadata from JPEG data in memory.
    public static func read(from data: Data) throws -> ImageMetadata {
        let jpegFile = try JPEGParser.parse(data)

        // Read IPTC
        var iptc = IPTCData()
        if let iptcSegment = jpegFile.iptcSegment() {
            iptc = try IPTCReader.readFromAPP13(iptcSegment.data)
        }

        // Read Exif
        var exif: ExifData?
        if let exifSegment = jpegFile.exifSegment() {
            exif = try ExifReader.read(from: exifSegment.data)
        }

        // Read XMP
        var xmp: XMPData?
        if let xmpSegment = jpegFile.xmpSegment() {
            xmp = try XMPReader.read(from: xmpSegment.data)
        }

        return ImageMetadata(jpegFile: jpegFile, iptc: iptc, exif: exif, xmp: xmp)
    }

    // MARK: - Writing

    /// Write all metadata back to a new Data blob (preserving image data).
    public func writeToData() throws -> Data {
        var file = jpegFile

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
                    if iptcTag == .keywords {
                        xmp?.setValue(.array(values), namespace: xmpMapping.namespace, property: xmpMapping.property)
                    } else if iptcTag == .byline {
                        xmp?.setValue(.array(values), namespace: xmpMapping.namespace, property: xmpMapping.property)
                    } else {
                        xmp?.setValue(.array(values), namespace: xmpMapping.namespace, property: xmpMapping.property)
                    }
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
}
