import Foundation

public enum APIError: Error, Sendable {
    /// The controlplane's `{"error": "message"}` envelope.
    case server(message: String, statusCode: Int)
    case unauthorized
    case rateLimited
    case decoding(String)
    case transport(String)
    case notLoggedIn

    public var userMessage: String {
        switch self {
        case .server(let message, _): message
        case .unauthorized: "Your session expired — please log in again."
        case .rateLimited: "Too many requests — try again in a few minutes."
        case .decoding: "The server sent an unexpected response."
        case .transport(let detail): "Network problem: \(detail)"
        case .notLoggedIn: "Please log in first."
        }
    }
}
