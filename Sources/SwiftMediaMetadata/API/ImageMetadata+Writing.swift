import Foundation

extension ImageMetadata {
    // MARK: - Write Options

    /// Options controlling how metadata is written to disk.
    public struct WriteOptions: Sendable {
        /// Policy for the filesystem modification date of the written file.
        ///
        /// This is separate from metadata timestamps embedded in a media
        /// container, such as `VideoMetadata.modificationDate`.
        public enum FileModificationDatePolicy: Sendable, Equatable {
            /// Let the filesystem assign the modification date when bytes are written.
            case update

            /// Preserve the destination's modification date when it already exists.
            /// A newly created destination uses the filesystem-assigned date.
            case preserveExisting

            /// Assign a specific modification date, such as the date of a source
            /// file when writing metadata to a different destination.
            case set(Date)
        }

        /// Policy for the filesystem creation date of the written file.
        public enum FileCreationDatePolicy: Sendable, Equatable {
            /// Let the filesystem assign the creation date when bytes are installed.
            case update

            /// Preserve the destination's creation date when it already exists.
            /// A newly created destination uses the filesystem-assigned date.
            case preserveExisting

            /// Assign a specific creation date, when supported by the filesystem.
            case set(Date)
        }

        /// Write to a temporary file then atomically rename (prevents corruption on crash).
        /// Default: true.
        public var atomic: Bool

        /// Create a backup of the original file before overwriting (e.g. "photo.jpg_original").
        /// Default: false.
        public var createBackup: Bool

        /// Suffix appended to the original filename for the backup (e.g. "_original").
        /// Default: "_original".
        public var backupSuffix: String

        /// Allow embedding metadata into a proprietary TIFF-based RAW container
        /// (Sony ARW, Nikon NEF, Canon CR2, Panasonic RW2, Olympus ORF, …).
        /// Default: false. These formats are rewritten by `TIFFWriter`, which cannot
        /// preserve maker-private structures such as Sony's encrypted SR2Private
        /// white-balance block — so the write corrupts the file (broken decode + bloat).
        /// RAW metadata belongs in an XMP sidecar. DNG/GPR (Adobe's open, writable TIFF
        /// spec) and CR3 (ISOBMFF, dedicated writer) are not affected by this guard.
        /// Only enable if you have verified the specific format round-trips losslessly.
        public var allowUnsafeRawEmbed: Bool

        /// Controls the filesystem modification date after a successful write.
        /// Default: `.update`.
        public var fileModificationDate: FileModificationDatePolicy

        /// Controls the filesystem creation date after a successful write.
        /// Metadata-only rewrites preserve an existing destination's date by default.
        public var fileCreationDate: FileCreationDatePolicy

        public init(
            atomic: Bool = true,
            createBackup: Bool = false,
            backupSuffix: String = "_original",
            allowUnsafeRawEmbed: Bool = false,
            fileModificationDate: FileModificationDatePolicy = .update
        ) {
            self.init(
                atomic: atomic,
                createBackup: createBackup,
                backupSuffix: backupSuffix,
                allowUnsafeRawEmbed: allowUnsafeRawEmbed,
                fileModificationDate: fileModificationDate,
                fileCreationDate: .preserveExisting
            )
        }

        /// Create write options with an explicit filesystem creation-date policy.
        ///
        /// `fileCreationDate` is intentionally required on this overload so the
        /// exact pre-2.1 initializer remains available to existing clients.
        public init(
            atomic: Bool = true,
            createBackup: Bool = false,
            backupSuffix: String = "_original",
            allowUnsafeRawEmbed: Bool = false,
            fileModificationDate: FileModificationDatePolicy = .update,
            fileCreationDate: FileCreationDatePolicy
        ) {
            self.atomic = atomic
            self.createBackup = createBackup
            self.backupSuffix = backupSuffix
            self.allowUnsafeRawEmbed = allowUnsafeRawEmbed
            self.fileModificationDate = fileModificationDate
            self.fileCreationDate = fileCreationDate
        }

        /// Default options: atomic write, no backup.
        public static let `default` = WriteOptions()

        /// Safe options: atomic write with backup file creation.
        public static let safe = WriteOptions(atomic: true, createBackup: true)
    }

    // MARK: - Writing

    /// Serialize updated metadata without touching the filesystem.
    public func serialized() throws -> MetadataWriteResult<Data> {
        var warnings: [String] = []
        let data = try writeToData(collectingWarnings: &warnings)
        return MetadataWriteResult(output: data, warnings: warnings)
    }

