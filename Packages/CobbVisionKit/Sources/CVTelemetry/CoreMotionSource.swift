#if os(iOS)
import Foundation
import CoreMotion

/// Device motion (sensor-fused accelerometer) bridged to an AsyncStream.
/// `.xArbitraryZVertical` gives a stable gravity estimate without waiting for
/// a magnetometer fix.
public final class CoreMotionSource: MotionSource, @unchecked Sendable {
    // CMMotionManager docs require one instance per app; delegate callbacks
    // land on the dedicated operation queue below.
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "co.grio.cobbvision.motion"
        return q
    }()

    public init() {}

    public var isAvailable: Bool { manager.isDeviceMotionAvailable }

    public func samples(hz: Double) -> AsyncStream<MotionSample> {
        AsyncStream { continuation in
            guard manager.isDeviceMotionAvailable else {
                continuation.finish()
                return
            }
            manager.deviceMotionUpdateInterval = 1.0 / max(1, hz)
            // CMDeviceMotion timestamps are seconds since boot; convert to
            // wall-clock once using the offset at subscription time.
            let bootToWall = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
            manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { motion, _ in
                guard let motion else { return }
                continuation.yield(MotionSample(
                    timestamp: Date(timeIntervalSince1970: bootToWall + motion.timestamp),
                    userAcceleration: Vector3(
                        x: motion.userAcceleration.x,
                        y: motion.userAcceleration.y,
                        z: motion.userAcceleration.z
                    ),
                    gravity: Vector3(
                        x: motion.gravity.x,
                        y: motion.gravity.y,
                        z: motion.gravity.z
                    )
                ))
            }
            continuation.onTermination = { [manager] _ in
                manager.stopDeviceMotionUpdates()
            }
        }
    }
}
#endif
