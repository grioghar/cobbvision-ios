import Foundation
import CVCore
import CVAPI

/// Pushes finished sessions to the controlplane: GPX → `/api/v1/gps-track`,
/// videos → chunked media API. Progress persists into the session manifest
/// after every chunk, so a killed app resumes instead of re-uploading.
public actor PostSessionUploader {
    public struct UploadProgress: Sendable, Hashable {
        public var sessionID: UUID
        public var fraction: Double
        public var detail: String
    }

    private let api: APIClient
    private let sessionsRoot: URL
    private var inFlight: Set<String> = []
    private var progressContinuations: [UUID: AsyncStream<UploadProgress>.Continuation] = [:]

    public init(api: APIClient, sessionsRoot: URL) {
        self.api = api
        self.sessionsRoot = sessionsRoot
    }

    public func progressUpdates() -> AsyncStream<UploadProgress> {
        AsyncStream { continuation in
            let id = UUID()
            progressContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        progressContinuations[id] = nil
    }

    /// Scans for sessions with pending uploads (call on app launch/foreground).
    public func processPending() async {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: nil
        )) ?? []
        for dir in dirs {
            await process(sessionDirectory: dir)
        }
    }

    /// Uploads one session directory (no-op when already uploaded/in flight).
    public func process(sessionDirectory: URL) async {
        let key = sessionDirectory.lastPathComponent
        guard !inFlight.contains(key) else { return }
        guard var manifest = try? SessionManifest.read(from: sessionDirectory) else { return }
        guard !manifest.fullyUploaded else { return }
        guard await api.isLoggedIn else { return }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        // GPX first — it's small and unlocks server-side correlation.
        if !manifest.gpxUploaded {
            let gpxURL = sessionDirectory.appendingPathComponent("track.gpx")
            if let gpx = try? Data(contentsOf: gpxURL) {
                do {
                    let response = try await api.uploadGPSTrack(
                        gpx: gpx,
                        fileName: "\(manifest.sessionID.uuidString).gpx",
                        vehicleID: manifest.vehicleID
                    )
                    manifest.gpxUploaded = true
                    manifest.gpxRemoteTrackID = response.id
                    try? manifest.write(to: sessionDirectory)
                } catch {
                    // Retry on the next processPending() pass.
                }
            } else {
                manifest.gpxUploaded = true
                try? manifest.write(to: sessionDirectory)
            }
            emit(manifest, detail: "GPS track uploaded")
        }

        let uploader = ChunkedVideoUploader(api: api)
        for index in manifest.videos.indices where !manifest.videos[index].uploaded {
            let artifact = manifest.videos[index]
            let fileURL = sessionDirectory.appendingPathComponent(artifact.fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                manifest.videos[index].uploaded = true
                try? manifest.write(to: sessionDirectory)
                continue
            }
            do {
                let remoteID = try await uploader.upload(
                    fileURL: fileURL,
                    durationSeconds: artifact.durationSeconds,
                    existingRemoteID: artifact.remoteID,
                    startChunkIndex: artifact.nextChunkIndex,
                    onChunkUploaded: { [weak self] next, remoteID, progress in
                        await self?.persistChunkProgress(
                            directory: sessionDirectory,
                            fileName: artifact.fileName,
                            nextChunk: next,
                            remoteID: remoteID,
                            fraction: progress.fraction
                        )
                    }
                )
                manifest = (try? SessionManifest.read(from: sessionDirectory)) ?? manifest
                if let i = manifest.videos.firstIndex(where: { $0.fileName == artifact.fileName }) {
                    manifest.videos[i].uploaded = true
                    manifest.videos[i].remoteID = remoteID
                }
                try? manifest.write(to: sessionDirectory)
                emit(manifest, detail: "\(artifact.fileName) uploaded")
            } catch {
                // Chunk cursor is already persisted; retry resumes there.
                emit(manifest, detail: "Upload paused: \(artifact.fileName)")
                return
            }
        }
    }

    private func persistChunkProgress(
        directory: URL,
        fileName: String,
        nextChunk: Int,
        remoteID: String,
        fraction: Double
    ) {
        guard var manifest = try? SessionManifest.read(from: directory),
              let index = manifest.videos.firstIndex(where: { $0.fileName == fileName }) else { return }
        manifest.videos[index].nextChunkIndex = nextChunk
        manifest.videos[index].remoteID = remoteID
        try? manifest.write(to: directory)
        emit(manifest, detail: "Uploading \(fileName) — \(Int(fraction * 100))%")
    }

    private func emit(_ manifest: SessionManifest, detail: String) {
        let totalParts = manifest.videos.count + 1
        let doneParts = manifest.videos.filter(\.uploaded).count + (manifest.gpxUploaded ? 1 : 0)
        let progress = UploadProgress(
            sessionID: manifest.sessionID,
            fraction: Double(doneParts) / Double(totalParts),
            detail: detail
        )
        progressContinuations.values.forEach { $0.yield(progress) }
    }
}

/// Read-only view over the local session directories for the history UI.
public struct SessionLibrary: Sendable {
    public let sessionsRoot: URL

    public init(sessionsRoot: URL) {
        self.sessionsRoot = sessionsRoot
    }

    public func manifests() -> [SessionManifest] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: nil
        )) ?? []
        return dirs
            .compactMap { try? SessionManifest.read(from: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func directory(for sessionID: UUID) -> URL {
        sessionsRoot.appendingPathComponent(sessionID.uuidString)
    }

    /// Frees the local video files for a fully-uploaded session (keeps the
    /// manifest + telemetry for the history list).
    public func deleteVideos(for sessionID: UUID) {
        let dir = directory(for: sessionID)
        guard let manifest = try? SessionManifest.read(from: dir), manifest.fullyUploaded else { return }
        for video in manifest.videos {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(video.fileName))
        }
    }

    public func deleteSession(_ sessionID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: sessionID))
    }
}
