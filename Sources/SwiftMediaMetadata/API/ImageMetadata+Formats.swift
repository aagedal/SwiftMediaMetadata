import Foundation

extension ImageMetadata {
    // MARK: - Format-Specific Writing

    func writeJPEG(_ file: inout JPEGFile, warnings: inout [String]) throws -> Data {
        // Write IPTC
        let existingAPP13 = file.iptcSegment()?.data
        let app13Data = try IPTCWriter.writeToAPP13(iptc, existingAPP13: existingAPP13, warnings: &warnings)
        file.replaceOrAddIPTCSegment(JPEGSegment(marker: .app13, data: app13Data))

        // Write Exif — size-capped to JPEG's per-segment ceiling. EXIF copied
        // from a RAW can carry oversized proprietary blobs (e.g. a Sony A1's
        // ~1.5 MB C2PA manifest in IFD0 tag 0xCD41) that overflow APP1; the
        // capped writer drops the largest droppable tags rather than letting a
        // single tag abort the whole metadata write. See ExifWriter.write(_:maxPayload:warnings:).
        if let exif = exif {
            let exifData = ExifWriter.write(exif, maxPayload: JPEGWriter.maxSegmentPayload, warnings: &warnings)
            file.replaceOrAddExifSegment(JPEGSegment(marker: .app1, data: exifData))
        }

        // Write XMP
        if let xmp = xmp {
            let xmpData = XMPWriter.write(xmp)
            file.replaceOrAddXMPSegment(JPEGSegment(marker: .app1, data: xmpData))
        } else {
            // Remove existing XMP segment if XMP was stripped
            file.segments.removeAll { $0.isXMP }
        }

        // Write ICC profile
        if let iccProfile = iccProfile {
            file.replaceOrAddICCProfileSegments(iccProfile.data)
        } else {
            // Remove existing ICC segments if profile was stripped
            file.segments.removeAll { $0.isICCProfile }
        }

        // Final safety net: a single oversized metadata segment must never abort
        // the whole write and drop all the *other* good metadata. Exif is already
        // size-capped above and ICC profiles are chunked, so the realistic
        // remaining offenders are an unusually large XMP packet (APP1) or IPTC
        // block (APP13). Drop the offending segment with a warning rather than
        // throwing. (Their proper oversize homes — ExtendedXMP / multi-segment
        // IPTC — are a separate, larger feature.)
        Self.dropOversizedMetadataSegments(&file, warnings: &warnings)

        return try JPEGWriter.write(file)
    }

    /// Drop any metadata APP segment whose payload exceeds JPEG's per-segment
    /// ceiling, recording a non-fatal warning. Only touches the metadata
    /// segments this writer authors (Exif/XMP/IPTC); anything else oversized
    /// still surfaces as `JPEGWriter.write`'s hard error.
    static func dropOversizedMetadataSegments(_ file: inout JPEGFile, warnings: inout [String]) {
        file.segments.removeAll { segment in
            guard segment.data.count > JPEGWriter.maxSegmentPayload else { return false }
            let kind: String
            if segment.isExif { kind = "Exif" }
            else if segment.isXMP { kind = "XMP" }
            else if segment.isPhotoshop { kind = "IPTC" }
            else { return false } // not ours to drop — let JPEGWriter flag it
            warnings.append(
                "Dropped oversized \(kind) segment: \(segment.data.count) bytes exceeds "
                + "JPEG's \(JPEGWriter.maxSegmentPayload)-byte per-segment limit."
            )
            return true
        }
    }

    func writePNG(_ file: inout PNGFile, warnings: inout [String]) -> Data {
        // Write Exif as eXIf chunk (raw TIFF, no prefix)
        if let exif = exif {
            let tiffData = ExifWriter.writeTIFF(exif, warnings: &warnings)
            file.replaceOrAddExifChunk(tiffData)
        }

        // Write XMP as iTXt chunk
        if let xmp = xmp {
            let xml = XMPWriter.generateXML(xmp)
            file.replaceOrAddXMPChunk(xml)
        } else {
            // Remove existing XMP chunk if XMP was stripped
            file.removeXMPChunk()
        }

        // Write ICC profile as iCCP chunk
        if let iccProfile = iccProfile {
            Self.writeICCPChunk(&file, profile: iccProfile)
        } else {
            file.removeChunk("iCCP")
        }

        return PNGWriter.write(file)
    }

