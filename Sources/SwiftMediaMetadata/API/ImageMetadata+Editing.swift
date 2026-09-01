import Foundation

extension ImageMetadata {
    // MARK: - Stripping

    /// Remove all metadata (Exif, IPTC, XMP, C2PA, ICC profile).
    public mutating func stripAllMetadata() {
        exif = nil
        iptc = IPTCData()
        xmp = nil
        c2pa = nil
        iccProfile = nil
    }

    /// Remove all Exif data.
    public mutating func stripExif() {
        exif = nil
    }

    /// Remove all IPTC data.
    public mutating func stripIPTC() {
        iptc = IPTCData()
    }

    /// Remove all XMP data.
    public mutating func stripXMP() {
        xmp = nil
    }

    /// Remove GPS data from Exif and XMP.
    public mutating func stripGPS() {
        exif?.gpsIFD = nil
        xmp?.removeValue(namespace: XMPNamespace.iptcCore, property: "Location")
    }

    /// Remove C2PA provenance data.
    public mutating func stripC2PA() {
        c2pa = nil
    }

    /// Remove the embedded ICC color profile.
    public mutating func stripICCProfile() {
        iccProfile = nil
    }

    // MARK: - Individual Tag Deletion

    /// Remove a specific EXIF tag from IFD0.
    /// - Returns: true if the tag was found and removed.
    @discardableResult
    public mutating func removeExifTag(_ tag: UInt16) -> Bool {
        guard let ifd = exif?.ifd0, ifd.hasEntry(for: tag) else { return false }
        exif?.ifd0 = ifd.removingEntry(for: tag)
        return true
    }

    /// Remove a specific EXIF tag from the Exif sub-IFD.
    /// - Returns: true if the tag was found and removed.
    @discardableResult
    public mutating func removeExifSubIFDTag(_ tag: UInt16) -> Bool {
        guard let ifd = exif?.exifIFD, ifd.hasEntry(for: tag) else { return false }
        exif?.exifIFD = ifd.removingEntry(for: tag)
        return true
    }

    /// Remove a specific GPS tag from the GPS IFD.
    /// - Returns: true if the tag was found and removed.
    @discardableResult
    public mutating func removeGPSTag(_ tag: UInt16) -> Bool {
        guard let ifd = exif?.gpsIFD, ifd.hasEntry(for: tag) else { return false }
        exif?.gpsIFD = ifd.removingEntry(for: tag)
        return true
    }

    /// Remove a specific IPTC field.
    /// - Returns: true if the field was found and removed.
    @discardableResult
    public mutating func removeIPTCTag(_ tag: IPTCTag) -> Bool {
        let before = iptc.datasets.count
        iptc.removeAll(for: tag)
        return iptc.datasets.count < before
    }

    /// Remove a specific XMP property.
    /// - Returns: true if the property was found and removed.
    @discardableResult
    public mutating func removeXMPProperty(namespace: String, property: String) -> Bool {
        guard xmp?.value(namespace: namespace, property: property) != nil else { return false }
        xmp?.removeValue(namespace: namespace, property: property)
        return true
    }

