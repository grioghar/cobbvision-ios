import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
import CVCore

/// Uploads a finished session video to the controlplane in ≤20 MB chunks
/// (DreamHost request cap), resumably: the caller persists `nextChunkIndex`
/// after every chunk (via `onChunkUploaded`) so a killed app picks up where it
/// left off instead of re-sending gigabytes.
public actor ChunkedVideoUploader {
    public struct Progress: Sendable {
        public let uploadedChunks: Int
        public let totalChunks: Int
        public var fraction: Double { totalChunks > 0 ? Double(uploadedChunks) / Double(totalChunks) : 0 }
    }

    private let api: APIClient
    private let chunkSize: Int

    public init(api: APIClient, chunkSize: Int = 20_971_520) {
        self.api = api
        // The server rejects chunks over 20 MB; anything smaller just costs
        // more requests.
        self.chunkSize = min(chunkSize, 20_971_520)
    }

    public static func chunkCount(fileSize: Int64, chunkSize: Int) -> Int {
        guard fileSize > 0 else { return 0 }
        return Int((fileSize + Int64(chunkSize) - 1) / Int64(chunkSize))
    }

    /// Uploads `fileURL`. Set `existingRemoteID`/`startChunkIndex` from the
    /// session manifest to resume. Returns the remote media id.
    @discardableResult
    public func upload(
        fileURL: URL,
        durationSeconds: Double?,
        existingRemoteID: String? = nil,
        startChunkIndex: Int = 0,
        onChunkUploaded: (@Sendable (_ nextChunkIndex: Int, _ remoteID: String, _ progress: Progress) async -> Void)? = nil
    ) async throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        guard fileSize > 0 else {
            throw APIError.transport("empty file: \(fileURL.lastPathComponent)")
        }
        let totalChunks = Self.chunkCount(fileSize: fileSize, chunkSize: chunkSize)

        let remoteID: String
        if let existingRemoteID {
            remoteID = existingRemoteID
        } else {
            let sha = try Self.sha256Hex(of: fileURL)
            let created = try await api.createVideo(
                fileName: fileURL.lastPathComponent,
                totalChunks: totalChunks,
                durationSeconds: durationSeconds,
                sha256Hex: sha
            )
            remoteID = created.videoID
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        for index in startChunkIndex..<totalChunks {
            try handle.seek(toOffset: UInt64(index) * UInt64(chunkSize))
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                throw APIError.transport("short read at chunk \(index) of \(fileURL.lastPathComponent)")
            }
            try await api.uploadVideoChunk(videoID: remoteID, index: index, chunk: chunk)
            await onChunkUploaded?(
                index + 1,
                remoteID,
                Progress(uploadedChunks: index + 1, totalChunks: totalChunks)
            )
        }

        try await api.completeVideo(videoID: remoteID)
        return remoteID
    }

    /// Streaming SHA-256 so multi-GB files never load into memory at once.
    public static func sha256Hex(of fileURL: URL) throws -> String {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        throw APIError.transport("SHA-256 unavailable on this platform")
        #endif
    }
}
