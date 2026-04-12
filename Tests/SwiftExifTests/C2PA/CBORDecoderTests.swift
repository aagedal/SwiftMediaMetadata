import XCTest
@testable import SwiftExif

final class CBORDecoderTests: XCTestCase {

    // MARK: - Unsigned Integers

    func testDecodeSmallUnsignedInt() throws {
        // CBOR: 0x00 = 0, 0x01 = 1, 0x17 = 23
        XCTAssertEqual(try CBORDecoder.decode(from: Data([0x00])).unsignedIntValue, 0)
        XCTAssertEqual(try CBORDecoder.decode(from: Data([0x01])).unsignedIntValue, 1)
        XCTAssertEqual(try CBORDecoder.decode(from: Data([0x17])).unsignedIntValue, 23)
    }

    func testDecodeUInt8() throws {
        // CBOR: 0x18 0x18 = 24, 0x18 0xFF = 255
        XCTAssertEqual(try CBORDecoder.decode(from: Data([0x18, 0x18])).unsignedIntValue, 24)
        XCTAssertEqual(try CBORDecoder.decode(from: Data([0x18, 0xFF])).unsignedIntValue, 255)
    }

    func testDecodeUInt16() throws {
        // CBOR: 0x19 0x01 0x00 = 256
        XCTAssertEqual(try CBORDecoder.decode(from: Data([0x19, 0x01, 0x00])).unsignedIntValue, 256)
    }

    func testDecodeUInt32() throws {
        // CBOR: 0x1A 0x00 0x01 0x00 0x00 = 65536
        XCTAssertEqual(try CBORDecoder.decode(from: Data([0x1A, 0x00, 0x01, 0x00, 0x00])).unsignedIntValue, 65536)
    }

    // MARK: - Negative Integers

    func testDecodeNegativeInt() throws {
        // CBOR: 0x20 = -1, 0x37 = -24
        XCTAssertEqual(try CBORDecoder.decode(from: Data([0x20])).negativeIntValue, -1)
        XCTAssertEqual(try CBORDecoder.decode(from: Data([0x37])).negativeIntValue, -24)
    }

    func testDecodeNegativeInt8() throws {
        // CBOR: 0x38 0x63 = -100
        XCTAssertEqual(try CBORDecoder.decode(from: Data([0x38, 0x63])).negativeIntValue, -100)
    }

    // MARK: - Byte Strings

