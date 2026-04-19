import Foundation

/// Camera/clip metadata extracted from professional video containers.
/// Sourced from Sony NonRealTimeMeta (NRT) XML — either embedded in MXF
/// or carried as a sidecar `.XML` file next to MP4/MXF clips.
public struct CameraMetadata: Sendable, Equatable {
    /// Device manufacturer — e.g. "Sony" (from `<Device manufacturer="…" />`).
    public var deviceManufacturer: String?
    /// Device model — e.g. "PXW-FX9" (from `<Device modelName="…" />`).
    public var deviceModelName: String?
    /// Device serial number (from `<Device serialNo="…" />`).
    public var deviceSerialNumber: String?
    /// Lens model name (from `<LensUnitMetadata><LensModelName />`).
    public var lensModelName: String?
    /// Capture time zone offset (from `<TimeZone />`).
    public var timeZone: String?
    /// Capture gamma curve — e.g. "Rec709", "SLog3"
    /// (from `<AcquisitionRecord><Group><Item name="CaptureGammaEquation" value="…" />`).
    public var captureGammaEquation: String?
    /// Recording mode — "normal", "S&Q", etc. (from `<RecordingMode type="…" />`).
    public var recordingModeType: String?
    /// Capture frame rate in frames-per-second
    /// (from `<VideoFormat><VideoFrame captureFps="…" />`).
    public var captureFps: Double?

    /// User descriptive metadata "name" tokens.
    public var userMetaNames: [String]
    /// User descriptive metadata "content" tokens (aligned with `userMetaNames`).
    public var userMetaContents: [String]
    /// Clip creation date reported by the camera.
    public var creationDate: Date?

    public init(
        deviceManufacturer: String? = nil,
        deviceModelName: String? = nil,
        deviceSerialNumber: String? = nil,
        lensModelName: String? = nil,
        timeZone: String? = nil,
        captureGammaEquation: String? = nil,
        recordingModeType: String? = nil,
        captureFps: Double? = nil,
        userMetaNames: [String] = [],
        userMetaContents: [String] = [],
        creationDate: Date? = nil
    ) {
        self.deviceManufacturer = deviceManufacturer
        self.deviceModelName = deviceModelName
        self.deviceSerialNumber = deviceSerialNumber
        self.lensModelName = lensModelName
        self.timeZone = timeZone
        self.captureGammaEquation = captureGammaEquation
        self.recordingModeType = recordingModeType
        self.captureFps = captureFps
        self.userMetaNames = userMetaNames
        self.userMetaContents = userMetaContents
        self.creationDate = creationDate
    }

    /// True when no interesting field was populated.
    public var isEmpty: Bool {
        deviceManufacturer == nil && deviceModelName == nil && deviceSerialNumber == nil
            && lensModelName == nil && timeZone == nil && captureGammaEquation == nil
            && recordingModeType == nil && captureFps == nil
            && userMetaNames.isEmpty && userMetaContents.isEmpty && creationDate == nil
    }
}
