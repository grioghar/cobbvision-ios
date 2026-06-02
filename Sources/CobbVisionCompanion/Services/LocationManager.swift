import CoreLocation
import Combine
import Foundation

final class LocationManager: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isRecording = false
    @Published var currentLocation: CLLocation?
    @Published var currentSession: DriveSession?

    // MARK: - Private

    private let manager: CLLocationManager = {
        let m = CLLocationManager()
        m.desiredAccuracy           = kCLLocationAccuracyBestForNavigation
        m.activityType              = .automotiveNavigation
        m.distanceFilter            = kCLDistanceFilterNone
        m.allowsBackgroundLocationUpdates = true
        m.pausesLocationUpdatesAutomatically = false
        m.showsBackgroundLocationIndicator   = true
        return m
    }()

    override init() {
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
    }

    // MARK: - Public interface

    func requestPermission() {
        manager.requestAlwaysAuthorization()
    }

    func startRecording() {
        guard authorizationStatus == .authorizedAlways ||
              authorizationStatus == .authorizedWhenInUse else {
            requestPermission()
            return
        }
        currentSession = DriveSession()
        isRecording    = true
        manager.startUpdatingLocation()
    }

    func stopRecording() -> DriveSession? {
        manager.stopUpdatingLocation()
        isRecording = false
        currentSession?.endedAt = Date()
        let finished = currentSession
        currentSession = nil
        return finished
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        guard isRecording, var session = currentSession else { return }
        for loc in locations {
            // Reject points with poor accuracy (> 30 m) or negative speed
            guard loc.horizontalAccuracy >= 0,
                  loc.horizontalAccuracy <= 30 else { continue }
            currentLocation = loc
            session.trackPoints.append(TrackPoint(from: loc))
        }
        currentSession = session
    }

    func locationManager(_ manager: CLLocationManager,
                         didFailWithError error: Error) {
        print("[LocationManager] error: \(error.localizedDescription)")
    }
}
