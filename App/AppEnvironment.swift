import Foundation
import SwiftUI
import CVCore
import CVAPI
import CVTelemetry
import CVCapture
import CVStreaming
import CVExternalCam
import CVSession
import CVWatchBridge

/// Composition root. Built once by `AppDelegate`; shared by the phone UI, the
/// CarPlay scene, and the watch bridge. ObservableObject (not @Observable)
/// keeps the deployment floor at iOS 16.
@MainActor
final class AppEnvironment: ObservableObject {
    // MARK: - Services

    let api: APIClient
    let presetStore: PresetStore
    let destinations: StreamDestinationStore
    let sessionManager: SessionManager
    let uploader: PostSessionUploader
    let library: SessionLibrary
    let externalCameras: ExternalCameraGroup
    let watchBridge = PhoneWatchBridge()
    let locationPermission = LocationPermission()
    /// Concrete engine kept for preview layers (nil in the simulator).
    let multiCamEngine: MultiCamCaptureEngine?
    let goProScanner = GoProScanner()
    /// Shared motion source — the session pumps and the calibration flow read it.
    let motionSource: any MotionSource

    // MARK: - UI state (mirrors of actor state for SwiftUI)

    @Published private(set) var isLoggedIn = false
    @Published private(set) var user: User?
    @Published private(set) var vehicles: [Vehicle] = []
    @Published private(set) var presets: [Preset] = []
    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var uploadProgress: PostSessionUploader.UploadProgress?
    @Published var selectedVehicleID: String? {
        didSet {
            UserDefaults.standard.set(selectedVehicleID, forKey: "selectedVehicleID")
            Task { await sessionManager.setVehicleID(selectedVehicleID) }
        }
    }

    private static let calibrationKey = "vehicleFrameCalibration"

    init() {
        let api = APIClient()
        self.api = api
        let presetStore = PresetStore(api: api)
        self.presetStore = presetStore
        let destinations = StreamDestinationStore()
        self.destinations = destinations

        let sessionsRoot = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        library = SessionLibrary(sessionsRoot: sessionsRoot)

        let uploader = PostSessionUploader(api: api, sessionsRoot: sessionsRoot)
        self.uploader = uploader

        let externalCameras = ExternalCameraGroup()
        self.externalCameras = externalCameras

        #if targetEnvironment(simulator)
        let capture: any CaptureEngine = FakeCaptureEngine()
        multiCamEngine = nil
        let motion: any MotionSource = ReplayMotionSource.syntheticDrive(durationSeconds: 600, start: Date())
        #else
        let engine = MultiCamCaptureEngine()
        multiCamEngine = engine
        let capture: any CaptureEngine = engine
        let motion: any MotionSource = CoreMotionSource()
        #endif
        motionSource = motion

        sessionManager = SessionManager(
            capture: capture,
            stream: HaishinStreamEngineFactory.make(),
            locationSource: CoreLocationSource(),
            motionSource: motion,
            externalCameras: externalCameras,
            uploader: uploader,
            destinations: destinations,
            tokenStore: KeychainStore(),
            sessionsRoot: sessionsRoot
        )

        selectedVehicleID = UserDefaults.standard.string(forKey: "selectedVehicleID")

        Task { await bootstrap() }
    }

    // MARK: - Lifecycle

    private func bootstrap() async {
        isLoggedIn = await api.isLoggedIn
        if let data = UserDefaults.standard.data(forKey: Self.calibrationKey),
           let calibration = try? JSONDecoder().decode(VehicleFrameCalibration.self, from: data) {
            await sessionManager.setCalibration(calibration)
        }
        await sessionManager.setVehicleID(selectedVehicleID)

        watchBridge.onCommand = { [weak self] command in
            await self?.handleWatchCommand(command)
                ?? WatchStateSnapshot(phase: .idle)
        }
        watchBridge.activate()

        // Fan the session state out to SwiftUI, the watch, and uploads.
        let states = await sessionManager.stateUpdates()
        Task { [weak self] in
            for await state in states {
                guard let self else { return }
                self.sessionState = state
                self.watchBridge.push(snapshot: self.makeWatchSnapshot(state))
            }
        }
        let progress = await uploader.progressUpdates()
        Task { [weak self] in
            for await update in progress {
                self?.uploadProgress = update
            }
        }
        startWatchTelemetryPump()

        if isLoggedIn {
            await refreshFromServer()
        } else {
            presets = await presetStore.presets
        }
        await uploader.processPending()
    }

    func refreshFromServer() async {
        if let me = try? await api.me() {
            user = me
        }
        if let vehicles = try? await api.vehicles() {
            self.vehicles = vehicles
            if selectedVehicleID == nil { selectedVehicleID = vehicles.first?.id }
        }
        await presetStore.refresh()
        presets = await presetStore.presets
        pushIdleSnapshotToWatch()
    }

    // MARK: - Auth

    func login(email: String, password: String) async throws {
        let response = try await api.login(email: email, password: password)
        user = response.user
        vehicles = response.vehicles
        isLoggedIn = true
        if selectedVehicleID == nil { selectedVehicleID = vehicles.first?.id }
        await refreshFromServer()
    }

    func logout() async {
        await api.logout()
        isLoggedIn = false
        user = nil
        vehicles = []
    }

    // MARK: - Presets

    func savePresets(_ updated: [Preset]) async {
        await presetStore.save(updated)
        presets = await presetStore.presets
        pushIdleSnapshotToWatch()
    }

    // MARK: - Calibration

    func saveCalibration(_ calibration: VehicleFrameCalibration) async {
        if let data = try? JSONEncoder().encode(calibration) {
            UserDefaults.standard.set(data, forKey: Self.calibrationKey)
        }
        await sessionManager.setCalibration(calibration)
    }

    // MARK: - Watch

    private func handleWatchCommand(_ command: WatchCommand) async -> WatchStateSnapshot {
        switch command {
        case .startSession(let presetID):
            if let preset = presets.first(where: { $0.id == presetID }) {
                await sessionManager.start(preset: preset)
            }
        case .stopSession:
            await sessionManager.stop()
        case .requestSnapshot:
            break
        }
        return makeWatchSnapshot(await sessionManager.state)
    }

    private func makeWatchSnapshot(_ state: SessionState) -> WatchStateSnapshot {
        WatchStateSnapshot(
            from: state,
            presets: presets.map { WatchPresetSummary(id: $0.id, name: $0.name) }
        )
    }

    private func pushIdleSnapshotToWatch() {
        watchBridge.push(snapshot: makeWatchSnapshot(sessionState))
    }

    private func startWatchTelemetryPump() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                guard self.sessionState.isActive else { continue }
                let g = await self.sessionManager.currentG()
                let speed = self.sessionState.activeInfo?.speedMps
                self.watchBridge.pushTelemetry(WatchTelemetryTick(
                    gLateral: g.lateral,
                    gLongitudinal: g.longitudinal,
                    speedMps: speed
                ))
            }
        }
    }
}

/// HaishinKit only links on device builds; the simulator gets the fake.
enum HaishinStreamEngineFactory {
    static func make() -> (any StreamEngine)? {
        #if targetEnvironment(simulator)
        return FakeStreamEngine()
        #else
        return HaishinStreamEngine()
        #endif
    }
}
