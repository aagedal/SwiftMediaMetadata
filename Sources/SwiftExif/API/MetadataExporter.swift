import Foundation

/// Export metadata in machine-readable formats (JSON, XML).
public struct MetadataExporter: Sendable {

    // MARK: - JSON Export

    /// Export metadata as JSON Data, matching ExifTool's `-json` output format.
    public static func toJSON(_ metadata: ImageMetadata) -> Data {
        toJSON([metadata])
    }

    /// Export multiple files' metadata as a JSON array.
    public static func toJSON(_ items: [ImageMetadata]) -> Data {
        var entries: [[String: Any]] = []
        for metadata in items {
            entries.append(buildDictionary(metadata))
        }
        let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        return data ?? Data("[]".utf8)
    }

    /// Export metadata as a JSON string.
    public static func toJSONString(_ metadata: ImageMetadata) -> String {
        String(data: toJSON(metadata), encoding: .utf8) ?? "[]"
    }

    // MARK: - XML Export

    /// Export metadata as an XML string.
    public static func toXML(_ metadata: ImageMetadata) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n"
        xml += "<rdf:Description>\n"

        let dict = buildDictionary(metadata)
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            if let array = value as? [String] {
                xml += "  <\(escapeXMLTag(key))>\n"
                for item in array {
                    xml += "    <rdf:li>\(escapeXMLValue(item))</rdf:li>\n"
                }
                xml += "  </\(escapeXMLTag(key))>\n"
            } else {
                xml += "  <\(escapeXMLTag(key))>\(escapeXMLValue(String(describing: value)))</\(escapeXMLTag(key))>\n"
            }
        }

        xml += "</rdf:Description>\n"
        xml += "</rdf:RDF>\n"
        return xml
    }

    // MARK: - Dictionary Building

    /// Build a flat dictionary of all metadata fields, including file-level tags if URL is provided.
    public static func buildDictionary(_ metadata: ImageMetadata, fileURL: URL? = nil) -> [String: Any] {
        var dict: [String: Any] = [:]

        dict["FileFormat"] = formatName(metadata.format)

        // File-level tags (size, hashes) when URL is available
        if let url = fileURL, let data = try? Data(contentsOf: url) {
            dict["File:FileSize"] = Int(data.count)
            let hashes = FileHasher.allHashes(data)
            dict["File:MD5"] = hashes.md5
            dict["File:SHA256"] = hashes.sha256
            dict["File:FileName"] = url.lastPathComponent
            dict["File:Directory"] = url.deletingLastPathComponent().path
        }

        // EXIF
        if let exif = metadata.exif {
            addExifFields(&dict, exif)
        }

        // IPTC
        addIPTCFields(&dict, metadata.iptc)

        // XMP
        if let xmp = metadata.xmp {
            addXMPFields(&dict, xmp)
        }

        // MakerNote
        if let makerNote = metadata.exif?.makerNote {
            for (key, value) in makerNote.tags {
                switch value {
                case .string(let s): dict["MakerNote:\(key)"] = s
                case .int(let i): dict["MakerNote:\(key)"] = i
                case .uint(let u): dict["MakerNote:\(key)"] = Int(u)
                case .double(let d): dict["MakerNote:\(key)"] = d
                case .data: break
                case .intArray(let arr): dict["MakerNote:\(key)"] = arr.map(String.init).joined(separator: " ")
                }
            }
        }

        // Composite Tags
        if let exif = metadata.exif {
            let composites = CompositeTagCalculator.calculate(from: exif)
            for (key, value) in composites {
                dict[key] = value
            }
        }

        // PDF Info dictionary
        if case .pdf(let pdfFile) = metadata.container {
            for (key, value) in pdfFile.infoDict {
                dict["PDF:\(key)"] = value
            }
        }

        // BMP header info
        if case .bmp(let bmpFile) = metadata.container {
            dict["BMP:ImageWidth"] = Int(bmpFile.width)
            dict["BMP:ImageHeight"] = Int(bmpFile.absoluteHeight)
            dict["BMP:BitsPerPixel"] = Int(bmpFile.bitsPerPixel)
            dict["BMP:Compression"] = bmpFile.compressionName
            dict["BMP:Version"] = bmpFile.bmpVersion
            if bmpFile.xPixelsPerMeter != 0 {
                dict["BMP:XResolution"] = Int(round(bmpFile.xDPI))
                dict["BMP:YResolution"] = Int(round(bmpFile.yDPI))
            }
        }

        // GIF dimensions
        if case .gif(let gifFile) = metadata.container {
            dict["GIF:ImageWidth"] = Int(gifFile.width)
            dict["GIF:ImageHeight"] = Int(gifFile.height)
            let comments = gifFile.comments
            if !comments.isEmpty { dict["GIF:Comment"] = comments.joined(separator: "; ") }
        }

        // SVG dimensions
        if case .svg(let svgFile) = metadata.container {
            if let w = svgFile.width { dict["SVG:Width"] = w }
            if let h = svgFile.height { dict["SVG:Height"] = h }
            if let vb = svgFile.viewBox { dict["SVG:ViewBox"] = vb }
        }

        // ICC Profile
        if let icc = metadata.iccProfile {
            dict["ICCProfile:ColorSpace"] = icc.colorSpace.trimmingCharacters(in: .whitespaces)
            if let desc = icc.profileDescription {
                dict["ICCProfile:Description"] = desc
            }
            dict["ICCProfile:Size"] = Int(icc.profileSize)
        }

        return dict
    }

    /// Build a filtered dictionary, including only keys that match the filter.
    public static func filteredDictionary(_ metadata: ImageMetadata, filter: TagFilter) -> [String: Any] {
        filter.apply(to: buildDictionary(metadata))
    }

    // MARK: - EXIF Fields

    private static func addExifFields(_ dict: inout [String: Any], _ exif: ExifData) {
        if let v = exif.make { dict["Make"] = v }
        if let v = exif.model { dict["Model"] = v }
        if let v = exif.software { dict["Software"] = v }
        if let v = exif.dateTime { dict["DateTime"] = v }
        if let v = exif.dateTimeOriginal { dict["DateTimeOriginal"] = v }
        if let v = exif.copyright { dict["Copyright"] = v }
        if let v = exif.artist { dict["Artist"] = v }
        if let v = exif.lensModel { dict["LensModel"] = v }
        if let v = exif.orientation { dict["Orientation"] = Int(v) }
        if let v = exif.isoSpeed { dict["ISO"] = Int(v) }

        if let v = exif.exposureTime {
            if v.denominator != 0 {
                dict["ExposureTime"] = "\(v.numerator)/\(v.denominator)"
            }
        }
        if let v = exif.fNumber {
            if v.denominator != 0 {
                dict["FNumber"] = Double(v.numerator) / Double(v.denominator)
            }
        }
        if let v = exif.focalLength {
            if v.denominator != 0 {
                dict["FocalLength"] = Double(v.numerator) / Double(v.denominator)
            }
        }

        // Numeric Exif fields (raw values for PrintConverter)
        if let entry = exif.exifIFD?.entry(for: ExifTag.exposureProgram),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["ExposureProgram"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.meteringMode),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["MeteringMode"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.flash),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["Flash"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.colorSpace),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["ColorSpace"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.whiteBalance),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["WhiteBalance"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.sceneCaptureType),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["SceneCaptureType"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.exposureMode),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["ExposureMode"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.customRendered),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["CustomRendered"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.lightSource),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["LightSource"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.sensingMethod),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["SensingMethod"] = Int(v) }
        if let entry = exif.ifd0?.entry(for: ExifTag.resolutionUnit),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["ResolutionUnit"] = Int(v) }
        if let entry = exif.ifd0?.entry(for: ExifTag.compression),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["Compression"] = Int(v) }

        if let lat = exif.gpsLatitude { dict["GPSLatitude"] = lat }
        if let lon = exif.gpsLongitude { dict["GPSLongitude"] = lon }

        // Additional Exif fields
        if let w = exif.pixelXDimension { dict["PixelXDimension"] = Int(w) }
        if let h = exif.pixelYDimension { dict["PixelYDimension"] = Int(h) }
        if let fl35 = exif.focalLengthIn35mmFilm { dict["FocalLengthIn35mmFilm"] = Int(fl35) }
        if let lm = exif.lensMake { dict["LensMake"] = lm }

        // DateTimeDigitized
        if let entry = exif.exifIFD?.entry(for: ExifTag.dateTimeDigitized),
           let v = entry.stringValue(endian: exif.byteOrder) {
            dict["DateTimeDigitized"] = v
        }

        // SubSecond time tags
        if let v = exif.subSecTime { dict["SubSecTime"] = v }
        if let v = exif.subSecTimeOriginal { dict["SubSecTimeOriginal"] = v }
        if let v = exif.subSecTimeDigitized { dict["SubSecTimeDigitized"] = v }

        // Timezone offset tags (EXIF 2.31+)
        if let v = exif.offsetTime { dict["OffsetTime"] = v }
        if let v = exif.offsetTimeOriginal { dict["OffsetTimeOriginal"] = v }
        if let v = exif.offsetTimeDigitized { dict["OffsetTimeDigitized"] = v }

        // Image dimensions
        if let entry = exif.ifd0?.entry(for: ExifTag.imageWidth) {
            if let v = entry.uint32Value(endian: exif.byteOrder) { dict["ImageWidth"] = Int(v) }
            else if let v = entry.uint16Value(endian: exif.byteOrder) { dict["ImageWidth"] = Int(v) }
        }
        if let entry = exif.ifd0?.entry(for: ExifTag.imageHeight) {
            if let v = entry.uint32Value(endian: exif.byteOrder) { dict["ImageHeight"] = Int(v) }
            else if let v = entry.uint16Value(endian: exif.byteOrder) { dict["ImageHeight"] = Int(v) }
        }
    }

    // MARK: - IPTC Fields

    private static func addIPTCFields(_ dict: inout [String: Any], _ iptc: IPTCData) {
        if let v = iptc.headline { dict["IPTC:Headline"] = v }
        if let v = iptc.caption { dict["IPTC:Caption-Abstract"] = v }
        if let v = iptc.byline { dict["IPTC:By-line"] = v }
        if let v = iptc.credit { dict["IPTC:Credit"] = v }
        if let v = iptc.source { dict["IPTC:Source"] = v }
        if let v = iptc.copyright { dict["IPTC:CopyrightNotice"] = v }
        if let v = iptc.city { dict["IPTC:City"] = v }
        if let v = iptc.sublocation { dict["IPTC:Sub-location"] = v }
        if let v = iptc.provinceState { dict["IPTC:Province-State"] = v }
        if let v = iptc.countryCode { dict["IPTC:Country-PrimaryLocationCode"] = v }
        if let v = iptc.countryName { dict["IPTC:Country-PrimaryLocationName"] = v }
        if let v = iptc.dateCreated { dict["IPTC:DateCreated"] = v }
        if let v = iptc.timeCreated { dict["IPTC:TimeCreated"] = v }
        if let v = iptc.specialInstructions { dict["IPTC:SpecialInstructions"] = v }
        if let v = iptc.objectName { dict["IPTC:ObjectName"] = v }
        if let v = iptc.writerEditor { dict["IPTC:Writer-Editor"] = v }
        if let v = iptc.jobId { dict["IPTC:OriginalTransmissionReference"] = v }
        if let v = iptc.bylineTitle { dict["IPTC:By-lineTitle"] = v }
        if let v = iptc.category { dict["IPTC:Category"] = v }
        if let v = iptc.editStatus { dict["IPTC:EditStatus"] = v }
        if let v = iptc.languageIdentifier { dict["IPTC:LanguageIdentifier"] = v }
        if let v = iptc.releaseDate { dict["IPTC:ReleaseDate"] = v }
        if let v = iptc.releaseTime { dict["IPTC:ReleaseTime"] = v }
        if let v = iptc.expirationDate { dict["IPTC:ExpirationDate"] = v }
        if let v = iptc.expirationTime { dict["IPTC:ExpirationTime"] = v }
        if let v = iptc.urgency { dict["IPTC:Urgency"] = v }

        let keywords = iptc.keywords
        if !keywords.isEmpty { dict["IPTC:Keywords"] = keywords }

        let bylines = iptc.bylines
        if bylines.count > 1 { dict["IPTC:By-line"] = bylines }

        let bylineTitles = iptc.bylineTitles
        if bylineTitles.count > 1 { dict["IPTC:By-lineTitle"] = bylineTitles }

        let categories = iptc.supplementalCategories
        if !categories.isEmpty { dict["IPTC:SupplementalCategories"] = categories }

        let contacts = iptc.contacts
        if !contacts.isEmpty { dict["IPTC:Contact"] = contacts }
    }

    // MARK: - XMP Fields

    private static func addXMPFields(_ dict: inout [String: Any], _ xmp: XMPData) {
        for key in xmp.allKeys.sorted() {
            guard let (prefix, localName) = resolveXMPKey(key) else { continue }
            let exportKey = "XMP-\(prefix):\(localName)"

            if let value = xmp.value(namespace: extractNamespace(from: key), property: localName) {
                switch value {
                case .simple(let s):
                    dict[exportKey] = s
                case .array(let items):
                    dict[exportKey] = items
                case .langAlternative(let s):
                    dict[exportKey] = s
                case .structure(let fields):
                    var nested: [String: String] = [:]
                    for (k, v) in fields {
                        if let (p, ln) = resolveXMPKey(k) { nested["\(p):\(ln)"] = v }
                        else { nested[k] = v }
                    }
                    dict[exportKey] = nested
                case .structuredArray(let items):
                    dict[exportKey] = items.map { item in
                        var nested: [String: String] = [:]
                        for (k, v) in item {
                            if let (p, ln) = resolveXMPKey(k) { nested["\(p):\(ln)"] = v }
                            else { nested[k] = v }
                        }
                        return nested
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private static func formatName(_ format: ImageFormat) -> String {
        switch format {
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .raw(let r): return r.rawValue.uppercased()
        case .jpegXL: return "JXL"
        case .png: return "PNG"
        case .avif: return "AVIF"
        case .heif: return "HEIF"
        case .webp: return "WebP"
        case .pdf: return "PDF"
        case .psd: return "PSD"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        case .svg: return "SVG"
        }
    }

    private static func resolveXMPKey(_ key: String) -> (prefix: String, localName: String)? {
        for (ns, prefix) in XMPNamespace.prefixes.sorted(by: { $0.key.count > $1.key.count }) {
            if key.hasPrefix(ns) {
                let localName = String(key.dropFirst(ns.count))
                guard !localName.isEmpty && !localName.contains("/") else { continue }
                return (prefix, localName)
            }
        }
        return nil
    }

    private static func extractNamespace(from key: String) -> String {
        for ns in XMPNamespace.prefixes.keys.sorted(by: { $0.count > $1.count }) {
            if key.hasPrefix(ns) { return ns }
        }
        return ""
    }

    private static func escapeXMLTag(_ name: String) -> String {
        // Replace characters invalid in XML element names
        name.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private static func escapeXMLValue(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