    /// Build and write a PNG iCCP chunk from an ICC profile.
    static func writeICCPChunk(_ file: inout PNGFile, profile: ICCProfile) {
        let name = profile.profileDescription ?? "ICC Profile"
        var payload = Data(name.utf8)
        payload.append(0x00) // null terminator
        payload.append(0x00) // compression method: zlib deflate
        if let compressed = ZlibInflate.deflate(profile.data) {
            payload.append(compressed)
        } else {
            payload.append(profile.data)
        }
        file.replaceOrAddChunk("iCCP", data: payload)
    }

    func writeJXL(_ file: inout JXLFile, warnings: inout [String]) throws -> Data {
        // Write Exif box (4-byte offset prefix + TIFF data)
        if let exif = exif {
            var exifPayload = Data([0x00, 0x00, 0x00, 0x00]) // offset prefix
            exifPayload.append(ExifWriter.writeTIFF(exif, warnings: &warnings))
            file.replaceOrAddBox("Exif", data: exifPayload)
        }

        // Write XMP box (type "xml ")
        if let xmp = xmp {
            let xml = XMPWriter.generateXML(xmp)
            file.replaceOrAddBox("xml ", data: Data(xml.utf8))
        } else {
            // Remove existing XMP box if XMP was stripped
            file.removeBox("xml ")
        }

        return try JXLWriter.write(file)
    }

    func writeAVIF(_ file: AVIFFile) throws -> Data {
        return try AVIFWriter.write(file, exif: exif, xmp: xmp)
    }

    func writeHEIF(_ file: HEIFFile) throws -> Data {
        return try HEIFWriter.write(file, exif: exif, xmp: xmp)
    }

    func writeWebP(_ file: WebPFile) throws -> Data {
        return try WebPWriter.write(file, exif: exif, xmp: xmp, iccProfile: iccProfile)
    }

    func writeCR3(_ file: CR3File) throws -> Data {
        guard let originalData = file.originalData else {
            throw MetadataError.invalidCR3("Cannot write CR3 without original data")
        }
        return try CR3Writer.write(file, exif: exif, xmp: xmp, originalData: originalData)
    }

    func writeTIFFFile(_ file: TIFFFile, warnings: inout [String]) throws -> Data {
        return try TIFFWriter.write(file, exif: exif, iptc: iptc, xmp: xmp, iccProfile: iccProfile, warnings: &warnings)
    }

    // MARK: - Format-Specific Reading

