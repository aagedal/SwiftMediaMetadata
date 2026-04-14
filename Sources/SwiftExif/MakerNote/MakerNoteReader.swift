import Foundation

/// Dispatches MakerNote parsing to the appropriate manufacturer-specific parser.
public struct MakerNoteReader: Sendable {

    /// Parse MakerNote from the ExifIFD's tag 0x927C.
    /// - Parameters:
    ///   - exifIFD: The Exif sub-IFD containing the MakerNote tag.
    ///   - make: The camera Make string from IFD0 (used for manufacturer identification).
    ///   - byteOrder: The TIFF byte order.
    /// - Returns: Parsed MakerNote data, or nil if absent or unrecognized.
    public static func parse(
        from exifIFD: IFD,
        make: String?,
        byteOrder: ByteOrder
    ) -> MakerNoteData? {
        guard let entry = exifIFD.entry(for: ExifTag.makerNote) else { return nil }

        let rawData = entry.valueData
        guard rawData.count >= 12 else { return nil }

        let manufacturer = identifyManufacturer(make: make)
        guard manufacturer != .unknown else { return nil }

        let tags: [String: MakerNoteValue]
        switch manufacturer {
        case .canon:
            tags = CanonMakerNote.parse(data: rawData, byteOrder: byteOrder)
        case .nikon:
            tags = NikonMakerNote.parse(data: rawData, parentByteOrder: byteOrder)
        case .sony:
            tags = SonyMakerNote.parse(data: rawData, byteOrder: byteOrder)
        case .fujifilm:
            tags = FujifilmMakerNote.parse(data: rawData, parentByteOrder: byteOrder)
        case .olympus:
            tags = OlympusMakerNote.parse(data: rawData, byteOrder: byteOrder)
        case .panasonic:
            tags = PanasonicMakerNote.parse(data: rawData, byteOrder: byteOrder)
        case .unknown:
            return nil
        }

        guard !tags.isEmpty else { return nil }

        return MakerNoteData(manufacturer: manufacturer, tags: tags, rawData: rawData)
    }

    private static func identifyManufacturer(make: String?) -> MakerNoteManufacturer {
        guard let make = make?.lowercased() else { return .unknown }
        if make.hasPrefix("canon") { return .canon }
        if make.hasPrefix("nikon") { return .nikon }
        if make.hasPrefix("sony") { return .sony }
        if make.hasPrefix("fujifilm") || make.hasPrefix("fuji") { return .fujifilm }
        if make.hasPrefix("olympus") || make.hasPrefix("om ") { return .olympus }
        if make.hasPrefix("panasonic") { return .panasonic }
        return .unknown
    }
}
