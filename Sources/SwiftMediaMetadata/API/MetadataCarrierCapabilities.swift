import Foundation

/// A standardized metadata family carried by an image or sidecar.
public enum MetadataDomain: String, CaseIterable, Sendable, Hashable {
    case exif
    case iptcIIM
    case xmp
    /// Adobe Camera Raw settings (`crs:`) transported inside XMP.
    case cameraRaw
    case icc
    case c2pa
}

/// Whether the package can expose values from a metadata domain.
public enum MetadataReadSupport: String, Sendable, Equatable {
    case readable
    /// Bytes survive a rewrite, but the package does not interpret them as this domain.
    case preservedOpaquely
    case unsupported
}

/// How callers can write values in a metadata domain for a carrier.
public enum MetadataWriteSupport: String, Sendable, Equatable {
    case directlyWritable
    case sidecarOnly
    case unsupported
}

/// What a normal metadata rewrite promises for existing domain values.
public enum MetadataPreservationSupport: String, Sendable, Equatable {
    /// Values are parsed, serialized, and available for semantic verification.
    case semantic
    /// Original carrier bytes are retained without claiming semantic rewrite support.
    case preservedOpaquely
    /// The writer deliberately removes this domain.
    case intentionallyStripped
    case unsupported
}

/// Read, write, and preservation behavior for one domain in one carrier.
public struct MetadataDomainCapability: Sendable, Equatable {
    public let read: MetadataReadSupport
    public let write: MetadataWriteSupport
    public let preservation: MetadataPreservationSupport

    public init(
        read: MetadataReadSupport,
        write: MetadataWriteSupport,
        preservation: MetadataPreservationSupport
    ) {
        self.read = read
        self.write = write
        self.preservation = preservation
    }
}

/// Per-domain metadata behavior for an image format.
public struct MetadataCarrierCapabilities: Sendable, Equatable {
    public let format: ImageFormat
    public let domains: [MetadataDomain: MetadataDomainCapability]

    public init(format: ImageFormat, domains: [MetadataDomain: MetadataDomainCapability]) {
        self.format = format
        self.domains = domains
    }

    public subscript(domain: MetadataDomain) -> MetadataDomainCapability {
        domains[domain] ?? .unsupported
    }
}

public extension MetadataDomainCapability {
    static let unsupported = MetadataDomainCapability(
        read: .unsupported,
        write: .unsupported,
        preservation: .unsupported
    )

    static let semanticReadWrite = MetadataDomainCapability(
        read: .readable,
        write: .directlyWritable,
        preservation: .semantic
    )

    static let readableOpaque = MetadataDomainCapability(
        read: .readable,
        write: .unsupported,
        preservation: .preservedOpaquely
    )

    static let opaqueTransport = MetadataDomainCapability(
        read: .preservedOpaquely,
        write: .unsupported,
        preservation: .preservedOpaquely
    )

    static let sidecar = MetadataDomainCapability(
        read: .readable,
        write: .sidecarOnly,
        preservation: .preservedOpaquely
    )
}

public extension ImageFormat {
    /// The package's explicit metadata contract for this carrier.
    ///
    /// This describes the safe default write path. In particular, proprietary
    /// RAW formats remain sidecar-only even though `allowUnsafeRawEmbed` exists
    /// as an expert escape hatch.
    var metadataCapabilities: MetadataCarrierCapabilities {
        func table(
            exif: MetadataDomainCapability = .unsupported,
            iptc: MetadataDomainCapability = .unsupported,
            xmp: MetadataDomainCapability = .unsupported,
            cameraRaw: MetadataDomainCapability? = nil,
            icc: MetadataDomainCapability = .unsupported,
            c2pa: MetadataDomainCapability = .unsupported
        ) -> MetadataCarrierCapabilities {
            let cameraRaw = cameraRaw ?? {
                guard xmp.read != .unsupported else { return .unsupported }
                return MetadataDomainCapability(
                    read: xmp.read,
                    write: xmp.write,
                    preservation: xmp.preservation
                )
            }()
            return MetadataCarrierCapabilities(format: self, domains: [
                .exif: exif,
                .iptcIIM: iptc,
                .xmp: xmp,
                .cameraRaw: cameraRaw,
                .icc: icc,
                .c2pa: c2pa,
            ])
        }

        switch self {
        case .jpeg:
            return table(exif: .semanticReadWrite, iptc: .semanticReadWrite,
                         xmp: .semanticReadWrite, icc: .semanticReadWrite,
                         c2pa: .readableOpaque)
        case .tiff, .raw(.dng), .raw(.gpr):
            return table(exif: .semanticReadWrite, iptc: .semanticReadWrite,
                         xmp: .semanticReadWrite, icc: .semanticReadWrite,
                         c2pa: .readableOpaque)
        case .raw(.cr3):
            return table(exif: .semanticReadWrite,
                         iptc: MetadataDomainCapability(read: .readable, write: .unsupported,
                                                        preservation: .preservedOpaquely),
                         xmp: .semanticReadWrite,
                         icc: .opaqueTransport, c2pa: .opaqueTransport)
        case .raw:
            return table(exif: .sidecar,
                         iptc: MetadataDomainCapability(read: .readable, write: .unsupported,
                                                        preservation: .preservedOpaquely),
                         xmp: .sidecar,
                         cameraRaw: .sidecar,
                         icc: MetadataDomainCapability(read: .readable, write: .unsupported,
                                                       preservation: .preservedOpaquely),
                         c2pa: .readableOpaque)
        case .jpegXL:
            return table(exif: .semanticReadWrite, xmp: .semanticReadWrite,
                         icc: .opaqueTransport, c2pa: .readableOpaque)
        case .png:
            return table(exif: .semanticReadWrite, xmp: .semanticReadWrite,
                         icc: .semanticReadWrite, c2pa: .readableOpaque)
        case .avif, .heif:
            return table(exif: .semanticReadWrite, xmp: .semanticReadWrite,
                         icc: MetadataDomainCapability(read: .readable, write: .unsupported,
                                                       preservation: .preservedOpaquely),
                         c2pa: .readableOpaque)
        case .webp:
            return table(exif: .semanticReadWrite, xmp: .semanticReadWrite,
                         icc: .semanticReadWrite, c2pa: .readableOpaque)
        case .pdf, .gif:
            return table(xmp: .semanticReadWrite, c2pa: .readableOpaque)
        case .psd:
            return table(exif: .semanticReadWrite, iptc: .semanticReadWrite,
                         xmp: .semanticReadWrite, icc: .semanticReadWrite,
                         c2pa: .opaqueTransport)
        case .svg:
            return table(xmp: .semanticReadWrite)
        case .bmp:
            return table()
        }
    }
}

public extension ImageMetadata {
    /// Metadata behavior of this value's parsed carrier format.
    var metadataCapabilities: MetadataCarrierCapabilities {
        format.metadataCapabilities
    }
}
