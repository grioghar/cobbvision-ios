#if os(watchOS) && canImport(WatchConnectivity)
import Foundation
import WatchConnectivity
import CVCore

/// Watch side of the link. Snapshots arrive via application context (and as
/// command acks); telemetry ticks via live messages while reachable.
public final class WatchPhoneBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotContinuations: [UUID: AsyncStream<WatchStateSnapshot>.Continuation] = [:]
    private var telemetryContinuations: [UUID: AsyncStream<WatchTelemetryTick>.Continuation] = [:]
    private(set) public var latestSnapshot: WatchStateSnapshot?

    public override init() {
        super.init()
    }

    public func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    public func snapshots() -> AsyncStream<WatchStateSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                snapshotContinuations[id] = continuation
                // Replay whatever we already have (incl. stale app context).
                if let latest = latestSnapshot {
                    continuation.yield(latest)
                } else if let dict = WCSession.isSupported()
                    ? WCSession.default.receivedApplicationContext : nil,
                    let message = WatchMessage(dictionary: dict),
                    case .stateSnapshot(let snapshot) = message {
                    latestSnapshot = snapshot
                    continuation.yield(snapshot)
                }
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock { self?.snapshotContinuations.removeValue(forKey: id) }
            }
        }
    }

    public func telemetry() -> AsyncStream<WatchTelemetryTick> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { telemetryContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock { self?.telemetryContinuations.removeValue(forKey: id) }
            }
        }
    }

    /// Sends a command. Returns true when the phone acked (haptic-worthy);
    /// falls back to `transferUserInfo` (queued delivery) when unreachable.
    public func send(_ command: WatchCommand) async -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let dict = try? WatchMessage.command(command).encodedDictionary() else {
            return false
        }
        guard WCSession.default.isReachable else {
            WCSession.default.transferUserInfo(dict)
            return false
        }
        return await withCheckedContinuation { continuation in
            WCSession.default.sendMessage(dict, replyHandler: { [weak self] reply in
                if let message = WatchMessage(dictionary: reply),
                   case .stateSnapshot(let snapshot) = message {
                    self?.deliver(snapshot: snapshot)
                }
                continuation.resume(returning: true)
            }, errorHandler: { _ in
                WCSession.default.transferUserInfo(dict)
                continuation.resume(returning: false)
            })
        }
    }

    private func deliver(snapshot: WatchStateSnapshot) {
        let conts = lock.withLock { () -> [AsyncStream<WatchStateSnapshot>.Continuation] in
            latestSnapshot = snapshot
            return Array(snapshotContinuations.values)
        }
        conts.forEach { $0.yield(snapshot) }
    }

    // MARK: - WCSessionDelegate

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let message = WatchMessage(dictionary: applicationContext),
              case .stateSnapshot(let snapshot) = message else { return }
        deliver(snapshot: snapshot)
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let watchMessage = WatchMessage(dictionary: message) else { return }
        switch watchMessage {
        case .stateSnapshot(let snapshot):
            deliver(snapshot: snapshot)
        case .telemetryTick(let tick):
            let conts = lock.withLock { Array(telemetryContinuations.values) }
            conts.forEach { $0.yield(tick) }
        case .command:
            break
        }
    }
}
#endif
