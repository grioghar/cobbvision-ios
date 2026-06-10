import Foundation
import CVCore

/// Live-stream transport. `HaishinStreamEngine` (RTMP/SRT) on device; tests
/// use `FakeStreamEngine`. The engine also acts as the capture engine's
/// `StreamTap` — `SessionManager` attaches it to the chosen camera.
public protocol StreamEngine: AnyObject, Sendable {
    /// `streamKey` comes from the Keychain at call time, never from the model.
    func connect(to destination: StreamDestination, streamKey: String, quality: VideoQuality) async throws
    func disconnect() async
    func health() -> AsyncStream<StreamHealth>
}

public final class FakeStreamEngine: StreamEngine, @unchecked Sendable {
    public enum Call: Sendable, Equatable {
        case connect(kind: StreamDestination.Kind, url: String)
        case disconnect
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var continuations: [UUID: AsyncStream<StreamHealth>.Continuation] = [:]
    public var connectError: Error?

    public init() {}

    public var calls: [Call] { lock.withLock { _calls } }

    public func connect(to destination: StreamDestination, streamKey: String, quality: VideoQuality) async throws {
        lock.withLock { _calls.append(.connect(kind: destination.kind, url: destination.url)) }
        if let connectError { throw connectError }
        emit(.live(bitrateBps: quality.recordBitrate, rttMs: nil))
    }

    public func disconnect() async {
        lock.withLock { _calls.append(.disconnect) }
        emit(.disconnected(reason: nil))
    }

    public func health() -> AsyncStream<StreamHealth> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock { self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func emit(_ health: StreamHealth) {
        let conts = lock.withLock { Array(continuations.values) }
        conts.forEach { $0.yield(health) }
    }
}
