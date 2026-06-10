import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import CVAPI

/// Intercepts every request on a dedicated URLSession and answers from a
/// queue of canned responses. Captured requests are inspectable afterwards.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let body: Data
        /// Matched against the request path if set (helps catch ordering bugs).
        let expectPathSuffix: String?
    }

    // Static because URLProtocol instances are created by the URL loading
    // system. Tests run serially within a case; state is reset in setUp.
    nonisolated(unsafe) static var stubs: [Stub] = []
    nonisolated(unsafe) static var capturedRequests: [(request: URLRequest, body: Data?)] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            stubs = []
            capturedRequests = []
        }
    }

    static func enqueue(status: Int = 200, json: String, expectPathSuffix: String? = nil) {
        lock.withLock {
            stubs.append(Stub(statusCode: status, body: Data(json.utf8), expectPathSuffix: expectPathSuffix))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }

        let stub: Stub? = Self.lock.withLock {
            Self.capturedRequests.append((self.request, body))
            return Self.stubs.isEmpty ? nil : Self.stubs.removeFirst()
        }

        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if let suffix = stub.expectPathSuffix,
           let path = request.url?.path,
           !path.hasSuffix(suffix) {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "MockURLProtocol", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "expected path *\(suffix), got \(path)"]
                )
            )
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLSession {
    static var mocked: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

func makeMockedClient() -> APIClient {
    APIClient(
        baseURL: URL(string: "https://cobbvision.test")!,
        session: .mocked,
        tokenStore: InMemoryTokenStore()
    )
}
