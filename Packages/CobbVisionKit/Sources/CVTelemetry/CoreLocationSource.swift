#if os(iOS)
import Foundation
import CoreLocation

/// GPS via the iOS 17 `CLLocationUpdate.liveUpdates` async API. While a
/// session is active a `CLBackgroundActivitySession` keeps updates flowing
/// with the app backgrounded (shows the system location indicator).
public final class CoreLocationSource: LocationSource {
    public init() {}

    public func updates() -> AsyncThrowingStream<LocationFix, Error> {
        AsyncThrowingStream { continuation in
            let backgroundSession = CLBackgroundActivitySession()
            let task = Task {
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                        guard let location = update.location else { continue }
                        continuation.yield(LocationFix(
                            timestamp: location.timestamp,
                            latitude: location.coordinate.latitude,
                            longitude: location.coordinate.longitude,
                            altitudeM: location.verticalAccuracy > 0 ? location.altitude : nil,
                            speedMps: location.speed >= 0 ? location.speed : nil,
                            horizontalAccuracyM: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                backgroundSession.invalidate()
            }
        }
    }
}

/// Requests when-in-use authorization up front (the background activity
/// session covers backgrounded sessions without "Always").
@MainActor
public final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Bool, Never>?

    public override init() {
        super.init()
        manager.delegate = self
    }

    public var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    public func request() async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                continuation = cont
                manager.requestWhenInUseAuthorization()
            }
        default:
            return false
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined else { return }
        Task { @MainActor in
            continuation?.resume(returning: status == .authorizedWhenInUse || status == .authorizedAlways)
            continuation = nil
        }
    }
}
#endif
