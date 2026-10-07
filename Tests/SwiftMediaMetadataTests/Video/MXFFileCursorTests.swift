import XCTest
@testable import SwiftMediaMetadata

extension XCTestCase {
    func assertMXFFileParity(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mxf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let fromData = try MXFReader.parse(data)
        let fromFile = try MXFReader.parse(from: url)
        XCTAssertEqual(try exportedMXF(fromData), try exportedMXF(fromFile), file: file, line: line)
        let urlResult = try VideoMetadata.read(from: url)
        XCTAssertNil(urlResult.originalData, file: file, line: line)
        XCTAssertEqual(urlResult.fileSize, Int64(data.count), file: file, line: line)
    }

    func readVideoWithMXFFileParity(_ data: Data) throws -> VideoMetadata {
        if MXFReader.isMXF(data) { try assertMXFFileParity(data) }
        return try VideoMetadata.read(from: data)
    }

    func parseMXFWithFileParity(_ data: Data) throws -> VideoMetadata {
        try assertMXFFileParity(data)
        return try MXFReader.parse(data)
    }

    func exportedMXF(_ metadata: VideoMetadata) throws -> Data {
        try JSONSerialization.data(withJSONObject: VideoMetadataExporter.buildDictionary(metadata), options: [.sortedKeys])
    }
}

final class MXFFileCursorTests: XCTestCase {
    private let partition = Data([0x06,0x0E,0x2B,0x34,0x02,0x05,0x01,0x01,0x0D,0x01,0x02,0x01,0x01,0x02,0x04,0x00]) + Data([0])
    private let xml = Data("<NonRealTimeMeta><Device manufacturer=\"Sony\" modelName=\"Late FX6\"/></NonRealTimeMeta>".utf8)

