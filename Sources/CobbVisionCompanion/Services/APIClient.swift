import Foundation

/// Talks to the CobbVision PHP backend.
/// Base URL and API key are read from UserDefaults (set on the Settings screen).
final class APIClient {

    // MARK: - Configuration

    static var baseURL: String {
        UserDefaults.standard.string(forKey: "api_base_url") ?? "https://cobbvision.com"
    }

    static var apiKey: String {
        UserDefaults.standard.string(forKey: "api_key") ?? ""
    }

    // MARK: - Upload

    struct UploadResult {
        let sessionId:   String
        let healthScore: Int?
        let analysisURL: String?
    }

    /// Upload a GPX file for a specific vehicle session.
    /// - Parameters:
    ///   - gpxURL:    Local file URL produced by GPXExporter.export(session:)
    ///   - vehicleId: UUID of the vehicle this session belongs to
    static func uploadGPX(gpxURL: URL, vehicleId: String) async throws -> UploadResult {
        let url = URL(string: "\(baseURL)/api/v1/gps-track")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "CobbVisionBoundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")

        var body = Data()
        // vehicle_id field
        body.appendFormField(name: "vehicle_id", value: vehicleId, boundary: boundary)
        // gpx file field
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
        guard http.statusCode == 201 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.serverError(http.statusCode, msg)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return UploadResult(
            sessionId:   json?["session_id"]   as? String ?? "",
            healthScore: json?["health_score"]  as? Int,
            analysisURL: json?["analysis_url"]  as? String
        )
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
    }

    static func fetchVehicles() async throws -> [Vehicle] {
        let url = URL(string: "\(baseURL)/api/v1/vehicles")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode([Vehicle].self, from: data)
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
