import Foundation

/// Parsed Exif metadata from a JPEG file.
public struct ExifData: Equatable, Sendable {
    public var ifd0: IFD?
    public var ifd1: IFD?       // Thumbnail IFD
    public var exifIFD: IFD?
    public var gpsIFD: IFD?
    public var byteOrder: ByteOrder

    public init(byteOrder: ByteOrder = .bigEndian) {
        self.byteOrder = byteOrder
    }

    // MARK: - High-Level Accessors

    public var make: String? {
        ifd0?.entry(for: ExifTag.make)?.stringValue(endian: byteOrder)
    }

    public var model: String? {
        ifd0?.entry(for: ExifTag.model)?.stringValue(endian: byteOrder)
    }

    public var dateTime: String? {
        ifd0?.entry(for: ExifTag.dateTime)?.stringValue(endian: byteOrder)
    }

    public var dateTimeOriginal: String? {
        exifIFD?.entry(for: ExifTag.dateTimeOriginal)?.stringValue(endian: byteOrder)
    }

    public var orientation: UInt16? {
        ifd0?.entry(for: ExifTag.orientation)?.uint16Value(endian: byteOrder)
    }

    public var exposureTime: (numerator: UInt32, denominator: UInt32)? {
        exifIFD?.entry(for: ExifTag.exposureTime)?.rationalValue(endian: byteOrder)
    }

    public var fNumber: (numerator: UInt32, denominator: UInt32)? {
        exifIFD?.entry(for: ExifTag.fNumber)?.rationalValue(endian: byteOrder)
    }

    public var isoSpeed: UInt16? {
        exifIFD?.entry(for: ExifTag.isoSpeedRatings)?.uint16Value(endian: byteOrder)
    }

    public var focalLength: (numerator: UInt32, denominator: UInt32)? {
        exifIFD?.entry(for: ExifTag.focalLength)?.rationalValue(endian: byteOrder)
    }

    public var software: String? {
        ifd0?.entry(for: ExifTag.software)?.stringValue(endian: byteOrder)
    }

    public var copyright: String? {
        ifd0?.entry(for: ExifTag.copyright)?.stringValue(endian: byteOrder)
    }

    public var artist: String? {
        ifd0?.entry(for: ExifTag.artist)?.stringValue(endian: byteOrder)
    }

    public var lensModel: String? {
        exifIFD?.entry(for: ExifTag.lensModel)?.stringValue(endian: byteOrder)
    }

    // MARK: - GPS

    public var gpsLatitude: Double? {
        guard let ref = gpsIFD?.entry(for: ExifTag.gpsLatitudeRef)?.stringValue(endian: byteOrder),
              let lat = gpsIFD?.entry(for: ExifTag.gpsLatitude) else { return nil }
        let degrees = parseGPSCoordinate(lat, endian: byteOrder)
        return ref == "S" ? -degrees : degrees
    }

    public var gpsLongitude: Double? {
        guard let ref = gpsIFD?.entry(for: ExifTag.gpsLongitudeRef)?.stringValue(endian: byteOrder),
              let lon = gpsIFD?.entry(for: ExifTag.gpsLongitude) else { return nil }
        let degrees = parseGPSCoordinate(lon, endian: byteOrder)
        return ref == "W" ? -degrees : degrees
    }

    private func parseGPSCoordinate(_ entry: IFDEntry, endian: ByteOrder) -> Double {
        guard entry.type == .rational, entry.count == 3, entry.valueData.count >= 24 else { return 0 }
        var reader = BinaryReader(data: entry.valueData)
        guard let degNum = try? reader.readUInt32(endian: endian),
              let degDen = try? reader.readUInt32(endian: endian),
              let minNum = try? reader.readUInt32(endian: endian),
              let minDen = try? reader.readUInt32(endian: endian),
              let secNum = try? reader.readUInt32(endian: endian),
              let secDen = try? reader.readUInt32(endian: endian) else { return 0 }
        let deg = degDen > 0 ? Double(degNum) / Double(degDen) : 0
        let min = minDen > 0 ? Double(minNum) / Double(minDen) : 0
        let sec = secDen > 0 ? Double(secNum) / Double(secDen) : 0
        return deg + min / 60.0 + sec / 3600.0
    }
}
