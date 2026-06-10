import Foundation

/// The single wire format between phone and watch. Encoded with JSONEncoder
/// into the `"msg"` key of a WatchConnectivity dictionary by `CVWatchBridge`.
public enum WatchMessage: Codable, Sendable, Hashable {
    case command(WatchCommand)
    /// Phone → watch: full state snapshot. Sent via `updateApplicationContext`
    /// (latest-wins, survives watch backgrounding) and as `sendMessage` acks.
    case stateSnapshot(WatchStateSnapshot)
    /// Phone → watch: high-rate live numbers while reachable (≤ 2 Hz).
    case telemetryTick(WatchTelemetryTick)

    public static let dictionaryKey = "msg"
}

/// Watch → phone commands.
public enum WatchCommand: Codable, Sendable, Hashable {
    case startSession(presetID: UUID)
    case stopSession
    case requestSnapshot
}

/// Compact session state for the watch UI.
public struct WatchStateSnapshot: Codable, Sendable, Hashable {
    public enum Phase: String, Codable, Sendable {
        case idle, preparing, active, stopping, failed
    }

    public var phase: Phase
    public var presetName: String?
    public var startedAt: Date?
    public var recording: Bool
    public var streamingLive: Bool
    public var gpsFix: GPSFixQuality
    public var peakG: GPeaks
    public var errorMessage: String?
    /// Presets the watch can offer for one-tap start.
    public var presets: [WatchPresetSummary]

    public init(
        phase: Phase,
        presetName: String? = nil,
        startedAt: Date? = nil,
        recording: Bool = false,
        streamingLive: Bool = false,
        gpsFix: GPSFixQuality = .none,
        peakG: GPeaks = GPeaks(),
        errorMessage: String? = nil,
        presets: [WatchPresetSummary] = []
    ) {
        self.phase = phase
        self.presetName = presetName
        self.startedAt = startedAt
        self.recording = recording
        self.streamingLive = streamingLive
        self.gpsFix = gpsFix
        self.peakG = peakG
        self.errorMessage = errorMessage
        self.presets = presets
    }

    public init(from state: SessionState, presets: [WatchPresetSummary] = []) {
        switch state {
        case .idle:
            self.init(phase: .idle, presets: presets)
        case .preparing(let step):
            self.init(phase: .preparing, presetName: step, presets: presets)
        case .active(let info):
            self.init(
                phase: .active,
                presetName: info.presetName,
                startedAt: info.startedAt,
                recording: info.recording,
                streamingLive: info.streaming.isLive,
                gpsFix: info.gpsFix,
                peakG: info.peakG,
                presets: presets
            )
        case .stopping:
            self.init(phase: .stopping, presets: presets)
        case .failed(let error):
            self.init(phase: .failed, errorMessage: error.userMessage, presets: presets)
        }
    }
}

public struct WatchPresetSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Live numbers for the watch gauge; deliberately tiny.
public struct WatchTelemetryTick: Codable, Sendable, Hashable {
    public var gLateral: Double
    public var gLongitudinal: Double
    public var speedMps: Double?

    public init(gLateral: Double, gLongitudinal: Double, speedMps: Double?) {
        self.gLateral = gLateral
        self.gLongitudinal = gLongitudinal
        self.speedMps = speedMps
    }
}

public extension WatchMessage {
    func encodedDictionary() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        return [Self.dictionaryKey: data]
    }

    init?(dictionary: [String: Any]) {
        guard let data = dictionary[Self.dictionaryKey] as? Data,
              let message = try? JSONDecoder().decode(WatchMessage.self, from: data) else {
            return nil
        }
        self = message
    }
}
