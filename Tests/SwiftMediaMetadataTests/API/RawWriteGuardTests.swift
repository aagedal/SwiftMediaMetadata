import XCTest
@testable import SwiftMediaMetadata

/// Regression: embedding metadata into a proprietary TIFF-based RAW (ARW/NEF/CR2/…)
/// must be refused by default. Rewriting the container via `TIFFWriter` cannot preserve
/// maker-private structures such as Sony's encrypted SR2Private white-balance block, so
/// the write corrupts the file (broken RAW decode + raster bloat). DNG/GPR (Adobe's open,
/// writable TIFF spec) and plain TIFF stay writable, and an explicit opt-in overrides.
///
/// A minimal in-memory TIFF detects as plain `.tiff`, so the proprietary-RAW classification
/// here comes from the target URL's extension — the guard's content-detection branch takes
/// the same path once a real ARW/NEF is parsed.
final class RawWriteGuardTests: XCTestCase {

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftexif_rawguard_\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    private func loadTIFF() throws -> ImageMetadata {
        var metadata = try ImageMetadata.read(from: TestFixtures.tiffWithExif())
        if metadata.xmp == nil { metadata.xmp = XMPData() }
        metadata.xmp?.setValue(.simple("4"),
                               namespace: "http://ns.adobe.com/xap/1.0/", property: "Rating")
        return metadata
    }

    func testRefusesEmbedIntoProprietaryRaw() throws {
        let metadata = try loadTIFF()
        for ext in ["arw", "nef", "nrw", "cr2", "rw2", "orf", "pef", "srw"] {
            let url = tempURL(ext)
            XCTAssertThrowsError(try metadata.write(to: url), "Writing to .\(ext) must be refused") { error in
                guard case MetadataError.rawWriteUnsupported(let format) = error else {
                    return XCTFail("Expected .rawWriteUnsupported for .\(ext), got \(error)")
                }
                XCTAssertEqual(format.rawValue, ext)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "A refused write must not create .\(ext)")
        }
    }

    func testAllowsPlainTIFFAndDNG() throws {
        let metadata = try loadTIFF()
        for ext in ["tif", "tiff", "dng"] {
            let url = tempURL(ext)
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertNoThrow(try metadata.write(to: url), "Writing to .\(ext) must be allowed")
        }
    }

    func testOptInOverridesGuard() throws {
        let metadata = try loadTIFF()
        let url = tempURL("arw")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(
            try metadata.write(to: url, options: .init(allowUnsafeRawEmbed: true)),
            "allowUnsafeRawEmbed must permit the write"
        )
    }
}
