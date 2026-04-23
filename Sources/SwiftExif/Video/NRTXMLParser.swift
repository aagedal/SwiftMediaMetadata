import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parser for Sony NonRealTimeMeta (NRT / RDD-18) XML.
///
/// Produced by Sony XDCAM/XAVC cameras and PXW/FX-series camcorders. The XML
/// is either embedded in an MXF metadata track or written as a sidecar file
/// next to the clip (`CLIP.MXF` → `CLIP.XML`, `CLIP.MP4` → `CLIP.XML` / `CLIP.M01`).
///
/// Shape (simplified):
///
/// ```xml
/// <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:…">
///   <Device manufacturer="Sony" modelName="PXW-FX9" serialNo="12345"/>
///   <LensUnitMetadata>
///     <LensModelName>Sony FE 24-70mm F2.8 GM</LensModelName>
///   </LensUnitMetadata>
///   <CreationDate value="2024-01-15T10:30:00+02:00"/>
///   <TimeZone>+02:00</TimeZone>
///   <RecordingMode type="normal"/>
///   <VideoFormat>
///     <VideoFrame captureFps="24p" formatFps="24p"/>
///   </VideoFormat>
///   <AcquisitionRecord>
///     <Group name="CameraUnitMetadataSet">
///       <Item name="CaptureGammaEquation" value="rec709"/>
///     </Group>
///   </AcquisitionRecord>
///   <UserDescriptiveMetadata>
///     <Meta name="Creator" content="Jane Doe"/>
///   </UserDescriptiveMetadata>
/// </NonRealTimeMeta>
/// ```
public struct NRTXMLParser: Sendable {

    /// Parse Sony NRT XML from a file URL.
    public static func parse(from url: URL) throws -> CameraMetadata {
        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    /// Parse Sony NRT XML from data. Throws `invalidVideo` if the XML
    /// cannot be parsed at all.
    public static func parse(_ data: Data) throws -> CameraMetadata {
        let delegate = NRTDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw MetadataError.invalidVideo(
                "NonRealTimeMeta XML parse error: \(delegate.parseError ?? "unknown")"
            )
        }
        return delegate.build()
    }

    // MARK: - Sidecar discovery

    /// Candidate sidecar XML URLs for a given video clip URL.
    ///
    /// Handles both common Sony layouts:
    /// - XDCAM optical / MXF: `CLIP.MXF` → `CLIP.XML`
    /// - XAVC / NXCAM cards:  `CLIP.MP4` → `CLIPM01.XML`
    ///
    /// Plus lowercase variants and the occasional `.NFO` used by older
    /// NXCAM firmware.
    public static func sidecarCandidates(for videoURL: URL) -> [URL] {
        let dir = videoURL.deletingLastPathComponent()
        let baseName = videoURL.deletingPathExtension().lastPathComponent

        // Order matters — the `M01` layout is by far the most common on
        // modern Sony cameras (FX3/FX6/A7S/FS5/FX9), so probe it first.
        let candidateNames: [String] = [
            "\(baseName)M01.XML",
            "\(baseName)M01.xml",
            "\(baseName)m01.XML",
            "\(baseName)m01.xml",
            "\(baseName).XML",
            "\(baseName).xml",
            "\(baseName).M01",
            "\(baseName).m01",
            "\(baseName).NFO",
            "\(baseName).nfo",
        ]
        return candidateNames.map { dir.appendingPathComponent($0) }
    }