    /// Remove a tag by its qualified name (e.g. "EXIF:Make", "IPTC:Headline", "XMP-dc:title").
    /// Supports group prefixes: EXIF:, ExifIFD:, GPS:, IPTC:, XMP-prefix:
    /// - Returns: true if the tag was found and removed.
    @discardableResult
    public mutating func removeTag(_ qualifiedName: String) -> Bool {
        if qualifiedName.hasPrefix("EXIF:") {
            let tagName = String(qualifiedName.dropFirst(5))
            if let tagID = ExifTag.tagID(for: tagName, ifd: .ifd0) {
                return removeExifTag(tagID)
            }
            // Also try exif sub-IFD
            if let tagID = ExifTag.tagID(for: tagName, ifd: .exifIFD) {
                return removeExifSubIFDTag(tagID)
            }
            return false
        }

        if qualifiedName.hasPrefix("ExifIFD:") {
            let tagName = String(qualifiedName.dropFirst(8))
            if let tagID = ExifTag.tagID(for: tagName, ifd: .exifIFD) {
                return removeExifSubIFDTag(tagID)
            }
            return false
        }

        if qualifiedName.hasPrefix("GPS:") {
            let tagName = String(qualifiedName.dropFirst(4))
            if let tagID = ExifTag.tagID(for: tagName, ifd: .gpsIFD) {
                return removeGPSTag(tagID)
            }
            return false
        }

        if qualifiedName.hasPrefix("IPTC:") {
            let tagName = String(qualifiedName.dropFirst(5))
            if let tag = IPTCTag.byName(tagName) {
                return removeIPTCTag(tag)
            }
            return false
        }

        if qualifiedName.hasPrefix("XMP-") {
            // Format: "XMP-prefix:property"
            let rest = qualifiedName.dropFirst(4) // drop "XMP-"
            if let colonIdx = rest.firstIndex(of: ":") {
                let prefix = String(rest[rest.startIndex..<colonIdx])
                let property = String(rest[rest.index(after: colonIdx)...])
                if let namespace = XMPNamespace.namespace(for: prefix) {
                    return removeXMPProperty(namespace: namespace, property: property)
                }
            }
            return false
        }

        return false
    }

    // MARK: - Date Shifting

    /// Shift all date/time fields by the given interval.
    /// Positive values move dates forward, negative values move them backward.
    /// Updates EXIF (DateTime, DateTimeOriginal, DateTimeDigitized),
    /// IPTC (DateCreated/TimeCreated, DigitalCreationDate/Time), and XMP (photoshop:DateCreated).
    public mutating func shiftDates(by interval: TimeInterval) {
        // EXIF dates: "YYYY:MM:DD HH:MM:SS"
        if exif != nil {
            shiftExifDate(tag: ExifTag.dateTime, ifdKeyPath: \.ifd0, interval: interval)
            shiftExifDate(tag: ExifTag.dateTimeOriginal, ifdKeyPath: \.exifIFD, interval: interval)
            shiftExifDate(tag: ExifTag.dateTimeDigitized, ifdKeyPath: \.exifIFD, interval: interval)
        }

        // IPTC dates: "YYYYMMDD" + "HHMMSS±HHMM"
        shiftIPTCDate(dateTag: .dateCreated, timeTag: .timeCreated, interval: interval)
        shiftIPTCDate(dateTag: .digitalCreationDate, timeTag: .digitalCreationTime, interval: interval)

        // XMP: photoshop:DateCreated (ISO 8601 or EXIF format)
        if let dateStr = xmp?.simpleValue(namespace: XMPNamespace.photoshop, property: "DateCreated"),
           let shifted = Self.shiftDateString(dateStr, by: interval) {
            xmp?.setValue(.simple(shifted), namespace: XMPNamespace.photoshop, property: "DateCreated")
        }
    }

    private mutating func shiftExifDate(tag: UInt16, ifdKeyPath: WritableKeyPath<ExifData, IFD?>, interval: TimeInterval) {
        guard let ifd = exif?[keyPath: ifdKeyPath],
              let entry = ifd.entry(for: tag),
              let dateStr = entry.stringValue(endian: exif!.byteOrder),
              let shifted = Self.shiftExifDateString(dateStr, by: interval) else { return }

        // Build new entry with shifted date
        guard let newData = shifted.data(using: .ascii) else { return }
        var padded = newData
        padded.append(0x00) // null terminator
        let newEntry = IFDEntry(tag: tag, type: .ascii, count: UInt32(padded.count), valueData: padded)

        // Replace the entry in the IFD
        var entries = ifd.entries.filter { $0.tag != tag }
        entries.append(newEntry)
        exif?[keyPath: ifdKeyPath] = IFD(entries: entries, nextIFDOffset: ifd.nextIFDOffset)
    }

