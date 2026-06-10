import Foundation
import CVCore

/// Registry of connected external cameras plus group broadcast: one tap fires
/// start/stop/mode on every camera concurrently, with a per-camera timeout.
/// Partial failure is the normal case (a GoPro fell asleep, the Insta360 is a
/// stub) — results surface per camera and never block the phone session.
public actor ExternalCameraGroup {
    public static let commandTimeout: Duration = .seconds(5)

    private var controllers: [String: any CameraController] = [:]

    public init() {}

    public func register(_ controller: any CameraController) {
        controllers[controller.info.id] = controller
    }

    public func unregister(id: String) async {
        if let controller = controllers.removeValue(forKey: id) {
            await controller.disconnect()
        }
    }

    public var registeredIDs: [String] { Array(controllers.keys) }

    public func statuses() async -> [ExternalCamStatus] {
        var result: [ExternalCamStatus] = []
        for controller in controllers.values {
            result.append(await controller.currentStatus())
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Fires `actions` on all registered cameras concurrently. Returns
    /// per-camera failure messages (empty = everything worked).
    @discardableResult
    public func broadcast(_ actions: [ExternalCamAction]) async -> [String: String] {
        guard !controllers.isEmpty, !actions.isEmpty else { return [:] }
        let timeout = Self.commandTimeout
        let snapshot = controllers

        return await withTaskGroup(of: (String, String?).self) { group in
            for (id, controller) in snapshot {
                group.addTask {
                    do {
                        try await Self.withTimeout(timeout) {
                            for action in actions {
                                try await controller.perform(action)
                            }
                        }
                        return (id, nil)
                    } catch {
                        let message = (error as? ExternalCamError).map(String.init(describing:))
                            ?? error.localizedDescription
                        return (id, message)
                    }
                }
            }
            var failures: [String: String] = [:]
            for await (id, failure) in group {
                if let failure { failures[id] = failure }
            }
            return failures
        }
    }

    private static func withTimeout(
        _ timeout: Duration,
        _ work: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ExternalCamError.timeout
            }
            // First finisher wins; cancel the loser.
            try await group.next()
            group.cancelAll()
        }
    }
}
