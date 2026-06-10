import Foundation

/// Minimal 3-vector used for accelerometer math. Platform-pure so the
/// calibration and binning logic tests run on any host.
public struct Vector3: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(x: 0, y: 0, z: 0)

    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }

    public var normalized: Vector3 {
        let m = magnitude
        guard m > 1e-12 else { return .zero }
        return Vector3(x: x / m, y: y / m, z: z / m)
    }

    public func dot(_ other: Vector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    public func cross(_ other: Vector3) -> Vector3 {
        Vector3(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }

    public static func - (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    public static func + (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    public static func * (lhs: Vector3, rhs: Double) -> Vector3 {
        Vector3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }
}

/// A GPS fix decoupled from CoreLocation so recorder logic tests anywhere.
public struct LocationFix: Sendable, Hashable {
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    public var altitudeM: Double?
    public var speedMps: Double?
    public var horizontalAccuracyM: Double?

    public init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        altitudeM: Double? = nil,
        speedMps: Double? = nil,
        horizontalAccuracyM: Double? = nil
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeM = altitudeM
        self.speedMps = speedMps
        self.horizontalAccuracyM = horizontalAccuracyM
    }
}

/// One device-motion reading in the DEVICE frame, units of g.
public struct MotionSample: Sendable, Hashable {
    public var timestamp: Date
    /// User acceleration (gravity already removed by sensor fusion).
    public var userAcceleration: Vector3
    /// Gravity direction in the device frame (unit-ish vector).
    public var gravity: Vector3

    public init(timestamp: Date, userAcceleration: Vector3, gravity: Vector3) {
        self.timestamp = timestamp
        self.userAcceleration = userAcceleration
        self.gravity = gravity
    }
}

/// Streams GPS fixes. `CoreLocationSource` on device; tests use hand-fed streams.
public protocol LocationSource: Sendable {
    func updates() -> AsyncThrowingStream<LocationFix, Error>
}

/// Streams device motion. `CoreMotionSource` on device; `ReplayMotionSource`
/// drives the simulator and unit tests.
public protocol MotionSource: Sendable {
    func samples(hz: Double) -> AsyncStream<MotionSample>
}

/// Replays a canned list of motion samples at ingest speed (no real-time
/// pacing) — for unit tests and simulator UI work.
public struct ReplayMotionSource: MotionSource {
    private let recorded: [MotionSample]

    public init(samples: [MotionSample]) {
        self.recorded = samples
    }

    /// A gentle synthetic drive: sine-wave lateral + longitudinal g.
    public static func syntheticDrive(durationSeconds: Double, hz: Double = 50, start: Date = Date(timeIntervalSince1970: 0)) -> ReplayMotionSource {
        let count = Int(durationSeconds * hz)
        let samples = (0..<count).map { i -> MotionSample in
            let t = Double(i) / hz
            return MotionSample(
                timestamp: start.addingTimeInterval(t),
                userAcceleration: Vector3(
                    x: 0.4 * sin(t * 0.8),
                    y: 0.25 * sin(t * 0.3),
                    z: 0.05 * sin(t * 2.1)
                ),
                gravity: Vector3(x: 0, y: 0, z: -1)
            )
        }
        return ReplayMotionSource(samples: samples)
    }

    public func samples(hz: Double) -> AsyncStream<MotionSample> {
        AsyncStream { continuation in
            for sample in recorded {
                continuation.yield(sample)
            }
            continuation.finish()
        }
    }
}
