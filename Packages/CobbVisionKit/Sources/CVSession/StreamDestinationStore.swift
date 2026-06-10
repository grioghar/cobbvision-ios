import Foundation
import CVCore
import CVAPI

/// Stream destinations live on-device only (the key/passphrase stays in the
/// Keychain; the URL list in a JSON file). Synchronous because callers are
/// already actors.
public final class StreamDestinationStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private let tokenStore: any TokenStore
    private var cached: [StreamDestination]

    public init(directory: URL? = nil, tokenStore: any TokenStore = KeychainStore()) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CobbVision", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("stream-destinations.json")
        self.tokenStore = tokenStore
        self.cached = (try? JSONDecoder().decode(
            [StreamDestination].self,
            from: Data(contentsOf: fileURL)
        )) ?? []
    }

    public var all: [StreamDestination] {
        lock.withLock { cached }
    }

    public func destination(id: UUID) -> StreamDestination? {
        lock.withLock { cached.first { $0.id == id } }
    }

    public func upsert(_ destination: StreamDestination, streamKey: String?) {
        lock.withLock {
            if let index = cached.firstIndex(where: { $0.id == destination.id }) {
                cached[index] = destination
            } else {
                cached.append(destination)
            }
            persistLocked()
        }
        if let streamKey {
            try? tokenStore.write(streamKey, account: destination.streamKeyKeychainRef)
        }
    }

    public func remove(id: UUID) {
        let removed: StreamDestination? = lock.withLock {
            guard let index = cached.firstIndex(where: { $0.id == id }) else { return nil }
            let destination = cached.remove(at: index)
            persistLocked()
            return destination
        }
        if let removed {
            try? tokenStore.delete(account: removed.streamKeyKeychainRef)
        }
    }

    public func streamKey(for destination: StreamDestination) -> String? {
        try? tokenStore.read(account: destination.streamKeyKeychainRef)
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
