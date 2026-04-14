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

        return dict
    }
}
