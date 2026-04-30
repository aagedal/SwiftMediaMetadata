import Foundation

/// Bitstream helpers and codec-specific parsers used by `MPEGReader`.
///
/// MPEG-TS streams carry codec parameters (resolution, frame rate, sample
/// rate) inside the elementary stream itself — there's no container-level
/// `tkhd` or descriptor to lift them from. Reaching feature parity with
/// ffprobe requires decoding the H.264/H.265 SPS, AAC ADTS, AC-3 sync
/// frames and AAC LATM `AudioSpecificConfig` directly.
///
/// Helpers live in their own file to keep `MPEGReader.swift` focused on
/// the container walk; nothing outside MPEGReader uses them today (the
/// MP4 parser stays byte-level), so they're file-internal.
enum MPEGBitstream {

    // MARK: - Bit reader

    /// Big-endian bit reader over a `Data` slice. Bits are consumed
    /// MSB-first within each byte, matching every bitstream syntax used
    /// here (H.264 / H.265 / AAC / AC-3).
    struct BitReader {
        let data: Data
        private(set) var bitOffset: Int = 0

        init(_ data: Data) { self.data = data }

        var bitsRemaining: Int { data.count * 8 - bitOffset }

        /// Read up to 64 bits as an unsigned integer. Reading past the
        /// end clamps and returns 0 — callers check `bitsRemaining` when
        /// they need to bail cleanly.
        mutating func read(_ n: Int) -> UInt64 {
            guard n > 0, n <= 64 else { return 0 }
            var value: UInt64 = 0
            var remaining = n
            while remaining > 0 {
                let byteIndex = data.startIndex + (bitOffset >> 3)
                if byteIndex >= data.endIndex {
                    bitOffset += remaining
                    return value << remaining
                }
                let bitInByte = bitOffset & 7
                let available = 8 - bitInByte
                let take = min(remaining, available)
                let byte = data[byteIndex]
                let shift = available - take
                let mask: UInt8 = (take == 8) ? 0xFF : UInt8((1 << take) - 1)
                let bits = (byte >> shift) & mask
                value = (value << take) | UInt64(bits)
                bitOffset += take
                remaining -= take
            }
            return value
        }

        mutating func readBool() -> Bool { read(1) == 1 }

        /// Skip `n` bits.
        mutating func skip(_ n: Int) { bitOffset += n }

        /// Unsigned Exp-Golomb (H.264/H.265 `ue(v)`). Returns 0 when the
        /// bitstream is truncated.
        mutating func readUE() -> UInt32 {
            var leadingZeros = 0
            while bitsRemaining > 0, read(1) == 0, leadingZeros < 32 {
                leadingZeros += 1
            }
            if leadingZeros == 0 { return 0 }
            let suffix = read(leadingZeros)
            return UInt32(truncatingIfNeeded: ((1 << leadingZeros) - 1) + Int(suffix))
        }

        /// Signed Exp-Golomb (H.264/H.265 `se(v)`).
        mutating func readSE() -> Int32 {
            let ue = readUE()
            if ue == 0 { return 0 }
            let sign: Int32 = (ue & 1) == 1 ? 1 : -1
            return sign * Int32((ue + 1) >> 1)
        }
    }

    // MARK: - NAL extraction

