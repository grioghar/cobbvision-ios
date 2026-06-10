import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Talks to the CobbVision PHP backend.
/// Base URL and API key are read from UserDefaults (set on the Settings screen).
final class APIClient {

    // MARK: - Configuration

    static var baseURL: String {
        UserDefaults.standard.string(forKey: "api_base_url") ?? "https://cobbvision.grio.co"
    }

    static var apiKey: String {
        UserDefaults.standard.string(forKey: "api_key") ?? ""
    }

    // MARK: - Upload

    /// Result of a GPS-track upload — mirrors the real `POST /api/v1/gps-track`
    /// response. A GPS track is NOT a datalog analysis, so there is no health
    /// score here; instead the server reports the stored track, whether it was
    /// auto-matched to a datalog session (a Trip), and the match confidence.
    struct UploadResult {
        let gpsTrackId:      String
        let tripId:          String?
        let pointCount:      Int?
        let matchConfidence: Double?   // % match to a datalog, when auto-correlated
        let message:         String?
    }

    /// Upload a recorded GPS track (GPX) for a vehicle.
    /// - Parameters:
    ///   - gpxURL:    Local file URL produced by GPXExporter.export(session:)
    ///   - vehicleId: UUID of the vehicle this track belongs to
    static func uploadGPX(gpxURL: URL, vehicleId: String) async throws -> UploadResult {
        let url = URL(string: "\(baseURL)/api/v1/gps-track")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "CobbVisionBoundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendFormField(name: "vehicle_id", value: vehicleId, boundary: boundary)
        // Identify the recording device. `source_type=device_app` marks this as the
        // first-party phone recorder — the authoritative GPS source in the server's
        // multi-source reconciliation (the phone app outranks video-extracted / GPS
        // files). The server ignores unknown fields today; this forward-wires it.
        body.appendFormField(name: "device", value: Self.deviceLabel, boundary: boundary)
        body.appendFormField(name: "source_type", value: "device_app", boundary: boundary)
        let gpxData = try Data(contentsOf: gpxURL)
        body.appendFilePart(name: "gpx",
                            filename: gpxURL.lastPathComponent,
                            data: gpxData,
                            mime: "application/gpx+xml",
                            boundary: boundary)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        // The endpoint returns 200 on success (some deployments 201). Accept any 2xx.
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.serverError(http.statusCode, msg)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return UploadResult(
            gpsTrackId:      json?["gps_track_id"]     as? String ?? "",
            tripId:          json?["trip_id"]          as? String,
            pointCount:      json?["point_count"]      as? Int,
            matchConfidence: (json?["match_confidence"] as? NSNumber)?.doubleValue,
            message:         json?["message"]          as? String
        )
    }

    /// A short, stable label for this device (e.g. "iPhone 16 Pro").
    static var deviceLabel: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "iOS device"
        #endif
    }

    // MARK: - Vehicles

    struct Vehicle: Identifiable, Decodable {
        let id:       String
        let name:     String
        let make:     String
        let model:    String
        let year:     String
        let apSerial: String?

        enum CodingKeys: String, CodingKey {
            case id, name, make, model, year
            case apSerial = "ap_serial"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id    = try c.decode(String.self, forKey: .id)
            name  = (try? c.decode(String.self, forKey: .name))  ?? ""
            make  = (try? c.decode(String.self, forKey: .make))  ?? ""
            model = (try? c.decode(String.self, forKey: .model)) ?? ""
            // `year` may arrive as a JSON string ("2006") or a number (2006).
            if let s = try? c.decode(String.self, forKey: .year)      { year = s }
            else if let i = try? c.decode(Int.self, forKey: .year)    { year = String(i) }
            else { year = "" }
            apSerial = try? c.decodeIfPresent(String.self, forKey: .apSerial)
        }
    }

    /// The vehicles endpoint wraps its list: `{ "vehicles": [ … ] }`.
    private struct VehiclesResponse: Decodable { let vehicles: [Vehicle] }

    static func fetchVehicles() async throws -> [Vehicle] {
        let url = URL(string: "\(baseURL)/api/v1/vehicles")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.serverError(http.statusCode, msg)
        }
        // Server returns the wrapped form; tolerate a bare array too (forward-compat).
        if let wrapped = try? JSONDecoder().decode(VehiclesResponse.self, from: data) {
            return wrapped.vehicles
        }
        return (try? JSONDecoder().decode([Vehicle].self, from: data)) ?? []
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case invalidResponse
        case serverError(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:           return "Invalid server response."
            case .serverError(let c, let m): return "Server error \(c): \(m)"
            }
        }
    }
}

// MARK: - Multipart helpers

private extension Data {
    mutating func appendFormField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendFilePart(name: String, filename: String,
                                  data fileData: Data, mime: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        append(fileData)
        append("\r\n".data(using: .utf8)!)
    }
}