    /// Return the first existing sidecar URL, or nil if none is present.
    public static func sidecarURL(for videoURL: URL) -> URL? {
        let fm = FileManager.default
        for candidate in sidecarCandidates(for: videoURL) {
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - XMLParser delegate

private final class NRTDelegate: NSObject, XMLParserDelegate {

    var parseError: String?

    // Flat fields
    private var deviceManufacturer: String?
    private var deviceModelName: String?
    private var deviceSerialNumber: String?
    private var lensModelName: String?
    private var timeZone: String?
    private var captureGammaEquation: String?
    private var recordingModeType: String?
    private var captureFps: Double?
    private var startTimecode: String?
    private var userMetaNames: [String] = []
    private var userMetaContents: [String] = []
    private var creationDate: Date?

    // Per-element text accumulator
    private var currentText = ""
    private var inLensUnit = false

    func build() -> CameraMetadata {
        CameraMetadata(
            deviceManufacturer: deviceManufacturer,
            deviceModelName: deviceModelName,
            deviceSerialNumber: deviceSerialNumber,
            lensModelName: lensModelName,
            timeZone: timeZone,
            captureGammaEquation: captureGammaEquation,
            recordingModeType: recordingModeType,
            captureFps: captureFps,
            startTimecode: startTimecode,
            userMetaNames: userMetaNames,
            userMetaContents: userMetaContents,
            creationDate: creationDate
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentText = ""
        let local = localName(elementName)

        switch local {
        case "Device":
            deviceManufacturer = deviceManufacturer ?? attributeDict["manufacturer"]
            deviceModelName = deviceModelName ?? attributeDict["modelName"]
            deviceSerialNumber = deviceSerialNumber ?? attributeDict["serialNo"]

        case "LensUnitMetadata":
            inLensUnit = true

        case "Lens":
            // Shorter attribute form used by Alpha-series NRT XML:
            //   <Lens modelName="FE 16-35mm F4 ZA OSS"/>
            // This lives outside <LensUnitMetadata>, so it's handled here
            // rather than in didEndElement.
            if lensModelName == nil, let v = attributeDict["modelName"], !v.isEmpty {
                lensModelName = v
            }

        case "RecordingMode":
            if let t = attributeDict["type"] { recordingModeType = t }

        case "VideoFrame":
            if let fps = attributeDict["captureFps"] {
                captureFps = parseFps(fps)
            }

        case "Item":
            // <Item name="CaptureGammaEquation" value="rec709"/>
            if let name = attributeDict["name"], let value = attributeDict["value"] {
                if name == "CaptureGammaEquation" {
                    captureGammaEquation = value
                }
            }

        case "CreationDate":
            if let v = attributeDict["value"], let d = parseISO8601(v) {
                creationDate = d
            }

        case "LtcChange":
            // RDD-18 `<LtcChangeTable>` carries `<LtcChange frameCount="N"
            // value="HH:MM:SS:FF" status="…"/>` entries. The first entry
            // (frameCount="0") is the clip start timecode. Later entries
            // only exist when the camera's LTC reel changed mid-clip, which
            // Sony tags with status="increment"/"reset" — we ignore those
            // and keep the first reading as the start TC.
            if startTimecode == nil,
               let frameCount = attributeDict["frameCount"],
               frameCount == "0",
               let v = attributeDict["value"], !v.isEmpty {
                startTimecode = formatLtcValue(v)
            }

        case "Meta":
            // <Meta name="Creator" content="Jane Doe"/>
            if let name = attributeDict["name"] { userMetaNames.append(name) }
            if let content = attributeDict["content"] { userMetaContents.append(content) }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch local {
        case "LensModelName":
            if inLensUnit, !text.isEmpty { lensModelName = text }

        case "LensUnitMetadata":
            inLensUnit = false

        case "TimeZone":
            if !text.isEmpty { timeZone = text }

        case "CreationDate":
            // Some writers use element text instead of value="" attr.
            if creationDate == nil, !text.isEmpty, let d = parseISO8601(text) {
                creationDate = d
            }

        default:
            break
        }

        currentText = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError.localizedDescription
    }

    // MARK: - Helpers

    private func localName(_ name: String) -> String {
        if let colon = name.firstIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }

    private func parseFps(_ value: String) -> Double? {
        // Strip trailing 'p' / 'i' ("24p", "59.94i") and accept "30000/1001".
        var s = value
        if s.hasSuffix("p") || s.hasSuffix("P") || s.hasSuffix("i") || s.hasSuffix("I") {
            s = String(s.dropLast())
        }
        if s.contains("/") {
            let parts = s.split(separator: "/")
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 {
                return a / b
            }
        }
        return Double(s)
    }

    /// Decode a Sony NRT `LtcChange value="…"` attribute into
    /// `HH:MM:SS:FF` form. Sony RDD-18 files carry two different encodings
    /// in the wild:
    ///   1. an 8 hex-digit SMPTE 12M LTC word (byte0=frames+flags,
    ///      byte1=seconds, byte2=minutes, byte3=hours, all BCD) — what
    ///      XDCAM / XAVC professional cameras write;
    ///   2. the already-formatted "HH:MM:SS:FF" / "HH:MM:SS;FF" string —
    ///      what a few Alpha-series consumer bodies write.
    /// Returns nil when the string matches neither shape.
    private func formatLtcValue(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.contains(":") || v.contains(";") { return v }

        var hex = v
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard hex.count == 8, let word = UInt32(hex, radix: 16) else { return nil }

        let byte0 = UInt8((word >> 24) & 0xFF) // FF + drop-frame/color-frame flags
        let byte1 = UInt8((word >> 16) & 0xFF) // SS + phase bit
        let byte2 = UInt8((word >>  8) & 0xFF) // MM + binary-group flag
        let byte3 = UInt8( word        & 0xFF) // HH + binary-group flag

        let ff = Int(byte0 & 0x0F) + 10 * Int((byte0 >> 4) & 0x3)
        let ss = Int(byte1 & 0x0F) + 10 * Int((byte1 >> 4) & 0x7)
        let mm = Int(byte2 & 0x0F) + 10 * Int((byte2 >> 4) & 0x7)
        let hh = Int(byte3 & 0x0F) + 10 * Int((byte3 >> 4) & 0x3)
        let dropFrame = (byte0 & 0x40) != 0
        let sep = dropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, sep, ff)
    }

    private func parseISO8601(_ value: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        if let d = fmt.date(from: value) { return d }
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: value)
    }
}
