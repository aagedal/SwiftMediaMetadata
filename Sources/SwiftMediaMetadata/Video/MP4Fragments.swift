import Foundation

/// Fragmented MP4/MOV support for MP4Parser: `moov > mvex` (`mehd`, `trex`)
/// and the top-level `moof > traf` boxes (`tfhd`, `trun`).
///
/// A fragmented movie's `moov` describes only the samples written before the
/// first fragment: none with ffmpeg's `empty_moov`, about one second with
/// `frag_keyframe` alone. Every later sample lives in a `moof`, so `mvhd`,
/// `mdhd`, `stsz` and `stts` all under-report the movie. ffprobe and
/// AVFoundation add the fragments to each track. A recording stopped
/// mid-stream (growing-file live recordings) has no `mehd`, so the totals
/// are summed from the `trun` sample tables.
extension MP4Parser {

    /// Samples carried by one track's movie fragments.
    struct FragmentTotals: Equatable, Sendable {
        var sampleCount: Int = 0
        /// In the track's media timescale.
        var duration: UInt64 = 0
        var bytes: UInt64 = 0
    }

    /// `trex` defaults for samples whose `tfhd` and `trun` leave them out.
    struct TrackExtendsDefaults: Equatable, Sendable {
        var sampleDuration: UInt32
        var sampleSize: UInt32
    }

    /// `moov > mvex`: `mehd`'s fragment_duration (movie timescale; nil when
    /// absent or zero) and the per-track `trex` defaults.
    static func parseMVEX(
        _ data: Data
    ) -> (fragmentDuration: UInt64?, trackDefaults: [UInt32: TrackExtendsDefaults]) {
        guard let children = try? ISOBMFFBoxReader.parseBoxes(from: data) else { return (nil, [:]) }
        var fragmentDuration: UInt64?
        var trackDefaults: [UInt32: TrackExtendsDefaults] = [:]
        for child in children {
            var reader = BinaryReader(data: child.data)
            switch child.type {
            case "mehd":
                // FullBox; version 1 widens fragment_duration to 64 bits.
                guard let version = try? reader.readUInt8(),
                      (try? reader.skip(3)) != nil else { continue }
                let value: UInt64? = version == 1
                    ? try? reader.readUInt64BigEndian()
                    : (try? reader.readUInt32BigEndian()).map(UInt64.init)
                if let value, value > 0 { fragmentDuration = value }
            case "trex":
                // version+flags(4) + track_ID(4) + default_sample_description_index(4)
                // + default_sample_duration(4) + default_sample_size(4) + default_sample_flags(4)
                guard (try? reader.skip(4)) != nil,
                      let trackID = try? reader.readUInt32BigEndian(),
                      (try? reader.skip(4)) != nil,
                      let duration = try? reader.readUInt32BigEndian(),
                      let size = try? reader.readUInt32BigEndian() else { continue }
                trackDefaults[trackID] = TrackExtendsDefaults(sampleDuration: duration, sampleSize: size)
            default:
                continue
            }
        }
        return (fragmentDuration, trackDefaults)
    }

    /// Per-track totals of every `moof > traf > trun` among the top-level boxes.
    static func fragmentTotals(
        in topLevelBoxes: [ISOBMFFBox],
        trackDefaults: [UInt32: TrackExtendsDefaults]
    ) -> [UInt32: FragmentTotals] {
        var totals: [UInt32: FragmentTotals] = [:]
        for moof in topLevelBoxes where moof.type == "moof" {
            guard let trafs = try? ISOBMFFBoxReader.parseBoxes(from: moof.data) else { continue }
            for traf in trafs where traf.type == "traf" {
                guard let children = try? ISOBMFFBoxReader.parseBoxes(from: traf.data),
                      let tfhd = children.first(where: { $0.type == "tfhd" }),
                      let header = parseTFHD(tfhd.data) else { continue }
                let defaults = trackDefaults[header.trackID]
                let defaultDuration = header.defaultSampleDuration ?? defaults?.sampleDuration ?? 0
                let defaultSize = header.defaultSampleSize ?? defaults?.sampleSize ?? 0
                var track = totals[header.trackID] ?? FragmentTotals()
                for trun in children where trun.type == "trun" {
                    addTRUN(trun.data, defaultDuration: defaultDuration, defaultSize: defaultSize, to: &track)
                }
                totals[header.trackID] = track
            }
        }
        return totals
    }

