#if os(iOS) && canImport(WatchConnectivity)
import Foundation
import WatchConnectivity
import CVCore

/// Phone side of the watch link.
///
/// - State snapshots go out via `updateApplicationContext` — latest-wins
///   delivery that survives the watch app being backgrounded or relaunched.
/// - Live telemetry goes out via `sendMessage` only while the watch is
///   reachable, throttled to 2 Hz (WatchConnectivity chokes above that).
/// - Commands arrive via `didReceiveMessage`; the reply carries a fresh
///   snapshot as the ack so the watch can fire haptics on confirmation.
public final class PhoneWatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lastTelemetrySend = Date.distantPast
    private var lastSnapshot: WatchStateSnapshot?

    /// Called for every command from the watch; returns the snapshot to ack with.
    public var onCommand: (@Sendable (WatchCommand) async -> WatchStateSnapshot)?

    public override init() {
        super.init()
    }

    public func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    public func push(snapshot: WatchStateSnapshot) {
        lock.withLock { lastSnapshot = snapshot }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        if let dict = try? WatchMessage.stateSnapshot(snapshot).encodedDictionary() {
            try? WCSession.default.updateApplicationContext(dict)
        }
    }

    public func pushTelemetry(_ tick: WatchTelemetryTick) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        let now = Date()
        let throttled = lock.withLock { () -> Bool in
            guard now.timeIntervalSince(lastTelemetrySend) >= 0.5 else { return true }
            lastTelemetrySend = now
            return false
        }
        guard !throttled else { return }
        if let dict = try? WatchMessage.telemetryTick(tick).encodedDictionary() {
            WCSession.default.sendMessage(dict, replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: - WCSessionDelegate

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // Re-push the latest snapshot so a freshly-paired watch isn't blank.
        if activationState == .activated, let snapshot = lock.withLock({ lastSnapshot }) {
            push(snapshot: snapshot)
        }
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let watchMessage = WatchMessage(dictionary: message),
              case .command(let command) = watchMessage,
              let onCommand else {
            replyHandler([:])
            return
        }
        Task {
            let snapshot = await onCommand(command)
            replyHandler((try? WatchMessage.stateSnapshot(snapshot).encodedDictionary()) ?? [:])
        }
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let watchMessage = WatchMessage(dictionary: message),
              case .command(let command) = watchMessage,
              let onCommand else { return }
        Task { _ = await onCommand(command) }
    }
}
#endif
