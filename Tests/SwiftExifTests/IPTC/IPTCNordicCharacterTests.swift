import XCTest
@testable import SwiftExif

final class IPTCNordicCharacterTests: XCTestCase {

    // MARK: - Individual Nordic Character Byte Verification

    func testLowercaseOSlash() throws {
        // ø = U+00F8 = UTF-8: 0xC3 0xB8
        let ds = IPTCDataSet(tag: .city, stringValue: "ø")
        XCTAssertEqual(Array(ds.rawValue), [0xC3, 0xB8])
        XCTAssertEqual(ds.stringValue(encoding: .utf8), "ø")
    }

    func testLowercaseAE() throws {
        // æ = U+00E6 = UTF-8: 0xC3 0xA6
        let ds = IPTCDataSet(tag: .city, stringValue: "æ")
        XCTAssertEqual(Array(ds.rawValue), [0xC3, 0xA6])
        XCTAssertEqual(ds.stringValue(encoding: .utf8), "æ")
    }

    func testLowercaseAA() throws {
        // å = U+00E5 = UTF-8: 0xC3 0xA5
        let ds = IPTCDataSet(tag: .city, stringValue: "å")
        XCTAssertEqual(Array(ds.rawValue), [0xC3, 0xA5])
        XCTAssertEqual(ds.stringValue(encoding: .utf8), "å")
    }

    func testUppercaseOSlash() throws {
        // Ø = U+00D8 = UTF-8: 0xC3 0x98
        let ds = IPTCDataSet(tag: .city, stringValue: "Ø")
        XCTAssertEqual(Array(ds.rawValue), [0xC3, 0x98])
    }

    func testUppercaseAE() throws {
        // Æ = U+00C6 = UTF-8: 0xC3 0x86
        let ds = IPTCDataSet(tag: .city, stringValue: "Æ")
        XCTAssertEqual(Array(ds.rawValue), [0xC3, 0x86])
    }

    func testUppercaseAA() throws {
        // Å = U+00C5 = UTF-8: 0xC3 0x85
        let ds = IPTCDataSet(tag: .city, stringValue: "Å")
        XCTAssertEqual(Array(ds.rawValue), [0xC3, 0x85])
    }

    func testGermanUmlauts() throws {
        // ä = 0xC3 0xA4, ö = 0xC3 0xB6, ü = 0xC3 0xBC
        XCTAssertEqual(Array(IPTCDataSet(tag: .city, stringValue: "ä").rawValue), [0xC3, 0xA4])
        XCTAssertEqual(Array(IPTCDataSet(tag: .city, stringValue: "ö").rawValue), [0xC3, 0xB6])
        XCTAssertEqual(Array(IPTCDataSet(tag: .city, stringValue: "ü").rawValue), [0xC3, 0xBC])
    }

    // MARK: - Round-trip Nordic Strings Through IPTC Reader/Writer

    func testRoundTripTromsoe() throws {
        try assertNordicRoundTrip("Tromsø, Norge")
    }

    func testRoundTripAeroe() throws {
        try assertNordicRoundTrip("Ærø Kommune")
    }

    func testRoundTripOestfold() throws {
        try assertNordicRoundTrip("Østfold fylke")
    }

    func testRoundTripAalesund() throws {
        try assertNordicRoundTrip("Ålesund havn")
    }

    func testRoundTripBjork() throws {
        try assertNordicRoundTrip("Björk Guðmundsdóttir")
    }

    func testRoundTripJarvenpaa() throws {
        try assertNordicRoundTrip("Järvenpää, Suomi")
    }

    func testRoundTripMalmoe() throws {
        try assertNordicRoundTrip("Malmö, Sverige")
    }

    func testRoundTripIsafjordur() throws {
        try assertNordicRoundTrip("Ísafjörður")
    }

    func testRoundTripKierkegaard() throws {
        try assertNordicRoundTrip("Søren Kierkegård")
    }

    func testRoundTripAngstrom() throws {
        try assertNordicRoundTrip("Ångström")
    }

    // MARK: - Nordic Characters in Different Field Types

    func testNordicInHeadline() throws {
        var iptc = IPTCData()
        iptc.headline = "Ølberg: Stormen rammer Tromsø"
        let data = try! IPTCWriter.write(iptc)
        let parsed = try IPTCReader.read(from: data)
        XCTAssertEqual(parsed.headline, "Ølberg: Stormen rammer Tromsø")
    }

    func testNordicInCaption() throws {
        var iptc = IPTCData()
        iptc.caption = "Fiskebåter i Ålesund havn under sterk nordavind. Værmeldingen varsler om kraftig snøvær i Trøndelag."
        let data = try! IPTCWriter.write(iptc)
        let parsed = try IPTCReader.read(from: data)
        XCTAssertEqual(parsed.caption, iptc.caption)
    }

    func testNordicInCity() throws {
        var iptc = IPTCData()
        iptc.city = "Tromsø"
        let data = try! IPTCWriter.write(iptc)
        let parsed = try IPTCReader.read(from: data)
        XCTAssertEqual(parsed.city, "Tromsø")
    }