    /// tfhd: version+flags(4) + track_ID(4), then the optional fields its
    /// flags announce, in this order: base_data_offset(8, 0x01),
    /// sample_description_index(4, 0x02), default_sample_duration(4, 0x08),
    /// default_sample_size(4, 0x10), default_sample_flags(4, 0x20).
    private static func parseTFHD(
        _ data: Data
    ) -> (trackID: UInt32, defaultSampleDuration: UInt32?, defaultSampleSize: UInt32?)? {
        var reader = BinaryReader(data: data)
        guard let versionAndFlags = try? reader.readUInt32BigEndian(),
              let trackID = try? reader.readUInt32BigEndian() else { return nil }
        let flags = versionAndFlags & 0x00FF_FFFF
        do {
            if flags & 0x01 != 0 { try reader.skip(8) }
            if flags & 0x02 != 0 { try reader.skip(4) }
            let duration = flags & 0x08 != 0 ? try reader.readUInt32BigEndian() : nil
            let size = flags & 0x10 != 0 ? try reader.readUInt32BigEndian() : nil
            return (trackID, duration, size)
        } catch {
            return (trackID, nil, nil)
        }
    }

    /// trun: version+flags(4) + sample_count(4) + data_offset(4, 0x01)
    /// + first_sample_flags(4, 0x04), then one row per sample holding
    /// duration (0x100), size (0x200), flags (0x400) and composition
    /// offset (0x800) when flagged. Missing durations and sizes take the
    /// tfhd/trex defaults.
    private static func addTRUN(
        _ data: Data,
        defaultDuration: UInt32,
        defaultSize: UInt32,
        to totals: inout FragmentTotals
    ) {
        var reader = BinaryReader(data: data)
        guard let versionAndFlags = try? reader.readUInt32BigEndian(),
              let sampleCount = try? reader.readUInt32BigEndian() else { return }
        let flags = versionAndFlags & 0x00FF_FFFF
        let hasDuration = flags & 0x100 != 0
        let hasSize = flags & 0x200 != 0
        let rowSize = [0x100, 0x200, 0x400, 0x800].filter { flags & $0 != 0 }.count * 4
        do {
            if flags & 0x01 != 0 { try reader.skip(4) }
            if flags & 0x04 != 0 { try reader.skip(4) }
        } catch {
            return
        }
        // A sample_count larger than the table that follows is malformed.
        guard rowSize == 0 || Int(sampleCount) <= reader.remainingCount / rowSize else { return }

        // (2^32 - 1)^2 fits in UInt64, so the default products cannot overflow.
        var duration: UInt64 = hasDuration ? 0 : UInt64(sampleCount) * UInt64(defaultDuration)
        var bytes: UInt64 = hasSize ? 0 : UInt64(sampleCount) * UInt64(defaultSize)
        if rowSize > 0 {
            for _ in 0..<Int(sampleCount) {
                guard let row = try? reader.readBytes(rowSize) else { break }
                var rowReader = BinaryReader(data: row)
                if hasDuration, let value = try? rowReader.readUInt32BigEndian() {
                    duration &+= UInt64(value)
                }
                if hasSize, let value = try? rowReader.readUInt32BigEndian() {
                    bytes &+= UInt64(value)
                }
            }
        }
        totals.sampleCount &+= Int(sampleCount)
        totals.duration &+= duration
        totals.bytes &+= bytes
    }

    /// Sum of sample_count × sample_delta over every stts entry: the duration
    /// of the samples described in `moov`, in the track's timescale.
    static func parseSTTSTotalDuration(_ box: ISOBMFFBox) -> UInt64? {
        guard box.data.count >= 8 else { return nil }
        var reader = BinaryReader(data: box.data)
        _ = try? reader.readBytes(4)
        guard let entryCount = try? reader.readUInt32BigEndian() else { return nil }
        var total: UInt64 = 0
        for _ in 0..<min(entryCount, 1 << 20) {
            guard let count = try? reader.readUInt32BigEndian(),
                  let delta = try? reader.readUInt32BigEndian() else { break }
            total &+= UInt64(count) * UInt64(delta)
        }
        return total
    }
}
