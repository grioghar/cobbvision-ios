import XCTest
import CVCore
@testable import CVAPI

final class PresetStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cv-presets-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testStartsWithDefaultsWhenNoCache() async {
        let store = PresetStore(api: makeMockedClient(), cacheDirectory: tempDir)
        let presets = await store.presets
        XCTAssertEqual(presets.map(\.name), Preset.defaultPresets.map(\.name))
    }

    func testRefreshFailureKeepsLocalSet() async {
        // No stubs enqueued → every request fails at the transport layer.
        let store = PresetStore(api: makeMockedClient(), cacheDirectory: tempDir)
        await store.refresh()
        let presets = await store.presets
        XCTAssertFalse(presets.isEmpty)
    }

    func testSavePersistsCacheAcrossInstances() async throws {
        let store = PresetStore(api: makeMockedClient(), cacheDirectory: tempDir)
        let custom = [Preset(name: "My custom preset", cameras: .front)]
        await store.save(custom) // server push fails (no stub); cache still written

        let reloaded = PresetStore(api: makeMockedClient(), cacheDirectory: tempDir)
        let presets = await reloaded.presets
        XCTAssertEqual(presets.map(\.name), ["My custom preset"])
        XCTAssertEqual(presets[0].cameras, .front)
    }

    func testRefreshIngestsServerPresetsAndConfig() async throws {
        MockURLProtocol.enqueue(json: """
        {"api_key":"k","user":{"id":"u","email":"e","is_admin":false},"vehicles":[]}
        """)
        let serverPreset = Preset(name: "From server", cameras: .both)
        let configJSON = String(data: try JSONEncoder().encode(serverPreset), encoding: .utf8)!
        MockURLProtocol.enqueue(json: """
        {"config":{"min_app_version":"1.0.0","chunk_size_bytes":10485760,"telemetry_hz":5,
          "features":{"insta360":true}},
         "presets":[{"id":"\(serverPreset.id.uuidString.lowercased())","name":"From server",
          "sort_order":0,"is_default":1,"config":\(configJSON)}]}
        """, expectPathSuffix: "/api/v1/app/config")

        let client = makeMockedClient()
        _ = try await client.login(email: "e", password: "p")
        let store = PresetStore(api: client, cacheDirectory: tempDir)
        await store.refresh()

        let presets = await store.presets
        let config = await store.appConfig
        XCTAssertEqual(presets.map(\.name), ["From server"])
        XCTAssertEqual(config.chunkSizeBytes, 10_485_760)
        XCTAssertEqual(config.telemetryHz, 5)
        XCTAssertTrue(config.features.insta360)
    }

    func testNewerSchemaPresetsAreFilteredOut() async throws {
        MockURLProtocol.enqueue(json: """
        {"api_key":"k","user":{"id":"u","email":"e","is_admin":false},"vehicles":[]}
        """)
        var future = Preset(name: "From the future")
        future.schemaVersion = Preset.currentSchemaVersion + 1
        var current = Preset(name: "Usable")
        current.schemaVersion = Preset.currentSchemaVersion
        let futureJSON = String(data: try JSONEncoder().encode(future), encoding: .utf8)!
        let currentJSON = String(data: try JSONEncoder().encode(current), encoding: .utf8)!
        MockURLProtocol.enqueue(json: """
        {"config":{},
         "presets":[
          {"id":"\(future.id.uuidString.lowercased())","name":"From the future","sort_order":0,"is_default":0,"config":\(futureJSON)},
          {"id":"\(current.id.uuidString.lowercased())","name":"Usable","sort_order":1,"is_default":0,"config":\(currentJSON)}
        ]}
        """)

        let client = makeMockedClient()
        _ = try await client.login(email: "e", password: "p")
        let store = PresetStore(api: client, cacheDirectory: tempDir)
        await store.refresh()
        let presets = await store.presets
        XCTAssertEqual(presets.map(\.name), ["Usable"])
    }
}
