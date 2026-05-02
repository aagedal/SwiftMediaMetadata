import XCTest
@testable import SwiftExif

/// Unit tests for `ARRIJSONParser` — the substring-scan + schema-routing
/// layer that turns ARRI's KLV-wrapped JSON metadata blobs into
/// `CameraMetadata` typed slots and userMeta entries.
///
/// All fixtures are hand-built byte sequences that mimic the
/// `\x80\x7C <UTF-16BE schema URL>` + `\x80\x7B <UTF-8 JSON>` layout
/// observed in real ALEXA 35 footage.
final class ARRIJSONParserTests: XCTestCase {

    // MARK: - Discovery

    func testFindEmbeddedJSONBlobsExtractsSingleBlob() {
        let blob = makeBlob(schema: "https://www.arri.com/schema/json/camera/camera_device/v1-0-0",
                            json: #"{"cameraModel":"ARRI ALEXA 35"}"#)
        let blobs = ARRIJSONParser.findEmbeddedJSONBlobs(in: blob)
        XCTAssertEqual(blobs.count, 1)
        XCTAssertEqual(blobs[0].schema, "camera_device")
        XCTAssertEqual(blobs[0].json["cameraModel"] as? String, "ARRI ALEXA 35")
    }

    func testFindEmbeddedJSONBlobsHandlesMultipleBlobsAndSortsBySchema() {
        var data = Data()
        data.append(makeBlob(schema: "https://www.arri.com/schema/json/camera/slate_info/v1-1-0",
                             json: #"{"scene":"10A","take":"19"}"#))
        data.append(Data(repeating: 0x00, count: 64)) // padding between sets
        data.append(makeBlob(schema: "https://www.arri.com/schema/json/camera/camera_device/v1-0-0",
                             json: #"{"cameraModel":"ARRI ALEXA 35"}"#))
        let blobs = ARRIJSONParser.findEmbeddedJSONBlobs(in: data)
        XCTAssertEqual(blobs.count, 2)
        // Sorted alphabetically by schema name → camera_device first.
        XCTAssertEqual(blobs[0].schema, "camera_device")
        XCTAssertEqual(blobs[1].schema, "slate_info")
    }

    func testFindEmbeddedJSONBlobsResolvesNestedSchemaPath() {
        // monitoring/frameline/v1-0-0 → "frameline"
        let blob = makeBlob(schema: "https://www.arri.com/schema/json/camera/monitoring/frameline/v1-0-0",
                            json: #"{"framelineFilename":"None.XML"}"#)
        let blobs = ARRIJSONParser.findEmbeddedJSONBlobs(in: blob)
        XCTAssertEqual(blobs.first?.schema, "frameline")
    }

    func testFindEmbeddedJSONBlobsSkipsMalformedJSON() {
        var bytes = Data([0x80, 0x7B])
        let payload = "not json here".data(using: .utf8)!
        bytes.append(uint16BE(UInt16(payload.count)))
        bytes.append(payload)
        let blobs = ARRIJSONParser.findEmbeddedJSONBlobs(in: bytes)
        XCTAssertTrue(blobs.isEmpty)
    }

    func testFindEmbeddedJSONBlobsSkipsTagsThatLookLikeJSONButAreNot() {
        // 0x80 0x7B happens to also be the LE byte order of a UTF-16 'À' or
        // any number of unrelated patterns. Make sure a payload that doesn't
        // start with `{` or `[` is rejected even when the tag bytes match.
        var bytes = Data([0x80, 0x7B])
        let payload: [UInt8] = [0x00, 0x01, 0x02, 0x03] // non-JSON bytes
        bytes.append(uint16BE(UInt16(payload.count)))
        bytes.append(Data(payload))
        let blobs = ARRIJSONParser.findEmbeddedJSONBlobs(in: bytes)
        XCTAssertTrue(blobs.isEmpty)
    }

    func testFindEmbeddedJSONBlobsReturnsEmptyForUnrelatedData() {
        let blobs = ARRIJSONParser.findEmbeddedJSONBlobs(in: Data(repeating: 0xFF, count: 4096))
        XCTAssertTrue(blobs.isEmpty)
    }

    // MARK: - Merge — typed slot mapping

    func testMergeMapsCameraDeviceToTypedSlots() {
        let blob = ARRIJSONParser.Blob(schema: "camera_device", json: [
            "cameraModel": "ARRI ALEXA 35",
            "cameraSerialNumber": "70253",
            "cameraSoftwarePackageName": "5.01.00"
        ])
        var cam = CameraMetadata()
        ARRIJSONParser.merge([blob], into: &cam)
        XCTAssertEqual(cam.deviceModelName, "ARRI ALEXA 35")
        XCTAssertEqual(cam.deviceSerialNumber, "70253")
        XCTAssertTrue(cam.userMetaNames.contains("Camera:Firmware"))
        let idx = cam.userMetaNames.firstIndex(of: "Camera:Firmware")!
        XCTAssertEqual(cam.userMetaContents[idx], "5.01.00")
    }

    func testMergeMapsLensModelToTypedSlot() {
        let blob = ARRIJSONParser.Blob(schema: "lens_device", json: [
            "lensModel": "ARRI SZ65-300 T2.8",
            "lensSerialNumber": "132674",
            "lensSqueezeFactor": "1/1"
        ])
        var cam = CameraMetadata()
        ARRIJSONParser.merge([blob], into: &cam)
        XCTAssertEqual(cam.lensModelName, "ARRI SZ65-300 T2.8")
        XCTAssertTrue(cam.userMetaNames.contains("Lens:SerialNumber"))
        XCTAssertTrue(cam.userMetaNames.contains("Lens:SqueezeFactor"))
    }

    func testMergeDoesNotOverwriteExistingTypedFields() {
        let blob = ARRIJSONParser.Blob(schema: "camera_device", json: [
            "cameraModel": "ARRI ALEXA 35"
        ])
        var cam = CameraMetadata(deviceModelName: "Pre-set Model")
        ARRIJSONParser.merge([blob], into: &cam)
        XCTAssertEqual(cam.deviceModelName, "Pre-set Model")
    }

    func testMergeSetsManufacturerFromSlateProductionCompany() {
        let blob = ARRIJSONParser.Blob(schema: "slate_info", json: [
            "productionCompany": "ARRI",
            "scene": "10A"
        ])
        var cam = CameraMetadata()
        ARRIJSONParser.merge([blob], into: &cam)
        XCTAssertEqual(cam.deviceManufacturer, "ARRI")
    }

    func testMergeDoesNotForceManufacturerWhenSlateMissingARRI() {
        let blob = ARRIJSONParser.Blob(schema: "slate_info", json: [
            "productionCompany": "Some Indie Co",
            "scene": "10A"
        ])
        var cam = CameraMetadata()
        ARRIJSONParser.merge([blob], into: &cam)
        XCTAssertNil(cam.deviceManufacturer)
    }

    // MARK: - Merge — userMeta fan-out

    func testMergePushesSlateFieldsToUserMeta() {
        let blob = ARRIJSONParser.Blob(schema: "slate_info", json: [
            "scene": "10A",
            "take": "19",
            "director": "DWS Dir",
            "cinematographer": "DWS Cin"
        ])
        var cam = CameraMetadata()
        ARRIJSONParser.merge([blob], into: &cam)
        XCTAssertTrue(cam.userMetaNames.contains("Slate:Scene"))
        XCTAssertTrue(cam.userMetaNames.contains("Slate:Take"))
        XCTAssertTrue(cam.userMetaNames.contains("Slate:Director"))
        XCTAssertTrue(cam.userMetaNames.contains("Slate:Cinematographer"))
        let sceneIdx = cam.userMetaNames.firstIndex(of: "Slate:Scene")!
        XCTAssertEqual(cam.userMetaContents[sceneIdx], "10A")
    }

    func testMergeFlattensUserInfoArray() {
        let blob = ARRIJSONParser.Blob(schema: "slate_info", json: [
            "userInfo": [
                ["key": "com.arri.metadata.UserInfo1", "value": "DWS 1"],
                ["key": "com.arri.metadata.UserInfo2", "value": "DWS 2"]
            ]
        ])
        var cam = CameraMetadata()
        ARRIJSONParser.merge([blob], into: &cam)
        XCTAssertTrue(cam.userMetaNames.contains("Slate:User:UserInfo1"))
        XCTAssertTrue(cam.userMetaNames.contains("Slate:User:UserInfo2"))
        let i1 = cam.userMetaNames.firstIndex(of: "Slate:User:UserInfo1")!
        XCTAssertEqual(cam.userMetaContents[i1], "DWS 1")
    }

    func testMergeRecordingMediumStripsPrefix() {
        let blob = ARRIJSONParser.Blob(schema: "recording_medium", json: [
            "mediumModelName": "CDXCDC0192M320N40A",
            "mediumSerialNumber": "37300614/X02TX01Q500587",
            "mediumType": "Codex Compact Drive"
        ])
        var cam = CameraMetadata()
        ARRIJSONParser.merge([blob], into: &cam)
        XCTAssertTrue(cam.userMetaNames.contains("Medium:ModelName"))
        XCTAssertTrue(cam.userMetaNames.contains("Medium:SerialNumber"))
        XCTAssertTrue(cam.userMetaNames.contains("Medium:Type"))
        let typeIdx = cam.userMetaNames.firstIndex(of: "Medium:Type")!
        XCTAssertEqual(cam.userMetaContents[typeIdx], "Codex Compact Drive")
    }

    func testMergeFramelineFlattensRectArray() {
        let blob = ARRIJSONParser.Blob(schema: "frameline", json: [
            "framelineFilename": "None.XML",
            "framelineRect": [
                ["x": 0, "y": 0, "w": 100, "h": 50],
                ["x": 10, "y": 5, "w": 80, "h": 40]
            ]
        ])
        var cam = CameraMetadata()
        ARRIJSONParser.merge([blob], into: &cam)
        XCTAssertTrue(cam.userMetaNames.contains("Frameline:File"))
        XCTAssertTrue(cam.userMetaNames.contains("Frameline:Rect[0]"))
        XCTAssertTrue(cam.userMetaNames.contains("Frameline:Rect[1]"))
    }

    func testMergeLUT3DStripsPrefix() {
        let blob = ARRIJSONParser.Blob(schema: "custom_lut3d_design", json: [
            "lut3DDrtType": "ARRI",
            "lut3DID": "arrimxf_llk_3d_lut_rec709"
        ])
        var cam = CameraMetadata()
        ARRIJSONParser.merge([blob], into: &cam)
        XCTAssertTrue(cam.userMetaNames.contains("LUT:DrtType"))
        XCTAssertTrue(cam.userMetaNames.contains("LUT:ID"))
    }

    // MARK: - Value formatting

    func testStringifyHandlesNumericTypes() {
        XCTAssertEqual(ARRIJSONParser.stringify(NSNumber(value: 24)), "24")
        XCTAssertEqual(ARRIJSONParser.stringify(NSNumber(value: 24.5)), "24.5")
    }

    func testStringifyDropsEmptyStringsAndNull() {
        XCTAssertNil(ARRIJSONParser.stringify(""))
        XCTAssertNil(ARRIJSONParser.stringify(NSNull()))
    }

    func testStringifyHandlesBooleans() {
        XCTAssertEqual(ARRIJSONParser.stringify(true), "true")
        XCTAssertEqual(ARRIJSONParser.stringify(false), "false")
    }

    func testStringifyEncodesNestedJSON() {
        let value: [String: Any] = ["min": 1800, "max": -1]
        let s = ARRIJSONParser.stringify(value)
        XCTAssertNotNil(s)
        // Sorted keys → "max" comes before "min" alphabetically.
        XCTAssertEqual(s, #"{"max":-1,"min":1800}"#)
    }

    // MARK: - Helpers

    /// Build a minimal `\x80\x7B <JSON UTF-8>` + `\x80\x7C <schema URL UTF-16BE>`
    /// byte sequence — the two KLV local-set triplets every ARRI metadata set
    /// emits, in the order observed in real ALEXA 35 footage. The schema URL
    /// follows the JSON payload (not precedes it), which is how the parser
    /// pairs them.
    private func makeBlob(schema: String, json: String) -> Data {
        var data = Data()
        // JSON payload triplet (tag 0x807B, UTF-8 value) — emitted FIRST.
        data.append(Data([0x80, 0x7B]))
        let jsonBytes = json.data(using: .utf8)!
        data.append(uint16BE(UInt16(jsonBytes.count)))
        data.append(jsonBytes)
        // Schema URL triplet (tag 0x807C, UTF-16BE value) — emitted AFTER.
        data.append(Data([0x80, 0x7C]))
        let schemaBytes = utf16BE(schema)
        data.append(uint16BE(UInt16(schemaBytes.count)))
        data.append(schemaBytes)
        return data
    }

    private func uint16BE(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    private func utf16BE(_ s: String) -> Data {
        var out = Data()
        for scalar in s.unicodeScalars {
            // Restrict to BMP — fine for ARRI schema URLs (ASCII only).
            let v = UInt16(scalar.value & 0xFFFF)
            out.append(UInt8(v >> 8))
            out.append(UInt8(v & 0xFF))
        }
        return out
    }
}
