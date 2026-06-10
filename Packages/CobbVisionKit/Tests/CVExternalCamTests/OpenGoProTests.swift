import XCTest
import CVCore
@testable import CVExternalCam

/// Golden tests against the public Open GoPro BLE spec
/// (https://gopro.github.io/OpenGoPro/ble/). If these change, the camera
/// stops obeying — keep them byte-exact.
final class OpenGoProCommandTests: XCTestCase {
    func testShutterCommands() {
        XCTAssertEqual([UInt8](OpenGoPro.Command.shutterOn), [0x03, 0x01, 0x01, 0x01])
        XCTAssertEqual([UInt8](OpenGoPro.Command.shutterOff), [0x03, 0x01, 0x01, 0x00])
    }

    func testPresetGroups() {
        // Group ids are big-endian UInt16: 1000/1001/1002.
        XCTAssertEqual([UInt8](OpenGoPro.Command.loadPresetGroup(.video)), [0x04, 0x3E, 0x02, 0x03, 0xE8])
        XCTAssertEqual([UInt8](OpenGoPro.Command.loadPresetGroup(.photo)), [0x04, 0x3E, 0x02, 0x03, 0xE9])
        XCTAssertEqual([UInt8](OpenGoPro.Command.loadPresetGroup(.timelapse)), [0x04, 0x3E, 0x02, 0x03, 0xEA])
    }

    func testWiFiAndKeepAlive() {
        XCTAssertEqual([UInt8](OpenGoPro.Command.enableWiFiAP), [0x03, 0x17, 0x01, 0x01])
        XCTAssertEqual([UInt8](OpenGoPro.Command.disableWiFiAP), [0x03, 0x17, 0x01, 0x00])
        XCTAssertEqual([UInt8](OpenGoPro.Setting.keepAlive), [0x03, 0x5B, 0x01, 0x42])
        XCTAssertEqual([UInt8](OpenGoPro.Command.sleep), [0x01, 0x05])
    }

    func testResponseParsing() {
        let ok = OpenGoPro.parseCommandResponse(Data([0x02, 0x01, 0x00]))
        XCTAssertEqual(ok?.commandID, 0x01)
        XCTAssertEqual(ok?.success, true)

        let failed = OpenGoPro.parseCommandResponse(Data([0x02, 0x3E, 0x02]))
        XCTAssertEqual(failed?.commandID, 0x3E)
        XCTAssertEqual(failed?.success, false)

        XCTAssertNil(OpenGoPro.parseCommandResponse(Data([0x01])))
    }
}

final class ExternalCameraGroupTests: XCTestCase {
    func testBroadcastHitsAllCameras() async {
        let group = ExternalCameraGroup()
        let a = FakeCameraController(id: "a")
        let b = FakeCameraController(id: "b")
        await group.register(a)
        await group.register(b)

        let failures = await group.broadcast([.setMode(.video), .startRecording])
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(a.calls, [.setMode(.video), .start])
        XCTAssertEqual(b.calls, [.setMode(.video), .start])
    }

    func testPartialFailureDoesNotBlockOthers() async {
        let group = ExternalCameraGroup()
        let good = FakeCameraController(id: "good")
        let bad = FakeCameraController(id: "bad")
        bad.commandError = ExternalCamError.notConnected
        await group.register(good)
        await group.register(bad)

        let failures = await group.broadcast([.startRecording])
        XCTAssertEqual(failures.count, 1)
        XCTAssertNotNil(failures["bad"])
        XCTAssertEqual(good.calls, [.start])
    }

    func testInsta360StubReportsPendingSDK() async {
        let group = ExternalCameraGroup()
        await group.register(Insta360Controller())
        let failures = await group.broadcast([.startRecording])
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.values.first?.contains("sdkUnavailable") ?? false)

        let statuses = await group.statuses()
        XCTAssertEqual(statuses.first?.phase, .disconnected)
        XCTAssertEqual(statuses.first?.vendor, .insta360)
    }

    func testSlowCameraTimesOutWithoutStallingGroup() async {
        let group = ExternalCameraGroup()
        let slow = FakeCameraController(id: "slow")
        slow.commandDelay = .seconds(30)
        let fast = FakeCameraController(id: "fast")
        await group.register(slow)
        await group.register(fast)

        let start = ContinuousClock.now
        let failures = await group.broadcast([.startRecording])
        let elapsed = ContinuousClock.now - start

        XCTAssertNotNil(failures["slow"])
        XCTAssertNil(failures["fast"])
        XCTAssertLessThan(elapsed, .seconds(15), "group must not wait out the slow camera")
    }

    func testUnregisterDisconnects() async {
        let group = ExternalCameraGroup()
        let cam = FakeCameraController(id: "x")
        await group.register(cam)
        await group.unregister(id: "x")
        XCTAssertEqual(cam.calls, [.disconnect])
        let ids = await group.registeredIDs
        XCTAssertTrue(ids.isEmpty)
    }
}
