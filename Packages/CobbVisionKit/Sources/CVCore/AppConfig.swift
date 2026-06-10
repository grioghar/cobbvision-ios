import Foundation

/// Server-driven configuration fetched from `GET /api/v1/app/config` on launch
/// and cached. Unknown keys are ignored so the server can grow the payload
/// without breaking old builds.
public struct AppConfig: Codable, Sendable, Hashable {
    public var minAppVersion: String
    public var chunkSizeBytes: Int
    public var telemetryHz: Double
    public var features: Features

    public struct Features: Codable, Sendable, Hashable {
        public var insta360: Bool

        public init(insta360: Bool = false) {
            self.insta360 = insta360
        }

        enum CodingKeys: String, CodingKey {
            case insta360
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            insta360 = try container.decodeIfPresent(Bool.self, forKey: .insta360) ?? false
        }
    }

    public init(
        minAppVersion: String = "0.0.0",
        chunkSizeBytes: Int = 20_971_520,
        telemetryHz: Double = 10,
        features: Features = Features()
    ) {
        self.minAppVersion = minAppVersion
        self.chunkSizeBytes = chunkSizeBytes
        self.telemetryHz = telemetryHz
        self.features = features
    }

    enum CodingKeys: String, CodingKey {
        case minAppVersion = "min_app_version"
        case chunkSizeBytes = "chunk_size_bytes"
        case telemetryHz = "telemetry_hz"
        case features
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minAppVersion = try container.decodeIfPresent(String.self, forKey: .minAppVersion) ?? "0.0.0"
        chunkSizeBytes = try container.decodeIfPresent(Int.self, forKey: .chunkSizeBytes) ?? 20_971_520
        telemetryHz = try container.decodeIfPresent(Double.self, forKey: .telemetryHz) ?? 10
        features = try container.decodeIfPresent(Features.self, forKey: .features) ?? Features()
    }

    public static let fallback = AppConfig()
}