    private func ber(_ count: Int) -> Data {
        var bytes: [UInt8] = []
        var n = count
        repeat { bytes.insert(UInt8(n & 255), at: 0); n >>= 8 } while n > 0
        return count < 128 ? Data([UInt8(count)]) : Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private func key(_ kind: UInt8) -> Data {
        Data([0x06,0x0E,0x2B,0x34,0x02,0x53,0x01,0x01,0x0D,0x01,0x01,0x01,0x01,0x01,kind,0])
    }

    private func local(_ tag: UInt16, _ value: Data) -> Data {
        var result = withUnsafeBytes(of: tag.bigEndian) { Data($0) }
        result += withUnsafeBytes(of: UInt16(value.count).bigEndian) { Data($0) }
        return result + value
    }

    private func klv(_ key: Data, _ value: Data) -> Data { key + ber(value.count) + value }

    private func withFile(_ data: Data, _ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mxf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    func testSparseEssenceSkippedAndFooterMetadataStillRead() throws {
        let essenceLength = 512 * 1024 * 1024
        let header = partition + Data(repeating: 0x77, count: 16) + ber(essenceLength)
        try withFile(header) { url in
            let writer = try FileHandle(forWritingTo: url)
            defer { try? writer.close() }
            let footerStart = header.count + essenceLength
            try writer.seek(toOffset: UInt64(footerStart))
            try writer.write(contentsOf: klv(Data(repeating: 0xAA, count: 16), xml) + klv(Data(repeating: 0xBB, count: 16), buildMinimalManifestStore()))
            var cursor = try MXFFileCursor(url: url)
            var reads: [(Int, Int)] = []
            cursor.onRead = { reads.append(($0, $1)) }
            let metadata = try MXFReader.parse(cursor: &cursor)
            XCTAssertEqual(metadata.camera?.deviceModelName, "Late FX6")
            XCTAssertEqual(metadata.c2pa?.manifests.count, 1)
            XCTAssertLessThan(reads.reduce(0) { $0 + $1.1 }, 17 * 1024 * 1024)
            XCTAssertTrue(reads.allSatisfy { offset, count in
                (offset == 0 && count <= 16 * 1024 * 1024)
                    || offset + count <= header.count + 512 || offset >= footerStart
            }, "No request may span skipped essence beyond the bounded prefix/peek")
            XCTAssertEqual(try exportedMXF(metadata), try exportedMXF(MXFReader.parse(Data(contentsOf: url, options: .alwaysMapped))))
        }
    }

    func testLateDurationAndTimecodeEncounterOrder() throws {
        func timecode(_ start: UInt64) -> Data {
            local(0x1501, withUnsafeBytes(of: start.bigEndian) { Data($0) })
                + local(0x1502, Data([0, 25])) + local(0x1503, Data([0]))
        }
        let track = local(0x4B01, Data([0,0,0,25,0,0,0,1]))
        let duration = local(0x0202, withUnsafeBytes(of: UInt64(2500).bigEndian) { Data($0) })
        let data = partition + klv(key(0x3B), track) + klv(key(0x14), timecode(25))
            + klv(Data(repeating: 0x77, count: 16), Data(repeating: 0, count: 1024 * 1024))
            + klv(key(0x0F), duration) + klv(key(0x14), timecode(50))
        try withFile(data) { url in
            let metadata = try MXFReader.parse(from: url)
            XCTAssertEqual(metadata.duration, 100)
            XCTAssertEqual(metadata.timecodes.map(\.source), [.mxfMaterialPackage, .mxfFilePackage])
            try assertMXFFileParity(data)
        }
    }

    func testNonzeroStartIndexDataSliceMatchesFile() throws {
        let data = Data(repeating: 0, count: 19) + partition + klv(Data(repeating: 0xAA, count: 16), xml)
        let slice = data.dropFirst(19)
        XCTAssertNotEqual(slice.startIndex, 0)
        try assertMXFFileParity(slice)
    }

    func testInvalidAndOverflowingBERToleratedEqually() throws {
        for ber in [Data([0x80]), Data([0x89]), Data([0x88] + [UInt8](repeating: 255, count: 8)), Data([0x84, 1])] {
            try assertMXFFileParity(partition + Data(repeating: 0xAA, count: 16) + ber)
        }
    }

    func testCursorBoundsRejectOverflowAndNegativeOffsets() throws {
        try withFile(partition) { url in
            let cursor = try MXFFileCursor(url: url)
            XCTAssertThrowsError(try cursor.slice(from: 1, count: Int.max))
            XCTAssertThrowsError(try cursor.slice(from: Int.max, count: 1))
            XCTAssertThrowsError(try cursor.slice(from: -1, count: 1))
            XCTAssertThrowsError(try cursor.slice(from: 0, count: -1))
            XCTAssertThrowsError(try cursor.seek(to: Int.max))
        }
    }

    func testConcurrentTruncationFailsExactReadAndExtentCheck() throws {
        try withFile(partition + Data(repeating: 0, count: 4096)) { url in
            let cursor = try MXFFileCursor(url: url)
            let writer = try FileHandle(forWritingTo: url)
            defer { try? writer.close() }
            try writer.truncate(atOffset: 0)
            XCTAssertThrowsError(try cursor.readBytes(16))
            XCTAssertThrowsError(try cursor.validateExtent())
        }
    }

    func testIOErrorsPropagateInsteadOfReturningPartialMetadata() throws {
        struct FailingCursor: MXFByteCursor {
            var offset = 0
            let count = 32
            var remainingCount: Int { count - offset }
            let header: Data
            mutating func readUInt8() throws -> UInt8 { throw POSIXError(.EIO) }
            mutating func readBytes(_ count: Int) throws -> Data { throw POSIXError(.EIO) }
            func slice(from start: Int, count: Int) throws -> Data { Data(header.prefix(count)) }
            mutating func seek(to offset: Int) throws { self.offset = offset }
        }
        var cursor = FailingCursor(header: partition)
        XCTAssertThrowsError(try MXFReader.parse(cursor: &cursor)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EIO)
        }
    }

    func testAuthenticCameraExporterParityWhenOptedIn() throws {
        guard let path = ProcessInfo.processInfo.environment["MXF_FILE_CURSOR_AUTHENTIC_PATH"] else {
            throw XCTSkip("Opt in with MXF_FILE_CURSOR_AUTHENTIC_PATH")
        }
        let url = URL(fileURLWithPath: path)
        let fromData = try VideoMetadata.read(from: Data(contentsOf: url, options: .alwaysMapped))
        let fromFile = try VideoMetadata.read(from: url)
        XCTAssertEqual(try exportedMXF(fromData), try exportedMXF(fromFile))
        XCTAssertNil(fromFile.originalData)
        var cursor = try MXFFileCursor(url: url)
        var total = 0
        var maximum = 0
        var requests = 0
        cursor.onRead = { _, count in
            total += count
            maximum = max(maximum, count)
            requests += 1
        }
        _ = try MXFReader.parse(cursor: &cursor)
        XCTAssertLessThanOrEqual(maximum, 32 * 1024 * 1024)
        print("MXF_FILE_CURSOR_READS requests=\(requests) bytes=\(total) maximumRequest=\(maximum) fileBytes=\(cursor.count)")
    }

    private func buildMinimalManifestStore() -> Data {
        let claim = buildClaim(generator: "SwiftMediaMetadata Test")
        let manifest = buildManifest(label: "urn:c2pa:test-manifest", claimCBOR: claim)
        return wrapInManifestStore(manifest)
    }

    private func buildClaim(generator: String) -> Data {
        var cbor = Data()
        cbor.append(cborMap(1))
        cbor.append(cborTextString("claim_generator"))
        cbor.append(cborTextString(generator))
        return cbor
    }

    private func buildMinimalSignature() -> Data {
        var cbor = Data()
        cbor.append(0xD2) // tag 18
        cbor.append(cborArray(4))
        var protectedMap = Data()
        protectedMap.append(cborMap(1))
        protectedMap.append(cborUInt(1))
        protectedMap.append(cborNegInt(-7))
        cbor.append(cborByteString(protectedMap))
        cbor.append(cborMap(0))
        cbor.append(Data([0xF6]))
        cbor.append(cborByteString(Data(repeating: 0xFF, count: 64)))
        return cbor
    }

    private func buildManifest(label: String, claimCBOR: Data) -> Data {
        var manifestPayload = Data()
        appendBox(to: &manifestPayload, type: "jumd", data: buildJUMD(prefix: "c2ma", label: label))

        var claimSuper = Data()
        appendBox(to: &claimSuper, type: "jumd", data: buildJUMD(prefix: "c2cl", label: "c2pa.claim"))
        appendBox(to: &claimSuper, type: "cbor", data: claimCBOR)
        appendBox(to: &manifestPayload, type: "jumb", data: claimSuper)

        var sigSuper = Data()
        appendBox(to: &sigSuper, type: "jumd", data: buildJUMD(prefix: "c2cs", label: "c2pa.signature"))
        appendBox(to: &sigSuper, type: "cbor", data: buildMinimalSignature())
        appendBox(to: &manifestPayload, type: "jumb", data: sigSuper)

        return manifestPayload
    }

    private func wrapInManifestStore(_ manifestPayload: Data) -> Data {
        var storePayload = Data()
        appendBox(to: &storePayload, type: "jumd", data: buildJUMD(prefix: "c2pa", label: "c2pa"))
        appendBox(to: &storePayload, type: "jumb", data: manifestPayload)

        var out = Data()
        appendBox(to: &out, type: "jumb", data: storePayload)
        return out
    }

    private func buildJUMD(prefix: String, label: String) -> Data {
        var d = Data()
        d.append(contentsOf: [UInt8](prefix.utf8))
        d.append(contentsOf: [0x00, 0x11, 0x00, 0x10, 0x80, 0x00, 0x00, 0xAA,
                              0x00, 0x38, 0x9B, 0x71])
        d.append(0x03)
        d.append(contentsOf: [UInt8](label.utf8))
        d.append(0x00)
        return d
    }

    private func appendBox(to data: inout Data, type: String, data payload: Data) {
        let size = UInt32(8 + payload.count)
        data.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
        data.append(type.data(using: .ascii)!)
        data.append(payload)
    }

    private func cborUInt(_ value: UInt64) -> Data {
        if value <= 23 { return Data([UInt8(value)]) }
        if value <= 0xFF { return Data([0x18, UInt8(value)]) }
        if value <= 0xFFFF { return Data([0x19, UInt8(value >> 8), UInt8(value & 0xFF)]) }
        var d = Data([0x1A])
        d.append(contentsOf: withUnsafeBytes(of: UInt32(value).bigEndian) { Array($0) })
        return d
    }

    private func cborNegInt(_ value: Int64) -> Data {
        let n = UInt64(-1 - value)
        if n <= 23 { return Data([0x20 | UInt8(n)]) }
        return Data([0x38, UInt8(n)])
    }

    private func cborTextString(_ s: String) -> Data {
        let utf8 = [UInt8](s.utf8)
        let count = utf8.count
        var header: [UInt8]
        if count <= 23 { header = [0x60 | UInt8(count)] }
        else if count <= 255 { header = [0x78, UInt8(count)] }
        else { header = [0x79, UInt8(count >> 8), UInt8(count & 0xFF)] }
        return Data(header + utf8)
    }

    private func cborByteString(_ bytes: Data) -> Data {
        let count = bytes.count
        var header: [UInt8]
        if count <= 23 { header = [0x40 | UInt8(count)] }
        else if count <= 255 { header = [0x58, UInt8(count)] }
        else { header = [0x59, UInt8(count >> 8), UInt8(count & 0xFF)] }
        return Data(header) + bytes
    }

    private func cborMap(_ count: Int) -> Data {
        if count <= 23 { return Data([0xA0 | UInt8(count)]) }
        return Data([0xB8, UInt8(count)])
    }

    private func cborArray(_ count: Int) -> Data {
        if count <= 23 { return Data([0x80 | UInt8(count)]) }
        return Data([0x98, UInt8(count)])
    }
}
