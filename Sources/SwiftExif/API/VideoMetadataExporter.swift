import Foundation

/// Export video metadata in machine-readable formats.
public struct VideoMetadataExporter: Sendable {

    /// Export video metadata as JSON Data.
    public static func toJSON(_ metadata: VideoMetadata) -> Data {
        let dict = buildDictionary(metadata)
        let data = try? JSONSerialization.data(withJSONObject: [dict], options: [.prettyPrinted, .sortedKeys])
        return data ?? Data("[]".utf8)
    }

    /// Export video metadata as a JSON string.
    public static func toJSONString(_ metadata: VideoMetadata) -> String {
        String(data: toJSON(metadata), encoding: .utf8) ?? "[]"
    }

    /// Build a flat dictionary of all video metadata fields.
    public static func buildDictionary(_ metadata: VideoMetadata) -> [String: Any] {
        var dict: [String: Any] = [:]

        dict["FileFormat"] = metadata.format.rawValue.uppercased()

        if let d = metadata.duration { dict["Duration"] = d }
        if let w = metadata.videoWidth { dict["VideoWidth"] = w }
        if let h = metadata.videoHeight { dict["VideoHeight"] = h }
        if let c = metadata.videoCodec { dict["VideoCodec"] = c }
        if let c = metadata.audioCodec { dict["AudioCodec"] = c }
        if let r = metadata.frameRate { dict["FrameRate"] = r }
        if let f = metadata.fieldOrder { dict["FieldOrder"] = f.rawValue }
        if let depth = metadata.bitDepth { dict["BitDepth"] = depth }
        if let chroma = metadata.chromaSubsampling { dict["ChromaSubsampling"] = chroma }
        if let par = metadata.pixelAspectRatio {
            dict["PixelAspectRatio"] = "\(par.0):\(par.1)"
        }
        if let dw = metadata.displayWidth { dict["DisplayWidth"] = dw }
        if let dh = metadata.displayHeight { dict["DisplayHeight"] = dh }
        if let sr = metadata.audioSampleRate { dict["AudioSampleRate"] = sr }
        if let ch = metadata.audioChannels { dict["AudioChannels"] = ch }
        if let layout = metadata.audioStreams.first?.channelLayout { dict["AudioChannelLayout"] = layout }
        if let audioBR = metadata.audioStreams.first?.bitRate { dict["AudioBitRate"] = audioBR }
        if let videoBR = metadata.videoStreams.first?.bitRate { dict["VideoBitRate"] = videoBR }
        if let br = metadata.bitRate { dict["BitRate"] = br }
        if let color = metadata.colorInfo {
            if let p = color.primaries { dict["ColorPrimaries"] = p }
            if let t = color.transfer { dict["TransferCharacteristics"] = t }
            if let m = color.matrix { dict["MatrixCoefficients"] = m }
            if let full = color.fullRange { dict["ColorRange"] = full ? "full" : "limited" }
            if let label = color.label { dict["ColorSpace"] = label }
        }
        if !metadata.videoStreams.isEmpty {
            dict["VideoStreamCount"] = metadata.videoStreams.count
        }
        if !metadata.audioStreams.isEmpty {
            dict["AudioStreamCount"] = metadata.audioStreams.count
        }
        if let t = metadata.title { dict["Title"] = t }
        if let a = metadata.artist { dict["Artist"] = a }
        if let c = metadata.comment { dict["Comment"] = c }
        if let lat = metadata.gpsLatitude { dict["GPSLatitude"] = lat }
        if let lon = metadata.gpsLongitude { dict["GPSLongitude"] = lon }
        if let alt = metadata.gpsAltitude { dict["GPSAltitude"] = alt }

        if let date = metadata.creationDate {
            dict["CreationDate"] = ISO8601DateFormatter().string(from: date)
        }
        if let date = metadata.modificationDate {
            dict["ModificationDate"] = ISO8601DateFormatter().string(from: date)
        }

        if let cam = metadata.camera {
            if let v = cam.deviceManufacturer    { dict["DeviceManufacturer"]    = v }
            if let v = cam.deviceModelName       { dict["DeviceModelName"]       = v }
            if let v = cam.deviceSerialNumber    { dict["DeviceSerialNumber"]    = v }
            if let v = cam.lensModelName         { dict["LensModelName"]         = v }
            if let v = cam.timeZone              { dict["TimeZone"]              = v }
            if let v = cam.captureGammaEquation  { dict["CaptureGammaEquation"]  = v }
            if let v = cam.recordingModeType     { dict["RecordingMode"]         = v }
            if let v = cam.captureFps            { dict["CaptureFps"]            = v }
            if !cam.userMetaNames.isEmpty {
                dict["UserDescriptiveMetadataMetaName"]    = cam.userMetaNames
                dict["UserDescriptiveMetadataMetaContent"] = cam.userMetaContents
            }
            if let date = cam.creationDate {
                dict["CreationDateValue"] = ISO8601DateFormatter().string(from: date)
            }
        }

        if let c2pa = metadata.c2pa {
            dict["HasContentCredentials"] = true
            if let manifest = c2pa.activeManifest {
                dict["HasSignature"] = true
                dict["ManifestLabel"] = manifest.label
                dict["ClaimGenerator"] = manifest.claim.claimGenerator
                if let info = manifest.claim.claimGeneratorInfo {
                    dict["ClaimGeneratorInfoName"] = info.name
                    if let v = info.version { dict["ClaimGeneratorInfoVersion"] = v }
                }
                if let title = manifest.claim.title { dict["ClaimTitle"] = title }
                if let fmt = manifest.claim.format { dict["ClaimFormat"] = fmt }
                if let alg = manifest.signature.algorithm {
                    dict["SignatureAlgorithm"] = String(describing: alg)
                }
                if !manifest.signature.certificateChain.isEmpty {
                    dict["SignatureCertificateCount"] = manifest.signature.certificateChain.count
                }
                dict["Assertions"] = manifest.assertions.map(\.label)

                // First c2pa.actions assertion is what the Media Converter app uses
                // to populate actionsAction / actionsDigitalSourceType.
                if let actionsAssertion = manifest.assertions.first(where: { $0.label.hasPrefix("c2pa.actions") }),
                   case .actions(let actions) = actionsAssertion.content,
                   let firstAction = actions.actions.first {
                    dict["ActionsAction"] = firstAction.action
                    if let digital = firstAction.digitalSourceType {
                        dict["ActionsDigitalSourceType"] = digital
                    }
                    if let agent = firstAction.softwareAgent {
                        dict["ActionsSoftwareAgent"] = agent
                    }
                }
            }
        }

        return dict
    }
}
