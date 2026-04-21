import Foundation

/// Pure-Swift SHA-256 and MD5. Used on non-Apple platforms where CryptoKit
/// is unavailable. Kept in-tree to avoid the swift-crypto / BoringSSL
/// dependency, which stalls the Linux-musl cross-compile optimizer.

enum PureSHA256 {
    private static let K: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
        0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
        0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
        0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
        0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
        0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    static func hash(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]

        // Pre-processing: pad to 448 mod 512 bits, append 64-bit length.
        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitLen >> shift) & 0xff))
        }

        // Process 512-bit blocks.
        var block = 0
        while block < msg.count {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let o = block + i * 4
                w[i] = (UInt32(msg[o]) << 24) | (UInt32(msg[o + 1]) << 16)
                     | (UInt32(msg[o + 2]) << 8) | UInt32(msg[o + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)
                let s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]

            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ K[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let mj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ mj
                hh = g; g = f; f = e
                e = d &+ t1
                d = c; c = b; b = a
                a = t1 &+ t2
            }

            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh

            block += 64
        }

        var out = [UInt8]()
        out.reserveCapacity(32)
        for v in h {
            out.append(UInt8((v >> 24) & 0xff))
            out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 8) & 0xff))
            out.append(UInt8(v & 0xff))
        }
        return out
    }

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}

enum PureMD5 {
    private static let S: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]
    private static let K: [UInt32] = [
        0xd76a_a478, 0xe8c7_b756, 0x2420_70db, 0xc1bd_ceee,
        0xf57c_0faf, 0x4787_c62a, 0xa830_4613, 0xfd46_9501,
        0x6980_98d8, 0x8b44_f7af, 0xffff_5bb1, 0x895c_d7be,
        0x6b90_1122, 0xfd98_7193, 0xa679_438e, 0x49b4_0821,
        0xf61e_2562, 0xc040_b340, 0x265e_5a51, 0xe9b6_c7aa,
        0xd62f_105d, 0x0244_1453, 0xd8a1_e681, 0xe7d3_fbc8,
        0x21e1_cde6, 0xc337_07d6, 0xf4d5_0d87, 0x455a_14ed,
        0xa9e3_e905, 0xfcef_a3f8, 0x676f_02d9, 0x8d2a_4c8a,
        0xfffa_3942, 0x8771_f681, 0x6d9d_6122, 0xfde5_380c,
        0xa4be_ea44, 0x4bde_cfa9, 0xf6bb_4b60, 0xbebf_bc70,
        0x289b_7ec6, 0xeaa1_27fa, 0xd4ef_3085, 0x0488_1d05,
        0xd9d4_d039, 0xe6db_99e5, 0x1fa2_7cf8, 0xc4ac_5665,
        0xf429_2244, 0x432a_ff97, 0xab94_23a7, 0xfc93_a039,
        0x655b_59c3, 0x8f0c_cc92, 0xffef_f47d, 0x8584_5dd1,
        0x6fa8_7e4f, 0xfe2c_e6e0, 0xa301_4314, 0x4e08_11a1,
        0xf753_7e82, 0xbd3a_f235, 0x2ad7_d2bb, 0xeb86_d391,
    ]

    static func hash(_ data: Data) -> [UInt8] {
        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for shift in 0..<8 {
            msg.append(UInt8((bitLen >> (shift * 8)) & 0xff))
        }

        var a0: UInt32 = 0x6745_2301
        var b0: UInt32 = 0xefcd_ab89
        var c0: UInt32 = 0x98ba_dcfe
        var d0: UInt32 = 0x1032_5476

        var offset = 0
        while offset < msg.count {
            var M = [UInt32](repeating: 0, count: 16)
            for j in 0..<16 {
                let o = offset + j * 4
                M[j] = UInt32(msg[o]) | (UInt32(msg[o + 1]) << 8)
                     | (UInt32(msg[o + 2]) << 16) | (UInt32(msg[o + 3]) << 24)
            }

            var A = a0, B = b0, C = c0, D = d0

            for i in 0..<64 {
                var F: UInt32 = 0
                var g: Int = 0
                if i < 16 {
                    F = (B & C) | (~B & D); g = i
                } else if i < 32 {
                    F = (D & B) | (~D & C); g = (5 * i + 1) % 16
                } else if i < 48 {
                    F = B ^ C ^ D; g = (3 * i + 5) % 16
                } else {
                    F = C ^ (B | ~D); g = (7 * i) % 16
                }
                F = F &+ A &+ K[i] &+ M[g]
                A = D; D = C; C = B
                B = B &+ rotl(F, UInt32(S[i]))
            }

            a0 &+= A; b0 &+= B; c0 &+= C; d0 &+= D
            offset += 64
        }

        var out = [UInt8]()
        out.reserveCapacity(16)
        for v in [a0, b0, c0, d0] {
            out.append(UInt8(v & 0xff))
            out.append(UInt8((v >> 8) & 0xff))
            out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 24) & 0xff))
        }
        return out
    }

    @inline(__always)
    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }
}
