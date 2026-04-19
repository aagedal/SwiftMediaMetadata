import XCTest
@testable import SwiftExif

final class PDFTests: XCTestCase {

    // MARK: - Format Detection

    func testDetectPDFMagicBytes() {
        let pdf = buildMinimalPDF(title: "Test")
        XCTAssertEqual(FormatDetector.detect(pdf), .pdf)
    }

    func testDetectPDFExtension() {
        XCTAssertEqual(FormatDetector.detectFromExtension("pdf"), .pdf)
    }

    func testNotPDF() {
        let jpeg = TestFixtures.minimalJPEG()
        XCTAssertNotEqual(FormatDetector.detect(jpeg), .pdf)
    }

    // MARK: - Parsing

    func testParseInfoDict() throws {
        let pdf = buildMinimalPDF(title: "My Document", author: "Alice")
        let file = try PDFParser.parse(pdf)

        XCTAssertEqual(file.infoDict["Title"], "My Document")
        XCTAssertEqual(file.infoDict["Author"], "Alice")
        XCTAssertTrue(file.headerVersion.hasPrefix("1."))
    }

    func testParseInfoDictWithSpecialChars() throws {
        let pdf = buildMinimalPDF(title: "Parentheses \\(and\\) backslash")
        let file = try PDFParser.parse(pdf)
        XCTAssertEqual(file.infoDict["Title"], "Parentheses (and) backslash")
    }

    func testParseEmptyInfoDict() throws {
        let pdf = buildMinimalPDF()
        let file = try PDFParser.parse(pdf)
        XCTAssertTrue(file.infoDict.isEmpty || file.infoDict.values.allSatisfy { !$0.isEmpty })
    }

    func testRejectEncryptedPDF() {
        let pdf = buildEncryptedPDF()
        XCTAssertThrowsError(try PDFParser.parse(pdf)) { error in
            XCTAssertTrue("\(error)".contains("Encrypted"))
        }
    }

