#if os(iOS)
import Foundation
import CoreLocation

/// GPS via a CLLocationManager delegate bridged to an AsyncThrowingStream
/// (iOS 16-compatible — `CLLocationUpdate.liveUpdates` needs 17).
/// `allowsBackgroundLocationUpdates` + the `location` background mode keep
/// fixes flowing while the app is backgrounded, with the system indicator on.
public final class CoreLocationSource: NSObject, LocationSource, CLLocationManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var manager: CLLocationManager?
    private var continuation: AsyncThrowingStream<LocationFix, Error>.Continuation?

    public override init() {
        super.init()
    }

    public func updates() -> AsyncThrowingStream<LocationFix, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            // CLLocationManager wants a run-loop thread; main is the safe one.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let manager = CLLocationManager()
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
                manager.activityType = .automotiveNavigation
                manager.distanceFilter = kCLDistanceFilterNone
                manager.pausesLocationUpdatesAutomatically = false
                if Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") != nil {
                    manager.allowsBackgroundLocationUpdates = true
                    manager.showsBackgroundLocationIndicator = true
                }
                self.lock.withLock { self.manager = manager }
                manager.startUpdatingLocation()
            }
            continuation.onTermination = { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let manager = self.lock.withLock { () -> CLLocationManager? in
                        let m = self.manager
                        self.manager = nil
                        self.continuation = nil
                        return m
                    }
                    manager?.stopUpdatingLocation()
                    manager?.delegate = nil
                }
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let continuation = lock.withLock { self.continuation }
        for location in locations {
            continuation?.yield(LocationFix(
                timestamp: location.timestamp,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitudeM: location.verticalAccuracy > 0 ? location.altitude : nil,
                speedMps: location.speed >= 0 ? location.speed : nil,
                horizontalAccuracyM: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
            ))
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorDenied is fatal; transient errors (no fix yet) are not.
        if let clError = error as? CLError, clError.code == .denied {
            let continuation = lock.withLock { self.continuation }
            continuation?.finish(throwing: error)
        }
    }
}

/// Requests when-in-use authorization up front (background updates ride on
/// the `location` background mode plus `allowsBackgroundLocationUpdates`).
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