    /// Walk `data` looking for Annex-B start codes (`00 00 01` or
    /// `00 00 00 01`) and return the byte ranges of each NAL unit's
    /// RBSP payload. Each returned `Range` excludes the start code so
    /// callers can read the NAL header byte directly at `range.lowerBound`.
    static func annexBNALRanges(_ data: Data) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let count = data.count
        guard count >= 4 else { return ranges }
        var i = 0
        var unitStart: Int? = nil
        while i + 2 < count {
            // Detect 00 00 01 or 00 00 00 01.
            if data[data.startIndex + i] == 0 && data[data.startIndex + i + 1] == 0 {
                let startLen: Int
                if i + 3 < count, data[data.startIndex + i + 2] == 0,
                   data[data.startIndex + i + 3] == 1 {
                    startLen = 4
                } else if data[data.startIndex + i + 2] == 1 {
                    startLen = 3
                } else {
                    i += 1
                    continue
                }
                if let prev = unitStart {
                    ranges.append(prev..<i)
                }
                unitStart = i + startLen
                i += startLen
                continue
            }
            i += 1
        }
        if let prev = unitStart, prev < count {
            ranges.append(prev..<count)
        }
        return ranges
    }

    /// Strip H.264/H.265 emulation-prevention bytes (`00 00 03` → `00 00`).
    /// Returns a fresh `Data` because callers feed it to a `BitReader` that
    /// expects contiguous storage.
    static func stripEmulationPrevention(_ src: Data) -> Data {
        var out = Data()
        out.reserveCapacity(src.count)
        var i = 0
        let n = src.count
        while i < n {
            if i + 2 < n,
               src[src.startIndex + i] == 0,
               src[src.startIndex + i + 1] == 0,
               src[src.startIndex + i + 2] == 3 {
                out.append(0)
                out.append(0)
                i += 3
                continue
            }
            out.append(src[src.startIndex + i])
            i += 1
        }
        return out
    }

    // MARK: - H.264 SPS

    struct H264SPSFields {
        var profile: String?
        var level: String?
        var width: Int?
        var height: Int?
        var chromaSubsampling: String?
        var bitDepth: Int?
        var sampleAspect: (Int, Int)?
        var displayAspect: (Int, Int)?
        var frameRate: Double?
        var color: VideoColorInfo?
        var chromaLocation: String?
        var fieldOrder: VideoFieldOrder?
    }

    /// Decode the subset of an H.264 SPS RBSP needed for ffprobe-parity
    /// metadata. `rbsp` must already have emulation-prevention bytes
    /// stripped and start at the byte after the 1-byte NAL header.
    static func parseH264SPS(_ rbsp: Data) -> H264SPSFields? {
        guard rbsp.count >= 4 else { return nil }
        var f = H264SPSFields()

        let profileIDC = Int(rbsp[rbsp.startIndex])
        let constraintFlags = rbsp[rbsp.startIndex + 1]
        let levelIDC = Int(rbsp[rbsp.startIndex + 2])
        f.profile = h264ProfileName(profileIDC: profileIDC, constraintFlags: constraintFlags)
        f.level = h264LevelName(levelIDC: levelIDC)

        var br = BitReader(rbsp.subdata(in: (rbsp.startIndex + 3)..<rbsp.endIndex))
        _ = br.readUE() // seq_parameter_set_id

        var chromaFormatIDC: UInt32 = 1
        var bitDepthLuma: UInt32 = 8
        let highFamily: Set<Int> = [44, 83, 86, 100, 110, 118, 122, 128, 134, 135, 138, 139, 244]
        if highFamily.contains(profileIDC) {
            chromaFormatIDC = br.readUE()
            if chromaFormatIDC == 3 { _ = br.readBool() } // separate_colour_plane_flag
            bitDepthLuma = br.readUE() + 8
            _ = br.readUE() + 8  // bit_depth_chroma_minus8
            _ = br.readBool()    // qpprime_y_zero_transform_bypass_flag
            let seqScalingPresent = br.readBool()
            if seqScalingPresent {
                let scalingListCount = chromaFormatIDC == 3 ? 12 : 8
                for i in 0..<scalingListCount {
                    if br.readBool() {
                        skipH264ScalingList(&br, size: i < 6 ? 16 : 64)
                    }
                }
            }
        }
        f.chromaSubsampling = h264ChromaName(chromaFormatIDC: chromaFormatIDC)
        f.bitDepth = Int(bitDepthLuma)

        _ = br.readUE() // log2_max_frame_num_minus4
        let picOrderCntType = br.readUE()
        if picOrderCntType == 0 {
            _ = br.readUE() // log2_max_pic_order_cnt_lsb_minus4
        } else if picOrderCntType == 1 {
            _ = br.readBool() // delta_pic_order_always_zero_flag
            _ = br.readSE()   // offset_for_non_ref_pic
            _ = br.readSE()   // offset_for_top_to_bottom_field
            let numRef = br.readUE()
            for _ in 0..<min(numRef, 256) { _ = br.readSE() }
        }
        _ = br.readUE() // num_ref_frames
        _ = br.readBool() // gaps_in_frame_num_value_allowed_flag

        let picWidthInMBs = br.readUE() + 1
        let picHeightInMapUnits = br.readUE() + 1
        let frameMBsOnly = br.readBool()
        if !frameMBsOnly { _ = br.readBool() } // mb_adaptive_frame_field_flag
        _ = br.readBool() // direct_8x8_inference_flag

        var width = Int(picWidthInMBs) * 16
        var height = Int(picHeightInMapUnits) * 16 * (frameMBsOnly ? 1 : 2)

        let frameCroppingFlag = br.readBool()
        if frameCroppingFlag {
            let cropL = br.readUE()
            let cropR = br.readUE()
            let cropT = br.readUE()
            let cropB = br.readUE()
            let (subW, subH) = h264ChromaSubFactors(chromaFormatIDC: chromaFormatIDC)
            let cropUnitX = subW
            let cropUnitY = subH * (frameMBsOnly ? 1 : 2)
            width -= Int(cropL + cropR) * cropUnitX
            height -= Int(cropT + cropB) * cropUnitY
        }
        f.width = max(0, width)
        f.height = max(0, height)
        f.fieldOrder = frameMBsOnly ? .progressive : nil

        let vuiPresent = br.readBool()
        if vuiPresent {
            // aspect_ratio_info_present_flag
            if br.readBool() {
                let idc = br.read(8)
                if idc == 255 {
                    let sarW = Int(br.read(16))
                    let sarH = Int(br.read(16))
                    if sarW > 0, sarH > 0 { f.sampleAspect = (sarW, sarH) }
                } else if let sar = h264SARTable(idc: Int(idc)) {
                    f.sampleAspect = sar
                }
            }
            if let sar = f.sampleAspect, let w = f.width, let h = f.height,
               sar.0 > 0, sar.1 > 0, w > 0, h > 0 {
                let dispW = w * sar.0
                let dispH = h * sar.1
                let g = gcd(dispW, dispH)
                if g > 0 { f.displayAspect = (dispW / g, dispH / g) }
            }
            // overscan_info_present_flag
            if br.readBool() { _ = br.readBool() }
            // video_signal_type_present_flag
            if br.readBool() {
                _ = br.read(3) // video_format
                let fullRange = br.readBool()
                var color = VideoColorInfo()
                color.fullRange = fullRange
                if br.readBool() { // colour_description_present_flag
                    color.primaries = Int(br.read(8))
                    color.transfer = Int(br.read(8))
                    color.matrix = Int(br.read(8))
                }
                if !color.isEmpty { f.color = color }
            }
            // chroma_loc_info_present_flag
            if br.readBool() {
                let topField = br.readUE()
                _ = br.readUE() // bottom_field
                f.chromaLocation = h264ChromaLocationName(Int(topField))
            }
            // timing_info_present_flag
            if br.readBool() {
                let numUnitsInTick = br.read(32)
                let timeScale = br.read(32)
                let fixed = br.readBool()
                _ = fixed
                if numUnitsInTick > 0, timeScale > 0 {
                    f.frameRate = Double(timeScale) / (2.0 * Double(numUnitsInTick))
                }
            }
        }
        return f
    }

    private static func skipH264ScalingList(_ br: inout BitReader, size: Int) {
        var lastScale = 8
        var nextScale = 8
        for _ in 0..<size {
            if nextScale != 0 {
                let delta = br.readSE()
                nextScale = (lastScale + Int(delta) + 256) % 256
            }
            lastScale = nextScale == 0 ? lastScale : nextScale
        }
    }

    private static func h264ProfileName(profileIDC: Int, constraintFlags: UInt8) -> String? {
        let cs1 = (constraintFlags & 0x40) != 0
        let cs3 = (constraintFlags & 0x10) != 0
        switch profileIDC {
        case 44:  return "CAVLC 4:4:4 Intra"
        case 66:  return cs1 ? "Constrained Baseline" : "Baseline"
        case 77:  return "Main"
        case 83:  return "Scalable Baseline"
        case 86:  return "Scalable High"
        case 88:  return "Extended"
        case 100: return cs3 ? "High Progressive" : "High"
        case 110: return cs3 ? "High 10 Intra" : "High 10"
        case 118: return "Multiview High"
        case 122: return cs3 ? "High 4:2:2 Intra" : "High 4:2:2"
        case 128: return "Stereo High"
        case 134: return "MFC High"
        case 135: return "MFC Depth High"
        case 138, 139: return "Multiview Depth High"
        case 244: return cs3 ? "High 4:4:4 Intra" : "High 4:4:4 Predictive"
        default:  return nil
        }
    }

    private static func h264LevelName(levelIDC: Int) -> String? {
        switch levelIDC {
        case 9: return "1b"
        case 10, 11, 12, 13:
            return "1.\(levelIDC - 10)"
        case 20, 21, 22:
            return "2.\(levelIDC - 20)"
        case 30, 31, 32:
            return "3.\(levelIDC - 30)"
        case 40, 41, 42:
            return "4.\(levelIDC - 40)"
        case 50, 51, 52:
            return "5.\(levelIDC - 50)"
        case 60, 61, 62:
            return "6.\(levelIDC - 60)"
        default:
            return nil
        }
    }

    private static func h264ChromaName(chromaFormatIDC: UInt32) -> String? {
        switch chromaFormatIDC {
        case 0: return "monochrome"
        case 1: return "4:2:0"
        case 2: return "4:2:2"
        case 3: return "4:4:4"
        default: return nil
        }
    }

    private static func h264ChromaSubFactors(chromaFormatIDC: UInt32) -> (Int, Int) {
        switch chromaFormatIDC {
        case 1: return (2, 2) // 4:2:0
        case 2: return (2, 1) // 4:2:2
        case 3: return (1, 1) // 4:4:4
        default: return (1, 1)
        }
    }

    /// H.264 Annex E.2.1 (Table E-1): `aspect_ratio_idc` to (sar_width, sar_height).
    private static func h264SARTable(idc: Int) -> (Int, Int)? {
        switch idc {
        case 1:  return (1, 1)
        case 2:  return (12, 11)
        case 3:  return (10, 11)
        case 4:  return (16, 11)
        case 5:  return (40, 33)
        case 6:  return (24, 11)
        case 7:  return (20, 11)
        case 8:  return (32, 11)
        case 9:  return (80, 33)
        case 10: return (18, 11)
        case 11: return (15, 11)
        case 12: return (64, 33)
        case 13: return (160, 99)
        case 14: return (4, 3)
        case 15: return (3, 2)
        case 16: return (2, 1)
        default: return nil
        }
    }

    private static func h264ChromaLocationName(_ topField: Int) -> String? {
        switch topField {
        case 0: return "left"
        case 1: return "center"
        case 2: return "topleft"
        case 3: return "top"
        case 4: return "bottomleft"
        case 5: return "bottom"
        default: return nil
        }
    }

    // MARK: - HEVC SPS

    struct HEVCSPSFields {
        var profile: String?
        var level: String?
        var width: Int?
        var height: Int?
        var chromaSubsampling: String?
        var bitDepth: Int?
        var color: VideoColorInfo?
        var chromaLocation: String?
        var sampleAspect: (Int, Int)?
        var displayAspect: (Int, Int)?
        var frameRate: Double?
    }

    /// Decode an HEVC SPS NAL (NAL type 33). `rbsp` must have
    /// emulation-prevention bytes stripped and start at the byte after
    /// the 2-byte NAL header.
    static func parseHEVCSPS(_ rbsp: Data) -> HEVCSPSFields? {
        guard rbsp.count >= 4 else { return nil }
        var f = HEVCSPSFields()
        var br = BitReader(rbsp)
        _ = br.read(4)                                  // sps_video_parameter_set_id
        let maxSubLayersMinus1 = Int(br.read(3))
        _ = br.readBool()                               // sps_temporal_id_nesting_flag

        // profile_tier_level(maxSubLayersMinus1)
        if let ptl = parseHEVCProfileTierLevel(&br, maxSubLayersMinus1: maxSubLayersMinus1) {
            f.profile = ptl.profile
            f.level = ptl.level
        }

        _ = br.readUE() // sps_seq_parameter_set_id
        let chromaFormatIDC = br.readUE()
        if chromaFormatIDC == 3 { _ = br.readBool() } // separate_colour_plane_flag
        f.chromaSubsampling = h264ChromaName(chromaFormatIDC: chromaFormatIDC)
        let picWidth = br.readUE()
        let picHeight = br.readUE()
        var width = Int(picWidth)
        var height = Int(picHeight)
        if br.readBool() { // conformance_window_flag
            let cropL = br.readUE()
            let cropR = br.readUE()
            let cropT = br.readUE()
            let cropB = br.readUE()
            let (subW, subH) = h264ChromaSubFactors(chromaFormatIDC: chromaFormatIDC)
            width -= Int(cropL + cropR) * subW
            height -= Int(cropT + cropB) * subH
        }
        f.width = max(0, width)
        f.height = max(0, height)

        let bitDepthLuma = br.readUE() + 8
        _ = br.readUE() + 8 // bit_depth_chroma
        f.bitDepth = Int(bitDepthLuma)

        _ = br.readUE() // log2_max_pic_order_cnt_lsb_minus4

        let subLayerOrderingPresent = br.readBool()
        let firstLayer = subLayerOrderingPresent ? 0 : maxSubLayersMinus1
        for _ in firstLayer...maxSubLayersMinus1 {
            _ = br.readUE() // sps_max_dec_pic_buffering_minus1
            _ = br.readUE() // sps_max_num_reorder_pics
            _ = br.readUE() // sps_max_latency_increase_plus1
        }

        _ = br.readUE() // log2_min_luma_coding_block_size_minus3
        _ = br.readUE() // log2_diff_max_min_luma_coding_block_size
        _ = br.readUE() // log2_min_luma_transform_block_size_minus2
        _ = br.readUE() // log2_diff_max_min_luma_transform_block_size
        _ = br.readUE() // max_transform_hierarchy_depth_inter
        _ = br.readUE() // max_transform_hierarchy_depth_intra

        if br.readBool() { // scaling_list_enabled_flag
            if br.readBool() { // sps_scaling_list_data_present_flag
                skipHEVCScalingListData(&br)
            }
        }
        _ = br.readBool() // amp_enabled_flag
        _ = br.readBool() // sample_adaptive_offset_enabled_flag

        if br.readBool() { // pcm_enabled_flag
            _ = br.read(4) // pcm_sample_bit_depth_luma
            _ = br.read(4) // pcm_sample_bit_depth_chroma
            _ = br.readUE() // log2_min_pcm_luma_coding_block_size_minus3
            _ = br.readUE() // log2_diff_max_min_pcm_luma_coding_block_size
            _ = br.readBool() // pcm_loop_filter_disabled_flag
        }

        let numShortTermRefPicSets = br.readUE()
        for i in 0..<min(numShortTermRefPicSets, 64) {
            // Approximate skip: short_term_ref_pic_set syntax is recursive
            // and uses ue(v)s and flags. A full skip is overkill — we only
            // need VUI for SAR + frame rate, which sits well after this
            // block. Bail out if we run out of bitstream.
            if i > 0, br.readBool() { // inter_ref_pic_set_prediction_flag
                if i == numShortTermRefPicSets - 1 { _ = br.readUE() } // delta_idx_minus1
                _ = br.readBool() // delta_rps_sign
                _ = br.readUE()   // abs_delta_rps_minus1
                // Skipping the use_delta_flag loop is unsafe — bail out.
                return f
            }
            let numNeg = br.readUE()
            let numPos = br.readUE()
            for _ in 0..<min(Int(numNeg + numPos), 64) {
                _ = br.readUE() // delta_poc_s0_minus1 / s1_minus1
                _ = br.readBool() // used_by_curr_pic_flag
            }
        }
        if br.readBool() { // long_term_ref_pics_present_flag
            let numLong = br.readUE()
            for _ in 0..<min(numLong, 32) {
                _ = br.read(4) // log2_max_pic_order_cnt_lsb_minus4 wide → bail-shape
                _ = br.readBool()
            }
        }
        _ = br.readBool() // sps_temporal_mvp_enabled_flag
        _ = br.readBool() // strong_intra_smoothing_enabled_flag

        if br.readBool() { // vui_parameters_present_flag
            if br.readBool() { // aspect_ratio_info_present_flag
                let idc = br.read(8)
                if idc == 255 {
                    let sarW = Int(br.read(16))
                    let sarH = Int(br.read(16))
                    if sarW > 0, sarH > 0 { f.sampleAspect = (sarW, sarH) }
                } else if let sar = h264SARTable(idc: Int(idc)) {
                    f.sampleAspect = sar
                }
            }
            if let sar = f.sampleAspect, let w = f.width, let h = f.height,
               sar.0 > 0, sar.1 > 0, w > 0, h > 0 {
                let dispW = w * sar.0
                let dispH = h * sar.1
                let g = gcd(dispW, dispH)
                if g > 0 { f.displayAspect = (dispW / g, dispH / g) }
            }
            if br.readBool() { _ = br.readBool() } // overscan_info
            if br.readBool() { // video_signal_type_present
                _ = br.read(3) // video_format
                let fullRange = br.readBool()
                var color = VideoColorInfo()
                color.fullRange = fullRange
                if br.readBool() { // colour_description_present
                    color.primaries = Int(br.read(8))
                    color.transfer = Int(br.read(8))
                    color.matrix = Int(br.read(8))
                }
                if !color.isEmpty { f.color = color }
            }
            if br.readBool() { // chroma_loc_info
                let topField = br.readUE()
                _ = br.readUE()
                f.chromaLocation = h264ChromaLocationName(Int(topField))
            }
            _ = br.readBool() // neutral_chroma_indication
            _ = br.readBool() // field_seq_flag
            _ = br.readBool() // frame_field_info_present_flag
            if br.readBool() { // default_display_window
                _ = br.readUE(); _ = br.readUE(); _ = br.readUE(); _ = br.readUE()
            }
            if br.readBool() { // vui_timing_info_present_flag
                let numUnitsInTick = br.read(32)
                let timeScale = br.read(32)
                if numUnitsInTick > 0, timeScale > 0 {
                    // HEVC's tick is field-rate-equivalent; ffprobe reports
                    // time_scale / num_units_in_tick (no /2 like H.264).
                    f.frameRate = Double(timeScale) / Double(numUnitsInTick)
                }
            }
        }
        return f
    }

    private static func parseHEVCProfileTierLevel(
        _ br: inout BitReader,
        maxSubLayersMinus1: Int
    ) -> (profile: String?, level: String?)? {
        guard br.bitsRemaining >= 88 + 8 * maxSubLayersMinus1 else { return nil }
        _ = br.read(2) // general_profile_space
        let tierFlag = br.readBool()
        let profileIDC = Int(br.read(5))
        var profileCompat: UInt32 = 0
        for _ in 0..<32 { profileCompat = (profileCompat << 1) | UInt32(br.read(1)) }
        _ = br.read(4)  // progressive_source_flag … non_packed_constraint_flag
        _ = br.read(43) // remaining general_constraint_indicator_flags
        _ = br.read(1)  // inbld / reserved
        let levelIDC = Int(br.read(8))

        var subLayerProfilePresent = [Bool](repeating: false, count: maxSubLayersMinus1)
        var subLayerLevelPresent = [Bool](repeating: false, count: maxSubLayersMinus1)
        for i in 0..<maxSubLayersMinus1 {
            subLayerProfilePresent[i] = br.readBool()
            subLayerLevelPresent[i] = br.readBool()
        }
        if maxSubLayersMinus1 > 0 {
            for _ in maxSubLayersMinus1..<8 { _ = br.read(2) } // reserved_zero_2bits
        }
        for i in 0..<maxSubLayersMinus1 {
            if subLayerProfilePresent[i] {
                _ = br.read(2)  // sub_layer_profile_space
                _ = br.read(1)  // sub_layer_tier_flag
                _ = br.read(5)  // sub_layer_profile_idc
                _ = br.read(32) // sub_layer_profile_compatibility_flag
                _ = br.read(48) // constraint flags
            }
            if subLayerLevelPresent[i] {
                _ = br.read(8) // sub_layer_level_idc
            }
        }
        return (
            hevcProfileName(profileIDC: profileIDC, profileCompat: profileCompat, tier: tierFlag),
            hevcLevelName(levelIDC: levelIDC)
        )
    }

    private static func skipHEVCScalingListData(_ br: inout BitReader) {
        for sizeId in 0..<4 {
            let matrixCount = (sizeId == 3) ? 2 : 6
            var i = 0
            while i < matrixCount {
                if !br.readBool() {
                    _ = br.readUE() // scaling_list_pred_matrix_id_delta
                } else {
                    var coefNum = min(64, 1 << (4 + (sizeId << 1)))
                    if sizeId > 1 { _ = br.readSE() } // scaling_list_dc_coef_minus8
                    while coefNum > 0 {
                        _ = br.readSE() // scaling_list_delta_coef
                        coefNum -= 1
                    }
                }
                i += (sizeId == 3) ? 3 : 1
            }
        }
    }

    private static func hevcProfileName(profileIDC: Int, profileCompat: UInt32, tier: Bool) -> String? {
        // profile_compatibility_flag[i] bits run MSB-first in the stream;
        // bit at position (31 - i) corresponds to flag[i].
        func compat(_ i: Int) -> Bool { (profileCompat >> (31 - i)) & 1 == 1 }
        let base: String?
        switch profileIDC {
        case 1: base = "Main"
        case 2: base = "Main 10"
        case 3: base = "Main Still Picture"
        case 4: base = "Format Range Extensions"
        case 5: base = "High Throughput"
        case 6: base = "Multiview Main"
        case 7: base = "Scalable Main"
        case 8: base = "3D Main"
        case 9: base = "Screen Content Coding"
        default:
            if compat(2) { base = "Main 10" }
            else if compat(1) { base = "Main" }
            else if compat(3) { base = "Main Still Picture" }
            else { base = nil }
        }
        guard let base else { return nil }
        return tier ? "\(base) High Tier" : base
    }

    private static func hevcLevelName(levelIDC: Int) -> String? {
        // levelIDC is encoded as level × 30 (e.g. 4.0 → 120, 5.1 → 153).
        guard levelIDC > 0 else { return nil }
        let value = Double(levelIDC) / 30.0
        let major = Int(value)
        let minorTimes10 = Int(value * 10) - major * 10
        return minorTimes10 == 0 ? "\(major)" : "\(major).\(minorTimes10)"
    }

    // MARK: - AAC ADTS

    struct ADTSFields {
        var profile: String?
        var sampleRate: Int?
        var channels: Int?
        var channelLayout: String?
    }

    /// Standard AAC sample-rate table (sampling_frequency_index → Hz).
    static let aacSampleRateTable: [Int] = [
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
        16000, 12000, 11025, 8000, 7350, 0, 0, 0,
    ]

    /// Find the first ADTS fixed header (`syncword == 0xFFF`) inside a
    /// PES payload and decode it.
    static func parseAACADTS(_ data: Data) -> ADTSFields? {
        let n = data.count
        guard n >= 4 else { return nil }
        var i = 0
        while i + 4 <= n {
            let b0 = data[data.startIndex + i]
            let b1 = data[data.startIndex + i + 1]
            if b0 == 0xFF, (b1 & 0xF6) == 0xF0 {
                let b2 = data[data.startIndex + i + 2]
                let b3 = data[data.startIndex + i + 3]
                let aotMinus1 = Int((b2 >> 6) & 0x03)
                let sfi = Int((b2 >> 2) & 0x0F)
                let chConfig = Int(((b2 & 0x01) << 2) | ((b3 >> 6) & 0x03))
                guard sfi < aacSampleRateTable.count, aacSampleRateTable[sfi] > 0 else {
                    i += 1
                    continue
                }
                var f = ADTSFields()
                f.profile = aacProfileName(aot: aotMinus1 + 1)
                f.sampleRate = aacSampleRateTable[sfi]
                if chConfig > 0 {
                    f.channels = aacChannelCount(chConfig)
                    f.channelLayout = aacChannelLayout(chConfig)
                }
                return f
            }
            i += 1
        }
        return nil
    }

    /// Decode an AAC `AudioSpecificConfig` (used by LATM/LOAS). `data`
    /// is the bitstream-aligned config as carried in `StreamMuxConfig`.
    static func parseAudioSpecificConfig(_ data: Data) -> ADTSFields? {
        guard !data.isEmpty else { return nil }
        var br = BitReader(data)
        var aot = Int(br.read(5))
        if aot == 31 { aot = 32 + Int(br.read(6)) }
        let sfi = Int(br.read(4))
        var sampleRate: Int? = nil
        if sfi == 15 {
            let sr = Int(br.read(24))
            if sr > 0 { sampleRate = sr }
        } else if sfi < aacSampleRateTable.count, aacSampleRateTable[sfi] > 0 {
            sampleRate = aacSampleRateTable[sfi]
        }
        let chConfig = Int(br.read(4))
        // Handle SBR/PS extensions (HE-AAC v1/v2): bumped sample rate is
        // stored as `extension_sampling_frequency_index` after the AOT.
        if aot == 5 || aot == 29 {
            let extSfi = Int(br.read(4))
            if extSfi == 15 { _ = br.read(24) }
            else if extSfi < aacSampleRateTable.count, aacSampleRateTable[extSfi] > 0 {
                // Match ffprobe: report base sample rate from AOT-5.
                sampleRate = aacSampleRateTable[extSfi]
            }
            aot = Int(br.read(5))
            if aot == 31 { aot = 32 + Int(br.read(6)) }
        }
        var f = ADTSFields()
        f.profile = aacProfileName(aot: aot)
        f.sampleRate = sampleRate
        if chConfig > 0 {
            f.channels = aacChannelCount(chConfig)
            f.channelLayout = aacChannelLayout(chConfig)
        }
        return f
    }

    private static func aacProfileName(aot: Int) -> String? {
        switch aot {
        case 1: return "Main"
        case 2: return "LC"
        case 3: return "SSR"
        case 4: return "LTP"
        case 5: return "HE-AAC"
        case 22: return "BSAC"
        case 23: return "LD"
        case 29: return "HE-AACv2"
        case 39: return "ELD"
        default: return nil
        }
    }

    private static func aacChannelCount(_ chConfig: Int) -> Int? {
        switch chConfig {
        case 1: return 1
        case 2: return 2
        case 3: return 3
        case 4: return 4
        case 5: return 5
        case 6: return 6
        case 7: return 8
        default: return nil
        }
    }

    private static func aacChannelLayout(_ chConfig: Int) -> String? {
        switch chConfig {
        case 1: return "mono"
        case 2: return "stereo"
        case 3: return "3.0"
        case 4: return "4.0"
        case 5: return "5.0"
        case 6: return "5.1"
        case 7: return "7.1"
        default: return nil
        }
    }

    // MARK: - AAC LATM/LOAS

    /// Parse the first LATM `AudioSpecificConfig` found inside a PES
    /// payload. Sync is the 11-bit `audio_mux_element` start
    /// `0x2B7` followed by `audioMuxLengthBytes` length field.
    static func parseAACLATM(_ data: Data) -> ADTSFields? {
        let n = data.count
        guard n >= 4 else { return nil }
        var i = 0
        while i + 3 < n {
            let b0 = data[data.startIndex + i]
            let b1 = data[data.startIndex + i + 1]
            // 11-bit syncword 0x2B7 — top 11 bits of [b0 b1].
            if b0 == 0x56, (b1 & 0xE0) == 0xE0 {
                let payloadStart = i + 3
                guard payloadStart < n else { return nil }
                let payload = data.subdata(in: (data.startIndex + payloadStart)..<data.endIndex)
                if let cfg = decodeLATMConfig(payload) { return cfg }
            }
            i += 1
        }
        return nil
    }

    private static func decodeLATMConfig(_ payload: Data) -> ADTSFields? {
        guard !payload.isEmpty else { return nil }
        var br = BitReader(payload)
        if br.readBool() { return nil } // useSameStreamMux=1: config absent in this frame
        // StreamMuxConfig: audioMuxVersion u(1), allStreamsSameTimeFraming u(1)
        let audioMuxVersion = br.readBool()
        if audioMuxVersion {
            // audioMuxVersionA u(1) etc. skipped for parity with most encoders
            return nil
        }
        _ = br.readBool() // allStreamsSameTimeFraming
        let numSubFrames = Int(br.read(6))
        let numProgram = Int(br.read(4))
        let numLayer = Int(br.read(3))
        _ = numSubFrames; _ = numProgram; _ = numLayer
        // AudioSpecificConfig follows directly.
        // Build a byte-aligned ASC by re-reading bits into a Data.
        var ascBits: [UInt8] = []
        var bitsCollected = 0
        var current: UInt8 = 0
        // Read at most 8 bytes — that's plenty for plain ASC.
        let maxBits = min(8 * 8, br.bitsRemaining)
        while bitsCollected < maxBits {
            current = (current << 1) | UInt8(br.read(1))
            bitsCollected += 1
            if bitsCollected % 8 == 0 {
                ascBits.append(current)
                current = 0
            }
        }
        if bitsCollected % 8 != 0 {
            current <<= UInt8(8 - bitsCollected % 8)
            ascBits.append(current)
        }
        return parseAudioSpecificConfig(Data(ascBits))
    }

    // MARK: - AC-3 / E-AC-3

    struct AC3Fields {
        var sampleRate: Int?
        var channels: Int?
        var channelLayout: String?
        var bitRate: Int?
    }

    /// AC-3 sync = 0x0B77. Decode the bsi up to acmod / lfeon for sample
    /// rate, channels, and bit rate.
    static func parseAC3(_ data: Data) -> AC3Fields? {
        let n = data.count
        guard n >= 7 else { return nil }
        var i = 0
        while i + 7 <= n {
            if data[data.startIndex + i] == 0x0B,
               data[data.startIndex + i + 1] == 0x77 {
                var br = BitReader(data.subdata(in: (data.startIndex + i + 2)..<data.endIndex))
                _ = br.read(16) // crc1
                let fscod = Int(br.read(2))
                let frmsizecod = Int(br.read(6))
                let bsid = Int(br.read(5))
                _ = br.read(3) // bsmod
                let acmod = Int(br.read(3))
                if (acmod & 1) != 0, acmod != 1 { _ = br.read(2) } // cmixlev
                if (acmod & 4) != 0 { _ = br.read(2) }             // surmixlev
                if acmod == 2 { _ = br.read(2) }                   // dsurmod
                let lfeon = br.readBool()
                if bsid > 10 {
                    // Out of range for plain AC-3 — could be E-AC-3
                    // misdetected. Skip.
                    return nil
                }
                var f = AC3Fields()
                f.sampleRate = ac3SampleRate(fscod: fscod)
                f.channels = ac3ChannelCount(acmod: acmod, lfe: lfeon)
                f.channelLayout = ac3ChannelLayout(acmod: acmod, lfe: lfeon)
                f.bitRate = ac3BitRate(frmsizecod: frmsizecod)
                return f
            }
            i += 1
        }
        return nil
    }

    /// E-AC-3 sync = 0x0B77 with `bsid` between 11 and 16.
    static func parseEAC3(_ data: Data) -> AC3Fields? {
        let n = data.count
        guard n >= 6 else { return nil }
        var i = 0
        while i + 6 <= n {
            if data[data.startIndex + i] == 0x0B,
               data[data.startIndex + i + 1] == 0x77 {
                var br = BitReader(data.subdata(in: (data.startIndex + i + 2)..<data.endIndex))
                _ = br.read(2) // strmtyp
                _ = br.read(3) // substreamid
                _ = br.read(11) // frmsiz
                let fscod = Int(br.read(2))
                let fscod2 = Int(br.read(2))
                _ = br.read(2) // numblkscod
                let acmod = Int(br.read(3))
                let lfeon = br.readBool()
                let bsid = Int(br.read(5))
                guard bsid >= 11, bsid <= 16 else { return nil }
                var f = AC3Fields()
                f.sampleRate = fscod == 3
                    ? eac3HalfRate(fscod2: fscod2)
                    : ac3SampleRate(fscod: fscod)
                f.channels = ac3ChannelCount(acmod: acmod, lfe: lfeon)
                f.channelLayout = ac3ChannelLayout(acmod: acmod, lfe: lfeon)
                return f
            }
            i += 1
        }
        return nil
    }

    private static func ac3SampleRate(fscod: Int) -> Int? {
        switch fscod {
        case 0: return 48000
        case 1: return 44100
        case 2: return 32000
        default: return nil
        }
    }

    private static func eac3HalfRate(fscod2: Int) -> Int? {
        switch fscod2 {
        case 0: return 24000
        case 1: return 22050
        case 2: return 16000
        default: return nil
        }
    }

    private static func ac3ChannelCount(acmod: Int, lfe: Bool) -> Int? {
        let main: Int
        switch acmod {
        case 0: main = 2 // 1+1 (Ch1, Ch2 dual mono)
        case 1: main = 1
        case 2: main = 2
        case 3: main = 3
        case 4: main = 3
        case 5: main = 4
        case 6: main = 4
        case 7: main = 5
        default: return nil
        }
        return main + (lfe ? 1 : 0)
    }

    private static func ac3ChannelLayout(acmod: Int, lfe: Bool) -> String? {
        let base: String
        switch acmod {
        case 0: base = "1+1"
        case 1: base = "mono"
        case 2: base = "stereo"
        case 3: base = "3.0"
        case 4: base = "2.1"
        case 5: base = "3.1"
        case 6: base = "2.2"
        case 7: base = "5.0"
        default: return nil
        }
        if !lfe { return base }
        // Append LFE for layouts that take one.
        switch acmod {
        case 1: return "1.1"
        case 2: return "2.1"
        case 3: return "3.1"
        case 4: return "3.1"
        case 5: return "4.1"
        case 6: return "4.1"
        case 7: return "5.1"
        default: return base
        }
    }

    private static func ac3BitRate(frmsizecod: Int) -> Int? {
        // Lower 5 bits index the bit-rate table; the 6th bit selects the
        // frame size variant at non-48k sample rates and doesn't change
        // the bit rate. ATSC A/52 Table 5.18.
        let table: [Int] = [
            32_000, 40_000, 48_000, 56_000, 64_000, 80_000, 96_000, 112_000,
            128_000, 160_000, 192_000, 224_000, 256_000, 320_000, 384_000, 448_000,
            512_000, 576_000, 640_000,
        ]
        let idx = frmsizecod >> 1
        guard idx < table.count else { return nil }
        return table[idx]
    }

    // MARK: - Helpers

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }
}
