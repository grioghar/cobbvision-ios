import XCTest
@testable import CVAPI

final class GzipTests: XCTestCase {
    // "time,rpm,boost_psi\n0.0,800,-9.5\n0.1,1450,-8.2\n0.2,2100,1.4\n"
    // gzipped with a standard System.IO.Compression.GzipStream.
    private let gzippedFixture = Data(base64Encoded:
        "H4sIAAAAAAAACgXBwQnAIBAEwP/Vsi57h4JWIwTy8CFKtH8yc8d88e2JZ61z+z7DRKFKSI3FRIfnIqTKMDEQLsGZ7QeycSq6OwAAAA=="
    )!
    private let expectedCSV = Data(base64Encoded:
        "dGltZSxycG0sYm9vc3RfcHNpCjAuMCw4MDAsLTkuNQowLjEsMTQ1MCwtOC4yCjAuMiwyMTAwLDEuNAo="
    )!

    func testDetectsGzipMagic() {
        XCTAssertTrue(Gzip.isGzipped(gzippedFixture))
        XCTAssertFalse(Gzip.isGzipped(expectedCSV))
        XCTAssertFalse(Gzip.isGzipped(Data([0x1F])))
    }

    func testDecompressesRealGzip() throws {
        let inflated = try Gzip.decompress(gzippedFixture)
        XCTAssertEqual(inflated, expectedCSV)
        XCTAssertEqual(
            String(data: inflated, encoding: .utf8)?.hasPrefix("time,rpm,boost_psi"),
            true
        )
    }

    func testRejectsNonGzip() {
        XCTAssertThrowsError(try Gzip.decompress(expectedCSV)) { error in
            guard case Gzip.GzipError.notGzip = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testRejectsTruncatedStream() {
        let truncated = gzippedFixture.prefix(gzippedFixture.count / 2)
        XCTAssertThrowsError(try Gzip.decompress(Data(truncated)))
    }

    func testRejectsCorruptPayload() {
        var corrupt = gzippedFixture
        // Flip bytes in the middle of the deflate stream.
        let middle = corrupt.index(corrupt.startIndex, offsetBy: corrupt.count / 2)
        corrupt[middle] ^= 0xFF
        corrupt[corrupt.index(after: middle)] ^= 0xFF
        XCTAssertThrowsError(try Gzip.decompress(corrupt))
    }

    func testHandlesFNAMEHeaderField() throws {
        // Build a gzip with FNAME set: header(FLG=0x08) + "log.csv\0" + the
        // fixture's deflate body + trailer.
        let body = gzippedFixture.dropFirst(10)
        var withName = Data([0x1F, 0x8B, 0x08, 0x08, 0, 0, 0, 0, 0, 0x0A])
        withName.append(Data("log.csv".utf8))
        withName.append(0)
        withName.append(body)
        let inflated = try Gzip.decompress(withName)
        XCTAssertEqual(inflated, expectedCSV)
    }
}

final class DatalogUploadTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testUploadDatalogMultipartAndResponse() async throws {
        MockURLProtocol.enqueue(json: """
        {"api_key":"k","user":{"id":"u","email":"e","is_admin":false},"vehicles":[]}
        """)
        MockURLProtocol.enqueue(status: 201, json: """
        {"session_id":"s1","status":"complete","health_score":"87.5","row_count":1200,
         "anomaly_count":3,"analysis_url":"https://cobbvision.test/analysis/s1"}
        """, expectPathSuffix: "/api/v1/upload")

        let client = makeMockedClient()
        _ = try await client.login(email: "e", password: "p")
        let response = try await client.uploadDatalog(
            csv: Data("time,rpm\n0,800\n".utf8),
            fileName: "datalog42.csv",
            vehicleID: "v1"
        )
        XCTAssertEqual(response.sessionID, "s1")
        XCTAssertEqual(response.status, "complete")
        XCTAssertEqual(response.healthScore, 87.5)
        XCTAssertEqual(response.rowCount, 1200)
        XCTAssertEqual(response.anomalyCount, 3)

        let (request, body) = MockURLProtocol.capturedRequests.last!
        XCTAssertTrue((request.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("multipart/form-data"))
        let bodyString = String(data: body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("filename=\"datalog42.csv\""))
        XCTAssertTrue(bodyString.contains("name=\"vehicle_id\""))
    }

    func testPaymentRequiredSurfaces() async throws {
        MockURLProtocol.enqueue(json: """
        {"api_key":"k","user":{"id":"u","email":"e","is_admin":false},"vehicles":[]}
        """)
        MockURLProtocol.enqueue(status: 402, json: #"{"error":"No analyses remaining."}"#)
        let client = makeMockedClient()
        _ = try await client.login(email: "e", password: "p")
        do {
            _ = try await client.uploadDatalog(csv: Data("x".utf8), fileName: "a.csv", vehicleID: nil)
            XCTFail("expected throw")
        } catch let APIError.server(message, statusCode) {
            XCTAssertEqual(statusCode, 402)
            XCTAssertEqual(message, "No analyses remaining.")
        }
    }
}
