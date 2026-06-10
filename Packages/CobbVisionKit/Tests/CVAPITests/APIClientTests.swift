import XCTest
import CVCore
@testable import CVAPI

final class APIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testLoginStoresKeyAndAuthorizesNextRequest() async throws {
        MockURLProtocol.enqueue(json: """
        {"api_key":"abc123","user":{"id":"u1","email":"t@example.com","is_admin":0},
         "vehicles":[{"id":"v1","name":"WRX","make":"Subaru","model":"WRX","year":"2021"}]}
        """, expectPathSuffix: "/api/v1/auth/login")
        MockURLProtocol.enqueue(json: """
        {"vehicles":[{"id":"v1","name":"WRX"}]}
        """, expectPathSuffix: "/api/v1/vehicles")

        let store = InMemoryTokenStore()
        let client = APIClient(
            baseURL: URL(string: "https://cobbvision.test")!,
            session: .mocked,
            tokenStore: store
        )

        let login = try await client.login(email: "t@example.com", password: "pw")
        XCTAssertEqual(login.apiKey, "abc123")
        XCTAssertEqual(login.user.email, "t@example.com")
        XCTAssertFalse(login.user.isAdmin)
        XCTAssertEqual(login.vehicles.first?.year, 2021)
        XCTAssertEqual(try store.read(account: TokenAccount.apiKey), "abc123")

        let vehicles = try await client.vehicles()
        XCTAssertEqual(vehicles.map(\.id), ["v1"])

