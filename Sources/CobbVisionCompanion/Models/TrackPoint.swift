import CoreLocation
import Foundation

/// A single GPS sample recorded during a drive session.
struct TrackPoint: Codable {
    let latitude:           Double
    let longitude:          Double
    let altitude:           Double   // metres
    let speedMS:            Double   // m/s  (negative = invalid, treat as 0)
    let horizontalAccuracy: Double   // metres
    let timestamp:          Date

    /// Speed in km/h, clamped to ≥ 0.
    var speedKPH: Double { max(0, speedMS) * 3.6 }

    /// Speed in mph, clamped to ≥ 0.
    var speedMPH: Double { max(0, speedMS) * 2.23694 }

    init(from location: CLLocation) {
        latitude           = location.coordinate.latitude
        longitude          = location.coordinate.longitude
        altitude           = location.altitude
        speedMS            = location.speed
        horizontalAccuracy = location.horizontalAccuracy
        timestamp          = location.timestamp
    }
}

// MARK: - Session model

/// A complete recorded drive session ready for upload.
struct DriveSession: Identifiable, Codable {
    let id:         UUID
    let startedAt:  Date
    var endedAt:    Date?
    var trackPoints: [TrackPoint]
    var vehicleId:  String?   // set by user before upload
    var uploaded:   Bool = false

    init() {
        id          = UUID()
        startedAt   = Date()
        trackPoints = []
    }

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
    var pointCount: Int        { trackPoints.count }

    /// Bounding box for quick map display.
    var latitudeRange:  ClosedRange<Double>? {
        guard !trackPoints.isEmpty else { return nil }
        let lats = trackPoints.map(\.latitude)
        return lats.min()! ... lats.max()!
    }
}
