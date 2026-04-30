import XCTest
@testable import SwiftExif

final class AAESidecarTests: XCTestCase {

    func testReadXMLPlist() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>adjustmentBaseVersion</key>
            <integer>0</integer>
            <key>adjustmentEditorBundleID</key>
            <string>com.apple.photo</string>
            <key>adjustmentFormatIdentifier</key>
            <string>com.apple.photo</string>
            <key>adjustmentFormatVersion</key>
            <string>1.5</string>
            <key>adjustmentRenderTypes</key>
            <integer>2</integer>
        </dict>
        </plist>
        """
        let data = Data(xml.utf8)
        let aae = try AAESidecar.read(data)
        XCTAssertEqual(aae.adjustmentBaseVersion, 0)
        XCTAssertEqual(aae.adjustmentEditorBundleID, "com.apple.photo")
        XCTAssertEqual(aae.adjustmentFormatIdentifier, "com.apple.photo")
        XCTAssertEqual(aae.adjustmentFormatVersion, "1.5")
        XCTAssertEqual(aae.adjustmentRenderTypes, 2)
    }

    func testReadBinaryPlist() throws {
        // Round-trip via PropertyListSerialization to produce a valid bplist00.
        let dict: [String: Any] = [
            "adjustmentBaseVersion": 0,
            "adjustmentEditorBundleID": "com.apple.photo",
            "adjustmentFormatIdentifier": "com.apple.photo",
            "adjustmentFormatVersion": "1.5",
            "adjustmentRenderTypes": 1,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        let aae = try AAESidecar.read(data)
        XCTAssertEqual(aae.adjustmentBaseVersion, 0)
        XCTAssertEqual(aae.adjustmentEditorBundleID, "com.apple.photo")
        XCTAssertEqual(aae.adjustmentRenderTypes, 1)
    }

    func testInvalidDataThrows() {
        XCTAssertThrowsError(try AAESidecar.read(Data([0x01, 0x02, 0x03]))) { error in
            guard let metadataError = error as? MetadataError else {
                XCTFail("Expected MetadataError, got \(error)"); return
            }
            if case .invalidAAE = metadataError { /* ok */ }
            else { XCTFail("Expected .invalidAAE, got \(metadataError)") }
        }
    }
}
