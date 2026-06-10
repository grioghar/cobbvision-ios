import Foundation

/// Status of one external camera, keyed by its stable identifier.
public struct ExternalCamStatus: Codable, Sendable, Hashable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        case disconnected
        case connecting
        case ready
        case recording
        case error
    }

    public var id: String
    public var vendor: ExternalCamVendor
    public var name: String
    public var phase: Phase
    public var detail: String?

    public init(id: String, vendor: ExternalCamVendor, name: String, phase: Phase, detail: String? = nil) {
        self.id = id
        self.vendor = vendor
        self.name = name
        self.phase = phase
        self.detail = detail
    }
}

public enum ExternalCamVendor: String, Codable, Sendable, CaseIterable {
    case gopro
    case insta360
}

/// Everything the status surfaces (phone dashboard, watch, CarPlay) need about
/// a running session, refreshed at ~1 Hz by `SessionManager`.
public struct ActiveSessionInfo: Codable, Sendable, Hashable {
    public var sessionID: UUID
    public var presetName: String
    public var startedAt: Date
    public var recording: Bool
    public var streaming: StreamHealth
    public var gpsFix: GPSFixQuality
    public var speedMps: Double?
    public var peakG: GPeaks
    public var thermalWarning: Bool
    public var externalCams: [ExternalCamStatus]

    public init(
        sessionID: UUID,
        presetName: String,
        startedAt: Date,
        recording: Bool = false,
        streaming: StreamHealth = .notStreaming,
        gpsFix: GPSFixQuality = .none,
        speedMps: Double? = nil,
        peakG: GPeaks = GPeaks(),
        thermalWarning: Bool = false,
        externalCams: [ExternalCamStatus] = []
    ) {
        self.sessionID = sessionID
        self.presetName = presetName
        self.startedAt = startedAt
        self.recording = recording
        self.streaming = streaming
        self.gpsFix = gpsFix
        self.speedMps = speedMps
        self.peakG = peakG
        self.thermalWarning = thermalWarning
        self.externalCams = externalCams
    }
}

public enum SessionError: Error, Codable, Sendable, Hashable {
    case cameraUnavailable(String)
    case multiCamUnsupported
    case streamConnectFailed(String)
    case storageFull(freeBytes: Int64)
    case permissionDenied(String)
    case alreadyActive
    case internalFailure(String)

    public var userMessage: String {
        switch self {
        case .cameraUnavailable(let detail): "Camera unavailable: \(detail)"
        case .multiCamUnsupported: "This iPhone can't capture front and rear cameras at the same time."
        case .streamConnectFailed(let detail): "Couldn't connect the live stream: \(detail)"
        case .storageFull(let free): "Not enough free space to record (\(free / 1_000_000) MB left)."
        case .permissionDenied(let what): "Permission needed: \(what)"
        case .alreadyActive: "A session is already running."
        case .internalFailure(let detail): "Something went wrong: \(detail)"
        }
    }
}

/// The single source of truth fanned out to every UI surface.
public enum SessionState: Codable, Sendable, Hashable {
    case idle
    /// `step` is a human-readable progress label ("Waiting for GPS fix…").
    case preparing(step: String)
    case active(ActiveSessionInfo)
    case stopping
    case failed(SessionError)

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    public var activeInfo: ActiveSessionInfo? {
        if case .active(let info) = self { return info }
        return nil
    }
}
