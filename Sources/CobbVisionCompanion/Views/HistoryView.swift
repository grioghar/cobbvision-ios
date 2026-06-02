import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @State private var sessionToUpload: DriveSession?

    var body: some View {
        NavigationView {
            List {
                if sessionStore.sessions.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "location.slash",
                        description: Text("Record a drive to see it here.")
                    )
                } else {
                    ForEach(sessionStore.sessions.reversed()) { session in
                        SessionRow(session: session)
                            .swipeActions(edge: .leading) {
                                if !session.uploaded {
                                    Button("Upload") { sessionToUpload = session }
                                        .tint(.orange)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", role: .destructive) {
                                    sessionStore.delete(session: session)
                                }
                            }
                    }
                }
            }
            .navigationTitle("Sessions")
            .sheet(item: $sessionToUpload) { session in
                UploadSheet(session: session)
                    .environmentObject(sessionStore)
            }
        }
    }
}

private struct SessionRow: View {
    let session: DriveSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                HStack(spacing: 12) {
                    Label(durationString, systemImage: "clock")
                    Label("\(session.pointCount) pts", systemImage: "mappin")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            if session.uploaded {
                Image(systemName: "checkmark.icloud.fill")
                    .foregroundColor(.green)
            } else {
                Image(systemName: "icloud.slash")
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var durationString: String {
        let t = Int(session.duration)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
