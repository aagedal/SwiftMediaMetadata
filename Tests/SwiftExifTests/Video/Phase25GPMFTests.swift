import XCTest
@testable import SwiftExif

// MARK: - GPMF parser (Phase 25)

final class GPMFReaderTests: XCTestCase {

    func testParsesSimpleScalarEntry() {
        // DVNM 'c' (ASCII string), sample size 6, count 1, value "HERO11" + 2 bytes padding to align.
        var data = Data()
        data.append(contentsOf: "DVNM".utf8)
        data.append(0x63)   // 'c' = ASCII string
        data.append(0x06)   // sample size 6 bytes
        data.append(0x00); data.append(0x01)  // sample count = 1
        data.append(contentsOf: "HERO11".utf8)
        data.append(contentsOf: [0x00, 0x00])  // padding to 4-byte boundary

        let entries = GPMFReader.parse(data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.fourCC, "DVNM")
    }

    func testNestedContainerParses() {
        // DEVC container holding one DVNM child.
        var dvnm = Data()
        dvnm.append(contentsOf: "DVNM".utf8)
        dvnm.append(0x63); dvnm.append(0x06)
        dvnm.append(0x00); dvnm.append(0x01)
        dvnm.append(contentsOf: "HERO11".utf8)
        dvnm.append(contentsOf: [0x00, 0x00])  // pad to 4

        var devc = Data()
        devc.append(contentsOf: "DEVC".utf8)
        devc.append(0x00)        // type 0 = container
        devc.append(0x01)        // sample size = 1 (per spec, payload bytes count)
        let count = UInt16(dvnm.count)
        devc.append(UInt8((count >> 8) & 0xFF)); devc.append(UInt8(count & 0xFF))
        devc.append(dvnm)

        let entries = GPMFReader.parse(devc)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.fourCC, "DEVC")
        XCTAssertEqual(entries.first?.children.count, 1)
        XCTAssertEqual(entries.first?.children.first?.fourCC, "DVNM")
    }

    func testTelemetryExtractsDeviceName() {
        var data = Data()
        appendKLV(&data, fourCC: "DVNM", typeChar: 0x63, sampleSize: 6, sampleCount: 1,
                  payload: Data("HERO11".utf8))
        let t = GPMFReader.telemetry(from: data)
        XCTAssertEqual(t.deviceName, "HERO11")
    }

    func testTelemetryExtractsGPS5WithSCAL() {
        // Build:
        //   SCAL: 5 × int32 scalars (10000000, 10000000, 1000, 1000, 100) — divisors per GPS5 column
        //   GPS5: 1 sample × 5 int32 (lat, lon, alt, speed, speed3D)
        var blob = Data()
        // SCAL
        var scalPayload = Data()
        for v in [Int32(10_000_000), 10_000_000, 1000, 1000, 100] {
            appendInt32BE(&scalPayload, v)
        }
        appendKLV(&blob, fourCC: "SCAL", typeChar: 0x4C, sampleSize: 4, sampleCount: 5,
                  payload: scalPayload)
        // GPS5: lat = 60.000000 → 600_000_000 / 10_000_000
        var gps5Payload = Data()
        appendInt32BE(&gps5Payload, Int32(600_000_000))   // lat = 60.0
        appendInt32BE(&gps5Payload, Int32(110_000_000))   // lon = 11.0
        appendInt32BE(&gps5Payload, Int32(150_000))       // alt = 150 m
        appendInt32BE(&gps5Payload, Int32(0))
        appendInt32BE(&gps5Payload, Int32(0))
        appendKLV(&blob, fourCC: "GPS5", typeChar: 0x6C, sampleSize: 20, sampleCount: 1,
                  payload: gps5Payload)

        let t = GPMFReader.telemetry(from: blob)
        XCTAssertEqual(t.gpsSampleCount, 1)
        XCTAssertEqual(t.firstGPS?.lat ?? 0, 60.0, accuracy: 0.0001)
        XCTAssertEqual(t.firstGPS?.lon ?? 0, 11.0, accuracy: 0.0001)
        XCTAssertEqual(t.firstGPS?.alt ?? 0, 150.0, accuracy: 0.001)
    }

    func testTelemetryFlagsSensorPresence() {
        var blob = Data()
        appendKLV(&blob, fourCC: "ACCL", typeChar: 0x73, sampleSize: 6, sampleCount: 1,
                  payload: Data([0, 1, 0, 1, 0, 1]))
        appendKLV(&blob, fourCC: "GYRO", typeChar: 0x73, sampleSize: 6, sampleCount: 1,
                  payload: Data([0, 1, 0, 1, 0, 1]))
        appendKLV(&blob, fourCC: "FACE", typeChar: 0x53, sampleSize: 4, sampleCount: 1,
                  payload: Data([0, 1, 0, 1]))

        let t = GPMFReader.telemetry(from: blob)
        XCTAssertTrue(t.hasAccelerometer)
        XCTAssertTrue(t.hasGyroscope)
        XCTAssertTrue(t.hasFaceDetection)
        XCTAssertFalse(t.hasMagnetometer)
    }

    // MARK: - Helpers

    /// Append a KLV entry with payload padded to a 4-byte boundary.
    private func appendKLV(_ data: inout Data, fourCC: String, typeChar: UInt8,
                           sampleSize: Int, sampleCount: Int, payload: Data) {
        data.append(contentsOf: fourCC.utf8)
        data.append(typeChar)
        data.append(UInt8(sampleSize))
        data.append(UInt8((sampleCount >> 8) & 0xFF))
        data.append(UInt8(sampleCount & 0xFF))
        data.append(payload)
        let pad = (4 - (payload.count % 4)) % 4
        if pad > 0 { data.append(Data(repeating: 0, count: pad)) }
    }

    private func appendInt32BE(_ data: inout Data, _ v: Int32) {
        let u = UInt32(bitPattern: v)
        data.append(UInt8((u >> 24) & 0xFF))
        data.append(UInt8((u >> 16) & 0xFF))
        data.append(UInt8((u >> 8) & 0xFF))
        data.append(UInt8(u & 0xFF))
    }
}
