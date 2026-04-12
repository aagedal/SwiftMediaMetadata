import Foundation

/// Type-erased container for parsed image file data.
public enum ImageContainer: Sendable {
    case jpeg(JPEGFile)
    case tiff(TIFFFile)
    case png(PNGFile)
    case jpegXL(JXLFile)
    case avif(AVIFFile)
}
