import Foundation
import CVCore

/// Server-driven presets with an offline cache. Pulls on launch/foreground,
/// pushes on local edit; the server copy wins on conflict (presets are
/// low-churn and the phone is the only editor in practice).
public actor PresetStore {
    private let api: APIClient
    private let cacheURL: URL
    private(set) public var presets: [Preset]
    private(set) public var appConfig: AppConfig

    public init(api: APIClient, cacheDirectory: URL? = nil) {
        self.api = api
        let dir = cacheDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CobbVision", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("presets.json")

        if let cached = Self.readCache(from: cacheURL) {
            presets = cached.presets
            appConfig = cached.config
        } else {
            presets = Preset.defaultPresets
            appConfig = .fallback
        }
    }

    public func preset(id: UUID) -> Preset? {
        presets.first { $0.id == id }
    }

    /// Pulls config + presets from the server. Keeps the cache on any failure
    /// so the app works offline. Presets with a newer schema than this build
    /// understands are dropped from the working set (but never deleted
    /// server-side — `push()` re-sends the full cached set including them).
    public func refresh() async {
        do {
            let response = try await api.fetchAppConfig()
            appConfig = response.config
            if let serverPresets = response.presets {
                ingest(serverPresets)
            } else {
                ingest(try await api.fetchPresets())
            }
            writeCache()
        } catch APIError.server(_, let code) where code == 404 {
            // Controlplane not yet upgraded with the app endpoints — keep
            // local defaults so the app remains usable.
        } catch {
            // Offline or transient failure: cache stands.
        }
    }

    /// Replaces the local set and pushes to the server (fire-and-forget on
    /// failure — the next refresh/push reconciles).
    public func save(_ updated: [Preset]) async {
        presets = updated
        writeCache()
        let wrapped = updated.enumerated().map { index, preset in
            ServerPreset(preset: preset, sortOrder: index, isDefault: index == 0)
        }
        if let canonical = try? await api.savePresets(wrapped) {
            ingest(canonical)
            writeCache()
        }
    }

    private func ingest(_ serverPresets: [ServerPreset]) {
        let usable = serverPresets
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.config)
            .filter { $0.schemaVersion <= Preset.currentSchemaVersion }
        if !usable.isEmpty {
            presets = usable
        }
    }

    // MARK: - Cache

    private struct Cache: Codable {
        var presets: [Preset]
        var config: AppConfig
    }

    private static func readCache(from url: URL) -> (presets: [Preset], config: AppConfig)? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              !cache.presets.isEmpty else {
            return nil
        }
        return (cache.presets, cache.config)
    }

    private func writeCache() {
        let cache = Cache(presets: presets, config: appConfig)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
