import Foundation
import CVCore
#if canImport(CoreMedia)
import CoreMedia
#endif

public struct CaptureSpec: Sendable, Hashable {
    public var cameras: CameraSelection
    public var quality: VideoQuality
    public var enableAudio: Bool

    public init(cameras: CameraSelection, quality: VideoQuality, enableAudio: Bool = true) {
        self.cameras = cameras
        self.quality = quality
        self.enableAudio = enableAudio
    }
}

/// A finished local recording, relative to the session directory.
public struct RecordedVideo: Sendable, Hashable {
    public var fileName: String
    public var camera: CameraPosition
    public var durationSeconds: Double?

    public init(fileName: String, camera: CameraPosition, durationSeconds: Double?) {
        self.fileName = fileName
        self.camera = camera
        self.durationSeconds = durationSeconds
    }
}

/// Events the session layer surfaces to the user (thermal pressure, interruptions).
public enum CaptureEvent: Sendable, Hashable {
    case thermalStepDown(to: Int) // new frame rate
    case interrupted(reason: String)
    case interruptionEnded
    case runtimeError(String)
}

#if canImport(CoreMedia)
/// Receives raw sample buffers from the capture engine — implemented by the
/// streaming engine. Calls arrive on the capture queue; implementations must
/// hand off fast.
public protocol StreamTap: AnyObject, Sendable {
    func appendVideo(_ sampleBuffer: CMSampleBuffer)
    func appendAudio(_ sampleBuffer: CMSampleBuffer)
}
#endif

/// What `SessionManager` drives. `MultiCamCaptureEngine` on device,
/// `FakeCaptureEngine` in tests and the simulator.
public protocol CaptureEngine: AnyObject, Sendable {
    /// Prepare inputs/outputs for the spec. Throws `SessionError`.
    func configure(_ spec: CaptureSpec) async throws
    func start() async throws
    func stop() async
    /// Begin writing video files into `directory` (one per camera).
    func startRecording(to directory: URL) async throws
    /// Finalize and return the recorded artifacts.
    func stopRecording() async throws -> [RecordedVideo]
    func events() -> AsyncStream<CaptureEvent>
    #if canImport(CoreMedia)
    /// Route one camera's buffers (plus audio) into a stream engine.
    func attachStreamTap(_ tap: StreamTap, camera: CameraPosition) async throws
    func detachStreamTap() async
    #endif
}

/// In-memory engine for unit tests and the iOS simulator (which has no
/// cameras). Writes a marker file per "recording" so upload paths can be
/// exercised end-to-end.
public final class FakeCaptureEngine: CaptureEngine, @unchecked Sendable {
    public enum Call: Sendable, Equatable {
        case configure(CaptureSpec)
        case start
        case stop
        case startRecording
        case stopRecording
        case attachTap(CameraPosition)
        case detachTap
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var spec: CaptureSpec?
    private var recordingDirectory: URL?
    private var eventContinuation: AsyncStream<CaptureEvent>.Continuation?

    /// Set to make the next configure/start call fail.
    public var configureError: Error?
    public var startError: Error?

    public init() {}

    public var calls: [Call] { lock.withLock { _calls } }

    private func record(_ call: Call) {
        lock.withLock { _calls.append(call) }
    }

    public func configure(_ spec: CaptureSpec) async throws {
        record(.configure(spec))
        if let configureError { throw configureError }
        lock.withLock { self.spec = spec }
    }

    public func start() async throws {
        record(.start)
        if let startError { throw startError }
    }

    public func stop() async {
        record(.stop)
    }

    public func startRecording(to directory: URL) async throws {
        record(.startRecording)
        lock.withLock { recordingDirectory = directory }
    }

    public func stopRecording() async throws -> [RecordedVideo] {
        record(.stopRecording)
        let (spec, dir) = lock.withLock { (self.spec, self.recordingDirectory) }
        guard let spec, let dir else { return [] }
        return spec.cameras.positions.map { position in
            let name = "\(position.rawValue).mov"
            try? Data("fake video \(position.rawValue)".utf8)
                .write(to: dir.appendingPathComponent(name))
            return RecordedVideo(fileName: name, camera: position, durationSeconds: 1.0)
        }
    }

    public func events() -> AsyncStream<CaptureEvent> {
        AsyncStream { continuation in
            lock.withLock { eventContinuation = continuation }
        }
    }

    public func emit(_ event: CaptureEvent) {
        lock.withLock { eventContinuation }?.yield(event)
    }

    #if canImport(CoreMedia)
    public func attachStreamTap(_ tap: StreamTap, camera: CameraPosition) async throws {
        record(.attachTap(camera))
    }

    public func detachStreamTap() async {
        record(.detachTap)
    }
    #endif
}
