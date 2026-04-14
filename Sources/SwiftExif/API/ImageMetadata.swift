import Foundation

/// Unified metadata access for an image file.
public struct ImageMetadata: Sendable {
    public var container: ImageContainer
    public var format: ImageFormat
    public var iptc: IPTCData
    public var exif: ExifData?
    public var xmp: XMPData?
    public var c2pa: C2PAData?

    /// Non-fatal issues encountered during parsing (e.g. corrupted C2PA data).
    public var warnings: [String]

    public init(container: ImageContainer = .jpeg(JPEGFile()), format: ImageFormat = .jpeg, iptc: IPTCData = IPTCData(), exif: ExifData? = nil, xmp: XMPData? = nil, c2pa: C2PAData? = nil, warnings: [String] = []) {
        self.container = container
        self.format = format
        self.iptc = iptc
        self.exif = exif
        self.xmp = xmp
        self.c2pa = c2pa
        self.warnings = warnings
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
        case .heif:
            return try readHEIF(from: data)
        }
    }

    // MARK: - Writing

    /// Write all metadata back to a new Data blob (preserving image data).
    public func writeToData() throws -> Data {
        switch container {
        case .jpeg(var file):
            return try writeJPEG(&file)
        case .png(var file):
            return writePNG(&file)
        case .tiff(let file):
            return try writeTIFFFile(file)
        case .jpegXL(var file):
            return try writeJXL(&file)
        case .avif(let file):
            return try writeAVIF(file)
        case .heif(let file):
            return try writeHEIF(file)
        }
    }

    /// Write metadata to a file URL.
    public func write(to url: URL) throws {
        let data = try writeToData()
        try data.write(to: url)
    }

    // MARK: - Stripping

    /// Remove all metadata (Exif, IPTC, XMP, C2PA).
    public mutating func stripAllMetadata() {
        exif = nil
        iptc = IPTCData()
        xmp = nil
        c2pa = nil
    }

    /// Remove all Exif data.
    public mutating func stripExif() {
        exif = nil
    }

    /// Remove all IPTC data.
    public mutating func stripIPTC() {
        iptc = IPTCData()
    }

    /// Remove all XMP data.
    public mutating func stripXMP() {
        xmp = nil
    }

    /// Remove GPS data from Exif and XMP.
    public mutating func stripGPS() {
        exif?.gpsIFD = nil
        xmp?.removeValue(namespace: XMPNamespace.iptcCore, property: "Location")
    }

    /// Remove C2PA provenance data.
    public mutating func stripC2PA() {
        c2pa = nil
    }

    // MARK: - Date Shifting

    /// Shift all date/time fields by the given interval.
    /// Positive values move dates forward, negative values move them backward.
    /// Updates EXIF (DateTime, DateTimeOriginal, DateTimeDigitized),
    /// IPTC (DateCreated/TimeCreated, DigitalCreationDate/Time), and XMP (photoshop:DateCreated).
    public mutating func shiftDates(by interval: TimeInterval) {
        // EXIF dates: "YYYY:MM:DD HH:MM:SS"
        if exif != nil {
            shiftExifDate(tag: ExifTag.dateTime, ifdKeyPath: \.ifd0, interval: interval)
            shiftExifDate(tag: ExifTag.dateTimeOriginal, ifdKeyPath: \.exifIFD, interval: interval)
            shiftExifDate(tag: ExifTag.dateTimeDigitized, ifdKeyPath: \.exifIFD, interval: interval)
        }

        // IPTC dates: "YYYYMMDD" + "HHMMSS±HHMM"
        shiftIPTCDate(dateTag: .dateCreated, timeTag: .timeCreated, interval: interval)
        shiftIPTCDate(dateTag: .digitalCreationDate, timeTag: .digitalCreationTime, interval: interval)

        // XMP: photoshop:DateCreated (ISO 8601 or EXIF format)
        if let dateStr = xmp?.simpleValue(namespace: XMPNamespace.photoshop, property: "DateCreated"),
           let shifted = Self.shiftDateString(dateStr, by: interval) {
            xmp?.setValue(.simple(shifted), namespace: XMPNamespace.photoshop, property: "DateCreated")
        }
    }

    private mutating func shiftExifDate(tag: UInt16, ifdKeyPath: WritableKeyPath<ExifData, IFD?>, interval: TimeInterval) {
        guard let ifd = exif?[keyPath: ifdKeyPath],
              let entry = ifd.entry(for: tag),
              let dateStr = entry.stringValue(endian: exif!.byteOrder),
              let shifted = Self.shiftExifDateString(dateStr, by: interval) else { return }

        // Build new entry with shifted date
        guard let newData = shifted.data(using: .ascii) else { return }
        var padded = newData
        padded.append(0x00) // null terminator
        let newEntry = IFDEntry(tag: tag, type: .ascii, count: UInt32(padded.count), valueData: padded)

        // Replace the entry in the IFD
        var entries = ifd.entries.filter { $0.tag != tag }
        entries.append(newEntry)
        exif?[keyPath: ifdKeyPath] = IFD(entries: entries, nextIFDOffset: ifd.nextIFDOffset)
    }

    private mutating func shiftIPTCDate(dateTag: IPTCTag, timeTag: IPTCTag, interval: TimeInterval) {
        guard let dateStr = iptc.value(for: dateTag) else { return }
        let timeStr = iptc.value(for: timeTag)

        // Combine into a parseable date, shift, then split back
        let combined = Self.combineIPTCDateTime(date: dateStr, time: timeStr)
        guard let shifted = Self.shiftExifDateString(combined, by: interval) else { return }

        // Split back: first 10 chars "YYYY:MM:DD" → "YYYYMMDD", rest → time
        let parts = shifted.split(separator: " ", maxSplits: 1)
        if let datePart = parts.first {
            let iptcDate = datePart.replacingOccurrences(of: ":", with: "")
            try? iptc.setValue(iptcDate, for: dateTag)
        }
        if parts.count > 1 {
            let timePart = String(parts[1]).replacingOccurrences(of: ":", with: "")
            try? iptc.setValue(timePart, for: timeTag)
        }
    }

    // MARK: - Date Parsing Helpers

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func shiftExifDateString(_ dateStr: String, by interval: TimeInterval) -> String? {
        guard let date = exifDateFormatter.date(from: dateStr) else { return nil }
        let shifted = date.addingTimeInterval(interval)
        return exifDateFormatter.string(from: shifted)
    }

    /// Shift a date string in various formats (EXIF, ISO 8601).
    static func shiftDateString(_ dateStr: String, by interval: TimeInterval) -> String? {
        // Try EXIF format first
        if let result = shiftExifDateString(dateStr, by: interval) {
            return result
        }
        // Try ISO 8601 (e.g. "2024-01-15T14:30:00")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: dateStr) {
            let shifted = date.addingTimeInterval(interval)
            return iso.string(from: shifted)
        }
        // Try date-only ISO (e.g. "2024-01-15")
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        if let date = dateOnly.date(from: dateStr) {
            let shifted = date.addingTimeInterval(interval)
            return dateOnly.string(from: shifted)
        }
        return nil
    }

    /// Combine IPTC date "YYYYMMDD" and time "HHMMSS" into EXIF format "YYYY:MM:DD HH:MM:SS".
    private static func combineIPTCDateTime(date: String, time: String?) -> String {
        // Date: "YYYYMMDD" → "YYYY:MM:DD"
        var result = date
        if date.count == 8 && !date.contains(":") {
            let y = date.prefix(4)
            let m = date.dropFirst(4).prefix(2)
            let d = date.dropFirst(6).prefix(2)
            result = "\(y):\(m):\(d)"
        }

        // Time: "HHMMSS" → " HH:MM:SS"
        if let time = time {
            // Strip timezone suffix if present (±HHMM)
            let core = time.prefix(6)
            if core.count == 6 {
                let h = core.prefix(2)
                let min = core.dropFirst(2).prefix(2)
                let s = core.dropFirst(4).prefix(2)
                result += " \(h):\(min):\(s)"
            }
        } else {
            result += " 00:00:00"
        }

        return result
    }

    // MARK: - Metadata Groups

    /// Groups of metadata that can be selectively copied or compared.
    public enum MetadataGroup: CaseIterable, Sendable {
        case exif
        case iptc
        case xmp
        case c2pa
    }

    // MARK: - Copy Metadata

    /// Copy all metadata from another ImageMetadata instance.
    /// Replaces all Exif, IPTC, XMP, and C2PA data with the source's values.
    public mutating func copyMetadata(from source: ImageMetadata) {
        exif = source.exif
        iptc = source.iptc
        xmp = source.xmp
        c2pa = source.c2pa
    }

    /// Copy selected metadata groups from another ImageMetadata instance.
    public mutating func copyMetadata(from source: ImageMetadata, groups: Set<MetadataGroup>) {
        if groups.contains(.exif) { exif = source.exif }
        if groups.contains(.iptc) { iptc = source.iptc }
        if groups.contains(.xmp) { xmp = source.xmp }
        if groups.contains(.c2pa) { c2pa = source.c2pa }
    }

    // MARK: - Metadata Diff

    /// A single difference between two metadata values.
    public struct MetadataChange: Equatable, Sendable {
        public enum ChangeType: Equatable, Sendable {
            case added
            case removed
            case modified
        }

        public let key: String
        public let type: ChangeType
        public let oldValue: String?
        public let newValue: String?

        public init(key: String, type: ChangeType, oldValue: String? = nil, newValue: String? = nil) {
            self.key = key
            self.type = type
            self.oldValue = oldValue
            self.newValue = newValue
        }
    }

    /// Result of comparing two metadata instances.
    public struct MetadataDiff: Sendable {
        public let changes: [MetadataChange]

        public var additions: [MetadataChange] { changes.filter { $0.type == .added } }
        public var removals: [MetadataChange] { changes.filter { $0.type == .removed } }
        public var modifications: [MetadataChange] { changes.filter { $0.type == .modified } }
        public var isEmpty: Bool { changes.isEmpty }
    }

    /// Compare this metadata against another instance and return differences.
    public func diff(against other: ImageMetadata) -> MetadataDiff {
        let selfDict = MetadataExporter.buildDictionary(self)
        let otherDict = MetadataExporter.buildDictionary(other)

        var changes: [MetadataChange] = []
        let allKeys = Set(selfDict.keys).union(otherDict.keys)

        for key in allKeys.sorted() {
            let selfVal = selfDict[key].map { Self.stringifyValue($0) }
            let otherVal = otherDict[key].map { Self.stringifyValue($0) }

            switch (selfVal, otherVal) {
            case (nil, .some(let new)):
                changes.append(MetadataChange(key: key, type: .added, newValue: new))
            case (.some(let old), nil):
                changes.append(MetadataChange(key: key, type: .removed, oldValue: old))
            case (.some(let old), .some(let new)) where old != new:
                changes.append(MetadataChange(key: key, type: .modified, oldValue: old, newValue: new))
            default:
                break
            }
        }

        return MetadataDiff(changes: changes)
    }

    private static func stringifyValue(_ value: Any) -> String {
        if let arr = value as? [String] {
            return arr.joined(separator: ", ")
        }
        return String(describing: value)
    }

    // MARK: - Thumbnail Extraction

    /// Extract the embedded JPEG thumbnail from Exif IFD1, if present.
    /// Returns the raw JPEG data of the thumbnail image.
    public func extractThumbnail() -> Data? {
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
        }
    }

    private func extractThumbnailFromISOBMFF(boxes: [ISOBMFFBox], offset: Int, length: Int) -> Data? {
        guard let exifBox = ISOBMFFMetadata.findBox(type: "Exif", in: boxes) else { return nil }
        let prefixSize = 4
        let absOffset = prefixSize + offset
        guard absOffset >= 0, absOffset + length <= exifBox.data.count else { return nil }
        return exifBox.data[exifBox.data.startIndex + absOffset ..< exifBox.data.startIndex + absOffset + length]
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
    /// Throws `MetadataError.encodingError` if any XMP value cannot be encoded for IPTC.
    public mutating func syncXMPToIPTC() throws {
        guard let xmp = xmp else { return }

        for (iptcTag, xmpMapping) in XMPNamespace.iimToXMP {
            if iptcTag.isRepeatable {
                let values = xmp.arrayValue(namespace: xmpMapping.namespace, property: xmpMapping.property)
                if !values.isEmpty {
                    try iptc.setValues(values, for: iptcTag)
                }
            } else {
                if let value = xmp.simpleValue(namespace: xmpMapping.namespace, property: xmpMapping.property) {
                    try iptc.setValue(value, for: iptcTag)
                }
            }
        }
    }

    // MARK: - XMP Sidecar

    /// Read XMP metadata from a sidecar file alongside the given image URL.
    public static func readSidecar(for imageURL: URL) throws -> XMPData {
        let sidecarURL = XMPSidecar.sidecarURL(for: imageURL)
        return try XMPSidecar.read(from: sidecarURL)
    }

    /// Write current XMP metadata as a sidecar file.
    public func writeSidecar(to url: URL) throws {
        guard let xmp = xmp else {
            throw MetadataError.writeNotSupported("No XMP data to write as sidecar")
        }
        try XMPSidecar.write(xmp, to: url)
    }

    /// Write current XMP metadata as a sidecar file alongside the given image URL.
    public func writeSidecar(for imageURL: URL) throws {
        let sidecarURL = XMPSidecar.sidecarURL(for: imageURL)
        try writeSidecar(to: sidecarURL)
    }

    // MARK: - Format-Specific Writing

    private func writeJPEG(_ file: inout JPEGFile) throws -> Data {
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

        return try JPEGWriter.write(file)
    }

    private func writePNG(_ file: inout PNGFile) -> Data {
        // Write Exif as eXIf chunk (raw TIFF, no prefix)
        if let exif = exif {
            let tiffData = ExifWriter.writeTIFF(exif)
            file.replaceOrAddExifChunk(tiffData)
        }

        // Write XMP as iTXt chunk
        if let xmp = xmp {
            let xml = XMPWriter.generateXML(xmp)
            file.replaceOrAddXMPChunk(xml)
        }

        return PNGWriter.write(file)
    }

    private func writeJXL(_ file: inout JXLFile) throws -> Data {
        // Write Exif box (4-byte offset prefix + TIFF data)
        if let exif = exif {
            var exifPayload = Data([0x00, 0x00, 0x00, 0x00]) // offset prefix
            exifPayload.append(ExifWriter.writeTIFF(exif))
            file.replaceOrAddBox("Exif", data: exifPayload)
        }

        // Write XMP box (type "xml ")
        if let xmp = xmp {
            let xml = XMPWriter.generateXML(xmp)
            file.replaceOrAddBox("xml ", data: Data(xml.utf8))
        }

        return try JXLWriter.write(file)
    }

    private func writeAVIF(_ file: AVIFFile) throws -> Data {
        return try AVIFWriter.write(file, exif: exif, xmp: xmp)
    }

    private func writeHEIF(_ file: HEIFFile) throws -> Data {
        return try HEIFWriter.write(file, exif: exif, xmp: xmp)
    }

    private func writeTIFFFile(_ file: TIFFFile) throws -> Data {
        return try TIFFWriter.write(file, exif: exif, iptc: iptc, xmp: xmp)
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

        // C2PA from APP11 JUMBF segments
        var c2pa: C2PAData?
        var warnings: [String] = []
        do {
            if let jumbfData = try C2PAReader.extractJUMBFFromJPEG(jpegFile) {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            }
        } catch {
            warnings.append("C2PA parsing failed: \(error)")
        }

        return ImageMetadata(container: .jpeg(jpegFile), format: .jpeg, iptc: iptc, exif: exif, xmp: xmp, c2pa: c2pa, warnings: warnings)
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

        // C2PA from jumb box
        var c2pa: C2PAData?
        var warnings: [String] = []
        if let jumbfData = C2PAReader.extractJUMBFFromJPEGXL(jxlFile) {
            do {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            } catch {
                warnings.append("C2PA parsing failed: \(error)")
            }
        }

        return ImageMetadata(container: .jpegXL(jxlFile), format: .jpegXL, iptc: IPTCData(), exif: exif, xmp: xmp, c2pa: c2pa, warnings: warnings)
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

        // C2PA from caBX chunk
        var c2pa: C2PAData?
        var warnings: [String] = []
        if let jumbfData = C2PAReader.extractJUMBFFromPNG(pngFile) {
            do {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            } catch {
                warnings.append("C2PA parsing failed: \(error)")
            }
        }

        return ImageMetadata(container: .png(pngFile), format: .png, iptc: IPTCData(), exif: exif, xmp: xmp, c2pa: c2pa, warnings: warnings)
    }

    private static func readAVIF(from data: Data) throws -> ImageMetadata {
        let avifFile = try AVIFParser.parse(data)

        let exif = try AVIFParser.extractExif(from: avifFile)
        let xmp = try AVIFParser.extractXMP(from: avifFile)

        // C2PA from jumb or uuid box
        var c2pa: C2PAData?
        var warnings: [String] = []
        if let jumbfData = C2PAReader.extractJUMBFFromAVIF(avifFile) {
            do {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            } catch {
                warnings.append("C2PA parsing failed: \(error)")
            }
        }

        return ImageMetadata(container: .avif(avifFile), format: .avif, iptc: IPTCData(), exif: exif, xmp: xmp, c2pa: c2pa, warnings: warnings)
    }

    private static func readHEIF(from data: Data) throws -> ImageMetadata {
        let heifFile = try HEIFParser.parse(data)

        let exif = try HEIFParser.extractExif(from: heifFile, fileData: data)
        let xmp = try HEIFParser.extractXMP(from: heifFile, fileData: data)

        // C2PA from jumb or uuid box
        var c2pa: C2PAData?
        var warnings: [String] = []
        if let jumbfData = C2PAReader.extractJUMBFFromHEIF(heifFile) {
            do {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            } catch {
                warnings.append("C2PA parsing failed: \(error)")
            }
        }

        return ImageMetadata(container: .heif(heifFile), format: .heif, iptc: IPTCData(), exif: exif, xmp: xmp, c2pa: c2pa, warnings: warnings)
    }
}
