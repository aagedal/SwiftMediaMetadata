import Foundation

extension ImageMetadata {
    // MARK: - Lossless Orientation Operations

    /// Set the EXIF orientation tag directly.
    /// - Parameter value: EXIF orientation value (1-8).
    public mutating func setOrientation(_ value: UInt16) {
        guard value >= 1 && value <= 8 else { return }
        let byteOrder = exif?.byteOrder ?? .bigEndian
        if exif == nil { exif = ExifData(byteOrder: byteOrder) }

        let entry = buildOrientationEntry(value, endian: byteOrder)

        // Update IFD0
        let ifd0Offset = exif?.ifd0?.nextIFDOffset ?? 0
        var entries = (exif?.ifd0?.entries ?? []).filter { $0.tag != ExifTag.orientation }
        entries.append(entry)
        exif?.ifd0 = IFD(entries: entries, nextIFDOffset: ifd0Offset)

        // Update IFD1 (thumbnail) if present
        if let ifd1 = exif?.ifd1 {
            var thumbEntries = ifd1.entries.filter { $0.tag != ExifTag.orientation }
            thumbEntries.append(entry)
            exif?.ifd1 = IFD(entries: thumbEntries, nextIFDOffset: ifd1.nextIFDOffset)
        }
    }

    /// Reset orientation to normal (1 = Horizontal).
    public mutating func resetOrientation() {
        setOrientation(1)
    }

    /// Rotate the image 90° clockwise by updating the orientation tag.
    public mutating func rotateClockwise() {
        let current = exif?.orientation ?? 1
        setOrientation(OrientationTransform.compose(current: current, operation: .rotateClockwise))
    }

    /// Rotate the image 90° counter-clockwise by updating the orientation tag.
    public mutating func rotateCounterClockwise() {
        let current = exif?.orientation ?? 1
        setOrientation(OrientationTransform.compose(current: current, operation: .rotateCounterClockwise))
    }

    /// Flip the image horizontally by updating the orientation tag.
    public mutating func flipHorizontal() {
        let current = exif?.orientation ?? 1
        setOrientation(OrientationTransform.compose(current: current, operation: .flipHorizontal))
    }

    /// Flip the image vertically by updating the orientation tag.
    public mutating func flipVertical() {
        let current = exif?.orientation ?? 1
        setOrientation(OrientationTransform.compose(current: current, operation: .flipVertical))
    }

    private func buildOrientationEntry(_ value: UInt16, endian: ByteOrder) -> IFDEntry {
        var writer = BinaryWriter(capacity: 2)
        writer.writeUInt16(value, endian: endian)
        return IFDEntry(tag: ExifTag.orientation, type: .short, count: 1, valueData: writer.data)
    }

    // MARK: - MakerNote Writing

    /// Set a MakerNote tag value.
    public mutating func setMakerNoteTag(_ key: String, value: MakerNoteValue) {
        exif?.makerNote?.setTag(key, value: value)
    }

    // MARK: - Direct GPS Writing

    /// Set GPS coordinates directly on the image.
    /// - Parameters:
    ///   - latitude: Latitude in decimal degrees (-90...90, positive = North).
    ///   - longitude: Longitude in decimal degrees (-180...180, positive = East).
    ///   - altitude: Altitude in meters above sea level. Negative values are below sea level.
    ///   - timestamp: GPS fix timestamp. Defaults to current time.
    public mutating func setGPS(
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        timestamp: Date = Date()
    ) {
        let trackpoint = GPXTrackpoint(
            latitude: latitude,
            longitude: longitude,
            elevation: altitude,
            timestamp: timestamp
        )
        let byteOrder = exif?.byteOrder ?? .bigEndian
        if exif == nil { exif = ExifData(byteOrder: byteOrder) }
        exif?.gpsIFD = GPXGeotagger.buildGPSIFD(from: trackpoint, byteOrder: byteOrder)
    }

    /// Remove all GPS data from the image.
    public mutating func removeGPS() {
        stripGPS()
    }

    /// Reverse-geocode the image's GPS coordinates and fill IPTC/XMP location fields.
    /// - Parameters:
    ///   - geocoder: The reverse geocoder to use. Defaults to the shared instance.
    ///   - overwrite: If true, overwrites existing location fields. Default false.
    /// - Returns: The resolved GeoLocation, or nil if no GPS data or no match found.
    @discardableResult
    public mutating func fillLocationFromGPS(
        geocoder: ReverseGeocoder = .shared,
        overwrite: Bool = false
    ) -> GeoLocation? {
        guard let lat = exif?.gpsLatitude, let lon = exif?.gpsLongitude else { return nil }
        guard let location = geocoder.lookup(latitude: lat, longitude: lon) else { return nil }

        if overwrite || iptc.city == nil {
            iptc.city = location.city
        }
        if overwrite || iptc.provinceState == nil {
            iptc.provinceState = location.region
        }
        if overwrite || iptc.countryName == nil {
            iptc.countryName = location.country
        }
        if overwrite || iptc.countryCode == nil {
            iptc.countryCode = location.countryCode
        }

        // Also sync to XMP
        if xmp == nil { xmp = XMPData() }
        if overwrite || xmp?.city == nil {
            xmp?.city = location.city
        }
        if overwrite || xmp?.state == nil {
            xmp?.state = location.region
        }
        if overwrite || xmp?.country == nil {
            xmp?.country = location.country
        }

        return location
    }

    // MARK: - GPX Geotagging

    /// Apply GPS coordinates from a GPX track by matching DateTimeOriginal.
    /// - Parameters:
    ///   - track: Parsed GPX track with timestamped points.
    ///   - maxOffset: Maximum time difference to accept in seconds. Default 60.
    ///   - timeZoneOffset: Camera timezone offset from UTC in seconds. Default 0.
    ///     If 0, automatically reads OffsetTimeOriginal from EXIF (e.g. "+02:00") when available.
    /// - Returns: true if GPS was applied, false if no match found.
    @discardableResult
    public mutating func applyGPX(
        _ track: GPXTrack,
        maxOffset: TimeInterval = 60,
        timeZoneOffset: TimeInterval = 0
    ) -> Bool {
        guard let dateTimeOriginal = exif?.dateTimeOriginal else { return false }

        // Auto-detect timezone from OffsetTimeOriginal if no explicit offset provided
        var effectiveOffset = timeZoneOffset
        if effectiveOffset == 0, let offsetStr = exif?.offsetTimeOriginal {
            effectiveOffset = Self.parseTimezoneOffset(offsetStr) ?? 0
        }

        guard let matched = GPXGeotagger.match(
            dateTimeOriginal: dateTimeOriginal,
            track: track,
            maxOffset: maxOffset,
            timeZoneOffset: effectiveOffset
        ) else { return false }

        let byteOrder = exif?.byteOrder ?? .bigEndian
        if exif == nil { exif = ExifData(byteOrder: byteOrder) }
        exif?.gpsIFD = GPXGeotagger.buildGPSIFD(from: matched, byteOrder: byteOrder)
        return true
    }

    /// Parse an EXIF OffsetTime string (e.g. "+02:00", "-05:30") to seconds from UTC.
    static func parseTimezoneOffset(_ offset: String) -> TimeInterval? {
        let trimmed = offset.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 5 else { return nil }
        let sign: Double = trimmed.hasPrefix("-") ? -1.0 : 1.0
        let digits = trimmed.dropFirst() // drop +/-
        let parts = digits.split(separator: ":")
        guard parts.count == 2,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]) else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }
}