        let authHeader = MockURLProtocol.capturedRequests.last?.request
            .value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authHeader, "Bearer abc123")
    }

    func testLoginRequestNotAuthenticated() async throws {
        MockURLProtocol.enqueue(json: """
        {"api_key":"k","user":{"id":"u","email":"e","is_admin":false},"vehicles":[]}
        """)
        let client = makeMockedClient()
        _ = try await client.login(email: "e", password: "p")
        let request = MockURLProtocol.capturedRequests[0].request
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testServerErrorEnvelopeSurfaces() async {
        MockURLProtocol.enqueue(status: 422, json: #"{"error":"VIN is locked"}"#)
        let client = makeMockedClient()
        do {
            _ = try await client.login(email: "e", password: "p")
            XCTFail("expected throw")
        } catch let APIError.server(message, statusCode) {
            XCTAssertEqual(message, "VIN is locked")
            XCTAssertEqual(statusCode, 422)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testUnauthenticatedCallThrowsBeforeNetwork() async {
        let client = makeMockedClient()
        do {
            _ = try await client.vehicles()
            XCTFail("expected throw")
        } catch APIError.notLoggedIn {
            XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test401MapsToUnauthorized() async throws {
        MockURLProtocol.enqueue(json: """
        {"api_key":"k","user":{"id":"u","email":"e","is_admin":false},"vehicles":[]}
        """)
        MockURLProtocol.enqueue(status: 401, json: #"{"error":"bad key"}"#)
        let client = makeMockedClient()
        _ = try await client.login(email: "e", password: "p")
        do {
            _ = try await client.me()
            XCTFail("expected throw")
        } catch APIError.unauthorized {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testGPSTrackUploadIsMultipart() async throws {
        MockURLProtocol.enqueue(json: """
        {"api_key":"k","user":{"id":"u","email":"e","is_admin":false},"vehicles":[]}
        """)
        MockURLProtocol.enqueue(json: #"{"id":"track1","point_count":100,"correlation_offset_ms":250}"#)
        let client = makeMockedClient()
        _ = try await client.login(email: "e", password: "p")

        let result = try await client.uploadGPSTrack(
            gpx: Data("<gpx/>".utf8),
            fileName: "session.gpx",
            vehicleID: "v1"
        )
        XCTAssertEqual(result.id, "track1")
        XCTAssertEqual(result.correlationOffsetMs, 250)

        let (request, body) = MockURLProtocol.capturedRequests.last!
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let bodyString = String(data: body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("filename=\"session.gpx\""))
        XCTAssertTrue(bodyString.contains("name=\"vehicle_id\""))
        XCTAssertTrue(bodyString.contains("<gpx/>"))
    }

    func testPresetRoundTrip() async throws {
        MockURLProtocol.enqueue(json: """
        {"api_key":"k","user":{"id":"u","email":"e","is_admin":false},"vehicles":[]}
        """)
        let preset = Preset(name: "Track")
        let configJSON = String(
            data: try JSONEncoder().encode(preset),
            encoding: .utf8
        )!
        MockURLProtocol.enqueue(json: """
        {"presets":[{"id":"\(preset.id.uuidString.lowercased())","name":"Track","sort_order":"0","is_default":1,"config":\(configJSON)}]}
        """)

        let client = makeMockedClient()
        _ = try await client.login(email: "e", password: "p")
        let presets = try await client.fetchPresets()
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets[0].config, preset)
        XCTAssertTrue(presets[0].isDefault)
        XCTAssertEqual(presets[0].sortOrder, 0)
    }
}

final class ChunkedVideoUploaderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testChunkCountMath() {
        XCTAssertEqual(ChunkedVideoUploader.chunkCount(fileSize: 0, chunkSize: 10), 0)
        XCTAssertEqual(ChunkedVideoUploader.chunkCount(fileSize: 1, chunkSize: 10), 1)
        XCTAssertEqual(ChunkedVideoUploader.chunkCount(fileSize: 10, chunkSize: 10), 1)
        XCTAssertEqual(ChunkedVideoUploader.chunkCount(fileSize: 11, chunkSize: 10), 2)
        XCTAssertEqual(ChunkedVideoUploader.chunkCount(fileSize: 20_971_521, chunkSize: 20_971_520), 2)
    }

    func testSha256OfKnownContent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cv-sha-\(UUID().uuidString).bin")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(
            try ChunkedVideoUploader.sha256Hex(of: url),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    func testUploadsAllChunksThenCompletes() async throws {
        // 5 bytes with 2-byte chunks → 3 chunks.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cv-upl-\(UUID().uuidString).mov")
        try Data([1, 2, 3, 4, 5]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        MockURLProtocol.enqueue(json: """
        {"api_key":"k","user":{"id":"u","email":"e","is_admin":false},"vehicles":[]}
        """)
        MockURLProtocol.enqueue(json: #"{"video_id":"vid9"}"#, expectPathSuffix: "/api/v1/media/video")
        MockURLProtocol.enqueue(json: #"{"received":1,"index":0}"#, expectPathSuffix: "/chunk")
        MockURLProtocol.enqueue(json: #"{"received":2,"index":1}"#, expectPathSuffix: "/chunk")
        MockURLProtocol.enqueue(json: #"{"received":3,"index":2}"#, expectPathSuffix: "/chunk")
        MockURLProtocol.enqueue(json: #"{"id":"vid9","status":"ready"}"#, expectPathSuffix: "/complete")

        let client = makeMockedClient()
        _ = try await client.login(email: "e", password: "p")

        let uploader = ChunkedVideoUploader(api: client, chunkSize: 2)
        let progressLog = ProgressLog()
        let remoteID = try await uploader.upload(
            fileURL: url,
            durationSeconds: 12.5,
            onChunkUploaded: { next, remote, progress in
                await progressLog.append(next: next, remote: remote, fraction: progress.fraction)
            }
        )
        XCTAssertEqual(remoteID, "vid9")
        let entries = await progressLog.entries
        XCTAssertEqual(entries.map(\.next), [1, 2, 3])
        XCTAssertEqual(entries.last?.fraction, 1.0)
    }

    func testResumeSkipsUploadedChunks() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cv-res-\(UUID().uuidString).mov")
        try Data([1, 2, 3, 4, 5]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        MockURLProtocol.enqueue(json: """
        {"api_key":"k","user":{"id":"u","email":"e","is_admin":false},"vehicles":[]}
        """)
        // Resume at chunk 2 of 3 with a known remote id: no create call.
        MockURLProtocol.enqueue(json: #"{"received":3,"index":2}"#, expectPathSuffix: "/chunk")
        MockURLProtocol.enqueue(json: #"{"id":"vid9","status":"ready"}"#, expectPathSuffix: "/complete")

        let client = makeMockedClient()
        _ = try await client.login(email: "e", password: "p")
        let uploader = ChunkedVideoUploader(api: client, chunkSize: 2)
        let remoteID = try await uploader.upload(
            fileURL: url,
            durationSeconds: nil,
            existingRemoteID: "vid9",
            startChunkIndex: 2
        )
        XCTAssertEqual(remoteID, "vid9")
        // login + 1 chunk + complete = 3 requests total.
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 3)
    }
}

private actor ProgressLog {
    struct Entry { let next: Int; let remote: String; let fraction: Double }
    var entries: [Entry] = []
    func append(next: Int, remote: String, fraction: Double) {
        entries.append(Entry(next: next, remote: remote, fraction: fraction))
    }
}
