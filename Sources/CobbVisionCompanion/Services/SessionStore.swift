import Foundation
import Combine

/// Persists completed sessions to disk and manages the upload queue.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [DriveSession] = []

    private let storageURL: URL = {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions.json")
    }()

    init() { load() }

    // MARK: - Public

    func save(session: DriveSession) {
        sessions.append(session)
        persist()
    }

    func delete(session: DriveSession) {
        sessions.removeAll { $0.id == session.id }
        persist()
    }

    /// Export and upload a completed session to CobbVision.
    func upload(session: DriveSession, vehicleId: String) async throws {
        let gpxURL = try GPXExporter.export(session: session)
        let result = try await APIClient.uploadGPX(gpxURL: gpxURL, vehicleId: vehicleId)

        await MainActor.run {
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[idx].uploaded  = true
                sessions[idx].vehicleId = vehicleId
            }
            persist()
        }

        if let analysisURL = result.analysisURL {
            print("[SessionStore] Uploaded session \(result.sessionId) — analysis: \(analysisURL)")
        }
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: storageURL)
        } catch {
            print("[SessionStore] persist error: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([DriveSession].self, from: data)
        else { return }
        sessions = decoded
    }
}