    private mutating func shiftIPTCDate(dateTag: IPTCTag, timeTag: IPTCTag, interval: TimeInterval) {
        guard let dateStr = iptc.value(for: dateTag) else { return }
        let timeStr = iptc.value(for: timeTag)

        // Combine into a parseable date, shift, then split back
        let combined = Self.combineIPTCDateTime(date: dateStr, time: timeStr)
        guard let shifted = Self.shiftExifDateString(combined, by: interval) else { return }

        // Split back: first 10 chars "YYYY:MM:DD" → "YYYYMMDD", rest → time
        let parts = shifted.split(separator: " ", maxSplits: 1)
        if let datePart = parts.first {
            let iptcDate = datePart.replacingOccurrences(of: ":", with: "")
            try? iptc.setValue(iptcDate, for: dateTag)
        }
        if parts.count > 1 {
            let timePart = String(parts[1]).replacingOccurrences(of: ":", with: "")
            try? iptc.setValue(timePart, for: timeTag)
        }
    }

    // MARK: - Date Parsing Helpers

    // DateFormatter is not thread-safe — it mutates internal state during both
    // `date(from:)` and `string(from:)`. Build a fresh instance per call so this
    // static API stays safe under concurrent use (TaskGroups, batch operations,
    // library clients running their own concurrency).
    private static func makeExifFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }

    static func shiftExifDateString(_ dateStr: String, by interval: TimeInterval) -> String? {
        let formatter = makeExifFormatter()
        guard let date = formatter.date(from: dateStr) else { return nil }
        let shifted = date.addingTimeInterval(interval)
        return formatter.string(from: shifted)
    }

    /// Shift a date string in various formats (EXIF, ISO 8601).
    static func shiftDateString(_ dateStr: String, by interval: TimeInterval) -> String? {
        // Try EXIF format first
        if let result = shiftExifDateString(dateStr, by: interval) {
            return result
        }
        // Try ISO 8601 (e.g. "2024-01-15T14:30:00")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: dateStr) {
            let shifted = date.addingTimeInterval(interval)
            return iso.string(from: shifted)
        }
        // Try date-only ISO (e.g. "2024-01-15")
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        if let date = dateOnly.date(from: dateStr) {
            let shifted = date.addingTimeInterval(interval)
            return dateOnly.string(from: shifted)
        }
        return nil
    }

    /// Combine IPTC date "YYYYMMDD" and time "HHMMSS" into EXIF format "YYYY:MM:DD HH:MM:SS".
    private static func combineIPTCDateTime(date: String, time: String?) -> String {
        // Date: "YYYYMMDD" → "YYYY:MM:DD"
        var result = date
        if date.count == 8 && !date.contains(":") {
            let y = date.prefix(4)
            let m = date.dropFirst(4).prefix(2)
            let d = date.dropFirst(6).prefix(2)
            result = "\(y):\(m):\(d)"
        }

        // Time: "HHMMSS" → " HH:MM:SS"
        if let time = time {
            // Strip timezone suffix if present (±HHMM)
            let core = time.prefix(6)
            if core.count == 6 {
                let h = core.prefix(2)
                let min = core.dropFirst(2).prefix(2)
                let s = core.dropFirst(4).prefix(2)
                result += " \(h):\(min):\(s)"
            }
        } else {
            result += " 00:00:00"
        }

        return result
    }

    // MARK: - Metadata Groups

    /// Groups of metadata that can be selectively copied or compared.
    public enum MetadataGroup: CaseIterable, Sendable {
        case exif
        case iptc
        case xmp
        case c2pa
        case iccProfile
    }

    // MARK: - Copy Metadata

    /// Copy all metadata from another ImageMetadata instance.
    /// Replaces all Exif, IPTC, XMP, and C2PA data with the source's values.
    public mutating func copyMetadata(from source: ImageMetadata) {
        exif = source.exif
        iptc = source.iptc
        xmp = source.xmp
        c2pa = source.c2pa
        iccProfile = source.iccProfile
    }

    /// Copy selected metadata groups from another ImageMetadata instance.
    public mutating func copyMetadata(from source: ImageMetadata, groups: Set<MetadataGroup>) {
        if groups.contains(.exif) { exif = source.exif }
        if groups.contains(.iptc) { iptc = source.iptc }
        if groups.contains(.xmp) { xmp = source.xmp }
        if groups.contains(.c2pa) { c2pa = source.c2pa }
        if groups.contains(.iccProfile) { iccProfile = source.iccProfile }
    }

    /// Copy metadata from source, filtered to only matching tags.
    public mutating func copyMetadata(from source: ImageMetadata, filter: TagFilter) {
        let sourceDict = MetadataExporter.buildDictionary(source)
        for (key, _) in sourceDict where filter.matches(key: key) {
            // Copy IPTC fields
            if key.hasPrefix("IPTC:") {
                let tagName = String(key.dropFirst(5))
                if let tag = IPTCTag.byName(tagName) {
                    let values = source.iptc.values(for: tag)
                    if !values.isEmpty {
                        try? iptc.setValues(values, for: tag)
                    }
                }
            }
            // Copy XMP fields
            else if key.hasPrefix("XMP-") {
                let rest = key.dropFirst(4)
                if let colonIdx = rest.firstIndex(of: ":") {
                    let prefix = String(rest[rest.startIndex..<colonIdx])
                    let property = String(rest[rest.index(after: colonIdx)...])
                    if let namespace = XMPNamespace.namespace(for: prefix),
                       let value = source.xmp?.value(namespace: namespace, property: property) {
                        if xmp == nil { xmp = XMPData() }
                        xmp?.setValue(value, namespace: namespace, property: property)
                    }
                }
            }
        }
    }

    /// Remove all tags whose keys match the filter pattern. Returns the number of tags removed.
    @discardableResult
    public mutating func removeMatchingTags(_ filter: TagFilter) -> Int {
        let dict = MetadataExporter.buildDictionary(self)
        var removed = 0
        for key in dict.keys where filter.matches(key: key) {
            if removeTag(key) { removed += 1 }
        }
        return removed
    }

    // MARK: - Metadata Diff

    /// A single difference between two metadata values.
    public struct MetadataChange: Equatable, Sendable {
        public enum ChangeType: Equatable, Sendable {
            case added
            case removed
            case modified
        }

        public let key: String
        public let type: ChangeType
        public let oldValue: String?
        public let newValue: String?

        public init(key: String, type: ChangeType, oldValue: String? = nil, newValue: String? = nil) {
            self.key = key
            self.type = type
            self.oldValue = oldValue
            self.newValue = newValue
        }
    }

    /// Result of comparing two metadata instances.
    public struct MetadataDiff: Sendable {
        public let changes: [MetadataChange]

        public var additions: [MetadataChange] { changes.filter { $0.type == .added } }
        public var removals: [MetadataChange] { changes.filter { $0.type == .removed } }
        public var modifications: [MetadataChange] { changes.filter { $0.type == .modified } }
        public var isEmpty: Bool { changes.isEmpty }
    }

    /// Compare this metadata against another instance and return differences.
    public func diff(against other: ImageMetadata) -> MetadataDiff {
        let selfDict = MetadataExporter.buildDictionary(self)
        let otherDict = MetadataExporter.buildDictionary(other)

        var changes: [MetadataChange] = []
        let allKeys = Set(selfDict.keys).union(otherDict.keys)

        for key in allKeys.sorted() {
            let selfVal = selfDict[key].map { Self.stringifyValue($0) }
            let otherVal = otherDict[key].map { Self.stringifyValue($0) }

            switch (selfVal, otherVal) {
            case (nil, .some(let new)):
                changes.append(MetadataChange(key: key, type: .added, newValue: new))
            case (.some(let old), nil):
                changes.append(MetadataChange(key: key, type: .removed, oldValue: old))
            case (.some(let old), .some(let new)) where old != new:
                changes.append(MetadataChange(key: key, type: .modified, oldValue: old, newValue: new))
            default:
                break
            }
        }

        return MetadataDiff(changes: changes)
    }

    private static func stringifyValue(_ value: Any) -> String {
        if let arr = value as? [String] {
            return arr.joined(separator: ", ")
        }
        return String(describing: value)
    }
}
