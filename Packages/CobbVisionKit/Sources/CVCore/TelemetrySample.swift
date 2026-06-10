import Foundation

/// One merged telemetry row: GPS fix (if any) plus vehicle-frame g-forces
/// (if any), binned by `TelemetryRecorder` at the configured rate (default 10 Hz).
public struct TelemetrySample: Codable, Sendable, Hashable {
    public var timestamp: Date
    public var latitude: Double?
    public var longitude: Double?
    public var altitudeM: Double?
    public var speedMps: Double?
    public var horizontalAccuracyM: Double?
    /// Vehicle frame after mounting calibration: +lateral = right,
    /// +longitudinal = forward (acceleration), +vertical = up. Units of g.
    public var gLateral: Double?
    public var gLongitudinal: Double?
    public var gVertical: Double?

    public init(
        timestamp: Date,
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitudeM: Double? = nil,
        speedMps: Double? = nil,
        horizontalAccuracyM: Double? = nil,
        gLateral: Double? = nil,
        gLongitudinal: Double? = nil,
        gVertical: Double? = nil
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeM = altitudeM
        self.speedMps = speedMps
        self.horizontalAccuracyM = horizontalAccuracyM
        self.gLateral = gLateral
        self.gLongitudinal = gLongitudinal
        self.gVertical = gVertical
    }

    public var hasFix: Bool { latitude != nil && longitude != nil }
}

/// Session-long g-force peaks (absolute values, in g).
public struct GPeaks: Codable, Sendable, Hashable {
    public var lateral: Double
    public var longitudinalAccel: Double
    public var longitudinalBrake: Double
    public var vertical: Double

    public init(lateral: Double = 0, longitudinalAccel: Double = 0, longitudinalBrake: Double = 0, vertical: Double = 0) {
        self.lateral = lateral
        self.longitudinalAccel = longitudinalAccel
        self.longitudinalBrake = longitudinalBrake
        self.vertical = vertical
    }

    public mutating func register(lateral lat: Double?, longitudinal lon: Double?, vertical vert: Double?) {
        if let lat { lateral = max(lateral, abs(lat)) }
        if let lon {
            if lon >= 0 { longitudinalAccel = max(longitudinalAccel, lon) }
            else { longitudinalBrake = max(longitudinalBrake, -lon) }
        }
        if let vert { vertical = max(vertical, abs(vert)) }
    }
}

/// GPS fix quality bucket for status surfaces (watch, CarPlay, dashboard).
public enum GPSFixQuality: String, Codable, Sendable {
    case none
    case poor      // > 25 m horizontal accuracy
    case good      // 10–25 m
    case excellent // < 10 m

    public init(horizontalAccuracyM: Double?) {
        guard let acc = horizontalAccuracyM, acc >= 0 else {
            self = .none
            return
        }
        switch acc {
        case ..<10: self = .excellent
        case ..<25: self = .good
        default: self = .poor
        }
    }
}