    func testNordicInByline() throws {
        var iptc = IPTCData()
        iptc.byline = "Bjørn Ødegård"
        let data = try! IPTCWriter.write(iptc)
        let parsed = try IPTCReader.read(from: data)
        XCTAssertEqual(parsed.byline, "Bjørn Ødegård")
    }

    func testNordicInKeywords() throws {
        var iptc = IPTCData()
        iptc.keywords = ["fjæra", "sjø", "båt", "ørret", "Ålesund"]
        let data = try! IPTCWriter.write(iptc)
        let parsed = try IPTCReader.read(from: data)
        XCTAssertEqual(parsed.keywords, ["fjæra", "sjø", "båt", "ørret", "Ålesund"])
    }

    func testNordicInCountryName() throws {
        var iptc = IPTCData()
        iptc.countryName = "Norge"
        iptc.provinceState = "Trøndelag"
        let data = try! IPTCWriter.write(iptc)
        let parsed = try IPTCReader.read(from: data)
        XCTAssertEqual(parsed.countryName, "Norge")
        XCTAssertEqual(parsed.provinceState, "Trøndelag")
    }

    func testNordicInCopyright() throws {
        var iptc = IPTCData()
        iptc.copyright = "© Ås Fotografforening 2026"
        let data = try! IPTCWriter.write(iptc)
        let parsed = try IPTCReader.read(from: data)
        XCTAssertEqual(parsed.copyright, "© Ås Fotografforening 2026")
    }

    // MARK: - Mixed ASCII and Nordic

    func testMixedASCIIAndNordic() throws {
        var iptc = IPTCData()
        iptc.headline = "Storm hits Tromsø: 50 boats damaged at Ærøskøbing harbor"
        let data = try! IPTCWriter.write(iptc)
        let parsed = try IPTCReader.read(from: data)
        XCTAssertEqual(parsed.headline, "Storm hits Tromsø: 50 boats damaged at Ærøskøbing harbor")
    }

    // MARK: - Full JPEG Round-trip with Nordic Characters

    func testFullJPEGRoundTripNordic() throws {
        var iptc = IPTCData()
        iptc.headline = "Sterk nordavind i Tromsø"
        iptc.byline = "Bjørn Ødegård"
        iptc.city = "Tromsø"
        iptc.provinceState = "Troms og Finnmark"
        iptc.countryName = "Norge"
        iptc.keywords = ["vær", "storm", "Tromsø", "nordavind"]
        iptc.caption = "Fiskebåter i Tromsø havn. Kraftig nordavind førte til skader på kaianlegget."
        iptc.copyright = "© NTB / Bjørn Ødegård"

        let jpeg = TestFixtures.jpegWithIPTC(datasets: iptc.datasets)

        // Parse JPEG and extract IPTC
        let file = try JPEGParser.parse(jpeg)
        let parsed = try IPTCReader.readFromAPP13(file.iptcSegment()!.data)

        XCTAssertEqual(parsed.headline, "Sterk nordavind i Tromsø")
        XCTAssertEqual(parsed.byline, "Bjørn Ødegård")
        XCTAssertEqual(parsed.city, "Tromsø")
        XCTAssertEqual(parsed.provinceState, "Troms og Finnmark")
        XCTAssertEqual(parsed.countryName, "Norge")
        XCTAssertEqual(parsed.keywords, ["vær", "storm", "Tromsø", "nordavind"])
        XCTAssertEqual(parsed.caption, "Fiskebåter i Tromsø havn. Kraftig nordavind førte til skader på kaianlegget.")
        XCTAssertEqual(parsed.copyright, "© NTB / Bjørn Ødegård")
    }

    // MARK: - CodedCharacterSet Verification

    func testCodedCharacterSetWrittenForNordic() throws {
        var iptc = IPTCData()
        iptc.city = "Tromsø"
        let data = try! IPTCWriter.write(iptc)
        let parsed = try IPTCReader.read(from: data)
        XCTAssertTrue(parsed.isUTF8, "CodedCharacterSet should indicate UTF-8 for Nordic content")
    }

    func testCodedCharacterSetNotWrittenForASCII() throws {
        var iptc = IPTCData()
        iptc.city = "Oslo"
        let data = try! IPTCWriter.write(iptc)

        // Check raw bytes for absence of 1:90
        let bytes = Array(data)
        for i in 0..<bytes.count - 2 {
            if bytes[i] == 0x1C && bytes[i+1] == 1 && bytes[i+2] == 90 {
                XCTFail("CodedCharacterSet should NOT be written for pure ASCII content")
                return
            }
        }
    }

    // MARK: - All Nordic Test Strings

    func testAllNordicTestStrings() throws {
        for string in TestFixtures.nordicStrings {
            try assertNordicRoundTrip(string)
        }
    }

    // MARK: - Helper

    private func assertNordicRoundTrip(_ string: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var iptc = IPTCData()
        iptc.headline = string
        let data = try IPTCWriter.write(iptc)
        let parsed = try IPTCReader.read(from: data)
        XCTAssertEqual(parsed.headline, string, "Nordic round-trip failed for: \(string)", file: file, line: line)
    }
}
