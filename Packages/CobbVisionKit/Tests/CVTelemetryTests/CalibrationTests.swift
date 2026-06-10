import XCTest
import CVCore
@testable import CVTelemetry

final class VehicleFrameCalibrationTests: XCTestCase {
    func testIdentityMountFlatScreenUp() {
        // Phone flat, screen up: gravity = device -Z; forward accel = device +Y.
        let cal = VehicleFrameCalibration(
            averageGravity: Vector3(x: 0, y: 0, z: -1),
            averageForwardAcceleration: Vector3(x: 0, y: 0.3, z: 0)
        )
        XCTAssertNotNil(cal)
        let g = cal!.vehicleFrame(Vector3(x: 0.5, y: 0.2, z: 0.1))
        XCTAssertEqual(g.lateral, 0.5, accuracy: 1e-9)
        XCTAssertEqual(g.longitudinal, 0.2, accuracy: 1e-9)
        XCTAssertEqual(g.vertical, 0.1, accuracy: 1e-9)
    }

    func testPortraitWindshieldMount() {
        // Phone portrait on the windshield, screen facing driver: device -Z
        // points forward(ish), device -Y points down, so gravity = +Y... use
        // gravity = (0, -1, 0)? Portrait upright: device +Y is up, gravity
        // points device -Y. Forward acceleration pushes the phone backwards
        // along device +Z (screen toward the rear).
        let cal = VehicleFrameCalibration(
            averageGravity: Vector3(x: 0, y: -1, z: 0),
            averageForwardAcceleration: Vector3(x: 0, y: 0, z: -0.3)
        )
        XCTAssertNotNil(cal)
        // Forward accel in the device frame should read as +longitudinal.
        let accel = cal!.vehicleFrame(Vector3(x: 0, y: 0, z: -0.5))
        XCTAssertEqual(accel.longitudinal, 0.5, accuracy: 1e-9)
        XCTAssertEqual(accel.lateral, 0, accuracy: 1e-9)
        // Device +X is still vehicle-right in this mount.
        let lateral = cal!.vehicleFrame(Vector3(x: 0.4, y: 0, z: 0))
        XCTAssertEqual(lateral.lateral, 0.4, accuracy: 1e-9)
    }

    func testTiltedMountProjectsOutGravityComponent() {
        // 45°-tilted mount: forward capture contains a gravity-axis component
        // that must be projected out.
        let cal = VehicleFrameCalibration(
            averageGravity: Vector3(x: 0, y: 0, z: -1),
            averageForwardAcceleration: Vector3(x: 0, y: 0.3, z: 0.3)
        )
        XCTAssertNotNil(cal)
        let g = cal!.vehicleFrame(Vector3(x: 0, y: 1, z: 0))
        XCTAssertEqual(g.longitudinal, 1.0, accuracy: 1e-9)
        XCTAssertEqual(g.vertical, 0, accuracy: 1e-9)
    }

    func testRightHandedFrame() {
        let cal = VehicleFrameCalibration.identity
        // right × forward = up for a right-handed frame... rather:
        // forward × up = right; check orthonormality and handedness.
        XCTAssertEqual(cal.forward.cross(cal.up).dot(cal.right), 1.0, accuracy: 1e-9)
        XCTAssertEqual(cal.right.dot(cal.forward), 0, accuracy: 1e-9)
        XCTAssertEqual(cal.right.dot(cal.up), 0, accuracy: 1e-9)
    }

    func testDegenerateForwardReturnsNil() {
        // Forward acceleration parallel to gravity: no horizontal component.
        XCTAssertNil(VehicleFrameCalibration(
            averageGravity: Vector3(x: 0, y: 0, z: -1),
            averageForwardAcceleration: Vector3(x: 0, y: 0, z: 0.5)
        ))
        XCTAssertNil(VehicleFrameCalibration(
            averageGravity: .zero,
            averageForwardAcceleration: Vector3(x: 0, y: 0.3, z: 0)
        ))
    }

    func testCalibrationCaptureAveragesAndFiltersIdle() {
        var capture = CalibrationCapture()
        let t = Date()
        for _ in 0..<10 {
            capture.addLevelSample(MotionSample(
                timestamp: t,
                userAcceleration: .zero,
                gravity: Vector3(x: 0.01, y: 0.02, z: -0.99)
            ))
        }
        // Coasting (sub-threshold) samples are ignored.
        capture.addForwardSample(MotionSample(
            timestamp: t, userAcceleration: Vector3(x: 0, y: 0.01, z: 0), gravity: .zero
        ))
        XCTAssertEqual(capture.forwardSampleCount, 0)
        capture.addForwardSample(MotionSample(
            timestamp: t, userAcceleration: Vector3(x: 0, y: 0.4, z: 0), gravity: .zero
        ))
        XCTAssertEqual(capture.forwardSampleCount, 1)

        let cal = capture.build()
        XCTAssertNotNil(cal)
        let g = cal!.vehicleFrame(Vector3(x: 0, y: 0.5, z: 0))
        XCTAssertEqual(g.longitudinal, 0.5, accuracy: 0.01)
    }

    func testCodableRoundTrip() throws {
        let cal = VehicleFrameCalibration(
            averageGravity: Vector3(x: 0.1, y: -0.2, z: -0.97),
            averageForwardAcceleration: Vector3(x: 0.05, y: 0.3, z: 0.1)
        )!
        let data = try JSONEncoder().encode(cal)
        let decoded = try JSONDecoder().decode(VehicleFrameCalibration.self, from: data)
        XCTAssertEqual(cal, decoded)
    }
}
