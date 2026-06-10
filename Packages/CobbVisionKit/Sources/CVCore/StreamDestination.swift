import Foundation

/// Where a live stream goes. The stream key/passphrase never lives in this
/// struct (it syncs to the server and the local JSON cache) — it is stored in
/// the Keychain under `streamKeyKeychainRef` and joined at connect time.
public struct StreamDestination: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case rtmp
        case srt
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Base URL without credentials, e.g. `rtmp://a.rtmp.youtube.com/live2`
    /// or `srt://stream.example.com:8890`.
    public var url: String
    /// Keychain account name holding the stream key (RTMP) or passphrase/streamid (SRT).
    public var streamKeyKeychainRef: String

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        url: String,
        streamKeyKeychainRef: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.streamKeyKeychainRef = streamKeyKeychainRef ?? "stream-key.\(id.uuidString)"
    }
}

/// Live health of an outgoing stream, folded into `SessionState`.
public enum StreamHealth: Codable, Sendable, Hashable {
    case notStreaming
    case connecting
    case live(bitrateBps: Int, rttMs: Int?)
    case degraded(reason: String)
    case disconnected(reason: String?)

    public var isLive: Bool {
        if case .live = self { return true }
        if case .degraded = self { return true }
        return false
    }
}
