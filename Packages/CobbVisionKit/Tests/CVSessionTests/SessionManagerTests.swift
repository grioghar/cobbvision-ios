import XCTest
import CVCore
import CVAPI
import CVTelemetry
import CVCapture
import CVStreaming
import CVExternalCam
@testable import CVSession

final class SessionManagerTests: XCTestCase {
    private var root: URL!
    private var capture: FakeCaptureEngine!
    private var stream: FakeStreamEngine!
    private var group: ExternalCameraGroup!
    private var destinations: StreamDestinationStore!
    private var tokenStore: InMemoryTokenStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cv-sess-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        capture = FakeCaptureEngine()
        stream = FakeStreamEngine()
        group = ExternalCameraGroup()
        tokenStore = InMemoryTokenStore()
        destinations = StreamDestinationStore(directory: root, tokenStore: tokenStore)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeManager(stream: FakeStreamEngine? = nil) -> SessionManager {
        SessionManager(
            capture: capture,
            stream: stream,
            locationSource: nil,
            motionSource: nil,
            externalCameras: group,
            uploader: nil,
            destinations: destinations,
            tokenStore: tokenStore,
            sessionsRoot: root
        )
    }

    func testRecordOnlySessionLifecycle() async throws {
        let manager = makeManager()
        let preset = Preset(name: "Record", cameras: .rear, mode: .record, gpsEnabled: false, gForceEnabled: false)

        await manager.start(preset: preset)
        let active = await manager.state
        guard case .active(let info) = active else {
            return XCTFail("expected active, got \(active)")
        }
        XCTAssertTrue(info.recording)
        XCTAssertEqual(info.presetName, "Record")

        await manager.stop()
        let final = await manager.state
        guard case .idle = final else {
            return XCTFail("expected idle, got \(final)")
        }

        XCTAssertEqual(capture.calls, [
            .configure(CaptureSpec(cameras: .rear, quality: .hd1080_30)),
            .start,
            .startRecording,
            .stopRecording,
            .stop,
        ])

        // Manifest written with the fake's video artifact.
        let manifests = SessionLibrary(sessionsRoot: root).manifests()
        XCTAssertEqual(manifests.count, 1)
        XCTAssertEqual(manifests[0].videos.map(\.fileName), ["rear.mov"])
        XCTAssertNotNil(manifests[0].endedAt)
    }

    func testStreamSessionConnectsAndTearsDown() async throws {
        let destination = StreamDestination(name: "MTX", kind: .srt, url: "srt://example:8890")
        destinations.upsert(destination, streamKey: "publish:cobbvision:cobb:pw")

        let manager = makeManager(stream: stream)
        var preset = Preset(name: "Live", cameras: .rear, mode: [.record, .stream], gpsEnabled: false, gForceEnabled: false)
        preset.streamDestinationID = destination.id

        await manager.start(preset: preset)
        guard case .active = await manager.state else {
            return XCTFail("expected active, got \(await manager.state)")
        }
        XCTAssertEqual(stream.calls, [.connect(kind: .srt, url: "srt://example:8890")])

        await manager.stop()
        XCTAssertEqual(stream.calls.last, .disconnect)
        guard case .idle = await manager.state else {
            return XCTFail("expected idle")
        }
    }

    func testStreamPresetWithoutDestinationFails() async {
        let manager = makeManager(stream: stream)
        let preset = Preset(name: "Bad", mode: [.stream], gpsEnabled: false, gForceEnabled: false)

        await manager.start(preset: preset)
        guard case .failed(let error) = await manager.state else {
            return XCTFail("expected failed, got \(await manager.state)")
        }
        guard case .streamConnectFailed = error else {
            return XCTFail("wrong error: \(error)")
        }
        // Failure must tear capture down.
        XCTAssertTrue(capture.calls.contains(.stop))

        await manager.acknowledgeFailure()
        guard case .idle = await manager.state else {
            return XCTFail("expected idle after acknowledge")
        }
    }

    func testCaptureFailureSurfacesAsFailedState() async {
        capture.configureError = SessionError.multiCamUnsupported
        let manager = makeManager()
        await manager.start(preset: Preset(name: "Both", cameras: .both, gpsEnabled: false, gForceEnabled: false))
        guard case .failed(.multiCamUnsupported) = await manager.state else {
            return XCTFail("expected multiCamUnsupported, got \(await manager.state)")
        }
    }

    func testDoubleStartIsIgnored() async {
        let manager = makeManager()
        let preset = Preset(name: "P", gpsEnabled: false, gForceEnabled: false)
        await manager.start(preset: preset)
        let callsAfterFirst = capture.calls.count
        await manager.start(preset: preset)
        XCTAssertEqual(capture.calls.count, callsAfterFirst, "second start must be a no-op")
        await manager.stop()
    }

    func testExternalCamerasFiredOnStartAndStop() async {
        let cam = FakeCameraController(id: "gopro1")
        await group.register(cam)
        let manager = makeManager()
        await manager.start(preset: Preset(name: "P", gpsEnabled: false, gForceEnabled: false))
        await manager.stop()
        XCTAssertEqual(cam.calls, [.start, .stop])
    }

    func testFailedExternalCameraDoesNotBlockSession() async {
        let bad = FakeCameraController(id: "dead")
        bad.commandError = ExternalCamError.notConnected
        await group.register(bad)
        let manager = makeManager()
        await manager.start(preset: Preset(name: "P", gpsEnabled: false, gForceEnabled: false))
        guard case .active = await manager.state else {
            return XCTFail("session must start despite external camera failure")
        }
        await manager.stop()
    }

    func testStateStreamFansOut() async {
        let manager = makeManager()
        let states = await manager.stateUpdates()
        let collector = Task { () -> [String] in
            var seen: [String] = []
            for await state in states {
                switch state {
                case .idle: seen.append("idle")
                case .preparing: seen.append("preparing")
                case .active: seen.append("active")
                case .stopping: seen.append("stopping")
                case .failed: seen.append("failed")
                }
                if seen.filter({ $0 == "idle" }).count == 2 { break }
            }
            return seen
        }
        // Give the collector a beat to subscribe.
        try? await Task.sleep(for: .milliseconds(50))
        await manager.start(preset: Preset(name: "P", gpsEnabled: false, gForceEnabled: false))
        await manager.stop()
        let seen = await collector.value
        XCTAssertEqual(seen.first, "idle", "stream must replay current state on subscribe")
        XCTAssertTrue(seen.contains("active"))
        XCTAssertTrue(seen.contains("stopping"))
        XCTAssertEqual(seen.last, "idle")
    }
}
