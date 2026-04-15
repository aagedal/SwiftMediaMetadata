import Foundation

/// Parsed Canon CR3 file structure.
/// CR3 is ISOBMFF-based with Canon-specific uuid boxes for metadata.
public struct CR3File: Sendable, Equatable {
    /// All top-level boxes (ftyp, moov, uuid, mdat, etc.).
    public var boxes: [ISOBMFFBox]

    /// JPEG thumbnail data from THMB box (160x120 or 320x214).
    public var thumbnailData: Data?

    /// JPEG preview data from PRVW box (1620x1080).
    public var previewData: Data?

    /// Original file data (needed for round-trip writing since mdat is skipped during parse).
    public var originalData: Data?

    public init(boxes: [ISOBMFFBox] = [], thumbnailData: Data? = nil, previewData: Data? = nil, originalData: Data? = nil) {
        self.boxes = boxes
        self.thumbnailData = thumbnailData
        self.previewData = previewData
        self.originalData = originalData
    }
}

/// Canon CR3 UUID constants.
enum CR3UUID {
    /// Canon metadata container (contains CMT1-4, THMB, CNCV).
    /// 85c0b687-820f-11e0-8111-f4ce462b6a48
    static let canonMetadata = Data([
        0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0,
        0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48
    ])

    /// Preview container (contains PRVW).
    /// eaf42b5e-1c98-4b88-b9fb-b7dc406e4d16
    static let canonPreview = Data([
        0xEA, 0xF4, 0x2B, 0x5E, 0x1C, 0x98, 0x4B, 0x88,
        0xB9, 0xFB, 0xB7, 0xDC, 0x40, 0x6E, 0x4D, 0x16
    ])

    /// XMP metadata.
    /// be7acfcb-97a9-42e8-9c71-999491e3afac
    static let xmpUUID = Data([
        0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8,
        0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC
    ])
}
