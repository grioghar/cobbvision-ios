import Foundation
import SwiftUI
import WatchKit
import CVCore
import CVWatchBridge

/// View model for the watch UI: mirrors phone session state, relays commands,
/// and fires haptics on acks.
@Observable
@MainActor
final class WatchSessionModel {
    private let bridge = WatchPhoneBridge()
    private var started = false

    var snapshot = WatchStateSnapshot(phase: .idle)
    var liveG = WatchTelemetryTick(gLateral: 0, gLongitudinal: 0, speedMps: nil)
    /// True between sending a command and receiving the ack/denial.
    var commandInFlight = false

    func activate() {
        guard !started else { return }
        started = true
        bridge.activate()

        Task { [bridge] in
            for await snapshot in bridge.snapshots() {
                self.apply(snapshot)
            }
        }
        Task { [bridge] in
            for await tick in bridge.telemetry() {
                self.liveG = tick
            }
        }
    }

    private func apply(_ snapshot: WatchStateSnapshot) {
        let wasActive = self.snapshot.phase == .active
        self.snapshot = snapshot
        if !wasActive, snapshot.phase == .active {
            WKInterfaceDevice.current().play(.start)
        } else if wasActive, snapshot.phase == .idle {
            WKInterfaceDevice.current().play(.stop)
        }
    }

    func start(presetID: UUID) {
        send(.startSession(presetID: presetID))
    }

    func stopSession() {
        send(.stopSession)
    }

    func refresh() {
        send(.requestSnapshot, haptic: false)
    }

    private func send(_ command: WatchCommand, haptic: Bool = true) {
        guard !commandInFlight else { return }
        commandInFlight = true
        Task {
            let acked = await bridge.send(command)
            commandInFlight = false
            if haptic {
                WKInterfaceDevice.current().play(acked ? .success : .failure)
            }
        }
    }
}
