import Foundation
import CVCore

public struct User: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var email: String
    public var isAdmin: Bool

    enum CodingKeys: String, CodingKey {
        case id, email
        case isAdmin = "is_admin"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try c.decode(String.self, forKey: .email)
        // PHP serializes tinyint columns as 0/1 ints, bools, or strings
        // depending on the driver — accept all three.
        isAdmin = (try? c.decodeFlexibleBool(forKey: .isAdmin)) ?? false
    }
}

public struct Vehicle: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var make: String?
    public var model: String?
    public var year: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, make, model, year
    }

    public init(id: String, name: String, make: String? = nil, model: String? = nil, year: Int? = nil) {
        self.id = id
        self.name = name
        self.make = make
        self.model = model
        self.year = year
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        make = try c.decodeIfPresent(String.self, forKey: .make)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        year = try? c.decodeFlexibleInt(forKey: .year)
    }

    public var displayName: String {
        if let year, let make, let model { return "\(year) \(make) \(model)" }
        return name
    }
}

public struct LoginResponse: Codable, Sendable {
    public var apiKey: String
    public var user: User
    public var vehicles: [Vehicle]

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case user, vehicles
    }
}

public struct GPSTrackUploadResponse: Codable, Sendable {
    public var id: String
    public var pointCount: Int?
    public var correlationOffsetMs: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case pointCount = "point_count"
        case correlationOffsetMs = "correlation_offset_ms"
    }
}

public struct VideoCreateResponse: Codable, Sendable {
    public var videoID: String

    enum CodingKeys: String, CodingKey {
        case videoID = "video_id"
    }
}

public struct VideoChunkResponse: Codable, Sendable {
    public var received: Int
    public var index: Int
}

public struct VideoCompleteResponse: Codable, Sendable {
    public var id: String
    public var status: String
}

/// Wrapper the server stores presets in: app-owned `config` plus columns the
/// web UI can list without parsing the blob.
public struct ServerPreset: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var sortOrder: Int
    public var isDefault: Bool
    public var config: Preset

    enum CodingKeys: String, CodingKey {
        case id, name, config
        case sortOrder = "sort_order"
        case isDefault = "is_default"
    }

    public init(id: String, name: String, sortOrder: Int, isDefault: Bool, config: Preset) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.isDefault = isDefault
        self.config = config
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sortOrder = (try? c.decodeFlexibleInt(forKey: .sortOrder)) ?? 0
        isDefault = (try? c.decodeFlexibleBool(forKey: .isDefault)) ?? false
        config = try c.decode(Preset.self, forKey: .config)
    }

    public init(preset: Preset, sortOrder: Int, isDefault: Bool = false) {
        self.init(
            id: preset.id.uuidString.lowercased(),
            name: preset.name,
            sortOrder: sortOrder,
            isDefault: isDefault,
            config: preset
        )
    }
}

public struct PresetListResponse: Codable, Sendable {
    public var presets: [ServerPreset]
}

public struct AppConfigResponse: Codable, Sendable {
    public var config: AppConfig
    public var presets: [ServerPreset]?
}

extension KeyedDecodingContainer {
    /// PHP/MySQL JSON sends numbers and booleans inconsistently (1, "1", true).
    func decodeFlexibleBool(forKey key: Key) throws -> Bool {
        if let b = try? decode(Bool.self, forKey: key) { return b }
        if let i = try? decode(Int.self, forKey: key) { return i != 0 }
        if let s = try? decode(String.self, forKey: key) { return s == "1" || s.lowercased() == "true" }
        throw DecodingError.typeMismatch(
            Bool.self,
            .init(codingPath: codingPath + [key], debugDescription: "not a flexible bool")
        )
    }

    func decodeFlexibleInt(forKey key: Key) throws -> Int {
        if let i = try? decode(Int.self, forKey: key) { return i }
        if let s = try? decode(String.self, forKey: key), let i = Int(s) { return i }
        throw DecodingError.typeMismatch(
            Int.self,
            .init(codingPath: codingPath + [key], debugDescription: "not a flexible int")
        )
    }
}
