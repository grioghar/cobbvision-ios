import XCTest
@testable import CVCore

final class GPXWriterTests: XCTestCase {
    private func sample(
        t: TimeInterval,
        lat: Double? = 33.95,
        lon: Double? = -84.55,
        alt: Double? = 300,
        speed: Double? = 31.3,
        gLat: Double? = 0.42,
        gLon: Double? = -0.9
    ) -> TelemetrySample {
        TelemetrySample(
            timestamp: Date(timeIntervalSince1970: t),
            latitude: lat,
            longitude: lon,
            altitudeM: alt,
            speedMps: speed,
            gLateral: gLat,
            gLongitudinal: gLon,
            gVertical: nil
        )
    }

    func testProducesValidShape() {
        var writer = GPXWriter(trackName: "Test & <Drive>")
        XCTAssertTrue(writer.append(sample(t: 1_750_000_000)))
        XCTAssertTrue(writer.append(sample(t: 1_750_000_000.1)))
        let gpx = writer.finish()

        XCTAssertTrue(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(gpx.contains("<gpx version=\"1.1\" creator=\"CobbVision iOS\""))
        XCTAssertTrue(gpx.contains("<name>Test &amp; &lt;Drive&gt;</name>"))
        XCTAssertTrue(gpx.contains("lat=\"33.95\""))
        XCTAssertTrue(gpx.contains("lon=\"-84.55\""))
        XCTAssertTrue(gpx.contains("<ele>300.0</ele>"))
        XCTAssertTrue(gpx.contains("<gpxtpx:speed>31.3</gpxtpx:speed>"))
        XCTAssertTrue(gpx.contains("<cv:gforce lateral=\"0.42\" longitudinal=\"-0.9\" vertical=\"\"/>"))
        XCTAssertTrue(gpx.hasSuffix("</gpx>"))
        XCTAssertEqual(writer.pointCount, 2)

        // Balanced tags.
        XCTAssertEqual(gpx.components(separatedBy: "<trkpt").count, gpx.components(separatedBy: "</trkpt>").count)
        XCTAssertEqual(gpx.components(separatedBy: "<trkseg>").count, 2)
        XCTAssertEqual(gpx.components(separatedBy: "</trkseg>").count, 2)
    }

    func testTimestampsAreISO8601UTC() {
        var writer = GPXWriter(trackName: "t")
        writer.append(sample(t: 0))
        let gpx = writer.finish()
        XCTAssertTrue(gpx.contains("<time>1970-01-01T00:00:00.000Z</time>"), "got: \(gpx)")
    }

    func testSkipsSamplesWithoutFix() {
        var writer = GPXWriter(trackName: "t")
        XCTAssertFalse(writer.append(sample(t: 0, lat: nil, lon: nil)))
        XCTAssertEqual(writer.pointCount, 0)
        let gpx = writer.finish()
        XCTAssertFalse(gpx.contains("<trkpt"))
    }

    func testOmitsEmptyExtensionBlocks() {
        var writer = GPXWriter(trackName: "t")
        writer.append(sample(t: 0, alt: nil, speed: nil, gLat: nil, gLon: nil))
        let gpx = writer.finish()
        XCTAssertFalse(gpx.contains("<extensions>"))
        XCTAssertFalse(gpx.contains("<ele>"))
    }

    func testCoordinatePrecisionPreserved() {
        var writer = GPXWriter(trackName: "t")
        writer.append(sample(t: 0, lat: 33.1234567, lon: -84.7654321))
        let gpx = writer.finish()
        XCTAssertTrue(gpx.contains("lat=\"33.1234567\""))
        XCTAssertTrue(gpx.contains("lon=\"-84.7654321\""))
    }
}

final class SessionManifestTests: XCTestCase {
    func testWriteReadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cv-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var manifest = SessionManifest(
            sessionID: UUID(),
            presetID: UUID(),
            presetName: "Track day",
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            telemetryFileName: "telemetry.jsonl",
            videos: [.init(fileName: "rear.mov", camera: .rear, nextChunkIndex: 3)]
        )
        try manifest.write(to: dir)
        let loaded = try SessionManifest.read(from: dir)
        XCTAssertEqual(loaded, manifest)
        XCTAssertFalse(loaded.fullyUploaded)

        manifest.gpxUploaded = true
        manifest.videos[0].uploaded = true
        XCTAssertTrue(manifest.fullyUploaded)
    }
}
