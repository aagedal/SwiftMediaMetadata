import Foundation

/// Supported audio file formats.
public enum AudioFormat: String, Sendable, Equatable {
    case mp3
    case flac
    case m4a
    /// Ogg Vorbis (.ogg/.oga)
    case oggVorbis
    /// Ogg Opus (.opus)
    case opus
}
