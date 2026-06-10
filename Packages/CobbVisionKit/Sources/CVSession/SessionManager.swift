import Foundation
import CVCore
import CVAPI
import CVTelemetry
import CVCapture
import CVStreaming
import CVExternalCam

/// The orchestrator. One source of truth (`SessionState`) fanned out to the
/// phone UI, the watch bridge, and CarPlay via `stateUpdates()`.
///
/// `start(preset:)` sequence — each step surfaces as `.preparing(step:)`:
///   1. telemetry up first (GPS warm-up costs the most wall-clock)
///   2. external cameras broadcast-start (concurrent with 3–4, never blocking)
///   3. capture configure + start (+ local recording)
///   4. stream connect + tap attach (when the preset streams)
///   5. `.active`, with a 1 Hz ticker folding telemetry/stream/thermal state
///
/// `stop()` reverses, writes the session manifest, and hands the directory to
/// `PostSessionUploader`.
public actor SessionManager {
    // MARK: - Dependencies

    private let capture: any CaptureEngine
    private let stream: (any StreamEngine)?
    private let locationSource: (any LocationSource)?
    private let motionSource: (any MotionSource)?
    private let externalCameras: ExternalCameraGroup
    private let uploader: PostSessionUploader?
    private let sessionsRoot: URL
    private let tokenStore: any TokenStore
    private let destinations: StreamDestinationStore
    private let telemetryHz: Double

    /// Minimum free disk space to allow recording (500 MB).
    private static let minFreeBytes: Int64 = 500_000_000

    // MARK: - State

    private(set) public var state: SessionState = .idle {
        didSet { stateContinuations.values.forEach { $0.yield(state) } }
    }
    private var stateContinuations: [UUID: AsyncStream<SessionState>.Continuation] = [:]

    public var calibration: VehicleFrameCalibration = .identity
    public var vehicleID: String?

    private var activeInfo: ActiveSessionInfo?
    private var activePreset: Preset?
    private var sessionDirectory: URL?
    private var telemetry: TelemetryRecorder?
    private var pumpTasks: [Task<Void, Never>] = []
    private var latestStreamHealth: StreamHealth = .notStreaming
    private var thermalWarning = false
    private var externalFailures: [String: String] = [:]

    public init(
        capture: any CaptureEngine,
        stream: (any StreamEngine)?,
        locationSource: (any LocationSource)?,
        motionSource: (any MotionSource)?,
        externalCameras: ExternalCameraGroup,
        uploader: PostSessionUploader?,
        destinations: StreamDestinationStore,
        tokenStore: any TokenStore,
        sessionsRoot: URL,
        telemetryHz: Double = 10
    ) {
        self.capture = capture
        self.stream = stream
        self.locationSource = locationSource
        self.motionSource = motionSource
        self.externalCameras = externalCameras
        self.uploader = uploader
        self.destinations = destinations
        self.tokenStore = tokenStore
        self.sessionsRoot = sessionsRoot
        self.telemetryHz = telemetryHz
    }

    public func stateUpdates() -> AsyncStream<SessionState> {
        AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    public func setCalibration(_ calibration: VehicleFrameCalibration) {
        self.calibration = calibration
    }

    public func setVehicleID(_ id: String?) {
        vehicleID = id
    }

    /// Live gauge feed for the dashboard (bypasses the 1 Hz state ticker).
    public func currentG() async -> (lateral: Double, longitudinal: Double, vertical: Double) {
        await telemetry?.latestG ?? (0, 0, 0)
    }

    // MARK: - Start

    public func start(preset: Preset) async {
        guard !state.isActive, case .idle = state else {
            return
        }

        let sessionID = UUID()
        let directory = sessionsRoot.appendingPathComponent(sessionID.uuidString)
        sessionDirectory = directory
        activePreset = preset
        externalFailures = [:]
        latestStreamHealth = .notStreaming
        thermalWarning = false

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            if preset.mode.contains(.record) {
                let free = Self.freeDiskBytes(at: sessionsRoot)
                guard free > Self.minFreeBytes else {
                    throw SessionError.storageFull(freeBytes: free)
                }
            }

            // 1. Telemetry first — GPS needs the longest warm-up.
            if preset.gpsEnabled || preset.gForceEnabled {
                state = .preparing(step: "Starting telemetry…")
                let recorder = TelemetryRecorder(
                    directory: directory,
                    hz: telemetryHz,
                    calibration: calibration,
                    trackName: "\(preset.name) — \(Self.dateLabel())"
                )
                try await recorder.start()
                telemetry = recorder
                startTelemetryPumps(preset: preset, recorder: recorder)
            }

            // 2. External cameras — concurrent, never blocks the phone.
            let extTask = Task { [externalCameras] in
                await externalCameras.broadcast(preset.externalCameraActionsOnStart)
            }

            // 3. Cameras.
            state = .preparing(step: "Configuring cameras…")
            let spec = CaptureSpec(cameras: preset.cameras, quality: preset.videoQuality)
            try await capture.configure(spec)
            try await capture.start()
            if preset.mode.contains(.record) {
                try await capture.startRecording(to: directory)
            }
            startCaptureEventPump()

            // 4. Stream.
            if preset.mode.contains(.stream) {
                state = .preparing(step: "Connecting stream…")
                try await connectStream(preset: preset)
            }

            externalFailures = await extTask.value

            // 5. Live.
            let info = ActiveSessionInfo(
                sessionID: sessionID,
                presetName: preset.name,
                startedAt: Date(),
                recording: preset.mode.contains(.record),
                streaming: latestStreamHealth,
                externalCams: await externalCameras.statuses()
            )
            activeInfo = info
            state = .active(info)
            startTicker()
        } catch {
            await teardownAfterFailure()
            state = .failed(error as? SessionError ?? .internalFailure(String(describing: error)))
        }
    }

    private func connectStream(preset: Preset) async throws {
        guard let stream else {
            throw SessionError.streamConnectFailed("no stream engine")
        }
        guard let destinationID = preset.streamDestinationID,
              let destination = destinations.destination(id: destinationID) else {
            throw SessionError.streamConnectFailed("preset has no stream destination configured")
        }
        let key = (try? tokenStore.read(account: destination.streamKeyKeychainRef)) ?? ""
        try await stream.connect(to: destination, streamKey: key, quality: preset.videoQuality)
        startStreamHealthPump()
        #if canImport(CoreMedia)
        if let tap = stream as? StreamTap {
            try await capture.attachStreamTap(tap, camera: preset.streamCamera)
        }
        #endif
    }

    // MARK: - Stop

    public func stop() async {
        guard state.isActive || isPreparing else { return }
        state = .stopping

        let preset = activePreset
        let directory = sessionDirectory

        // Streaming down first so viewers get a clean end.
        if preset?.mode.contains(.stream) == true {
            #if canImport(CoreMedia)
            await capture.detachStreamTap()
            #endif
            await stream?.disconnect()
        }

        var videos: [RecordedVideo] = []
        if preset?.mode.contains(.record) == true {
            videos = (try? await capture.stopRecording()) ?? []
        }
        await capture.stop()

        let telemetryOutput = try? await telemetry?.stop()
        cancelPumps()

        if let actions = preset?.externalCameraActionsOnStop {
            _ = await externalCameras.broadcast(actions)
        }

        if let preset, let directory {
            var manifest = SessionManifest(
                sessionID: activeInfo?.sessionID ?? UUID(),
                presetID: preset.id,
                presetName: preset.name,
                startedAt: activeInfo?.startedAt ?? Date(),
                endedAt: Date(),
                telemetryFileName: telemetryOutput?.telemetryFileURL != nil ? TelemetryRecorder.telemetryFileName : nil,
                videos: videos.map {
                    SessionManifest.VideoArtifact(
                        fileName: $0.fileName,
                        camera: $0.camera,
                        durationSeconds: $0.durationSeconds
                    )
                },
                peakG: telemetryOutput?.peaks ?? GPeaks(),
                vehicleID: vehicleID
            )
            if let gpx = telemetryOutput?.gpx {
                try? Data(gpx.utf8).write(to: directory.appendingPathComponent("track.gpx"), options: .atomic)
            } else {
                manifest.gpxUploaded = true // nothing to upload
            }
            try? manifest.write(to: directory)

            if let uploader {
                let dir = directory
                Task { await uploader.process(sessionDirectory: dir) }
            }
        }

        telemetry = nil
        activeInfo = nil
        activePreset = nil
        sessionDirectory = nil
        state = .idle
    }

    /// Clears a `.failed` state back to idle once the UI has shown it.
    public func acknowledgeFailure() {
        if case .failed = state {
            state = .idle
        }
    }

    private var isPreparing: Bool {
        if case .preparing = state { return true }
        return false
    }

    private func teardownAfterFailure() async {
        cancelPumps()
        if activePreset?.mode.contains(.stream) == true {
            #if canImport(CoreMedia)
            await capture.detachStreamTap()
            #endif
            await stream?.disconnect()
        }
        _ = try? await capture.stopRecording()
        await capture.stop()
        _ = try? await telemetry?.stop()
        telemetry = nil
        activeInfo = nil
        activePreset = nil
    }

    // MARK: - Pumps (stream source data into the actor)

    private func startTelemetryPumps(preset: Preset, recorder: TelemetryRecorder) {
        if preset.gpsEnabled, let locationSource {
            pumpTasks.append(Task {
                do {
                    for try await fix in locationSource.updates() {
                        guard !Task.isCancelled else { return }
                        await recorder.ingest(fix: fix)
                    }
                } catch {
                    // GPS failure degrades the session, never kills it.
                }
            })
        }
        if preset.gForceEnabled, let motionSource {
            pumpTasks.append(Task {
                for await sample in motionSource.samples(hz: 50) {
                    guard !Task.isCancelled else { return }
                    await recorder.ingest(motion: sample)
                }
            })
        }
    }

    private func startCaptureEventPump() {
        let events = capture.events()
        pumpTasks.append(Task {
            for await event in events {
                guard !Task.isCancelled else { return }
                await self.handleCaptureEvent(event)
            }
        })
    }

    private func handleCaptureEvent(_ event: CaptureEvent) {
        switch event {
        case .thermalStepDown:
            thermalWarning = true
        case .interrupted, .runtimeError, .interruptionEnded:
            // Recording keeps whatever frames arrive; the ticker's status
            // surface is enough for v1.
            break
        }
    }

    private func startStreamHealthPump() {
        guard let stream else { return }
        let health = stream.health()
        pumpTasks.append(Task {
            for await update in health {
                guard !Task.isCancelled else { return }
                await self.setStreamHealth(update)
            }
        })
    }

    private func setStreamHealth(_ health: StreamHealth) {
        latestStreamHealth = health
    }

    private func startTicker() {
        pumpTasks.append(Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self.tick()
            }
        })
    }

    private func tick() async {
        guard var info = activeInfo, state.isActive else { return }
        if let telemetry {
            let fix = await telemetry.latestFix
            info.gpsFix = GPSFixQuality(horizontalAccuracyM: staleness(fix) < 5 ? fix?.horizontalAccuracyM : nil)
            info.speedMps = staleness(fix) < 5 ? fix?.speedMps : nil
            info.peakG = await telemetry.peaks
        }
        info.streaming = latestStreamHealth
        info.thermalWarning = thermalWarning
        info.externalCams = await externalCameras.statuses()
        activeInfo = info
        state = .active(info)
    }

    private func staleness(_ fix: LocationFix?) -> TimeInterval {
        guard let fix else { return .infinity }
        return Date().timeIntervalSince(fix.timestamp)
    }

    private func cancelPumps() {
        pumpTasks.forEach { $0.cancel() }
        pumpTasks = []
    }

    // MARK: - Utilities

    private static func freeDiskBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    private static func dateLabel() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}