    func testParsePDFWithXMP() throws {
        let xmpXml = """
        <?xpacket begin="\u{feff}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="\(XMPNamespace.rdf)"
           xmlns:dc="\(XMPNamespace.dc)">
         <rdf:Description rdf:about="">
          <dc:title><rdf:Alt><rdf:li xml:lang="x-default">XMP Title</rdf:li></rdf:Alt></dc:title>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let pdf = buildMinimalPDF(title: "Info Title", xmpStream: xmpXml)
        let metadata = try ImageMetadata.read(from: pdf)

        XCTAssertEqual(metadata.format, .pdf)
        XCTAssertEqual(metadata.xmp?.title, "XMP Title")
    }

    // MARK: - Reading via ImageMetadata

    func testReadPDFMetadata() throws {
        let pdf = buildMinimalPDF(title: "Doc Title", author: "Bob")
        let metadata = try ImageMetadata.read(from: pdf)

        XCTAssertEqual(metadata.format, .pdf)
        if case .pdf(let file) = metadata.container {
            XCTAssertEqual(file.infoDict["Title"], "Doc Title")
            XCTAssertEqual(file.infoDict["Author"], "Bob")
        } else {
            XCTFail("Expected PDF container")
        }
    }

    // MARK: - Writing

    func testWritePDFPreservesOriginal() throws {
        let pdf = buildMinimalPDF(title: "Original")
        var metadata = try ImageMetadata.read(from: pdf)

        let written = try metadata.writeToData()

        // Verify the original data is still at the beginning (incremental update)
        XCTAssertTrue(written.count >= pdf.count)
        XCTAssertEqual(written.prefix(pdf.count), pdf)
    }

    func testModifyPDFInfoDict() throws {
        let pdf = buildMinimalPDF(title: "Old Title")
        var metadata = try ImageMetadata.read(from: pdf)

        // Modify via container
        if case .pdf(var file) = metadata.container {
            file.infoDict["Title"] = "New Title"
            metadata.container = .pdf(file)
        }

        let written = try metadata.writeToData()
        let reread = try ImageMetadata.read(from: written)

        if case .pdf(let file) = reread.container {
            XCTAssertEqual(file.infoDict["Title"], "New Title")
        } else {
            XCTFail("Expected PDF container")
        }
    }

    func testWritePDFPreservesUnicodeTitle() throws {
        // Regression: writer previously emitted raw UTF-8 inside `(…)`, which PDF readers
        // decode as PDFDocEncoding — corrupting Scandinavian characters.
        let pdf = buildMinimalPDF(title: "Original")
        var metadata = try ImageMetadata.read(from: pdf)

        if case .pdf(var file) = metadata.container {
            file.infoDict["Title"] = "Øvingsbilde fra Trondheim — Ærlig talt"
            file.infoDict["Author"] = "Ingrid Åse"
            metadata.container = .pdf(file)
        }

        let written = try metadata.writeToData()

        // Verify the Unicode values are NOT serialized as raw UTF-8 in a (…) literal.
        // The old buggy output contained the bytes C3 98 (Ø) between parens; the fix
        // should emit a UTF-16BE hex string <FEFF…> instead.
        let asciiDump = String(decoding: written, as: UTF8.self)
        XCTAssertFalse(asciiDump.contains("(Øvingsbilde"),
                       "Non-ASCII value must not be written as raw UTF-8 in a PDF literal")

        let reread = try ImageMetadata.read(from: written)
        if case .pdf(let file) = reread.container {
            XCTAssertEqual(file.infoDict["Title"], "Øvingsbilde fra Trondheim — Ærlig talt")
            XCTAssertEqual(file.infoDict["Author"], "Ingrid Åse")
        } else {
            XCTFail("Expected PDF container")
        }
    }

    func testPDFExport() throws {
        let pdf = buildMinimalPDF(title: "Export Test", author: "Charlie")
        let metadata = try ImageMetadata.read(from: pdf)
        let dict = MetadataExporter.buildDictionary(metadata)

        XCTAssertEqual(dict["PDF:Title"] as? String, "Export Test")
        XCTAssertEqual(dict["PDF:Author"] as? String, "Charlie")
        XCTAssertEqual(dict["FileFormat"] as? String, "PDF")
    }

    func testThumbnailReturnsNil() throws {
        let pdf = buildMinimalPDF(title: "No Thumb")
        let metadata = try ImageMetadata.read(from: pdf)

        XCTAssertNil(metadata.extractThumbnail())
    }

    // MARK: - Helpers

    /// Build a minimal valid PDF with optional metadata.
    private func buildMinimalPDF(title: String? = nil, author: String? = nil, xmpStream: String? = nil) -> Data {
        var objCount = 0
        var objects: [(num: Int, content: String)] = []

        // Object 1: Catalog
        objCount += 1
        let catalogNum = objCount
        var catalogDict = "/Type /Catalog /Pages 2 0 R"

        // Object 2: Pages
        objCount += 1
        let pagesNum = objCount

        // Object 3: Page
        objCount += 1
        let pageNum = objCount

        // Object 4: Info dictionary (optional)
        var infoNum: Int? = nil
        if title != nil || author != nil {
            objCount += 1
            infoNum = objCount
            var infoContent = "<<"
            if let t = title { infoContent += " /Title (\(t))" }
            if let a = author { infoContent += " /Author (\(a))" }
            infoContent += " >>"
            objects.append((infoNum!, "\(infoNum!) 0 obj\n\(infoContent)\nendobj"))
        }

        // Object 5: XMP metadata stream (optional)
        var xmpNum: Int? = nil
        if let xmp = xmpStream {
            objCount += 1
            xmpNum = objCount
            let xmpData = Data(xmp.utf8)
            objects.append((xmpNum!, "\(xmpNum!) 0 obj\n<< /Type /Metadata /Subtype /XML /Length \(xmpData.count) >>\nstream\n\(xmp)\nendstream\nendobj"))
            catalogDict += " /Metadata \(xmpNum!) 0 R"
        }

        objects.insert((catalogNum, "\(catalogNum) 0 obj\n<< \(catalogDict) >>\nendobj"), at: 0)
        objects.insert((pagesNum, "\(pagesNum) 0 obj\n<< /Type /Pages /Kids [\(pageNum) 0 R] /Count 1 >>\nendobj"), at: 1)
        objects.insert((pageNum, "\(pageNum) 0 obj\n<< /Type /Page /Parent \(pagesNum) 0 R /MediaBox [0 0 612 792] >>\nendobj"), at: 2)

        // Build PDF as Data (byte-accurate offsets for multi-byte chars like BOM)
        var pdfData = Data("%PDF-1.4\n".utf8)
        var offsets: [Int: Int] = [:]

        for obj in objects {
            offsets[obj.num] = pdfData.count
            pdfData.append(contentsOf: (obj.content + "\n").utf8)
        }

        // XRef table
        let xrefOffset = pdfData.count
        var xref = "xref\n"
        xref += "0 \(objCount + 1)\n"
        xref += "0000000000 65535 f \n"
        for i in 1...objCount {
            let offset = offsets[i] ?? 0
            xref += String(format: "%010d 00000 n \n", offset)
        }
        pdfData.append(contentsOf: xref.utf8)

        // Trailer
        var trailer = "trailer\n<< /Size \(objCount + 1) /Root \(catalogNum) 0 R"
        if let infoNum { trailer += " /Info \(infoNum) 0 R" }
        trailer += " >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        pdfData.append(contentsOf: trailer.utf8)

        return pdfData
    }

    private func buildEncryptedPDF() -> Data {
        var pdf = "%PDF-1.4\n"
        pdf += "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        pdf += "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n"
        let xrefOffset = pdf.count
        pdf += "xref\n0 3\n0000000000 65535 f \n"
        pdf += String(format: "%010d 00000 n \n", 9)
        pdf += String(format: "%010d 00000 n \n", 58)
        pdf += "trailer\n<< /Size 3 /Root 1 0 R /Encrypt 99 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}