    static func readJPEG(from data: Data) throws -> ImageMetadata {
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

        // ICC profile from APP2 segments
        var iccProfile: ICCProfile?
        let iccSegments = jpegFile.iccProfileSegments()
        if !iccSegments.isEmpty {
            // Sort by sequence number (byte 12 of data, after 12-byte identifier)
            let sorted = iccSegments.sorted { a, b in
                let seqA = a.data.count > 12 ? a.data[a.data.startIndex + 12] : 0
                let seqB = b.data.count > 12 ? b.data[b.data.startIndex + 12] : 0
                return seqA < seqB
            }
            var profileData = Data()
            for seg in sorted {
                guard seg.data.count > 14 else { continue }
                profileData.append(seg.data.suffix(from: seg.data.startIndex + 14))
            }
            iccProfile = ICCProfile(data: profileData)
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

        // MPF (CIPA DC-007) from an APP2 segment when the payload starts
        // with "MPF\0". Carries Live Photo aux frames, depth maps, etc.
        var mpf: MPFData?
        if let mpfSegment = jpegFile.mpfSegment() {
            mpf = MPFParser.parse(mpfSegment.data)
        }

        return ImageMetadata(container: .jpeg(jpegFile), format: .jpeg, iptc: iptc, exif: exif, xmp: xmp, c2pa: c2pa, iccProfile: iccProfile, mpf: mpf, warnings: warnings)
    }

    static func readTIFF(from data: Data, format: ImageFormat) throws -> ImageMetadata {
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

        // Extract ICC profile (tag 0x8773)
        let iccProfile = TIFFFileParser.extractICCProfile(from: tiffFile)

        // DNG private tags (only populated for DNG-marked files)
        let dng = DNGMetadataReader.read(from: tiffFile)

        // C2PA from IFD0 tag 0xCD41
        var c2pa: C2PAData?
        var warnings: [String] = []
        do {
            if let jumbfData = C2PAReader.extractJUMBFFromTIFF(tiffFile) {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            }
        } catch {
            warnings.append("C2PA parsing failed: \(error)")
        }

        return ImageMetadata(container: .tiff(tiffFile), format: format, iptc: iptc, exif: exif, xmp: xmp, c2pa: c2pa, iccProfile: iccProfile, dng: dng, warnings: warnings)
    }

    static func readRAW(from data: Data, format: ImageFormat) throws -> ImageMetadata {
        guard case .raw(let rawFormat) = format else {
            throw MetadataError.invalidRAW("Expected RAW format")
        }
        let tiffFile = try RAWFileParser.parse(data, format: rawFormat)

        var iptc = IPTCData()
        var exif: ExifData?
        var xmp: XMPData?

        exif = try TIFFFileParser.extractExif(from: tiffFile, data: tiffFile.rawData)
        iptc = try TIFFFileParser.extractIPTC(from: tiffFile)
        xmp = try TIFFFileParser.extractXMP(from: tiffFile)
        let iccProfile = TIFFFileParser.extractICCProfile(from: tiffFile)
        let dng = DNGMetadataReader.read(from: tiffFile)

        var c2pa: C2PAData?
        var warnings: [String] = []
        do {
            if let jumbfData = C2PAReader.extractJUMBFFromTIFF(tiffFile) {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            }
        } catch {
            warnings.append("C2PA parsing failed: \(error)")
        }

        return ImageMetadata(container: .tiff(tiffFile), format: format, iptc: iptc, exif: exif, xmp: xmp, c2pa: c2pa, iccProfile: iccProfile, dng: dng, warnings: warnings)
    }

    static func readJPEGXL(from data: Data) throws -> ImageMetadata {
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

    static func readPNG(from data: Data) throws -> ImageMetadata {
        let pngFile = try PNGParser.parse(data)

        var exif: ExifData?
        var xmp: XMPData?

        // eXIf chunk
        if let exifChunk = pngFile.findChunk("eXIf") {
            exif = try ExifReader.readFromTIFF(data: exifChunk.data)
        }

        // XMP in iTXt chunk with keyword "XML:com.adobe.xmp"
        xmp = try PNGParser.extractXMP(from: pngFile)

        // ICC profile from iCCP chunk
        var iccProfile: ICCProfile?
        if let iccpChunk = pngFile.findChunk("iCCP") {
            iccProfile = Self.parseICCPChunk(iccpChunk.data)
        }

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

        return ImageMetadata(container: .png(pngFile), format: .png, iptc: IPTCData(), exif: exif, xmp: xmp, c2pa: c2pa, iccProfile: iccProfile, warnings: warnings)
    }

    /// Parse a PNG iCCP chunk: profile name (null-terminated) + compression method (1 byte) + compressed data.
    static func parseICCPChunk(_ data: Data) -> ICCProfile? {
        let bytes = [UInt8](data)
        guard let nullIndex = bytes.firstIndex(of: 0), nullIndex + 2 < bytes.count else { return nil }
        // Skip profile name + null + compression method byte
        let compressedData = Data(bytes[(nullIndex + 2)...])
        guard let decompressed = ZlibInflate.inflate(compressedData) else { return nil }
        return ICCProfile(data: decompressed)
    }

    static func readAVIF(from data: Data) throws -> ImageMetadata {
        let avifFile = try AVIFParser.parse(data)

        let exif = try AVIFParser.extractExif(from: avifFile, fileData: data)
        let xmp = try AVIFParser.extractXMP(from: avifFile, fileData: data)

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

        let iccProfile = ISOBMFFMetadata.extractICCProfile(from: avifFile.boxes)
        let hdr = ISOBMFFMetadata.extractHDRMetadata(from: avifFile.boxes)

        return ImageMetadata(container: .avif(avifFile), format: .avif, iptc: IPTCData(), exif: exif, xmp: xmp, c2pa: c2pa, iccProfile: iccProfile, hdr: hdr, warnings: warnings)
    }

    static func readHEIF(from data: Data) throws -> ImageMetadata {
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

        let iccProfile = ISOBMFFMetadata.extractICCProfile(from: heifFile.boxes)
        let hdr = ISOBMFFMetadata.extractHDRMetadata(from: heifFile.boxes)

        return ImageMetadata(container: .heif(heifFile), format: .heif, iptc: IPTCData(), exif: exif, xmp: xmp, c2pa: c2pa, iccProfile: iccProfile, hdr: hdr, warnings: warnings)
    }

    static func readCR3(from data: Data) throws -> ImageMetadata {
        let (file, exif, xmp, iptc) = try CR3Parser.parse(data)
        return ImageMetadata(container: .cr3(file), format: .raw(.cr3), iptc: iptc, exif: exif, xmp: xmp)
    }

    static func readWebP(from data: Data) throws -> ImageMetadata {
        let webpFile = try WebPParser.parse(data)

        let exif = try WebPParser.extractExif(from: webpFile)
        let xmp = try WebPParser.extractXMP(from: webpFile)
        let iccProfile = WebPParser.extractICCProfile(from: webpFile)

        var c2pa: C2PAData?
        var warnings: [String] = []
        do {
            if let jumbfData = C2PAReader.extractJUMBFFromWebP(webpFile) {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            }
        } catch {
            warnings.append("C2PA parsing failed: \(error)")
        }

        return ImageMetadata(container: .webp(webpFile), format: .webp, iptc: IPTCData(), exif: exif, xmp: xmp, c2pa: c2pa, iccProfile: iccProfile, warnings: warnings)
    }

    // MARK: - PDF

    static func readPDF(from data: Data) throws -> ImageMetadata {
        let pdfFile = try PDFParser.parse(data)

        // Extract XMP from XMP stream if available
        var xmp: XMPData? = nil
        if let xmpStreamData = pdfFile.xmpStreamData {
            xmp = try? XMPReader.readFromXML(xmpStreamData)
        }

        var c2pa: C2PAData?
        var warnings: [String] = []
        do {
            if let jumbfData = C2PAReader.extractJUMBFFromPDF(pdfFile) {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            }
        } catch {
            warnings.append("C2PA parsing failed: \(error)")
        }

        return ImageMetadata(container: .pdf(pdfFile), format: .pdf, iptc: IPTCData(), xmp: xmp, c2pa: c2pa, warnings: warnings)
    }

    // MARK: - PSD

    static func readPSD(from data: Data) throws -> ImageMetadata {
        let psdFile = try PSDParser.parse(data)

        let exif = PSDParser.extractExif(from: psdFile)
        let xmp = try? PSDParser.extractXMP(from: psdFile)
        let iccProfile = PSDParser.extractICCProfile(from: psdFile)

        // Extract IPTC from IRB
        var iptc = IPTCData()
        if let iptcBlock = psdFile.irbBlocks.first(where: { $0.resourceID == PSDFile.iptcResourceID }) {
            iptc = (try? IPTCReader.read(from: iptcBlock.data)) ?? IPTCData()
        }

        return ImageMetadata(container: .psd(psdFile), format: .psd, iptc: iptc, exif: exif, xmp: xmp, iccProfile: iccProfile)
    }

    func writePSD(_ file: PSDFile) throws -> Data {
        try PSDWriter.write(file, iptc: iptc, exif: exif, xmp: xmp, iccProfile: iccProfile)
    }

    static func readGIF(from data: Data) throws -> ImageMetadata {
        let gifFile = try GIFParser.parse(data)
        let xmp = try? GIFParser.extractXMP(from: gifFile)

        var c2pa: C2PAData?
        var warnings: [String] = []
        do {
            if let jumbfData = C2PAReader.extractJUMBFFromGIF(gifFile) {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            }
        } catch {
            warnings.append("C2PA parsing failed: \(error)")
        }

        return ImageMetadata(container: .gif(gifFile), format: .gif, xmp: xmp, c2pa: c2pa, warnings: warnings)
    }

    func writeGIF(_ file: GIFFile) -> Data {
        GIFWriter.write(file, xmp: xmp)
    }

    static func readBMP(from data: Data) throws -> ImageMetadata {
        let bmpFile = try BMPParser.parse(data)
        return ImageMetadata(container: .bmp(bmpFile), format: .bmp)
    }

    func writeBMP(_ file: BMPFile) -> Data {
        // BMP is read-only for metadata — return raw data unchanged
        file.rawData
    }

    static func readSVG(from data: Data) throws -> ImageMetadata {
        let svgFile = try SVGParser.parse(data)
        let xmp = try? SVGParser.extractXMP(from: svgFile)
        return ImageMetadata(container: .svg(svgFile), format: .svg, xmp: xmp)
    }

    func writeSVG(_ file: SVGFile) -> Data {
        SVGWriter.write(file, xmp: xmp)
    }

    func writePDF(_ file: PDFFile) throws -> Data {
        // Build updated Info dict from the file's info dict
        var infoDict = file.infoDict

        // Sync XMP title/author to Info dict if available
        if let xmp {
            if let title = xmp.title { infoDict["Title"] = title }
            if let desc = xmp.description { infoDict["Subject"] = desc }
            if !xmp.creator.isEmpty { infoDict["Author"] = xmp.creator.joined(separator: ", ") }
        }

        let xmpData: Data? = xmp.map { Data(XMPWriter.generateXML($0).utf8) }

        return try PDFWriter.write(file, infoDict: infoDict, xmpData: xmpData)
    }
}