    func testDecodeByteString() throws {
        // CBOR: 0x44 followed by 4 bytes
        let data = Data([0x44, 0xDE, 0xAD, 0xBE, 0xEF])
        let result = try CBORDecoder.decode(from: data)
        XCTAssertEqual(result.byteStringValue, Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testDecodeEmptyByteString() throws {
        let result = try CBORDecoder.decode(from: Data([0x40]))
        XCTAssertEqual(result.byteStringValue, Data())
    }

    // MARK: - Text Strings

    func testDecodeTextString() throws {
        // CBOR: 0x65 "hello"
        let data = Data([0x65, 0x68, 0x65, 0x6C, 0x6C, 0x6F])
        let result = try CBORDecoder.decode(from: data)
        XCTAssertEqual(result.textStringValue, "hello")
    }

    func testDecodeEmptyTextString() throws {
        let result = try CBORDecoder.decode(from: Data([0x60]))
        XCTAssertEqual(result.textStringValue, "")
    }

    func testDecodeUTF8TextString() throws {
        // "ø" = 0xC3 0xB8 in UTF-8
        let data = Data([0x62, 0xC3, 0xB8])
        let result = try CBORDecoder.decode(from: data)
        XCTAssertEqual(result.textStringValue, "ø")
    }

    // MARK: - Arrays

    func testDecodeArray() throws {
        // CBOR: [1, 2, 3] = 0x83 0x01 0x02 0x03
        let data = Data([0x83, 0x01, 0x02, 0x03])
        let result = try CBORDecoder.decode(from: data)
        guard let array = result.arrayValue else {
            XCTFail("Expected array"); return
        }
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array[0].unsignedIntValue, 1)
        XCTAssertEqual(array[1].unsignedIntValue, 2)
        XCTAssertEqual(array[2].unsignedIntValue, 3)
    }

    func testDecodeEmptyArray() throws {
        let result = try CBORDecoder.decode(from: Data([0x80]))
        XCTAssertEqual(result.arrayValue?.count, 0)
    }

    // MARK: - Maps

    func testDecodeMap() throws {
        // CBOR: {"a": 1} = 0xA1 0x61 0x61 0x01
        let data = Data([0xA1, 0x61, 0x61, 0x01])
        let result = try CBORDecoder.decode(from: data)
        XCTAssertEqual(result["a"]?.unsignedIntValue, 1)
    }

    func testDecodeMapMultipleKeys() throws {
        // {"a": 1, "b": 2} = 0xA2 0x61 0x61 0x01 0x61 0x62 0x02
        let data = Data([0xA2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x02])
        let result = try CBORDecoder.decode(from: data)
        XCTAssertEqual(result["a"]?.unsignedIntValue, 1)
        XCTAssertEqual(result["b"]?.unsignedIntValue, 2)
    }

    func testDecodeMapWithIntegerKeys() throws {
        // {1: "alg"} = 0xA1 0x01 0x63 0x61 0x6C 0x67
        let data = Data([0xA1, 0x01, 0x63, 0x61, 0x6C, 0x67])
        let result = try CBORDecoder.decode(from: data)
        XCTAssertEqual(result[intKey: 1]?.textStringValue, "alg")
    }

    // MARK: - Tags

    func testDecodeTag() throws {
        // Tag 18 wrapping an integer 42 = 0xD2 0x18 0x2A
        let data = Data([0xD2, 0x18, 0x2A])
        let result = try CBORDecoder.decode(from: data)
        guard let tagged = result.taggedValue else {
            XCTFail("Expected tagged value"); return
        }
        XCTAssertEqual(tagged.tag, 18)
        XCTAssertEqual(tagged.value.unsignedIntValue, 42)
    }

    // MARK: - Simple Values

    func testDecodeBoolean() throws {
        XCTAssertEqual(try CBORDecoder.decode(from: Data([0xF4])).boolValue, false)
        XCTAssertEqual(try CBORDecoder.decode(from: Data([0xF5])).boolValue, true)
    }

    func testDecodeNull() throws {
        let result = try CBORDecoder.decode(from: Data([0xF6]))
        if case .null = result {
            // OK
        } else {
            XCTFail("Expected null")
        }
    }

    // MARK: - Floats

    func testDecodeFloat32() throws {
        // float32 3.14 ≈ 0x4048F5C3
        let data = Data([0xFA, 0x40, 0x48, 0xF5, 0xC3])
        let result = try CBORDecoder.decode(from: data)
        if case .float(let v) = result {
            XCTAssertEqual(v, 3.14, accuracy: 0.001)
        } else {
            XCTFail("Expected float")
        }
    }

    func testDecodeFloat64() throws {
        // float64 1.0 = 0x3FF0000000000000
        let data = Data([0xFB, 0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let result = try CBORDecoder.decode(from: data)
        if case .float(let v) = result {
            XCTAssertEqual(v, 1.0)
        } else {
            XCTFail("Expected float")
        }
    }

    // MARK: - Nested Structures

    func testDecodeNestedMapArray() throws {
        // {"actions": [{"action": "c2pa.created"}]}
        // Build CBOR manually:
        // map(1) { text(7)"actions": array(1) [ map(1) { text(6)"action": text(12)"c2pa.created" } ] }
        var data = Data()
        data.append(0xA1) // map(1)
        data.append(contentsOf: cborTextString("actions"))
        data.append(0x81) // array(1)
        data.append(0xA1) // map(1)
        data.append(contentsOf: cborTextString("action"))
        data.append(contentsOf: cborTextString("c2pa.created"))

        let result = try CBORDecoder.decode(from: data)
        let actions = result["actions"]?.arrayValue
        XCTAssertEqual(actions?.count, 1)
        XCTAssertEqual(actions?.first?["action"]?.textStringValue, "c2pa.created")
    }

    // MARK: - Error Cases

    func testDecodeEmptyDataThrows() {
        XCTAssertThrowsError(try CBORDecoder.decode(from: Data()))
    }

    func testDecodeTruncatedDataThrows() {
        // UInt16 but only 1 byte of payload
        XCTAssertThrowsError(try CBORDecoder.decode(from: Data([0x19, 0x01])))
    }

    // MARK: - Helpers

    private func cborTextString(_ string: String) -> [UInt8] {
        let utf8 = [UInt8](string.utf8)
        let count = utf8.count
        if count <= 23 {
            return [0x60 | UInt8(count)] + utf8
        } else if count <= 255 {
            return [0x78, UInt8(count)] + utf8
        } else {
            return [0x79, UInt8(count >> 8), UInt8(count & 0xFF)] + utf8
        }
    }
}
