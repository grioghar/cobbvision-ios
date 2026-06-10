import Foundation

/// Which iPhone cameras a session uses.
public enum CameraSelection: String, Codable, Sendable, CaseIterable {
    case front
    case rear
    case both
}

/// A physical camera position on the phone.
public enum CameraPosition: String, Codable, Sendable, CaseIterable {
    case front
    case rear
}

public extension CameraSelection {
    var positions: [CameraPosition] {
        switch self {
        case .front: [.front]
        case .rear: [.rear]
        case .both: [.front, .rear]
        }
    }
}

/// What a session does with the captured video.
public struct SessionMode: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let record = SessionMode(rawValue: 1 << 0)
    public static let stream = SessionMode(rawValue: 1 << 1)
}

public enum VideoQuality: String, Codable, Sendable, CaseIterable {
    case hd720_30
    case hd1080_30
    case hd1080_60
    case uhd4k_30

    public var width: Int {
        switch self {
        case .hd720_30: 1280
        case .hd1080_30, .hd1080_60: 1920
        case .uhd4k_30: 3840
        }
    }

    public var height: Int {
        switch self {
        case .hd720_30: 720
        case .hd1080_30, .hd1080_60: 1080
        case .uhd4k_30: 2160
        }
    }

    public var frameRate: Int {
        switch self {
        case .hd1080_60: 60
        default: 30
        }
    }

    /// Sensible H.264/HEVC encode bitrate for recording, bits per second.
    public var recordBitrate: Int {
        switch self {
        case .hd720_30: 5_000_000
        case .hd1080_30: 8_000_000
        case .hd1080_60: 12_000_000
        case .uhd4k_30: 25_000_000
        }
    }

    /// The next step down when the thermal governor needs to shed load.
    public var steppedDown: VideoQuality? {
        switch self {
        case .uhd4k_30: .hd1080_30
        case .hd1080_60: .hd1080_30
        case .hd1080_30: .hd720_30
        case .hd720_30: nil
        }
    }
}

/// An action to broadcast to connected external cameras when a session starts.
public enum ExternalCamAction: Codable, Sendable, Hashable {
    case startRecording
    case stopRecording
    case setMode(ExternalCamMode)
}

public enum ExternalCamMode: String, Codable, Sendable, CaseIterable {
    case video
    case photo
    case timelapse
}

/// A named, server-synced configuration describing everything one tap should
/// set in motion. Downloaded from the controlplane (`/api/v1/app/presets`) and
/// cached locally; `schemaVersion` lets old builds skip presets they can't parse.
public struct Preset: Codable, Sendable, Identifiable, Hashable {
    public static let currentSchemaVersion = 1

    public var id: UUID
    public var schemaVersion: Int
    public var name: String
    public var cameras: CameraSelection
    public var mode: SessionMode
    /// Which phone camera feeds the live stream when `mode` contains `.stream`.
    public var streamCamera: CameraPosition
    public var streamDestinationID: UUID?
    public var videoQuality: VideoQuality
    public var gpsEnabled: Bool
    public var gForceEnabled: Bool
    public var externalCameraActionsOnStart: [ExternalCamAction]
    public var externalCameraActionsOnStop: [ExternalCamAction]

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = Preset.currentSchemaVersion,
        name: String,
        cameras: CameraSelection = .rear,
        mode: SessionMode = .record,
        streamCamera: CameraPosition = .rear,
        streamDestinationID: UUID? = nil,
        videoQuality: VideoQuality = .hd1080_30,
        gpsEnabled: Bool = true,
        gForceEnabled: Bool = true,
        externalCameraActionsOnStart: [ExternalCamAction] = [.startRecording],
        externalCameraActionsOnStop: [ExternalCamAction] = [.stopRecording]
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.name = name
        self.cameras = cameras
        self.mode = mode
        self.streamCamera = streamCamera
        self.streamDestinationID = streamDestinationID
        self.videoQuality = videoQuality
        self.gpsEnabled = gpsEnabled
        self.gForceEnabled = gForceEnabled
        self.externalCameraActionsOnStart = externalCameraActionsOnStart
        self.externalCameraActionsOnStop = externalCameraActionsOnStop
    }
}

public extension Preset {
    /// Multi-cam recording defaults to 720p30 per camera: dual 1080p plus
    /// encode plus GPS in a sun-baked car hits serious thermal pressure fast.
    static var defaultPresets: [Preset] {
        [
            Preset(
                name: "Drive (rear cam)",
                cameras: .rear,
                mode: .record,
                videoQuality: .hd1080_30
            ),
            Preset(
                name: "Track day (both cams)",
                cameras: .both,
                mode: .record,
                videoQuality: .hd720_30
            ),
            Preset(
                name: "Live stream (rear)",
                cameras: .rear,
                mode: [.record, .stream],
                streamCamera: .rear,
                videoQuality: .hd1080_30
            ),
        ]
    }
}
