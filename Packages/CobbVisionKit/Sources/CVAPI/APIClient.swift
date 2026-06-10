import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CVCore

/// Talks to the CobbVision controlplane. All requests carry
/// `Authorization: Bearer <api_key>` once `apiKey` is set (login stores it via
/// the injected `TokenStore`, typically the Keychain).
public actor APIClient {
    public static let productionURL = URL(string: "https://cobbvision.grio.co")!

    private let baseURL: URL
    private let session: URLSession
    private let tokenStore: TokenStore
    private var apiKey: String?

    public init(
        baseURL: URL = APIClient.productionURL,
        session: URLSession = .shared,
        tokenStore: TokenStore = KeychainStore()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
        self.apiKey = try? tokenStore.read(account: TokenAccount.apiKey)
    }

    public var isLoggedIn: Bool { apiKey != nil }

    // MARK: - Auth

    @discardableResult
    public func login(email: String, password: String) async throws -> LoginResponse {
        let response: LoginResponse = try await post(
            "/api/v1/auth/login",
            json: ["email": email, "password": password],
            authenticated: false
        )
        apiKey = response.apiKey
        try? tokenStore.write(response.apiKey, account: TokenAccount.apiKey)
        return response
    }

    public func logout() {
        apiKey = nil
        try? tokenStore.delete(account: TokenAccount.apiKey)
    }

    public func me() async throws -> User {
        struct MeResponse: Codable { let user: User }
        // /api/v1/me returns the user object either bare or wrapped.
        let data = try await requestData(method: "GET", path: "/api/v1/me", body: nil, contentType: nil)
        if let wrapped = try? JSONDecoder().decode(MeResponse.self, from: data) { return wrapped.user }
        return try decode(User.self, from: data)
    }

    public func vehicles() async throws -> [Vehicle] {
        struct VehiclesResponse: Codable { let vehicles: [Vehicle] }
        let data = try await requestData(method: "GET", path: "/api/v1/vehicles", body: nil, contentType: nil)
        if let wrapped = try? JSONDecoder().decode(VehiclesResponse.self, from: data) { return wrapped.vehicles }
        return try decode([Vehicle].self, from: data)
    }

    // MARK: - App config & presets

    public func fetchAppConfig() async throws -> AppConfigResponse {
        try await get("/api/v1/app/config")
    }

    public func fetchPresets() async throws -> [ServerPreset] {
        let response: PresetListResponse = try await get("/api/v1/app/presets")
        return response.presets
    }

    @discardableResult
    public func savePresets(_ presets: [ServerPreset]) async throws -> [ServerPreset] {
        let body = try JSONEncoder().encode(["presets": presets])
        let data = try await requestData(
            method: "POST", path: "/api/v1/app/presets",
            body: body, contentType: "application/json"
        )
        return try decode(PresetListResponse.self, from: data).presets
    }

    // MARK: - GPS tracks

    @discardableResult
    public func uploadGPSTrack(
        gpx: Data,
        fileName: String,
        vehicleID: String?,
        sessionID: String? = nil
    ) async throws -> GPSTrackUploadResponse {
        var form = MultipartForm()
        form.addFile(name: "file", fileName: fileName, mimeType: "application/gpx+xml", data: gpx)
        if let vehicleID { form.addField(name: "vehicle_id", value: vehicleID) }
        if let sessionID { form.addField(name: "session_id", value: sessionID) }
        let data = try await requestData(
            method: "POST", path: "/api/v1/gps-track",
            body: form.finalized(), contentType: form.contentType
        )
        return try decode(GPSTrackUploadResponse.self, from: data)
    }

    // MARK: - Media (chunked video)

    public func createVideo(
        fileName: String,
        totalChunks: Int,
        durationSeconds: Double?,
        sha256Hex: String
    ) async throws -> VideoCreateResponse {
        var payload: [String: Any] = [
            "filename": fileName,
            "total_chunks": totalChunks,
            "sha256": sha256Hex,
        ]
        if let durationSeconds { payload["duration_s"] = durationSeconds }
        return try await post("/api/v1/media/video", json: payload)
    }

    @discardableResult
    public func uploadVideoChunk(videoID: String, index: Int, chunk: Data) async throws -> VideoChunkResponse {
        var form = MultipartForm()
        form.addField(name: "index", value: String(index))
        form.addFile(name: "file", fileName: "chunk-\(index).bin", mimeType: "application/octet-stream", data: chunk)
        let data = try await requestData(
            method: "POST", path: "/api/v1/media/video/\(videoID)/chunk",
            body: form.finalized(), contentType: form.contentType
        )
        return try decode(VideoChunkResponse.self, from: data)
    }

    @discardableResult
    public func completeVideo(videoID: String) async throws -> VideoCompleteResponse {
        try await post("/api/v1/media/video/\(videoID)/complete", json: [:])
    }

    // MARK: - Request plumbing

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await requestData(method: "GET", path: path, body: nil, contentType: nil)
        return try decode(T.self, from: data)
    }

    private func post<T: Decodable>(
        _ path: String,
        json: [String: Any],
        authenticated: Bool = true
    ) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: json)
        let data = try await requestData(
            method: "POST", path: path,
            body: body, contentType: "application/json",
            authenticated: authenticated
        )
        return try decode(T.self, from: data)
    }

    private func requestData(
        method: String,
        path: String,
        body: Data?,
        contentType: String?,
        authenticated: Bool = true
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 120
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let apiKey else { throw APIError.notLoggedIn }
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("non-HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw APIError.unauthorized
        case 429:
            throw APIError.rateLimited
        default:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.server(
                message: message ?? "HTTP \(http.statusCode)",
                statusCode: http.statusCode
            )
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}
