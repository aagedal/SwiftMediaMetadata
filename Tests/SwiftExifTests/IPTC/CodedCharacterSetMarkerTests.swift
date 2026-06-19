import XCTest
@testable import SwiftExif

/// Regression tests for the IPTC CodedCharacterSet (1:90) UTF-8 marker.
///
/// Bug: `IPTCWriter` only wrote the marker when the input `IPTCData` did NOT already
/// contain a 1:90 dataset, while the serialization loop ALWAYS skipped existing 1:90
/// datasets. So a write whose input already carried a marker (e.g. read back from a file
/// a prior write — or ImageIO — had marked) silently dropped it. Across a multi-write
/// pipeline the marker flipped on/off by parity, leaving non-ASCII captions unmarked and
/// mojibaked on readers that default to ISO-8859-1.
final class CodedCharacterSetMarkerTests: XCTestCase {

    private let utf8Marker = Data(IPTCReader.utf8EscapeSequence) // ESC % G

    func testNonASCIIWriteEmitsMarker() throws {
        var iptc = IPTCData()
        iptc.caption = "Jonas Gahr Støre og Åse Jonæs"
        let data = try IPTCWriter.write(iptc)
        XCTAssertNotNil(data.range(of: utf8Marker), "non-ASCII IPTC must declare UTF-8")
    }

    /// The core regression: an input that already carries a 1:90 must round-trip with the
    /// marker intact and not duplicated — repeated writes are idempotent.
    func testMarkerSurvivesRepeatedWrites() throws {
        let caption = "Jonas Gahr Støre og Åse Jonæs"
        var iptc = IPTCData()
        iptc.caption = caption

        let once = try IPTCWriter.write(iptc)
        XCTAssertNotNil(once.range(of: utf8Marker), "first write must emit the marker")

        let roundTrip = try IPTCReader.read(from: once)
        XCTAssertTrue(roundTrip.datasets.contains { $0.tag == .codedCharacterSet },
                      "re-read should carry the 1:90 dataset")

        let twice = try IPTCWriter.write(roundTrip)
        let final = try IPTCReader.read(from: twice)
        XCTAssertEqual(final.datasets.filter { $0.tag == .codedCharacterSet }.count, 1,
                       "exactly one marker after repeated writes — not dropped, not duplicated")
        XCTAssertEqual(final.caption, caption)
    }

    /// A pre-existing non-UTF-8 1:90 on non-ASCII content must be normalized to the canonical
    /// UTF-8 marker, never carried through verbatim.
    func testStaleMarkerIsReplacedWithCanonicalUTF8() throws {
        var iptc = IPTCData()
        iptc.caption = "Støre"
        // Inject a bogus/stale CodedCharacterSet dataset ahead of serialization.
        iptc = IPTCData(datasets: [IPTCDataSet(tag: .codedCharacterSet, rawValue: Data([0x1B, 0x2F, 0x41]))]
                        + iptc.datasets, encoding: .utf8)
        let data = try IPTCWriter.write(iptc)
        XCTAssertNotNil(data.range(of: utf8Marker), "must emit canonical UTF-8 marker")
        let final = try IPTCReader.read(from: data)
        XCTAssertEqual(final.datasets.filter { $0.tag == .codedCharacterSet }.count, 1)
        XCTAssertEqual(final.encoding, .utf8)
    }

    /// Pure-ASCII content needs no marker (and writing none keeps files lean / unchanged).
    func testASCIIContentEmitsNoMarker() throws {
        var iptc = IPTCData()
        iptc.caption = "Plain ASCII caption"
        let data = try IPTCWriter.write(iptc)
        XCTAssertNil(data.range(of: utf8Marker), "ASCII-only IPTC should not declare a charset")
    }

    /// Class-level invariant guarding against any future "flip on each write" regression:
    /// once IPTC has been serialized, re-reading and re-writing it must be byte-stable.
    /// (The marker parity bug violated this — the second write differed from the first.)
    func testSerializationIsByteStableAcrossWrites() throws {
        var iptc = IPTCData()
        iptc.caption = "Jonas Gahr Støre og Åse Jonæs"
        iptc.byline = "Tórður"
        iptc.city = "Tromsø"
        iptc.keywords = ["æ", "ø", "å", "ascii"]

        let first = try IPTCWriter.write(iptc)
        let second = try IPTCWriter.write(try IPTCReader.read(from: first))
        let third = try IPTCWriter.write(try IPTCReader.read(from: second))
        XCTAssertEqual(first, second, "write→read→write must be byte-stable")
        XCTAssertEqual(second, third, "serialization must converge to a fixed point")
    }
}
