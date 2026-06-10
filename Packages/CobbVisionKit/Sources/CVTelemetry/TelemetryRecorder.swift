import Foundation
import CVCore

/// Merges GPS fixes and motion samples into fixed-rate `TelemetrySample` bins,
/// appends them to `telemetry.jsonl` in the session directory, and tracks
/// session peaks. `SessionManager` pumps the source streams into `ingest*`;
/// tests call them directly.
///
/// Binning: a bin is `1/hz` seconds wide, anchored at the first ingested
/// timestamp. Whichever ingest call first crosses the bin boundary flushes it.
/// GPS is carried forward between fixes (a 1 Hz GPS chip still fills 10 Hz
/// bins); g-forces are peak-held (max |value| per axis) within each bin so a
/// spike between bins is never lost.
public actor TelemetryRecorder {
    public struct Output: Sendable {
        public let telemetryFileURL: URL?
        public let gpx: String?
        public let peaks: GPeaks
        public let sampleCount: Int
    }

    private let directory: URL
    private let binWidth: TimeInterval
    private let calibration: VehicleFrameCalibration
    private let trackName: String

    private var fileHandle: FileHandle?
    private var encoder = JSONEncoder()

    private var binStart: Date?
    private var lastFix: LocationFix?
    private var binPeakLateral: Double?
    private var binPeakLongitudinal: Double?
    private var binPeakVertical: Double?

    private(set) public var peaks = GPeaks()
    private(set) public var sampleCount = 0
    private(set) public var latestFix: LocationFix?
    private(set) public var latestG: (lateral: Double, longitudinal: Double, vertical: Double) = (0, 0, 0)

    /// How long a GPS fix is carried forward before bins go fix-less.
    private static let fixStaleness: TimeInterval = 3.0

    public static let telemetryFileName = "telemetry.jsonl"

    public init(
        directory: URL,
        hz: Double,
        calibration: VehicleFrameCalibration = .identity,
        trackName: String
    ) {
        self.directory = directory
        self.binWidth = 1.0 / max(1, hz)
        self.calibration = calibration
        self.trackName = trackName
        encoder.dateEncodingStrategy = .iso8601
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.telemetryFileName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: url)
    }

    public func ingest(fix: LocationFix) {
        // Flush completed bins first so earlier bins keep the fix that was
        // current while they were open, not this newer one.
        advanceBins(to: fix.timestamp)
        latestFix = fix
        lastFix = fix
    }

    public func ingest(motion: MotionSample) {
        // Flush first: a sample that crosses the boundary belongs to the new bin.
        advanceBins(to: motion.timestamp)

        let g = calibration.vehicleFrame(motion.userAcceleration)
        latestG = g
        peaks.register(lateral: g.lateral, longitudinal: g.longitudinal, vertical: g.vertical)

        func peakHold(_ current: Double?, _ new: Double) -> Double {
            guard let current else { return new }
            return abs(new) > abs(current) ? new : current
        }
        binPeakLateral = peakHold(binPeakLateral, g.lateral)
        binPeakLongitudinal = peakHold(binPeakLongitudinal, g.longitudinal)
        binPeakVertical = peakHold(binPeakVertical, g.vertical)
    }

    /// Flushes the open bin and finalizes the JSONL + GPX output.
    public func stop() throws -> Output {
        if binStart != nil {
            flushBin(endingAt: binStart!.addingTimeInterval(binWidth))
        }
        try fileHandle?.close()
        fileHandle = nil

        let fileURL = directory.appendingPathComponent(Self.telemetryFileName)
        let gpx = sampleCount > 0 ? try? buildGPX(from: fileURL) : nil
        return Output(
            telemetryFileURL: sampleCount > 0 ? fileURL : nil,
            gpx: (gpx?.isEmpty == false) ? gpx : nil,
            peaks: peaks,
            sampleCount: sampleCount
        )
    }

    // MARK: - Binning

    private func advanceBins(to timestamp: Date) {
        guard let start = binStart else {
            binStart = timestamp
            return
        }
        // Flush every completed bin between the anchor and the new timestamp
        // (gaps produce carried-forward GPS bins only if a fix is fresh).
        var binEnd = start.addingTimeInterval(binWidth)
        guard timestamp >= binEnd else { return }
        var guardCount = 0
        while timestamp >= binEnd, guardCount < 10_000 {
            flushBin(endingAt: binEnd)
            binStart = binEnd
            binEnd = binEnd.addingTimeInterval(binWidth)
            guardCount += 1
        }
    }

    private func flushBin(endingAt binEnd: Date) {
        defer {
            binPeakLateral = nil
            binPeakLongitudinal = nil
            binPeakVertical = nil
        }

        let fix: LocationFix? = {
            guard let lastFix else { return nil }
            return binEnd.timeIntervalSince(lastFix.timestamp) <= Self.fixStaleness ? lastFix : nil
        }()

        let hasG = binPeakLateral != nil || binPeakLongitudinal != nil || binPeakVertical != nil
        guard fix != nil || hasG else { return }

        let sample = TelemetrySample(
            timestamp: binEnd,
            latitude: fix?.latitude,
            longitude: fix?.longitude,
            altitudeM: fix?.altitudeM,
            speedMps: fix?.speedMps,
            horizontalAccuracyM: fix?.horizontalAccuracyM,
            gLateral: binPeakLateral,
            gLongitudinal: binPeakLongitudinal,
            gVertical: binPeakVertical
        )

        if let handle = fileHandle, var line = try? encoder.encode(sample) {
            line.append(0x0A)
            try? handle.write(contentsOf: line)
        }
        sampleCount += 1
    }

    // MARK: - GPX

    /// Streams the JSONL back through `GPXWriter` so a multi-hour session
    /// never holds both representations in memory.
    private func buildGPX(from fileURL: URL) throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var writer = GPXWriter(trackName: trackName)

        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            if lineEnd > lineStart,
               let sample = try? decoder.decode(TelemetrySample.self, from: data[lineStart..<lineEnd]) {
                writer.append(sample)
            }
            lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
        }
        return writer.pointCount > 0 ? writer.finish() : ""
    }
}
