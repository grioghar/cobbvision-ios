import Foundation
import CVCore

public struct ExternalCameraInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var vendor: ExternalCamVendor
    public var name: String

    public init(id: String, vendor: ExternalCamVendor, name: String) {
        self.id = id
        self.vendor = vendor
        self.name = name
    }
}

public enum ExternalCamError: Error, Sendable {
    case notConnected
    case sdkUnavailable(String)
    case bluetoothUnavailable
    case commandFailed(String)
    case timeout
}

/// One external action camera (GoPro, Insta360, …). Implementations are
/// responsible for their own reconnect behavior; group orchestration and
/// timeouts live in `ExternalCameraGroup`.
public protocol CameraController: Sendable {
    var info: ExternalCameraInfo { get }
    func connect() async throws
    func disconnect() async
    func startRecording() async throws
    func stopRecording() async throws
    func setMode(_ mode: ExternalCamMode) async throws
    func currentStatus() async -> ExternalCamStatus
}

public extension CameraController {
    func perform(_ action: ExternalCamAction) async throws {
        switch action {
        case .startRecording: try await startRecording()
        case .stopRecording: try await stopRecording()
        case .setMode(let mode): try await setMode(mode)
        }
    }
}

/// Insta360's mobile SDK is private (application pending). The stub keeps the
/// UI surface honest — the camera shows up greyed-out with this message —
/// and reserves the integration seam.
public struct Insta360Controller: CameraController {
    public let info: ExternalCameraInfo

    public init(name: String = "Insta360") {
        info = ExternalCameraInfo(id: "insta360-pending", vendor: .insta360, name: name)
    }

    private var unavailable: ExternalCamError {
        .sdkUnavailable("Insta360 SDK application pending — control coming soon.")
    }

    public func connect() async throws { throw unavailable }
    public func disconnect() async {}
    public func startRecording() async throws { throw unavailable }
    public func stopRecording() async throws { throw unavailable }
    public func setMode(_ mode: ExternalCamMode) async throws { throw unavailable }

    public func currentStatus() async -> ExternalCamStatus {
        ExternalCamStatus(
            id: info.id, vendor: .insta360, name: info.name,
            phase: .disconnected,
            detail: "Awaiting Insta360 SDK access"
        )
    }
}

/// Scripted test double.
public final class FakeCameraController: CameraController, @unchecked Sendable {
    public enum Call: Sendable, Equatable {
        case connect, disconnect, start, stop
        case setMode(ExternalCamMode)
    }

    public let info: ExternalCameraInfo
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var phase: ExternalCamStatus.Phase = .disconnected

    /// Set to make commands fail.
    public var commandError: Error?
    /// Set to delay every command (for group-timeout tests).
    public var commandDelay: Duration?

    public init(id: String = UUID().uuidString, vendor: ExternalCamVendor = .gopro, name: String = "Fake GoPro") {
        info = ExternalCameraInfo(id: id, vendor: vendor, name: name)
    }

    public var calls: [Call] { lock.withLock { _calls } }

    private func run(_ call: Call, newPhase: ExternalCamStatus.Phase?) async throws {
        if let commandDelay { try? await Task.sleep(for: commandDelay) }
        lock.withLock { _calls.append(call) }
        if let commandError { throw commandError }
        if let newPhase { lock.withLock { phase = newPhase } }
    }

    public func connect() async throws { try await run(.connect, newPhase: .ready) }
    public func disconnect() async { try? await run(.disconnect, newPhase: .disconnected) }
    public func startRecording() async throws { try await run(.start, newPhase: .recording) }
    public func stopRecording() async throws { try await run(.stop, newPhase: .ready) }
    public func setMode(_ mode: ExternalCamMode) async throws { try await run(.setMode(mode), newPhase: nil) }

    public func currentStatus() async -> ExternalCamStatus {
        ExternalCamStatus(
            id: info.id, vendor: info.vendor, name: info.name,
            phase: lock.withLock { phase }
        )
    }
}
