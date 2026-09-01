import XCTest
@testable import SwiftMediaMetadata
#if canImport(CryptoKit)
import CryptoKit
#endif

final class FileHasherStreamingTests: XCTestCase {

    // Known-answer test for an empty input — sanity-checks that the streaming
    // path's pad-and-length logic matches the canonical digests.
    func testKnownAnswers_Empty() {
        let emptyMD5 = "d41d8cd98f00b204e9800998ecf8427e"
        let emptySHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(FileHasher.md5(Data()), emptyMD5)
        XCTAssertEqual(FileHasher.sha256(Data()), emptySHA)
    }

    // Exercise every block-boundary edge case in the pad-and-length logic.
    func testStreamingMatchesOneShot_BoundaryLengths() {
        let lengths = [0, 3, 55, 56, 63, 64, 65, 119, 120, 128, 8192]
        for n in lengths {
            let bytes = Data((0..<n).map { UInt8($0 & 0xff) })

            let oneShotMD5 = FileHasher.md5(bytes)
            let oneShotSHA = FileHasher.sha256(bytes)

            // Single-update streaming.
            do {
                let (md5, sha) = streamHash(chunks: [bytes])
                XCTAssertEqual(md5, oneShotMD5, "MD5 mismatch at len=\(n)")
                XCTAssertEqual(sha, oneShotSHA, "SHA-256 mismatch at len=\(n)")
            }

            // Byte-by-byte streaming (worst case for the partial-block path).
            if n <= 128 {
                let perByte = (0..<n).map { bytes.subdata(in: $0..<$0 + 1) }
                let (md5, sha) = streamHash(chunks: perByte)
                XCTAssertEqual(md5, oneShotMD5, "byte-by-byte MD5 mismatch at len=\(n)")
                XCTAssertEqual(sha, oneShotSHA, "byte-by-byte SHA-256 mismatch at len=\(n)")
            }
        }
    }

    // Multi-megabyte buffer crossing several 1 MB read chunks, fed in irregular
    // pieces to stress block buffering across update boundaries.
    func testStreamingMatchesOneShot_LargeIrregularChunks() {
        var rng = SeededRNG(seed: 0xC0FFEE)
        let total = 3 * 1024 * 1024 + 7
        var bytes = Data(count: total)
        bytes.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            for i in 0..<total { buf[i] = UInt8(rng.next() & 0xff) }
        }

        let oneShotMD5 = FileHasher.md5(bytes)
        let oneShotSHA = FileHasher.sha256(bytes)

        // Awkward, prime-flavoured chunk sizes that straddle block boundaries.
        var chunks: [Data] = []
        var off = 0
        let sizes = [1, 63, 64, 65, 1_000_000, 7, 511, 513]
        var i = 0
        while off < total {
            let take = min(sizes[i % sizes.count], total - off)
            chunks.append(bytes.subdata(in: off..<off + take))
            off += take
            i += 1
        }

        let (md5, sha) = streamHash(chunks: chunks)
        XCTAssertEqual(md5, oneShotMD5)
        XCTAssertEqual(sha, oneShotSHA)
    }

    // End-to-end `FileHasher.hash(url:)` against a 3 MB temp file.
    func testHashURL_MatchesOneShotForFile() throws {
        var rng = SeededRNG(seed: 0xBADCAB)
        let total = 3 * 1024 * 1024
        var bytes = Data(count: total)
        bytes.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            for i in 0..<total { buf[i] = UInt8(rng.next() & 0xff) }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("filehasher-stream-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let hashes = try FileHasher.hash(url: url)
        XCTAssertEqual(hashes.md5, FileHasher.md5(bytes))
        XCTAssertEqual(hashes.sha256, FileHasher.sha256(bytes))
        XCTAssertEqual(hashes.fileSize, UInt64(total))
    }

    // Empty file: `hash(url:)` must still produce the canonical digests and a
    // zero file size — the streaming loop runs zero iterations, so finalize()
    // alone has to emit the right output.
    func testHashURL_EmptyFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("filehasher-empty-\(UUID().uuidString).bin")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let hashes = try FileHasher.hash(url: url)
        XCTAssertEqual(hashes.md5, "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(hashes.sha256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hashes.fileSize, 0)
    }

    // Validate the pure-Swift streaming types directly. They're the Linux
    // fallback, but exercising them on macOS catches Linux regressions early.
    func testPureStreamingMatchesPureOneShot() {
        let lengths = [0, 1, 55, 56, 64, 65, 8192]
        for n in lengths {
            let bytes = Data((0..<n).map { UInt8(($0 * 37 + 11) & 0xff) })

            var md5Streamer = PureMD5.Streaming()
            var shaStreamer = PureSHA256.Streaming()
            md5Streamer.update(data: bytes)
            shaStreamer.update(data: bytes)
            let md5Hex = md5Streamer.finalize().map { String(format: "%02x", $0) }.joined()
            let shaHex = shaStreamer.finalize().map { String(format: "%02x", $0) }.joined()

            let md5OneShot = PureMD5.hash(bytes).map { String(format: "%02x", $0) }.joined()
            let shaOneShot = PureSHA256.hash(bytes).map { String(format: "%02x", $0) }.joined()

            XCTAssertEqual(md5Hex, md5OneShot, "pure MD5 mismatch at len=\(n)")
            XCTAssertEqual(shaHex, shaOneShot, "pure SHA mismatch at len=\(n)")
        }
    }

    // MARK: - Helpers

    /// Mirror the production hash(url:) path: feed each chunk to both hashers
    /// and finalize. Exercises CryptoKit on Apple, Pure on Linux.
    private func streamHash(chunks: [Data]) -> (md5: String, sha256: String) {
        #if canImport(CryptoKit)
        var md5 = Insecure.MD5()
        var sha = SHA256()
        for c in chunks {
            md5.update(data: c)
            sha.update(data: c)
        }
        let md5Hex = md5.finalize().map { String(format: "%02x", $0) }.joined()
        let shaHex = sha.finalize().map { String(format: "%02x", $0) }.joined()
        return (md5Hex, shaHex)
        #else
        var md5 = PureMD5.Streaming()
        var sha = PureSHA256.Streaming()
        for c in chunks {
            md5.update(data: c)
            sha.update(data: c)
        }
        let md5Hex = md5.finalize().map { String(format: "%02x", $0) }.joined()
        let shaHex = sha.finalize().map { String(format: "%02x", $0) }.joined()
        return (md5Hex, shaHex)
        #endif
    }
}

// A tiny seeded LCG so the random buffers are reproducible across runs.
private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed | 1 }
    mutating func next() -> UInt64 {
        state &*= 6364136223846793005
        state &+= 1442695040888963407
        return state
    }
}
