import Foundation

/// Maps device-frame acceleration into the vehicle frame so the g-force gauge
/// reads correctly regardless of how the phone is mounted.
///
/// Two-step calibration:
///  1. **Level** (vehicle stationary): average gravity defines vehicle "down".
///  2. **Forward** (brief straight-line acceleration): the average horizontal
///     user-acceleration direction defines vehicle "forward".
///
/// Vehicle frame: +lateral = right, +longitudinal = forward, +vertical = up.
public struct VehicleFrameCalibration: Codable, Sendable, Hashable {
    /// Rows of the device→vehicle rotation matrix.
    public var right: Vector3
    public var forward: Vector3
    public var up: Vector3

    public init(right: Vector3, forward: Vector3, up: Vector3) {
        self.right = right
        self.forward = forward
        self.up = up
    }

    /// Identity: assumes the phone is flat, screen up, top of phone pointing
    /// at the windshield (device -Z = gravity, +Y = forward).
    public static let identity = VehicleFrameCalibration(
        right: Vector3(x: 1, y: 0, z: 0),
        forward: Vector3(x: 0, y: 1, z: 0),
        up: Vector3(x: 0, y: 0, z: 1)
    )

    /// Builds the frame from the two calibration captures. Returns nil when
    /// the vectors are degenerate (no acceleration captured, or forward is
    /// parallel to gravity).
    public init?(averageGravity: Vector3, averageForwardAcceleration: Vector3) {
        let up = (averageGravity * -1).normalized
        guard up.magnitude > 0.5 else { return nil }

        // Project the captured acceleration onto the horizontal plane.
        let raw = averageForwardAcceleration
        let horizontal = raw - up * raw.dot(up)
        let forward = horizontal.normalized
        guard forward.magnitude > 0.5 else { return nil }

        self.up = up
        self.forward = forward
        // Right-handed frame (X=right, Y=forward, Z=up): Y × Z = X.
        self.right = forward.cross(up).normalized
    }

    /// Rotates a device-frame vector into the vehicle frame:
    /// returns (lateral, longitudinal, vertical).
    public func vehicleFrame(_ deviceVector: Vector3) -> (lateral: Double, longitudinal: Double, vertical: Double) {
        (
            lateral: deviceVector.dot(right),
            longitudinal: deviceVector.dot(forward),
            vertical: deviceVector.dot(up)
        )
    }
}

/// Accumulates sensor readings during the two calibration phases.
public struct CalibrationCapture: Sendable {
    private var gravitySum = Vector3.zero
    private var gravityCount = 0
    private var accelSum = Vector3.zero
    private var accelCount = 0

    public init() {}

    public mutating func addLevelSample(_ sample: MotionSample) {
        gravitySum = gravitySum + sample.gravity
        gravityCount += 1
    }

    public mutating func addForwardSample(_ sample: MotionSample) {
        // Ignore near-zero readings so coasting doesn't dilute the direction.
        guard sample.userAcceleration.magnitude > 0.05 else { return }
        accelSum = accelSum + sample.userAcceleration
        accelCount += 1
    }

    public var levelSampleCount: Int { gravityCount }
    public var forwardSampleCount: Int { accelCount }

    public func build() -> VehicleFrameCalibration? {
        guard gravityCount > 0, accelCount > 0 else { return nil }
        return VehicleFrameCalibration(
            averageGravity: gravitySum * (1.0 / Double(gravityCount)),
            averageForwardAcceleration: accelSum * (1.0 / Double(accelCount))
        )
    }
}
