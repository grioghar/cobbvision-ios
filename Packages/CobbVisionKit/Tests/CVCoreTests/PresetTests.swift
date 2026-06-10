import XCTest
@testable import CVCore

final class PresetTests: XCTestCase {
    func testRoundTripCoding() throws {
        let preset = Preset(
            name: "Track day",
            cameras: .both,
            mode: [.record, .stream],
            streamCamera: .front,
            streamDestinationID: UUID(),
            videoQuality: .hd1080_60,
            gpsEnabled: true,
            gForceEnabled: false,
            externalCameraActionsOnStart: [.setMode(.video), .startRecording],
            externalCameraActionsOnStop: [.stopRecording]
        )
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        XCTAssertEqual(preset, decoded)
    }

    func testCameraSelectionPositions() {
        XCTAssertEqual(CameraSelection.front.positions, [.front])
        XCTAssertEqual(CameraSelection.rear.positions, [.rear])
        XCTAssertEqual(CameraSelection.both.positions, [.front, .rear])
    }

    func testVideoQualityStepDownLadder() {
        XCTAssertEqual(VideoQuality.uhd4k_30.steppedDown, .hd1080_30)
        XCTAssertEqual(VideoQuality.hd1080_60.steppedDown, .hd1080_30)
        XCTAssertEqual(VideoQuality.hd1080_30.steppedDown, .hd720_30)
        XCTAssertNil(VideoQuality.hd720_30.steppedDown)
    }

    func testDefaultPresetsParseable() {
        // Default presets must always carry the current schema version.
        for preset in Preset.defaultPresets {
            XCTAssertEqual(preset.schemaVersion, Preset.currentSchemaVersion)
        }
    }

    func testUnknownSchemaVersionStillDecodes() throws {
        // Server may send presets created by a newer app; decoding must not
        // throw (the store filters on schemaVersion afterwards).
        var preset = Preset(name: "future")
        preset.schemaVersion = 999
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 999)
    }
}

final class GPeaksTests: XCTestCase {
    func testRegisterTracksDirectionalPeaks() {
        var peaks = GPeaks()
        peaks.register(lateral: -0.8, longitudinal: 0.5, vertical: nil)
        peaks.register(lateral: 0.3, longitudinal: -1.1, vertical: 0.2)
        XCTAssertEqual(peaks.lateral, 0.8)
        XCTAssertEqual(peaks.longitudinalAccel, 0.5)
        XCTAssertEqual(peaks.longitudinalBrake, 1.1)
        XCTAssertEqual(peaks.vertical, 0.2)
    }
}

final class GPSFixQualityTests: XCTestCase {
    func testBuckets() {
        XCTAssertEqual(GPSFixQuality(horizontalAccuracyM: nil), .none)
        XCTAssertEqual(GPSFixQuality(horizontalAccuracyM: -1), .none)
        XCTAssertEqual(GPSFixQuality(horizontalAccuracyM: 5), .excellent)
        XCTAssertEqual(GPSFixQuality(horizontalAccuracyM: 15), .good)
        XCTAssertEqual(GPSFixQuality(horizontalAccuracyM: 60), .poor)
    }
}
