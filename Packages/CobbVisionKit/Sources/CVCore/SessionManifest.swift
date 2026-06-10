import Foundation

/// `manifest.json` written into each session directory
/// (`Documents/Sessions/<uuid>/`). Tracks what the session produced and what
/// has been uploaded so `PostSessionUploader` can resume after a crash or kill.
public struct SessionManifest: Codable, Sendable, Hashable {
    public struct VideoArtifact: Codable, Sendable, Hashable {
        public var fileName: String
        public var camera: CameraPosition
        public var durationSeconds: Double?
        /// Remote media id once `POST /api/v1/media/video` has been called.
        public var remoteID: String?
        /// Index of the next chunk to upload (chunks 0..<nextChunkIndex are done).
        public var nextChunkIndex: Int
        public var uploaded: Bool

        public init(
            fileName: String,
            camera: CameraPosition,
            durationSeconds: Double? = nil,
            remoteID: String? = nil,
            nextChunkIndex: Int = 0,
            uploaded: Bool = false
        ) {
            self.fileName = fileName
            self.camera = camera
            self.durationSeconds = durationSeconds
            self.remoteID = remoteID
            self.nextChunkIndex = nextChunkIndex
            self.uploaded = uploaded
        }
    }

    public var sessionID: UUID
    public var presetID: UUID
    public var presetName: String
    public var startedAt: Date
    public var endedAt: Date?
    public var telemetryFileName: String?
    public var gpxUploaded: Bool
    public var gpxRemoteTrackID: String?
    public var videos: [VideoArtifact]
    public var peakG: GPeaks
    public var vehicleID: String?

    public init(
        sessionID: UUID,
        presetID: UUID,
        presetName: String,
        startedAt: Date,
        endedAt: Date? = nil,
        telemetryFileName: String? = nil,
        gpxUploaded: Bool = false,
        gpxRemoteTrackID: String? = nil,
        videos: [VideoArtifact] = [],
        peakG: GPeaks = GPeaks(),
        vehicleID: String? = nil
    ) {
        self.sessionID = sessionID
        self.presetID = presetID
        self.presetName = presetName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.telemetryFileName = telemetryFileName
        self.gpxUploaded = gpxUploaded
        self.gpxRemoteTrackID = gpxRemoteTrackID
        self.videos = videos
        self.peakG = peakG
        self.vehicleID = vehicleID
    }

    public var fullyUploaded: Bool {
        (telemetryFileName == nil || gpxUploaded) && videos.allSatisfy(\.uploaded)
    }

    public static let fileName = "manifest.json"

    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func read(from directory: URL) throws -> SessionManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent(fileName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionManifest.self, from: data)
    }
}
