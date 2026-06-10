import XCTest
import CVCore
@testable import CVTelemetry

final class TelemetryRecorderTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cv-rec-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func fix(t: TimeInterval, lat: Double = 33.95, lon: Double = -84.55, speed: Double = 30) -> LocationFix {
        LocationFix(
            timestamp: Date(timeIntervalSince1970: t),
            latitude: lat, longitude: lon,
            altitudeM: 290, speedMps: speed, horizontalAccuracyM: 5
        )
    }

    private func motion(t: TimeInterval, x: Double = 0, y: Double = 0, z: Double = 0) -> MotionSample {
        MotionSample(
            timestamp: Date(timeIntervalSince1970: t),
            userAcceleration: Vector3(x: x, y: y, z: z),
            gravity: Vector3(x: 0, y: 0, z: -1)
        )
    }

    func testBinsMergeGPSAndMotionAt10Hz() async throws {
        let recorder = TelemetryRecorder(directory: dir, hz: 10, trackName: "merge")
        try await recorder.start()

        // 1 Hz GPS, 50 Hz motion over 2 seconds.
        for i in 0..<100 {
            let t = 100.0 + Double(i) * 0.02
            if i % 50 == 0 { await recorder.ingest(fix: fix(t: t)) }
            await recorder.ingest(motion: motion(t: t, x: 0.3 * Double(i % 2 == 0 ? 1 : -1), y: 0.1))
        }
        let output = try await recorder.stop()

        // ~2 s at 10 Hz → ≈20 bins; every bin has carried-forward GPS + g.
        XCTAssertGreaterThanOrEqual(output.sampleCount, 18)
        XCTAssertLessThanOrEqual(output.sampleCount, 21)
        XCTAssertNotNil(output.gpx)
        XCTAssertNotNil(output.telemetryFileURL)
        XCTAssertEqual(output.peaks.lateral, 0.3, accuracy: 1e-9)

        // Every JSONL row decodes and has both a fix and g data.
        let lines = try String(contentsOf: output.telemetryFileURL!, encoding: .utf8)
            .split(separator: "\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in lines {
            let sample = try decoder.decode(TelemetrySample.self, from: Data(line.utf8))
            XCTAssertTrue(sample.hasFix)
            XCTAssertNotNil(sample.gLateral)
        }
        XCTAssertEqual(lines.count, output.sampleCount)
    }

    func testPeakHoldWithinBinKeepsSpikes() async throws {
        let recorder = TelemetryRecorder(directory: dir, hz: 10, trackName: "spike")
        try await recorder.start()
        // 5 samples inside one bin; the 1.2 g spike must survive binning.
        await recorder.ingest(motion: motion(t: 0.00, x: 0.1))
        await recorder.ingest(motion: motion(t: 0.02, x: -1.2))
        await recorder.ingest(motion: motion(t: 0.04, x: 0.2))
        await recorder.ingest(motion: motion(t: 0.06, x: 0.1))
        await recorder.ingest(motion: motion(t: 0.12, x: 0.05)) // crosses boundary → flush
        let output = try await recorder.stop()

        XCTAssertGreaterThanOrEqual(output.sampleCount, 1)
        let lines = try String(contentsOf: dir.appendingPathComponent("telemetry.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let first = try decoder.decode(TelemetrySample.self, from: Data(lines[0].utf8))
        XCTAssertEqual(first.gLateral!, -1.2, accuracy: 1e-9, "peak-hold must keep the signed spike")
        XCTAssertEqual(output.peaks.lateral, 1.2, accuracy: 1e-9)
    }

    func testStaleFixIsNotCarriedForever() async throws {
        let recorder = TelemetryRecorder(directory: dir, hz: 10, trackName: "stale")
        try await recorder.start()
        await recorder.ingest(fix: fix(t: 0))
        // Motion continues for 6 s with no further GPS.
        for i in 1...300 {
            await recorder.ingest(motion: motion(t: Double(i) * 0.02, x: 0.1))
        }
        _ = try await recorder.stop()

        let lines = try String(contentsOf: dir.appendingPathComponent("telemetry.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let samples = try lines.map { try decoder.decode(TelemetrySample.self, from: Data($0.utf8)) }
        XCTAssertTrue(samples.first!.hasFix, "fresh fix carried into early bins")
        XCTAssertFalse(samples.last!.hasFix, "fix older than 3 s must not be carried")
        XCTAssertNotNil(samples.last!.gLateral, "g-only bins still recorded")
    }

    func testGPSOnlySession() async throws {
        let recorder = TelemetryRecorder(directory: dir, hz: 10, trackName: "gps-only")
        try await recorder.start()
        for i in 0..<5 {
            await recorder.ingest(fix: fix(t: Double(i), lat: 33.95 + Double(i) * 0.001))
        }
        let output = try await recorder.stop()
        XCTAssertGreaterThan(output.sampleCount, 30, "1 Hz GPS fills 10 Hz bins by carry-forward")
        XCTAssertNotNil(output.gpx)
        XCTAssertTrue(output.gpx!.contains("<trkpt"))
    }

    func testEmptySessionProducesNoArtifacts() async throws {
        let recorder = TelemetryRecorder(directory: dir, hz: 10, trackName: "empty")
        try await recorder.start()
        let output = try await recorder.stop()
        XCTAssertEqual(output.sampleCount, 0)
        XCTAssertNil(output.gpx)
        XCTAssertNil(output.telemetryFileURL)
    }

    func testCalibrationAppliedToBins() async throws {
        // Portrait windshield mount (from CalibrationTests).
        let cal = VehicleFrameCalibration(
            averageGravity: Vector3(x: 0, y: -1, z: 0),
            averageForwardAcceleration: Vector3(x: 0, y: 0, z: -0.3)
        )!
        let recorder = TelemetryRecorder(directory: dir, hz: 10, calibration: cal, trackName: "cal")
        try await recorder.start()
        // Device-frame "screen pushed back" = vehicle forward acceleration.
        await recorder.ingest(motion: motion(t: 0.0, z: -0.6))
        await recorder.ingest(motion: motion(t: 0.2, z: 0))
        let output = try await recorder.stop()
        XCTAssertEqual(output.peaks.longitudinalAccel, 0.6, accuracy: 1e-9)
    }
}