    /// Write all metadata back to a new Data blob (preserving image data).
    public func writeToData() throws -> Data {
        try serialized().output
    }

    /// Write all metadata back to a new Data blob and return any non-fatal write
    /// warnings. Currently this surfaces a relocated TIFF/DNG MakerNote whose
    /// manufacturer-specific internal offsets may not resolve (see `TIFFWriter`).
    public func writeToDataWithWarnings() throws -> (data: Data, warnings: [String]) {
        let result = try serialized()
        return (result.output, result.warnings)
    }

    private func writeToData(collectingWarnings warnings: inout [String]) throws -> Data {
        switch container {
        case .jpeg(var file):
            return try writeJPEG(&file, warnings: &warnings)
        case .png(var file):
            return writePNG(&file, warnings: &warnings)
        case .tiff(let file):
            return try writeTIFFFile(file, warnings: &warnings)
        case .jpegXL(var file):
            return try writeJXL(&file, warnings: &warnings)
        case .avif(let file):
            return try writeAVIF(file)
        case .heif(let file):
            return try writeHEIF(file)
        case .webp(let file):
            return try writeWebP(file)
        case .cr3(let file):
            return try writeCR3(file)
        case .pdf(let file):
            return try writePDF(file)
        case .psd(let file):
            return try writePSD(file)
        case .gif(let file):
            return writeGIF(file)
        case .bmp(let file):
            return writeBMP(file)
        case .svg(let file):
            return writeSVG(file)
        }
    }

    /// Write metadata to a file URL with default options (atomic, no backup).
    /// - Returns: non-fatal write warnings (see `writeToDataWithWarnings()`).
    @discardableResult
    public func write(to url: URL) throws -> [String] {
        try writeResult(to: url).warnings
    }

    /// Write metadata to a file URL with the given options.
    /// - Returns: non-fatal write warnings (see `writeToDataWithWarnings()`).
    @discardableResult
    public func write(to url: URL, options: WriteOptions) throws -> [String] {
        try writeResult(to: url, options: options).warnings
    }

    /// Serialize metadata, commit it to disk, and return the common write outcome.
    public func writeResult(
        to url: URL,
        options: WriteOptions = .default
    ) throws -> MetadataWriteResult<URL> {
        // Refuse to overwrite a proprietary TIFF-based RAW: TIFFWriter's full IFD
        // rebuild can't preserve maker-private blocks (e.g. Sony's encrypted
        // SR2Private), so the rewrite corrupts the file. RAW metadata belongs in an
        // XMP sidecar. Callers that have verified a format opt in via WriteOptions.
        if !options.allowUnsafeRawEmbed, let rawFormat = unsafeRawWriteFormat(url: url) {
            throw MetadataError.rawWriteUnsupported(rawFormat)
        }
        let result = try serialized()
        let output = try FileCommitter.commit(result.output, to: url, options: options)
        return MetadataWriteResult(output: output, warnings: result.warnings)
    }

    /// Returns the proprietary RAW format when writing back to `url` would rewrite a
    /// TIFF-based RAW that cannot safely round-trip its maker-private data — otherwise nil.
    ///
    /// Only the `.tiff` container path goes through `TIFFWriter`'s full IFD rebuild (the
    /// step that breaks Sony's encrypted SR2Private and bloats the raster). The precise
    /// format is recovered from the parsed bytes — an ARW/NEF/CR2/RW2/ORF/PEF/SRW reports
    /// as a TIFF container — falling back to the extension if content detection is
    /// inconclusive. DNG/GPR are Adobe's open, writable TIFF spec and are allowed; CR3
    /// (ISOBMFF, its own writer) never reaches this path.
    private func unsafeRawWriteFormat(url: URL) -> ImageFormat.RawFormat? {
        guard case .tiff(let file) = container else { return nil }
        // Refuse if EITHER the parsed content OR the target extension says proprietary RAW.
        // A real ARW/NEF detects by content; the extension is a backstop for odd/truncated
        // variants where content detection falls back to plain TIFF. DNG/GPR (open, writable)
        // are never refused.
        for case .raw(let raw)? in [FormatDetector.detect(file.rawData),
                                    FormatDetector.detectFromExtension(url.pathExtension)] {
            switch raw {
            case .dng, .gpr: continue
            default: return raw
            }
        }
        return nil
    }

    /// Get the backup URL for a given file URL.
    public static func backupURL(for url: URL, suffix: String = "_original") -> URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension()
        if ext.isEmpty {
            return base.appendingPathExtension(suffix.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
        // "photo.jpg" → "photo.jpg_original"
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + suffix)
    }
}
